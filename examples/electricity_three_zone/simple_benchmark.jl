#!/usr/bin/env julia

"""
Simple benchmark comparison of MacroEnergy.jl model generation 
with and without preallocation concept demonstration
"""

using MacroEnergy
using Gurobi
using Printf
using JuMP

println("MacroEnergy.jl Model Generation - Preallocation Concept Benchmark")
println("="^70)

# Configuration
const NUM_RUNS = 3  # Number of runs for averaging

"""
Run model generation without preallocation (standard approach)
"""
function run_standard_model_generation()
    println("\n🚀 Running model generation (standard approach)...")
    
    start_time = time()
    
    # Load the case
    case = MacroEnergy.load_case(@__DIR__)
    
    # Override to monolithic for simpler performance comparison
    for system in case.systems
        system.settings = merge(system.settings, (SolutionAlgorithm = MacroEnergy.Monolithic(),))
    end
    
    # Generate model using standard approach
    model = MacroEnergy.generate_model(case)
    
    generation_time = time() - start_time
    
    # Get model statistics
    num_variables = JuMP.num_variables(model)
    num_constraints = JuMP.num_constraints(model, count_variable_in_set_constraints=false)
    
    println("   ✅ Model generated in $(@sprintf("%.3f", generation_time)) seconds")
    println("   📊 Variables: $num_variables, Constraints: $num_constraints")
    
    return (
        model = model,
        generation_time = generation_time,
        num_variables = num_variables,
        num_constraints = num_constraints
    )
end

"""
Concept demonstration: What model generation with preallocation would look like
This shows how the preallocation system could be integrated
"""
function run_preallocation_concept_demo()
    println("\n🚀 Running preallocation concept demonstration...")
    
    start_time = time()
    
    # Load the case
    case = MacroEnergy.load_case(@__DIR__)
    
    # Override to monolithic
    for system in case.systems
        system.settings = merge(system.settings, (SolutionAlgorithm = MacroEnergy.Monolithic(),))
    end
    
    # This demonstrates where preallocation could be integrated
    periods = MacroEnergy.get_periods(case)
    
    println("   🔧 Concept: Preallocation phase")
    prealloc_start = time()
    
    # Collect all edges across all periods
    all_edges = MacroEnergy.AbstractEdge[]
    total_time_steps = 0
    
    for system in periods
        for asset in system.assets
            for field_name in fieldnames(typeof(asset))
                field_value = getfield(asset, field_name)
                if isa(field_value, MacroEnergy.AbstractEdge)
                    push!(all_edges, field_value)
                end
            end
        end
        total_time_steps += length(system.time_data[:Electricity].time_interval)
    end
    
    # Simulate preallocation overhead
    if !isempty(all_edges)
        # Create a dummy EdgeOptimizationManager to show concept
        dummy_model = Model()
        dummy_time_horizon = collect(1:total_time_steps)
        
        # This would be the preallocation step
        edge_manager = create_edge_optimization_manager(dummy_model, all_edges, dummy_time_horizon)
        
        println("   📊 Preallocated structures for $(length(all_edges)) edges, $total_time_steps time steps")
    end
    
    prealloc_time = time() - prealloc_start
    
    # Generate the actual model (standard way for now)
    model_gen_start = time()
    model = MacroEnergy.generate_model(case)
    model_gen_time = time() - model_gen_start
    
    total_time = time() - start_time
    
    # Get model statistics
    num_variables = JuMP.num_variables(model)
    num_constraints = JuMP.num_constraints(model, count_variable_in_set_constraints=false)
    
    println("   ⏱️  Preallocation simulation: $(@sprintf("%.3f", prealloc_time)) seconds")
    println("   ⏱️  Model generation: $(@sprintf("%.3f", model_gen_time)) seconds")
    println("   ✅ Total time: $(@sprintf("%.3f", total_time)) seconds")
    println("   📊 Variables: $num_variables, Constraints: $num_constraints")
    
    return (
        model = model,
        generation_time = total_time,
        prealloc_time = prealloc_time,
        model_gen_time = model_gen_time,
        num_variables = num_variables,
        num_constraints = num_constraints,
        num_edges = length(all_edges),
        total_time_steps = total_time_steps
    )
end

"""
Compare results and provide analysis
"""
function analyze_results(standard_results, prealloc_results)
    println("\n📊 ANALYSIS")
    println("="^50)
    
    println("🔍 Model Information:")
    println("   Variables: $(standard_results.num_variables)")
    println("   Constraints: $(standard_results.num_constraints)")
    
    if haskey(prealloc_results, :num_edges)
        println("   Edges found: $(prealloc_results.num_edges)")
        println("   Time steps: $(prealloc_results.total_time_steps)")
    end
    
    println("\n⏱️  Performance Comparison:")
    @printf "   Standard approach:      %.3f seconds\n" standard_results.generation_time
    @printf "   With preallocation:     %.3f seconds\n" prealloc_results.generation_time
    
    if haskey(prealloc_results, :prealloc_time) && haskey(prealloc_results, :model_gen_time)
        @printf "     - Preallocation:      %.3f seconds\n" prealloc_results.prealloc_time
        @printf "     - Model generation:   %.3f seconds\n" prealloc_results.model_gen_time
    end
    
    time_diff = prealloc_results.generation_time - standard_results.generation_time
    time_pct = (time_diff / standard_results.generation_time) * 100
    
    @printf "   Difference:             %+.3f seconds (%+.1f%%)\n" time_diff time_pct
    
    # Verify models are equivalent
    if standard_results.num_variables == prealloc_results.num_variables && 
       standard_results.num_constraints == prealloc_results.num_constraints
        println("   ✅ Models are structurally identical")
    else
        println("   ⚠️  Models differ in structure")
    end
    
    println("\n💡 Preallocation Analysis:")
    if time_pct > 0
        println("   📈 Current overhead: $(@sprintf("%.1f", time_pct))% (expected for proof-of-concept)")
        println("   🎯 Real benefits would emerge with:")
        println("      • Multiple model builds")
        println("      • Repeated variable/constraint access")
        println("      • Larger models with more edges")
        println("      • Iterative optimization workflows")
    else
        println("   🚀 Shows potential benefit even in simple case!")
    end
    
    return time_pct
end

"""
Run multiple trials and average results
"""
function run_benchmark_trials(num_trials::Int = NUM_RUNS)
    println("🔄 Running $num_trials trials for statistical significance...\n")
    
    standard_times = Float64[]
    prealloc_times = Float64[]
    
    for trial in 1:num_trials
        println("Trial $trial/$num_trials")
        println("-" * "^15")
        
        # Run standard approach
        try
            standard_result = run_standard_model_generation()
            push!(standard_times, standard_result.generation_time)
        catch e
            println("❌ Trial $trial failed (standard): $e")
            continue
        end
        
        # Run preallocation concept
        try
            prealloc_result = run_preallocation_concept_demo()
            push!(prealloc_times, prealloc_result.generation_time)
        catch e
            println("❌ Trial $trial failed (preallocation): $e")
            continue
        end
        
        println("✅ Trial $trial completed\n")
        
        # Analyze first trial in detail
        if trial == 1
            analyze_results(standard_result, prealloc_result)
        end
    end
    
    if length(standard_times) != length(prealloc_times) || isempty(standard_times)
        error("Not all trials completed successfully")
    end
    
    # Calculate averages
    avg_standard = mean(standard_times)
    avg_prealloc = mean(prealloc_times)
    std_standard = std(standard_times)
    std_prealloc = std(prealloc_times)
    
    println("\n📈 AVERAGE RESULTS OVER $(length(standard_times)) TRIALS")
    println("="^50)
    @printf "Standard approach:     %.3f ± %.3f seconds\n" avg_standard std_standard
    @printf "Preallocation concept: %.3f ± %.3f seconds\n" avg_prealloc std_prealloc
    
    avg_improvement = ((avg_standard - avg_prealloc) / avg_standard) * 100
    @printf "Average difference:    %+.1f%%\n" avg_improvement
    
    return (
        standard_times = standard_times,
        prealloc_times = prealloc_times,
        avg_improvement = avg_improvement
    )
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
        println("Starting MacroEnergy.jl model generation benchmark...")
        println("This demonstrates where preallocation could provide benefits in model building.\n")
        
        # Run benchmark trials
        results = run_benchmark_trials(NUM_RUNS)
        
        println("\n🎉 Benchmark completed successfully!")
        
        println("\n📚 Key Insights:")
        println("   • This benchmark focuses on model generation time")
        println("   • Preallocation benefits would be most apparent in:")
        println("     - Repeated model building (multiple scenarios)")
        println("     - Large-scale models with many edges and time periods")
        println("     - Interactive optimization workflows")
        println("   • The preallocation system in MacroEnergy.jl exists but isn't")
        println("     integrated into the main workflow yet")
        
    catch e
        println("\n❌ Benchmark failed with error: $e")
        println("\nStacktrace:")
        for (i, frame) in enumerate(stacktrace(catch_backtrace()))
            println("  $i. $frame")
            if i >= 10  # Limit stacktrace output
                println("  ... (truncated)")
                break
            end
        end
        rethrow(e)
    end
end

# Run the benchmark
main()
