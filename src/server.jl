function start_server(server::MCPServer)
    @info "Starting MCP Server: $(server.info.name) v$(server.info.version)"
    @info "Available tools: $(join(keys(server.tools), ", "))"
    
    try
        while true
            line = readline(stdin)
            if isempty(line)
                continue
            end
            
            request = parse_jsonrpc_request(line)
            if request === nothing
                error_response = create_jsonrpc_error(-32700, "Parse error", nothing)
                println(serialize_jsonrpc_response(error_response))
                continue
            end
            
            if request.id === nothing
                @debug "Received notification: $(request.method)"
                continue
            end
            
            @debug "Handling request: $(request.method)"
            response = handle_mcp_request(server, request)
            println(serialize_jsonrpc_response(response))
            flush(stdout)
        end
    catch e
        if isa(e, InterruptException)
            @info "Server shutting down..."
        else
            @error "Server error" exception=e
            rethrow(e)
        end
    end
end