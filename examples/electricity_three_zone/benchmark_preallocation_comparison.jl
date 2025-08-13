#!/usr/bin/env julia

"""
Benchmark comparison of MacroEnergy.jl electricity three zone example 
with and without variable/constraint preallocation
"""

using MacroEnergy
using Gurobi
using Printf
using BenchmarkTools

println("MacroEnergy.jl Electricity Three Zone - Preallocation Benchmark")
println("="^70)

# Configuration
const NUM_RUNS = 3  # Number of runs for averaging
const SOLVER_ATTRIBUTES = ("Method" => 2, "Crossover" => 1, "BarConvTol" => 1e-4)

"""
Run the electricity three zone case without preallocation (standard approach)
"""
function run_without_preallocation()
    println("\n🚀 Running WITHOUT preallocation (standard approach)...")
    
    # Load and run the case using the standard MacroEnergy approach
    start_time = time()
    
    # Temporarily change to monolithic for simpler comparison
    case_path = @__DIR__
    case = MacroEnergy.load_case(case_path)
    
    # Override to monolithic for simpler performance comparison
    for system in case.systems
        system.settings = merge(system.settings, (SolutionAlgorithm = MacroEnergy.Monolithic(),))
    end
    
    # Create optimizer
    optimizer = MacroEnergy.create_optimizer(Gurobi.Optimizer, missing, SOLVER_ATTRIBUTES)
    
    # Solve case
    (case_result, model) = MacroEnergy.solve_case(case, optimizer)
    total_time = time() - start_time
    
    # Get model statistics
    num_variables = JuMP.num_variables(model)
    num_constraints = JuMP.num_constraints(model, count_variable_in_set_constraints=false)
    termination_status = JuMP.termination_status(model)
    objective_value = JuMP.objective_value(model)
    
    return (
        system = case_result.systems,
        model = model,
        total_time = total_time,
        num_variables = num_variables,
        num_constraints = num_constraints,
        termination_status = termination_status,
        objective_value = objective_value
    )
end

"""
Modified version of the model generation that uses preallocation
Note: This is a proof-of-concept implementation showing how preallocation could be integrated
"""
function generate_model_with_preallocation(case::MacroEnergy.Case)
    println("📊 Generating model WITH preallocation...")
    
    periods = MacroEnergy.get_periods(case)
    settings = MacroEnergy.get_settings(case)
    num_periods = MacroEnergy.number_of_periods(case)

    start_time = time()
    model = Model()
    @variable(model, vREF == 1)

    # Initialize preallocation manager for edges
    edge_managers = Dict{Int, EdgeOptimizationManager}()
    
    fixed_cost = Dict()
    om_fixed_cost = Dict()
    investment_cost = Dict()
    variable_cost = Dict()

    for (period_idx, system) in enumerate(periods)
        @info(" -- Period $period_idx")

        model[:eFixedCost] = AffExpr(0.0)
        model[:eInvestmentFixedCost] = AffExpr(0.0)
        model[:eOMFixedCost] = AffExpr(0.0)
        model[:eVariableCost] = AffExpr(0.0)

        # Collect all edges from this period
        all_edges = MacroEnergy.AbstractEdge[]
        for asset in system.assets
            for field_name in fieldnames(typeof(asset))
                field_value = getfield(asset, field_name)
                if isa(field_value, MacroEnergy.AbstractEdge)
                    push!(all_edges, field_value)
                end
            end
        end
        
        # Create time horizon for this system
        time_horizon = system.time_data[:Electricity].time_steps
        
        # Initialize edge optimization manager with preallocation
        if !isempty(all_edges)
            edge_managers[period_idx] = create_edge_optimization_manager(model, all_edges, time_horizon)
            @info("   -- Preallocated variables and constraints for $(length(all_edges)) edges")
        end

        @info(" -- Adding linking variables")
        MacroEnergy.add_linking_variables!(system, model) 

        @info(" -- Defining available capacity")
        MacroEnergy.define_available_capacity!(system, model)

        @info(" -- Generating planning model")
        MacroEnergy.planning_model!(system, model)

        @info(" -- Including age-based retirements")
        MacroEnergy.add_age_based_retirements!.(system.assets, model)

        if period_idx < num_periods
            @info(" -- Available capacity in period $(period_idx) is being carried over to period $(period_idx+1)")
            MacroEnergy.carry_over_capacities!(periods[period_idx+1], system)
        end

        @info(" -- Generating operational model")
        MacroEnergy.operation_model!(system, model)

        model[:eFixedCost] = model[:eInvestmentFixedCost] + model[:eOMFixedCost]
        fixed_cost[period_idx] = model[:eFixedCost]
        investment_cost[period_idx] = model[:eInvestmentFixedCost]
        om_fixed_cost[period_idx] = model[:eOMFixedCost]
        unregister(model, :eFixedCost)
        unregister(model, :eInvestmentFixedCost)
        unregister(model, :eOMFixedCost)

        variable_cost[period_idx] = model[:eVariableCost]
        unregister(model, :eVariableCost)
    end

    # Add the rest of the standard model generation
    period_lengths = collect(settings.PeriodLengths)
    discount_rate = settings.DiscountRate
    cum_years = [sum(period_lengths[i] for i in 1:s-1; init=0) for s in 1:num_periods]
    discount_factor = 1 ./ ( (1 + discount_rate) .^ cum_years)

    @expression(model, eFixedCostByPeriod[s in 1:num_periods], discount_factor[s] * fixed_cost[s])
    @expression(model, eInvestmentFixedCostByPeriod[s in 1:num_periods], discount_factor[s] * investment_cost[s])
    @expression(model, eOMFixedCostByPeriod[s in 1:num_periods], discount_factor[s] * om_fixed_cost[s])
    @expression(model, eFixedCost, sum(eFixedCostByPeriod[s] for s in 1:num_periods))

    opexmult = [sum([1 / (1 + discount_rate)^(i) for i in 1:period_lengths[s]]) for s in 1:num_periods]
    @expression(model, eVariableCostByPeriod[s in 1:num_periods], discount_factor[s] * opexmult[s] * variable_cost[s])
    @expression(model, eVariableCost, sum(eVariableCostByPeriod[s] for s in 1:num_periods))

    @objective(model, Min, model[:eFixedCost] + model[:eVariableCost])

    generation_time = time() - start_time
    @info(" -- Model generation with preallocation complete, it took $(generation_time) seconds")

    return model, edge_managers
end

"""
Run the electricity three zone case with preallocation
"""
function run_with_preallocation()
    println("\n🚀 Running WITH preallocation...")
    
    start_time = time()
    
    # Load the case
    case = MacroEnergy.load_case(@__DIR__)
    
    # Override to monolithic for simpler performance comparison
    for system in case.systems
        system.settings = merge(system.settings, (SolutionAlgorithm = MacroEnergy.Monolithic(),))
    end
    
    # Generate model with preallocation
    model, edge_managers = generate_model_with_preallocation(case)
    
    # Set up optimizer
    optimizer = MacroEnergy.create_optimizer(Gurobi.Optimizer, missing, SOLVER_ATTRIBUTES)
    set_optimizer(model, optimizer)
    
    # Scale constraints if needed
    if case.systems[1].settings.ConstraintScaling
        @info "Scaling constraints and RHS"
        MacroEnergy.scale_constraints!(model)
    end
    
    # Solve
    optimize!(model)
    
    total_time = time() - start_time
    
    # Get model statistics
    num_variables = JuMP.num_variables(model)
    num_constraints = JuMP.num_constraints(model, count_variable_in_set_constraints=false)
    termination_status = JuMP.termination_status(model)
    objective_value = JuMP.objective_value(model)
    
    return (
        system = case.systems,
        model = model,
        edge_managers = edge_managers,
        total_time = total_time,
        num_variables = num_variables,
        num_constraints = num_constraints,
        termination_status = termination_status,
        objective_value = objective_value
    )
end

"""
Compare results between two runs
"""
function compare_results(result_no_prealloc, result_with_prealloc)
    println("\n📊 COMPARISON RESULTS")
    println("="^50)
    
    # Time comparison
    time_diff = result_with_prealloc.total_time - result_no_prealloc.total_time
    time_pct = (time_diff / result_no_prealloc.total_time) * 100
    
    @printf "⏱️  Total Time:\n"
    @printf "   Without preallocation: %.3f seconds\n" result_no_prealloc.total_time
    @printf "   With preallocation:    %.3f seconds\n" result_with_prealloc.total_time
    @printf "   Difference:            %+.3f seconds (%+.1f%%)\n" time_diff time_pct
    
    # Model size comparison
    println("\n📈 Model Size:")
    @printf "   Variables:   %d (no prealloc) vs %d (with prealloc)\n" result_no_prealloc.num_variables result_with_prealloc.num_variables
    @printf "   Constraints: %d (no prealloc) vs %d (with prealloc)\n" result_no_prealloc.num_constraints result_with_prealloc.num_constraints
    
    # Solution comparison
    println("\n🎯 Solution Quality:")
    @printf "   Status: %s (no prealloc) vs %s (with prealloc)\n" result_no_prealloc.termination_status result_with_prealloc.termination_status
    
    if result_no_prealloc.termination_status == result_with_prealloc.termination_status == JuMP.OPTIMAL
        obj_diff = abs(result_with_prealloc.objective_value - result_no_prealloc.objective_value)
        obj_rel_diff = obj_diff / abs(result_no_prealloc.objective_value)
        
        @printf "   Objective:  %.2f (no prealloc) vs %.2f (with prealloc)\n" result_no_prealloc.objective_value result_with_prealloc.objective_value
        @printf "   Difference: %.6f (relative: %.2e)\n" obj_diff obj_rel_diff
        
        if obj_rel_diff < 1e-6
            println("   ✅ Solutions are numerically identical")
        else
            println("   ⚠️  Solutions differ")
        end
    end
    
    # Performance summary
    println("\n🏆 Performance Summary:")
    if time_pct < -5
        println("   ✅ Preallocation provides significant speedup")
    elseif time_pct < 5
        println("   ≈ Preallocation has similar performance")
    else
        println("   ❌ Preallocation adds overhead")
    end
    
    return (time_improvement = -time_pct, model_size_same = (result_no_prealloc.num_variables == result_with_prealloc.num_variables))
end

"""
Run multiple trials and average results
"""
function run_benchmark_trials(num_trials::Int = NUM_RUNS)
    println("🔄 Running $num_trials trials for statistical significance...\n")
    
    results_no_prealloc = []
    results_with_prealloc = []
    
    for trial in 1:num_trials
        println("Trial $trial/$num_trials")
        println("-" * "^15")
        
        # Run without preallocation
        try
            result_no = run_without_preallocation()
            push!(results_no_prealloc, result_no)
        catch e
            println("❌ Trial $trial failed without preallocation: $e")
            continue
        end
        
        # Run with preallocation  
        try
            result_with = run_with_preallocation()
            push!(results_with_prealloc, result_with)
        catch e
            println("❌ Trial $trial failed with preallocation: $e")
            continue
        end
        
        println("✅ Trial $trial completed successfully\n")
    end
    
    if length(results_no_prealloc) != length(results_with_prealloc) || isempty(results_no_prealloc)
        error("Not all trials completed successfully")
    end
    
    # Calculate averages
    avg_time_no_prealloc = mean([r.total_time for r in results_no_prealloc])
    avg_time_with_prealloc = mean([r.total_time for r in results_with_prealloc])
    
    println("\n📈 AVERAGE RESULTS OVER $num_trials TRIALS")
    println("="^50)
    @printf "Average time without preallocation: %.3f ± %.3f seconds\n" avg_time_no_prealloc std([r.total_time for r in results_no_prealloc])
    @printf "Average time with preallocation:    %.3f ± %.3f seconds\n" avg_time_with_prealloc std([r.total_time for r in results_with_prealloc])
    
    avg_improvement = ((avg_time_no_prealloc - avg_time_with_prealloc) / avg_time_no_prealloc) * 100
    @printf "Average improvement: %+.1f%%\n" avg_improvement
    
    # Compare first successful runs
    if !isempty(results_no_prealloc) && !isempty(results_with_prealloc)
        compare_results(results_no_prealloc[1], results_with_prealloc[1])
    end
    
    return results_no_prealloc, results_with_prealloc
end

# Utility functions
function mean(arr)
    return sum(arr) / length(arr)
end

function std(arr)
    μ = mean(arr)
    return sqrt(sum((x - μ)^2 for x in arr) / length(arr))
end

# Main execution
function main()
    try
        println("Starting MacroEnergy.jl preallocation benchmark for electricity three zone example...")
        println("This will compare performance with and without variable/constraint preallocation.\n")
        
        # Run benchmark trials
        results_no_prealloc, results_with_prealloc = run_benchmark_trials(NUM_RUNS)
        
        println("\n🎉 Benchmark completed successfully!")
        println("\n💡 Note: This benchmark shows a proof-of-concept integration of the preallocation system.")
        println("   The preallocation system exists in MacroEnergy.jl but is not used in the main workflow by default.")
        println("   Real benefits would be seen in scenarios with:")
        println("   - Multiple model builds")
        println("   - Frequent variable/constraint access")
        println("   - Large-scale models with many edges")
        println("   - Iterative optimization workflows")
        
    catch e
        println("\n❌ Benchmark failed with error: $e")
        println("\nStacktrace:")
        for (i, frame) in enumerate(stacktrace(catch_backtrace()))
            println("  $i. $frame")
        end
        rethrow(e)
    end
end

# Run the benchmark
main()
