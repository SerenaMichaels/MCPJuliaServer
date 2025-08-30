#!/usr/bin/env julia

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer

function calculator_tool(args::Dict{String,Any})
    operation = get(args, "operation", "")
    a = get(args, "a", 0)
    b = get(args, "b", 0)
    
    result = if operation == "add"
        a + b
    elseif operation == "subtract"
        a - b
    elseif operation == "multiply"
        a * b
    elseif operation == "divide"
        b != 0 ? a / b : "Error: Division by zero"
    else
        "Error: Unknown operation '$operation'"
    end
    
    return "Result: $result"
end

function random_number_tool(args::Dict{String,Any})
    min_val = get(args, "min", 1)
    max_val = get(args, "max", 100)
    
    if min_val > max_val
        return "Error: min value cannot be greater than max value"
    end
    
    result = rand(min_val:max_val)
    return "Random number between $min_val and $max_val: $result"
end

function system_info_tool(args::Dict{String,Any})
    info_str = "Julia $(VERSION), System: $(Sys.MACHINE), CPU Threads: $(Sys.CPU_THREADS), Memory: $(round(Sys.total_memory() / 1024^3, digits=2)) GB"
    return "System Info: $info_str"
end

function main()
    server = MCPServer("Julia MCP Server", "0.1.0", "A sample MCP server implemented in Julia")
    
    calculator_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "operation" => Dict{String,Any}(
                "type" => "string",
                "enum" => ["add", "subtract", "multiply", "divide"],
                "description" => "The mathematical operation to perform"
            ),
            "a" => Dict{String,Any}(
                "type" => "number",
                "description" => "The first number"
            ),
            "b" => Dict{String,Any}(
                "type" => "number", 
                "description" => "The second number"
            )
        ),
        "required" => ["operation", "a", "b"]
    )
    
    random_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "min" => Dict{String,Any}(
                "type" => "integer",
                "description" => "Minimum value (default: 1)"
            ),
            "max" => Dict{String,Any}(
                "type" => "integer",
                "description" => "Maximum value (default: 100)"
            )
        )
    )
    
    system_info_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}()
    )
    
    add_tool!(server, MCPTool(
        "calculator",
        "Perform basic mathematical operations (add, subtract, multiply, divide)",
        calculator_schema,
        calculator_tool
    ))
    
    add_tool!(server, MCPTool(
        "random_number",
        "Generate a random number within a specified range",
        random_schema,
        random_number_tool
    ))
    
    add_tool!(server, MCPTool(
        "system_info",
        "Get information about the Julia system",
        system_info_schema,
        system_info_tool
    ))
    
    start_server(server)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end