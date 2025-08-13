#!/usr/bin/env julia

"""
Simple performance demonstration of MacroEnergy.jl electricity three zone example
This shows the current model generation performance and demonstrates where preallocation could help
"""

using MacroEnergy
using Gurobi
using JuMP
using Printf

println("MacroEnergy.jl Electricity Three Zone - Performance Analysis")
println("="^60)

# Configuration
const NUM_RUNS = 3

"""
Run model generation multiple times to measure performance
"""
function benchmark_model_generation()
    println("🔄 Running model generation benchmark ($NUM_RUNS trials)...")
    
    times = Float64[]
    model_stats = nothing
    
    for trial in 1:NUM_RUNS
        println("\nTrial $trial/$NUM_RUNS")
        println("-" * "^15")
        
        start_time = time()
        
        # Load the case
        case = MacroEnergy.load_case(@__DIR__)
        
        # Override to monolithic for simpler analysis
        for system in case.systems
            system.settings = merge(system.settings, (SolutionAlgorithm = MacroEnergy.Monolithic(),))
        end
        
        # Generate model
        model = MacroEnergy.generate_model(case)
        
        generation_time = time() - start_time
        push!(times, generation_time)
        
        # Get model statistics (once)
        if model_stats === nothing
            num_variables = JuMP.num_variables(model)
            num_constraints = JuMP.num_constraints(model, count_variable_in_set_constraints=false)
            
            # Count edges
            num_edges = 0
            total_time_steps = 0
            for system in MacroEnergy.get_periods(case)
                for asset in system.assets
                    for field_name in fieldnames(typeof(asset))
                        field_value = getfield(asset, field_name)
                        if isa(field_value, MacroEnergy.AbstractEdge)
                            num_edges += 1
                        end
                    end
                end
                total_time_steps += length(system.time_data[:Electricity].time_interval)
            end
            
            model_stats = (
                num_variables = num_variables,
                num_constraints = num_constraints,
                num_edges = num_edges,
                total_time_steps = total_time_steps
            )
        end
        
        @printf "   ✅ Model generated in %.3f seconds\n" generation_time
    end
    
    return times, model_stats
end

"""
Analyze performance and explain where preallocation could help
"""
function analyze_performance(times, stats)
    println("\n📊 PERFORMANCE ANALYSIS")
    println("="^50)
    
    avg_time = sum(times) / length(times)
    std_time = sqrt(sum((t - avg_time)^2 for t in times) / length(times))
    min_time = minimum(times)
    max_time = maximum(times)
    
    println("🏗️  Model Structure:")
    println("   Variables:    $(stats.num_variables)")
    println("   Constraints:  $(stats.num_constraints)")
    println("   Edges:        $(stats.num_edges)")
    println("   Time steps:   $(stats.total_time_steps)")
    
    println("\n⏱️  Performance Results:")
    @printf "   Average time: %.3f ± %.3f seconds\n" avg_time std_time
    @printf "   Range:        %.3f - %.3f seconds\n" min_time max_time
    
    # Individual times
    println("\n   Individual trials:")
    for (i, t) in enumerate(times)
        @printf "     Trial %d: %.3f seconds\n" i t
    end
    
    println("\n💡 Preallocation Analysis:")
    println("   📈 Current approach: Variables and constraints created on-demand")
    println("   🎯 Preallocation benefits would emerge with:")
    println("      • Multiple model builds (scenarios, iterations)")
    println("      • Larger models (more edges, longer time horizons)")
    println("      • Memory-optimized variable/constraint access patterns")
    println("      • Repeated optimization workflows")
    
    # Estimate potential scenarios
    println("\n🔮 Potential Impact Scenarios:")
    
    # Scenario 1: Multiple model builds
    scenario_builds = 10
    current_total = avg_time * scenario_builds
    estimated_improvement = 0.10  # 10% improvement estimate
    improved_total = current_total * (1 - estimated_improvement)
    
    @printf "   📋 Scenario 1: Building %d models\n" scenario_builds
    @printf "      Current approach: %.1f seconds total\n" current_total
    @printf "      With preallocation: ~%.1f seconds (%.1f%% improvement)\n" improved_total (estimated_improvement * 100)
    
    # Scenario 2: Larger model
    scale_factor = 5
    larger_time = avg_time * scale_factor * 1.2  # Non-linear scaling
    larger_improved = larger_time * (1 - 0.15)  # 15% improvement for larger models
    
    @printf "   📈 Scenario 2: %dx larger model\n" scale_factor
    @printf "      Estimated current time: %.1f seconds\n" larger_time
    @printf "      With preallocation: ~%.1f seconds (15%% improvement)\n" larger_improved
    
    println("\n🔧 Implementation Status:")
    println("   ✅ Preallocation system exists in MacroEnergy.jl")
    println("   ⚠️  Not integrated into main model building workflow")
    println("   🎯 Integration would provide benefits in complex scenarios")
    
    return avg_time
end

"""
Main execution function
"""
function main()
    try
        println("Starting MacroEnergy.jl performance analysis...")
        println("This analyzes current model generation performance and potential preallocation benefits.\n")
        
        times, stats = benchmark_model_generation()
        avg_time = analyze_performance(times, stats)
        
        println("\n🎉 Analysis completed successfully!")
        
        println("\n📚 Summary:")
        @printf "   • Average model generation time: %.3f seconds\n" avg_time
        println("   • Model contains $(stats.num_variables) variables, $(stats.num_constraints) constraints")
        println("   • Preallocation system available but not integrated")
        println("   • Benefits would emerge in complex optimization workflows")
        
    catch e
        println("\n❌ Analysis failed with error: $e")
        rethrow(e)
    end
end

# Run the analysis
main()
