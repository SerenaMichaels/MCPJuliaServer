module HttpServer

using HTTP
using JSON3
using Base64
using Sockets

export start_http_server, stop_http_server, HttpServerConfig

"""
HTTP Server configuration
"""
mutable struct HttpServerConfig
    host::String
    port::Int
    cors_enabled::Bool
    auth_enabled::Bool
    auth_token::String
    server_ref::Union{Nothing, HTTP.Server}
    
    HttpServerConfig(host="0.0.0.0", port=8080) = new(host, port, true, false, "", nothing)
end

"""
CORS headers for cross-origin requests
"""
function cors_headers()
    return [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers" => "Content-Type, Authorization",
        "Access-Control-Max-Age" => "86400"
    ]
end

"""
Handle OPTIONS preflight requests
"""
function handle_options(req::HTTP.Request)
    return HTTP.Response(200, cors_headers(), "")
end

"""
Authenticate request if authentication is enabled
"""
function authenticate_request(req::HTTP.Request, config::HttpServerConfig)
    if !config.auth_enabled
        return true
    end
    
    auth_header = HTTP.header(req, "Authorization", "")
    if isempty(auth_header)
        return false
    end
    
    # Expect "Bearer <token>" format
    if !startswith(auth_header, "Bearer ")
        return false
    end
    
    token = auth_header[8:end]  # Remove "Bearer " prefix
    return token == config.auth_token
end

"""
Create error response
"""
function error_response(status::Int, message::String, config::HttpServerConfig)
    error_data = Dict(
        "error" => Dict(
            "code" => status,
            "message" => message
        )
    )
    
    headers = config.cors_enabled ? cors_headers() : []
    push!(headers, "Content-Type" => "application/json")
    
    return HTTP.Response(status, headers, JSON3.write(error_data))
end

"""
Create success response
"""
function success_response(data::Any, config::HttpServerConfig)
    response_data = Dict("result" => data)
    
    headers = config.cors_enabled ? cors_headers() : []
    push!(headers, "Content-Type" => "application/json")
    
    return HTTP.Response(200, headers, JSON3.write(response_data))
end

"""
Parse JSON request body
"""
function parse_request_body(req::HTTP.Request)
    try
        body = String(req.body)
        if isempty(body)
            return Dict{String,Any}()
        end
        return JSON3.read(body, Dict{String,Any})
    catch e
        throw(ArgumentError("Invalid JSON in request body: $e"))
    end
end

"""
Create HTTP server router for MCP functionality
"""
function create_router(mcp_handler::Function, config::HttpServerConfig)
    
    function router(req::HTTP.Request)
        try
            # Handle CORS preflight
            if req.method == "OPTIONS"
                return handle_options(req)
            end
            
            # Authenticate request
            if !authenticate_request(req, config)
                return error_response(401, "Unauthorized", config)
            end
            
            # Parse URL path
            uri_parts = split(req.target, "/"; keepempty=false)
            
            if length(uri_parts) < 2 || uri_parts[1] != "mcp"
                return error_response(404, "Not found", config)
            end
            
            # Route MCP requests
            if req.method == "POST"
                if uri_parts[2] == "initialize"
                    return handle_initialize(req, mcp_handler, config)
                elseif uri_parts[2] == "tools"
                    if length(uri_parts) >= 3
                        if uri_parts[3] == "list"
                            return handle_list_tools(req, mcp_handler, config)
                        elseif uri_parts[3] == "call"
                            return handle_call_tool(req, mcp_handler, config)
                        end
                    end
                end
            elseif req.method == "GET"
                if uri_parts[2] == "health"
                    return handle_health_check(req, config)
                elseif uri_parts[2] == "info"
                    return handle_server_info(req, config)
                end
            end
            
            return error_response(404, "Endpoint not found", config)
            
        catch e
            @error "HTTP request error" exception=e
            return error_response(500, "Internal server error: $(string(e))", config)
        end
    end
    
    return router
end

"""
Handle MCP initialize endpoint
"""
function handle_initialize(req::HTTP.Request, mcp_handler::Function, config::HttpServerConfig)
    try
        body = parse_request_body(req)
        
        # Create MCP initialize request
        mcp_request = Dict(
            "jsonrpc" => "2.0",
            "method" => "initialize",
            "params" => get(body, "params", Dict()),
            "id" => get(body, "id", 1)
        )
        
        # Call MCP handler
        result = mcp_handler(mcp_request)
        return success_response(result, config)
        
    catch e
        return error_response(400, "Initialize failed: $(string(e))", config)
    end
end

"""
Handle MCP list tools endpoint
"""
function handle_list_tools(req::HTTP.Request, mcp_handler::Function, config::HttpServerConfig)
    try
        # Create MCP list tools request
        mcp_request = Dict(
            "jsonrpc" => "2.0",
            "method" => "tools/list",
            "params" => Dict(),
            "id" => 1
        )
        
        # Call MCP handler
        result = mcp_handler(mcp_request)
        return success_response(result, config)
        
    catch e
        return error_response(500, "List tools failed: $(string(e))", config)
    end
end

"""
Handle MCP call tool endpoint
"""
function handle_call_tool(req::HTTP.Request, mcp_handler::Function, config::HttpServerConfig)
    try
        body = parse_request_body(req)
        
        # Validate required fields
        if !haskey(body, "name")
            return error_response(400, "Missing required field: name", config)
        end
        
        # Create MCP tool call request
        mcp_request = Dict(
            "jsonrpc" => "2.0",
            "method" => "tools/call",
            "params" => Dict(
                "name" => body["name"],
                "arguments" => get(body, "arguments", Dict())
            ),
            "id" => get(body, "id", 1)
        )
        
        # Call MCP handler
        result = mcp_handler(mcp_request)
        return success_response(result, config)
        
    catch e
        return error_response(500, "Tool call failed: $(string(e))", config)
    end
end

"""
Handle health check endpoint
"""
function handle_health_check(req::HTTP.Request, config::HttpServerConfig)
    health_data = Dict(
        "status" => "healthy",
        "timestamp" => string(Dates.now()),
        "server" => "MCP Julia Server",
        "version" => "1.0.0"
    )
    
    return success_response(health_data, config)
end

"""
Handle server info endpoint
"""
function handle_server_info(req::HTTP.Request, config::HttpServerConfig)
    info_data = Dict(
        "server" => "MCP Julia Server",
        "version" => "1.0.0",
        "capabilities" => ["tools/list", "tools/call"],
        "endpoints" => [
            "/mcp/initialize",
            "/mcp/tools/list", 
            "/mcp/tools/call",
            "/mcp/health",
            "/mcp/info"
        ],
        "authentication" => config.auth_enabled,
        "cors" => config.cors_enabled
    )
    
    return success_response(info_data, config)
end

"""
Start HTTP server
"""
function start_http_server(mcp_handler::Function, config::HttpServerConfig)
    @info "Starting HTTP server on $(config.host):$(config.port)"
    
    router = create_router(mcp_handler, config)
    
    try
        # Start the server
        config.server_ref = HTTP.serve!(router, config.host, config.port; verbose=false)
        
        @info "✅ HTTP server started successfully"
        @info "📡 Server endpoints:"
        @info "   Health Check: http://$(config.host):$(config.port)/mcp/health"
        @info "   Server Info:  http://$(config.host):$(config.port)/mcp/info"
        @info "   Initialize:   POST http://$(config.host):$(config.port)/mcp/initialize"
        @info "   List Tools:   POST http://$(config.host):$(config.port)/mcp/tools/list"
        @info "   Call Tool:    POST http://$(config.host):$(config.port)/mcp/tools/call"
        
        if config.auth_enabled
            @info "🔒 Authentication enabled - Bearer token required"
        end
        
        return config.server_ref
        
    catch e
        @error "Failed to start HTTP server" exception=e
        rethrow(e)
    end
end

"""
Stop HTTP server
"""
function stop_http_server(config::HttpServerConfig)
    if config.server_ref !== nothing
        @info "Stopping HTTP server..."
        try
            close(config.server_ref)
            config.server_ref = nothing
            @info "✅ HTTP server stopped"
        catch e
            @warn "Error stopping HTTP server" exception=e
        end
    end
end

"""
Get local WSL IP address for Windows access
"""
function get_wsl_ip()
    try
        # Get WSL IP from hostname -I
        result = read(`hostname -I`, String)
        ip_addresses = split(strip(result))
        
        # Return the first IP address (usually the WSL IP)
        if !isempty(ip_addresses)
            return ip_addresses[1]
        end
        
        return "127.0.0.1"
    catch e
        @warn "Could not determine WSL IP, using localhost" exception=e
        return "127.0.0.1"
    end
end

"""
Print Windows connection instructions
"""
function print_windows_instructions(config::HttpServerConfig)
    wsl_ip = get_wsl_ip()
    
    println()
    println("🪟 Windows Claude Desktop Connection Instructions:")
    println("=" ^ 60)
    println("WSL IP Address: $wsl_ip")
    println("Server Port: $(config.port)")
    println()
    println("Add this to your Windows Claude Desktop configuration:")
    println("""
{
  "mcpServers": {
    "mcp-julia-server-http": {
      "command": "curl",
      "args": [
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", "{\\"method\\": \\"tools/call\\", \\"params\\": {\\"name\\": \\"list_tables\\", \\"arguments\\": {}}}",
        "http://$wsl_ip:$(config.port)/mcp/tools/call"
      ],
      "description": "MCP Julia Server via HTTP from WSL"
    }
  }
}
""")
    println("=" ^ 60)
end

end # module