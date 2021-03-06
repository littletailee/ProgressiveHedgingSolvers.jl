# ------------------------------------------------------------
# Parallel -> Algorithm is run in parallel
# ------------------------------------------------------------
@define_trait Parallel = begin
    Synchronous
    Asynchronous
end

@define_traitfn Parallel init_subproblems!(ph::AbstractProgressiveHedgingSolver{T,A,S}, subsolver::QPSolver) where {T <: Real, A <: AbstractVector, S <: LQSolver} = begin
    function init_subproblems!(ph::AbstractProgressiveHedgingSolver{T,A,S}, subsolver::QPSolver, !Parallel) where {T <: Real, A <: AbstractVector, S <: LQSolver}
        # Prepare the subproblems
        m = ph.stochasticprogram
        load_subproblems!(ph, subsolver)
        update_iterate!(ph)
        return ph
    end

    function init_subproblems!(ph::AbstractProgressiveHedgingSolver{T,A,S}, subsolver::QPSolver, Parallel) where {T <: Real, A <: AbstractVector, S <: LQSolver}
        # Create subproblems on worker processes
        m = ph.stochasticprogram
        @sync begin
            for w in workers()
                ph.subworkers[w-1] = RemoteChannel(() -> Channel{Vector{SubProblem{T,A,S}}}(1), w)
                @async load_worker!(scenarioproblems(m), m, w, ph.subworkers[w-1], subsolver)
            end
            # Prepare memory
            log_val = ph.parameters.log
            ph.parameters.log = false
            log!(ph)
            ph.parameters.log = log_val
        end
        update_iterate!(ph)
        return ph
    end
end

@define_traitfn Parallel iterate!(ph::AbstractProgressiveHedgingSolver) = begin
    function iterate!(ph::AbstractProgressiveHedgingSolver, !Parallel)
        iterate_nominal!(ph)
    end

    function iterate!(ph::AbstractProgressiveHedgingSolver, Synchronous)
        iterate_nominal!(ph)
    end

    function iterate!(ph::AbstractProgressiveHedgingSolver, Asynchronous)
        iterate_async!(ph)
    end
end

@define_traitfn Parallel resolve_subproblems!(ph::AbstractProgressiveHedgingSolver{T,A}) where {T <: Real, A <: AbstractVector} = begin
    function resolve_subproblems!(ph::AbstractProgressiveHedgingSolver{T,A}, !Parallel) where {T <: Real, A <: AbstractVector}
        Qs = A(undef, length(ph.subproblems))
        # Update subproblems
        reformulate_subproblems!(ph.subproblems, ph.ξ, penalty(ph))
        # Solve sub problems
        for (i, subproblem) ∈ enumerate(ph.subproblems)
            Qs[i] = subproblem()
        end
        # Return current objective value
        return sum(Qs)
    end
end

@define_traitfn Parallel update_iterate!(ph::AbstractProgressiveHedgingSolver) = begin
    function update_iterate!(ph::AbstractProgressiveHedgingSolver, !Parallel)
        # Update the estimate
        ξ_prev = copy(ph.ξ)
        ph.ξ[:] = sum([subproblem.π*subproblem.x for subproblem in ph.subproblems])
        # Update δ₁
        ph.solverdata.δ₁ = norm(ph.ξ-ξ_prev, 2)^2
        return nothing
    end
end

@define_traitfn Parallel update_subproblems!(ph::AbstractProgressiveHedgingSolver) = begin
    function update_subproblems!(ph::AbstractProgressiveHedgingSolver, !Parallel)
        # Update dual prices
        update_subproblems!(ph.subproblems, ph.ξ, penalty(ph))
        return nothing
    end
end

@define_traitfn Parallel update_dual_gap!(ph::AbstractProgressiveHedgingSolver{T}) where T <: Real = begin
    function update_dual_gap!(ph::AbstractProgressiveHedgingSolver{T}, !Parallel) where T <: Real
        # Update δ₂
        ph.solverdata.δ₂ = sum([s.π*norm(s.x-ph.ξ,2)^2 for s in ph.subproblems])
        return nothing
    end

    function update_dual_gap!(ph::AbstractProgressiveHedgingSolver{T}, Parallel) where T <: Real
        # Update δ₂
        partial_δs = Vector{Float64}(undef, nworkers())
        @sync begin
            for (i,w) in enumerate(workers())
                @async partial_δs[i] = remotecall_fetch((sw,ξ)->begin
                    subproblems = fetch(sw)
                    if length(subproblems) > 0
                        return sum([s.π*norm(s.x-ξ,2)^2 for s in subproblems])
                    else
                        return zero(T)
                    end
                end,
                w,
                ph.subworkers[w-1],
                ph.ξ)
            end
        end
        ph.solverdata.δ₂ = sum(partial_δs)
        return nothing
    end
end

@define_traitfn Parallel calculate_objective_value(ph::AbstractProgressiveHedgingSolver{T}) where T <: Real = begin
    function calculate_objective_value(ph::AbstractProgressiveHedgingSolver{T}, !Parallel) where T <: Real
        return sum([get_objective_value(s) for s in ph.subproblems])
    end

    function calculate_objective_value(ph::AbstractProgressiveHedgingSolver{T}, Parallel) where T <: Real
        partial_objectives = Vector{Float64}(undef, nworkers())
        @sync begin
            for (i,w) in enumerate(workers())
                @async partial_objectives[i] = remotecall_fetch((sw)->begin
                    subproblems = fetch(sw)
                    if length(subproblems) > 0
                        return sum([get_objective_value(s) for s in subproblems])
                    else
                        return zero(T)
                    end
                end,
                w,
                ph.subworkers[w-1])
            end
        end
        return sum(partial_objectives)
    end
end

@define_traitfn Parallel fill_submodels!(ph::AbstractProgressiveHedgingSolver, scenarioproblems::StochasticPrograms.ScenarioProblems) = begin
    function fill_submodels!(ph::AbstractProgressiveHedgingSolver, scenarioproblems::StochasticPrograms.ScenarioProblems, !Parallel)
        for (i, submodel) in enumerate(scenarioproblems.problems)
            fill_submodel!(submodel, ph.subproblems[i])
        end
    end

    function fill_submodels!(ph::AbstractProgressiveHedgingSolver, scenarioproblems::StochasticPrograms.ScenarioProblems, Parallel)
        j = 0
        @sync begin
            for w in workers()
                n = remotecall_fetch((sw)->length(fetch(sw)), w, ph.subworkers[w-1])
                for i = 1:n
                    k = i+j
                    @async fill_submodel!(scenarioproblems.problems[k],remotecall_fetch((sw,i,x)->begin
                        sp = fetch(sw)[i]
                        get_solution(sp)
                    end,
                    w,
                    ph.subworkers[w-1],
                    i,
                    ph.ξ)...)
                end
                j += n
            end
        end
    end
end

@define_traitfn Parallel fill_submodels!(ph::AbstractProgressiveHedgingSolver, scenarioproblems::StochasticPrograms.DScenarioProblems) = begin
    function fill_submodels!(ph::AbstractProgressiveHedgingSolver, scenarioproblems::StochasticPrograms.DScenarioProblems, !Parallel)
        j = 0
        @sync begin
            for w in workers()
                n = remotecall_fetch((sp)->length(fetch(sp).problems), w, scenarioproblems[w-1])
                for i in 1:n
                    k = i+j
                    @async remotecall_fetch((sp,i,x,μ,λ) -> fill_submodel!(fetch(sp).problems[i],x,μ,λ),
                                            w,
                                            scenarioproblems[w-1],
                                            i,
                                            get_solution(ph.subproblems[k])...)
                end
                j += n
            end
        end
    end

    function fill_submodels!(ph::AbstractProgressiveHedgingSolver, scenarioproblems::StochasticPrograms.DScenarioProblems, Parallel)
        @sync begin
            for w in workers()
                @async remotecall(fill_submodels!,
                                  w,
                                  ph.subworkers[w-1],
                                  ph.ξ,
                                  scenarioproblems[w-1])
            end
        end
    end
end

SubWorker{T,A,S} = RemoteChannel{Channel{Vector{SubProblem{T,A,S}}}}
ScenarioProblems{D,S} = RemoteChannel{Channel{StochasticPrograms.ScenarioProblems{D,S}}}

function load_subproblems!(ph::AbstractProgressiveHedgingSolver{T,A}, subsolver::MPB.AbstractMathProgSolver) where {T <: Real, A <: AbstractVector}
    for i = 1:ph.nscenarios
        push!(ph.subproblems,SubProblem(WS(ph.stochasticprogram, scenario(ph.stochasticprogram,i); solver = subsolver),
                                        i,
                                        probability(ph.stochasticprogram,i),
                                        decision_length(ph.stochasticprogram),
                                        subsolver))
    end
    return ph
end

function load_worker!(scenarioproblems::StochasticPrograms.ScenarioProblems,
                      sp::StochasticProgram,
                      w::Integer,
                      worker::SubWorker,
                      subsolver::QPSolver)
    n = StochasticPrograms.nscenarios(scenarioproblems)
    (nscen, extra) = divrem(n, nworkers())
    prev = [nscen + (extra + 2 - p > 0) for p in 2:(w-1)]
    start = isempty(prev) ? 1 : sum(prev) + 1
    stop = min(start + nscen + (extra + 2 - w > 0) - 1, n)
    return remotecall_fetch(init_subworker!,
                            w,
                            worker,
                            generator(sp, :stage_1),
                            generator(sp, :stage_2),
                            first_stage_data(sp),
                            second_stage_data(sp),
                            scenarios(sp)[start:stop],
                            decision_length(sp),
                            subsolver,
                            start)
end

function load_worker!(scenarioproblems::StochasticPrograms.DScenarioProblems,
                      sp::StochasticProgram,
                      w::Integer,
                      worker::SubWorker,
                      subsolver::QPSolver)
    leading_scen = [scenarioproblems.scenario_distribution[p-1] for p in 2:(w-1)]
    start_id = isempty(leading_scen) ? 1 : sum(leading_scen)+1
    return remotecall_fetch(init_subworker!,
                            w,
                            worker,
                            generator(sp, :stage_1),
                            generator(sp, :stage_2),
                            first_stage_data(sp),
                            scenarioproblems[w-1],
                            decision_length(sp),
                            subsolver,
                            start_id)
end

function init_subworker!(subworker::SubWorker{T,A,S},
                         stage_one_generator::Function,
                         stage_two_generator::Function,
                         first_stage::Any,
                         second_stage::Any,
                         scenarios::Vector{<:AbstractScenario},
                         xdim::Integer,
                         subsolver::QPSolver,
                         start_id::Integer) where {T <: Real, A <: AbstractArray, S <: LQSolver}
    subproblems = Vector{SubProblem{T,A,S}}(undef, length(scenarios))
    id = start_id
    solver = get_solver(subsolver)
    for (i,scenario) = enumerate(scenarios)
        subproblems[i] = SubProblem(_WS(stage_one_generator, stage_two_generator, first_stage, second_stage, scenario, solver),
                                    id,
                                    probability(scenario),
                                    xdim,
                                    solver)
        id += 1
    end
    put!(subworker, subproblems)
end

function init_subworker!(subworker::SubWorker{T,A,S},
                         stage_one_generator::Function,
                         stage_two_generator::Function,
                         first_stage::Any,
                         scenarioproblems::ScenarioProblems,
                         xdim::Integer,
                         subsolver::QPSolver,
                         start_id::Integer) where {T <: Real, A <: AbstractArray, S <: LQSolver}
    sp = fetch(scenarioproblems)
    subproblems = Vector{SubProblem{T,A,S}}(undef, StochasticPrograms.nscenarios(sp))
    id = start_id
    solver = get_solver(subsolver)
    for (i,scenario) = enumerate(scenarios(sp))
        subproblems[i] = SubProblem(_WS(stage_one_generator, stage_two_generator, first_stage, stage_data(sp), scenario, solver),
                                    id,
                                    probability(scenario),
                                    xdim,
                                    solver)
        id += 1
    end
    put!(subworker, subproblems)
end

function fill_submodels!(subworker::SubWorker{T,A,S},
                         x::A,
                         scenarioproblems::ScenarioProblems) where {T <: Real, A <: AbstractArray, S <: LQSolver}
    sp = fetch(scenarioproblems)
    subproblems::Vector{SubProblem{T,A,S}} = fetch(subworker)
    for (i, submodel) in enumerate(sp.problems)
        fill_submodel!(submodel, subproblems[i])
    end
end

function fill_submodel!(submodel::JuMP.Model, subproblem::SubProblem)
    fill_submodel!(submodel, get_solution(subproblem)...)
end

function fill_submodel!(submodel::JuMP.Model, x::AbstractVector, μ::AbstractVector, λ::AbstractVector)
    submodel.colVal = x
    submodel.redCosts = μ
    submodel.linconstrDuals = λ
    submodel.objVal = JuMP.prepAffObjective(submodel)⋅x
end
