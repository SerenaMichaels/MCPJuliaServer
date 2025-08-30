#!/usr/bin/env julia

using JSON3

function test_mcp_server()
    println("Testing Julia MCP Server...")
    
    test_cases = [
        Dict("jsonrpc" => "2.0", "method" => "initialize", "params" => Dict(), "id" => 1),
        Dict("jsonrpc" => "2.0", "method" => "tools/list", "params" => Dict(), "id" => 2),
        Dict("jsonrpc" => "2.0", "method" => "tools/call", "params" => Dict("name" => "calculator", "arguments" => Dict("operation" => "add", "a" => 15, "b" => 27)), "id" => 3),
        Dict("jsonrpc" => "2.0", "method" => "tools/call", "params" => Dict("name" => "random_number", "arguments" => Dict("min" => 1, "max" => 10)), "id" => 4),
        Dict("jsonrpc" => "2.0", "method" => "tools/call", "params" => Dict("name" => "system_info", "arguments" => Dict()), "id" => 5)
    ]
    
    for (i, test_case) in enumerate(test_cases)
        println("\n--- Test $i: $(test_case["method"]) ---")
        json_msg = JSON3.write(test_case)
        println("Request: $json_msg")
        
        cmd = `echo $json_msg`
        server_cmd = `../test-project/julia-1.11.2/bin/julia --project=. example.jl`
        
        try
            result = read(pipeline(cmd, server_cmd), String)
            println("Response: $result")
        catch e
            println("Error: $e")
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    test_mcp_server()
end