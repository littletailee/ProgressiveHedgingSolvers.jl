@implement_traitfn function init_subproblems!(ph::AbstractProgressiveHedgingSolver{T,A,S}, subsolver::QPSolver, Asynchronous) where {T <: Real, A <: AbstractVector, S <: LQSolver}
    @unpack κ = ph.parameters
    # Partitioning
    (jobsize, extra) = divrem(ph.nscenarios, nworkers())
    # One extra to guarantee coverage
    if extra > 0
        jobsize += 1
    end
    # Create subproblems on worker processes
    m = ph.stochasticprogram
    start = 1
    stop = jobsize
    active_workers = Vector{Future}(undef, nworkers())
    @sync begin
        for w in workers()
            ph.subworkers[w-1] = RemoteChannel(() -> Channel{Vector{SubProblem{T,A,S}}}(1), w)
            @async load_worker!(scenarioproblems(m), m, w, ph.subworkers[w-1], subsolver)
        end
    end
    @sync begin
        # Continue preparation
        for w in workers()
            ph.work[w-1] = RemoteChannel(() -> Channel{Int}(round(Int,10/κ)), w)
            @async ph.x̄[w-1] = remotecall_fetch((sw, xdim)->begin
                subproblems = fetch(sw)
                if length(subproblems) > 0
                    x̄ = sum([s.π*s.x for s in subproblems])
                    return RemoteChannel(()->RunningAverageChannel(x̄, [s.x for s in subproblems]), myid())
                else
                    return RemoteChannel(()->RunningAverageChannel(zeros(T,xdim), Vector{A}()), myid())
                end
            end, w, ph.subworkers[w-1], decision_length(m))
            @async ph.δ[w-1] = remotecall_fetch((sw, xdim)->RemoteChannel(()->RunningAverageChannel(zero(T), fill(zero(T),length(fetch(sw))))), w, ph.subworkers[w-1], decision_length(m))
            put!(ph.work[w-1], 1)
        end
        # Prepare memory
        push!(ph.subobjectives, zeros(nscenarios(ph)))
        push!(ph.finished, 0)
        log_val = ph.parameters.log
        ph.parameters.log = false
        log!(ph)
        ph.parameters.log = log_val
    end
    update_iterate!(ph)
    # Init δ₂
    @sync begin
        for w in workers()
            @async remotecall_fetch((sw,ξ,δ)->begin
                for (i,s) ∈ enumerate(fetch(sw))
                    take!(δ, i)
                    put!(δ, i, norm(s.x - ξ, 2)^2, s.π)
                end
            end, w, ph.subworkers[w-1], ph.ξ, ph.δ[w-1])
        end
    end
    return ph
end

@implement_traitfn function update_iterate!(ph::AbstractProgressiveHedgingSolver, Asynchronous)
    ξ_prev = copy(ph.ξ)
    ph.ξ[:] = sum(fetch.(ph.x̄))
    # Update δ₁
    ph.solverdata.δ₁ = norm(ph.ξ-ξ_prev, 2)^2
    return nothing
end

@implement_traitfn function update_dual_gap!(ph::AbstractProgressiveHedgingSolver{T}, Asynchronous) where T <: Real
    ph.solverdata.δ₂ = sum(fetch.(ph.δ))
    return nothing
end

@define_traitfn Parallel init_workers!(ph::AbstractProgressiveHedgingSolver) = begin
    function init_workers!(ph::AbstractProgressiveHedgingSolver, Asynchronous)
        # Load initial decision
        put!(ph.decisions, 1, ph.ξ)
        put!(ph.r, 1, penalty(ph))
        for w in workers()
            ph.active_workers[w-1] = remotecall(work_on_subproblems!,
                                                w,
                                                ph.subworkers[w-1],
                                                ph.work[w-1],
                                                ph.progressqueue,
                                                ph.x̄[w-1],
                                                ph.δ[w-1],
                                                ph.decisions,
                                                ph.r)
        end
        return nothing
    end
end

@define_traitfn Parallel close_workers!(ph::AbstractProgressiveHedgingSolver) = begin
    function close_workers!(ph::AbstractProgressiveHedgingSolver, Asynchronous)
        map(wait, ph.active_workers)
    end
end

mutable struct IterationChannel{D} <: AbstractChannel{D}
    data::Dict{Int,D}
    cond_take::Condition
    IterationChannel(data::Dict{Int,D}) where D = new{D}(data, Condition())
end

function put!(channel::IterationChannel, t, x)
    channel.data[t] = copy(x)
    notify(channel.cond_take)
    return channel
end

function take!(channel::IterationChannel, t)
    x = fetch(channel, t)
    delete!(channel.data, t)
    return x
end

isready(channel::IterationChannel) = length(channel.data) > 1
isready(channel::IterationChannel, t) = haskey(channel.data, t)

function fetch(channel::IterationChannel, t)
    wait(channel, t)
    return channel.data[t]
end

function wait(channel::IterationChannel, t)
    while !isready(channel, t)
        wait(channel.cond_take)
    end
end

mutable struct RunningAverageChannel{D} <: AbstractChannel{D}
    average::D
    data::Vector{D}
    buffer::Dict{Int,D}
    cond_put::Condition
    RunningAverageChannel(average::D, data::Vector{D}) where D = new{D}(average, data, Dict{Int,D}(), Condition())
end

function take!(channel::RunningAverageChannel, i::Integer)
    channel.buffer[i] = copy(channel.data[i])
end

function put!(channel::RunningAverageChannel, i::Integer, π::AbstractFloat)
    channel.average -= π*channel.buffer[i]
    channel.average += π*channel.data[i]
    delete!(channel.buffer, i)
    notify(channel.cond_put)
    return channel
end

function put!(channel::RunningAverageChannel{D}, i::Integer, x::D, π::AbstractFloat) where D
    channel.average -= π*channel.buffer[i]
    channel.average += π*x
    channel.data[i] = copy(x)
    delete!(channel.buffer, i)
    notify(channel.cond_put)
    return channel
end

isready(channel::RunningAverageChannel) = length(channel.buffer) == 0

function fetch(channel::RunningAverageChannel)
    wait(channel)
    return channel.average
end

function fetch(channel::RunningAverageChannel, i::Integer)
    return channel.data[i]
end

function wait(channel::RunningAverageChannel)
    while !isready(channel)
        wait(channel.cond_put)
    end
end

Work = RemoteChannel{Channel{Int}}
IteratedValue{T <: AbstractFloat} = RemoteChannel{IterationChannel{T}}
RunningAverage{D} = RemoteChannel{RunningAverageChannel{D}}
Decisions{A <: AbstractArray} = RemoteChannel{IterationChannel{A}}
Progress{T <: AbstractFloat} = Tuple{Int,Int,T}
ProgressQueue{T <: AbstractFloat} = RemoteChannel{Channel{Progress{T}}}

function work_on_subproblems!(subworker::SubWorker{T,A,S},
                              work::Work,
                              progress::ProgressQueue{T},
                              x̄::RunningAverage{A},
                              δ::RunningAverage{T},
                              decisions::Decisions{A},
                              r::IteratedValue{T}) where {T <: Real, A <: AbstractArray, S <: LQSolver}
    subproblems::Vector{SubProblem{T,A,S}} = fetch(subworker)
    if isempty(subproblems)
       # Workers has nothing do to, return.
       return
    end
    while true
        t::Int = try
            wait(work)
            take!(work)
        catch err
            if err isa InvalidStateException
                # Master closed the work channel. Worker finished
                return
            end
        end
        if t == -1
            # Worker finished
            return
        end
        ξ::A = fetch(decisions, t)
        if t > 1
            update_subproblems!(subproblems, ξ, fetch(r,t-1))
        end
        @sync for (i,subproblem) ∈ enumerate(subproblems)
            @async begin
                take!(δ, i)
                take!(x̄, i)
                put!(δ, i, norm(subproblem.x - ξ, 2)^2, subproblem.π)
                reformulate_subproblem!(subproblem, ξ, fetch(r,t))
                Q::T = subproblem()
                put!(x̄, i, subproblem.π)
                put!(progress, (t,subproblem.id,Q))
            end
        end
    end
end

function calculate_tau!(ph::AbstractProgressiveHedgingSolver{T}) where T <: Real
    active_workers = Vector{Future}(undef, nworkers())
    for w in workers()
        active_workers[w-1] = remotecall(collect_primals, w, ph.subworkers[w-1], length(ph.ξ))
    end
end

function calculate_theta!(ph::AbstractProgressiveHedgingSolver{T}, t::Integer) where T <: Real
    @unpack τ = ph.solverdata
    @unpack ν = ph.parameters
    partial_thetas = Vector{T}(undef, nworkers())
    @sync begin
        for (i,w) in enumerate(workers())
            partial_thetas[i] = remotecall_fetch(calculate_theta_part, w, ph.subworkers[w-1], ph.ȳ[w-1], fetch(ph.decisions, t))
        end
    end
    # Update θ
    ph.solverdata.θ = (ν/τ)*max(0, sum(partial_thetas))
end

function calculate_theta_part(subworker::SubWorker{T,A,S}, ȳ::RunningAverage{A}, ξ::AbstractVector) where {T <: Real, A <: AbstractArray, S <: LQSolver}
    subproblems::Vector{SubProblem{T,A,S}} = fetch(subworker)
    if length(subproblems) > 0
        return sum([subproblem.π*(ξ-subproblem.x)⋅(subproblem.ρ-fetch(ȳ)) for subproblem in subproblems])
    else
        return zero(T)
    end
end

function iterate_async!(ph::AbstractProgressiveHedgingSolver{T}) where T <: Real
    wait(ph.progressqueue)
    while isready(ph.progressqueue)
        # Add new cuts from subworkers
        t::Int, i::Int, Q::T = take!(ph.progressqueue)
        if Q == Inf
            @warn "Subproblem $(i) is infeasible, aborting procedure."
            return :Infeasible
        end
        ph.subobjectives[t][i] = Q
        ph.finished[t] += 1
        if ph.finished[t] == nscenarios(ph)
            # Update objective
            ph.Q_history[t] = current_objective_value(ph, ph.subobjectives[t])
            ph.solverdata.Q = ph.Q_history[t]
        end
    end
    # Project and generate new iterate
    t = ph.solverdata.iterations
    if ph.finished[t] >= ph.parameters.κ*nscenarios(ph)
        # Get dual gap
        update_dual_gap!(ph)
        # Update progress
        @unpack δ₁, δ₂ = ph.solverdata
        ph.dual_gaps[t] = δ₂
        ph.solverdata.δ = sqrt(δ₁ + δ₂)/(1e-10+norm(ph.ξ,2))
        # Check if optimal
        if check_optimality(ph)
            # Optimal, tell workers to stop
            map((w,aw)->!isready(aw) && put!(w,t), ph.work, ph.active_workers)
            map((w,aw)->!isready(aw) && put!(w,-1), ph.work, ph.active_workers)
            # Final log
            log!(ph)
            return :Optimal
        end
        # Update penalty (if applicable)
        update_penalty!(ph)
        # Update iterate
        update_iterate!(ph)
        # Send new work to workers
        put!(ph.decisions, t+1, ph.ξ)
        put!(ph.r, t+1, penalty(ph))
        map((w,aw)->!isready(aw) && put!(w,t+1), ph.work, ph.active_workers)
        # Prepare memory for next iteration
        push!(ph.subobjectives, zeros(nscenarios(ph)))
        push!(ph.finished, 0)
        # Log progress
        log!(ph)
    end
    # Just return a valid status for this iteration
    return :Valid
end
