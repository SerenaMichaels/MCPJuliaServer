module HttpServer

using HTTP
using JSON3
using Base64
using Sockets
using Dates

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
                elseif uri_parts[2] == "orchestrator"
                    return handle_orchestrator(req, mcp_handler, config)
                end
            elseif req.method == "GET"
                if uri_parts[2] == "health"
                    return handle_health_check(req, config)
                elseif uri_parts[2] == "info"
                    return handle_server_info(req, config)
                elseif uri_parts[2] == "docs"
                    return handle_documentation(req, mcp_handler, config)
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
            "/mcp/info",
            "/mcp/docs"
        ],
        "authentication" => config.auth_enabled,
        "cors" => config.cors_enabled
    )
    
    return success_response(info_data, config)
end

"""
Handle orchestrator endpoint
"""
function handle_orchestrator(req::HTTP.Request, mcp_handler::Function, config::HttpServerConfig)
    body_data = parse_request_body(req)
    
    if body_data === nothing
        return error_response(400, "Invalid JSON request body", config)
    end
    
    try
        workflow = get(body_data, "workflow", "")
        parameters_str = get(body_data, "parameters", "{}")
        
        # Parse parameters if they're a string
        parameters = if isa(parameters_str, String)
            isempty(parameters_str) || parameters_str == "{}" ? Dict() : JSON3.read(parameters_str, Dict)
        else
            parameters_str
        end
        
        # Create MCP request for the orchestrator handler
        mcp_request = Dict(
            "method" => "tools/call",
            "params" => Dict(
                "name" => workflow,
                "arguments" => parameters
            ),
            "id" => 1
        )
        
        # Call the MCP handler
        result = mcp_handler(mcp_request)
        
        # Extract the result text from the MCP response
        result_text = ""
        if haskey(result, "result") && haskey(result["result"], "content") && 
           !isempty(result["result"]["content"])
            result_text = result["result"]["content"][1]["text"]
        else
            result_text = JSON3.write(Dict("error" => "Unknown workflow: $workflow"))
        end
        
        return success_response(result_text, config)
        
    catch e
        @error "Orchestrator endpoint error" exception=e
        return error_response(500, "Internal server error: $(string(e))", config)
    end
end

"""
Handle documentation endpoint - provides comprehensive server documentation
"""
function handle_documentation(req::HTTP.Request, mcp_handler::Function, config::HttpServerConfig)
    try
        # Get tools list from MCP handler
        tools_request = Dict("method" => "tools/list", "id" => 1)
        tools_response = mcp_handler(tools_request)
        
        tools_list = get(get(tools_response, "result", Dict()), "tools", [])
        
        # Detect server type based on tools
        server_type = detect_server_type(tools_list)
        
        # Generate simple documentation for now
        wsl_ip = get_wsl_ip()
        
        html_content = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>MCP Server Documentation - $(uppercasefirst(server_type))</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
                .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
                .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 8px; margin: -30px -30px 30px -30px; }
                .tool { background: #f8f9fa; padding: 15px; margin: 15px 0; border-radius: 6px; border-left: 4px solid #28a745; }
                .code { background: #f4f4f4; padding: 15px; border-radius: 4px; font-family: monospace; font-size: 0.9em; overflow-x: auto; }
                h1, h2, h3 { color: #333; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h1>MCP $(uppercasefirst(server_type)) Server</h1>
                    <p>Model Context Protocol Server Documentation</p>
                </div>
                
                <h2>Server Information</h2>
                <ul>
                    <li><strong>Server Type:</strong> $(server_type)</li>
                    <li><strong>WSL IP:</strong> $(wsl_ip)</li>
                    <li><strong>Port:</strong> $(config.port)</li>
                    <li><strong>Base URL:</strong> http://$(wsl_ip):$(config.port)</li>
                </ul>

                <h2>Available Tools ($(length(tools_list)))</h2>
                $(join([
                    "<div class=\"tool\">
                        <h3>$(tool["name"])</h3>
                        <p>$(tool["description"])</p>
                        <div class=\"code\">$(JSON3.write(tool["inputSchema"]))</div>
                    </div>"
                    for tool in tools_list
                ], ""))

                <h2>Claude Desktop Configuration</h2>
                <p>Add this to your Claude Desktop configuration at: <strong>%APPDATA%/Claude/claude_desktop_config.json</strong></p>
                <div class="code">
{
  "mcpServers": {
    "mcp-$(server_type)-http": {
      "command": "powershell",
      "args": [
        "-Command",
        "\$response = Invoke-RestMethod -Uri 'http://$(wsl_ip):$(config.port)/mcp/tools/call' -Method POST -ContentType 'application/json' -Body (ConvertTo-Json @{name=\$args[0]; arguments=(ConvertFrom-Json \$args[1])}); Write-Output (\$response.result.content[0].text)"
      ],
      "env": {},
      "description": "MCP $(uppercasefirst(server_type)) Server via HTTP"
    }
  }
}
                </div>

                <h2>API Endpoints</h2>
                <ul>
                    <li><strong>GET /mcp/health</strong> - Health check</li>
                    <li><strong>GET /mcp/info</strong> - Server information</li>
                    <li><strong>GET /mcp/docs</strong> - This documentation page</li>
                    <li><strong>POST /mcp/tools/list</strong> - List available tools</li>
                    <li><strong>POST /mcp/tools/call</strong> - Execute a tool</li>
                    $(server_type == "orchestrator" ? "<li><strong>POST /mcp/orchestrator</strong> - Direct workflow execution (orchestrator only)</li>" : "")
                </ul>
            </div>
        </body>
        </html>
        """
        
        headers = ["Content-Type" => "text/html"]
        if config.cors_enabled
            headers = vcat(headers, cors_headers())
        end
        
        return HTTP.Response(200, headers, html_content)
        
    catch e
        @error "Documentation endpoint error" exception=e
        return error_response(500, "Documentation generation failed: $(string(e))", config)
    end
end

"""
Detect server type based on available tools
"""
function detect_server_type(tools_list::Vector)
    tool_names = Set([tool["name"] for tool in tools_list])
    
    if "execute_sql" in tool_names || "execute_query" in tool_names
        return "postgres"
    elseif "create_database" in tool_names && "create_user" in tool_names
        return "db_admin"
    elseif "database_workflow" in tool_names || "multi_server_status" in tool_names
        return "orchestrator"
    elseif "list_directory" in tool_names || "read_file" in tool_names
        return "file"
    else
        return "unknown"
    end
end

"""
Generate comprehensive server documentation
"""
function generate_server_documentation(server_type::String, tools_list::Vector, config::HttpServerConfig)
    
    # Base server information
    base_info = Dict(
        "server_type" => server_type,
        "endpoints" => Dict(
            "health" => "/mcp/health",
            "info" => "/mcp/info", 
            "docs" => "/mcp/docs",
            "tools_list" => "/mcp/tools/list",
            "tools_call" => "/mcp/tools/call"
        ),
        "authentication" => config.auth_enabled,
        "cors" => config.cors_enabled
    )
    
    # Server-specific documentation
    server_docs = if server_type == "postgres"
        generate_postgres_docs()
    elseif server_type == "db_admin"
        generate_db_admin_docs()
    elseif server_type == "orchestrator"
        generate_orchestrator_docs()
    elseif server_type == "file"
        generate_file_docs()
    else
        generate_generic_docs()
    end
    
    # Claude Desktop integration guides
    claude_guides = generate_claude_desktop_guides(server_type, config)
    
    # MCP protocol information
    mcp_info = generate_mcp_protocol_info()
    
    return Dict(
        "base_info" => base_info,
        "server_docs" => server_docs,
        "tools" => tools_list,
        "claude_guides" => claude_guides,
        "mcp_protocol" => mcp_info,
        "examples" => generate_usage_examples(server_type, tools_list)
    )
end

"""
Generate PostgreSQL server documentation
"""
function generate_postgres_docs()
    return Dict(
        "name" => "PostgreSQL MCP Server",
        "description" => "Provides direct SQL query execution and database interaction capabilities",
        "key_features" => [
            "Execute raw SQL queries",
            "Transaction support",
            "Connection pooling",
            "Result formatting",
            "Error handling"
        ],
        "use_cases" => [
            "Data analysis and reporting",
            "Database content exploration", 
            "Custom query execution",
            "Data validation",
            "Performance analysis"
        ],
        "security" => [
            "Environment-based configuration",
            "Connection pooling with limits",
            "SQL injection protection via LibPQ",
            "Configurable base directory restrictions"
        ]
    )
end

"""
Generate Database Admin server documentation
"""
function generate_db_admin_docs()
    return Dict(
        "name" => "Database Administration MCP Server",
        "description" => "Provides high-level database administration and management tools",
        "key_features" => [
            "Database creation and management",
            "User and role management", 
            "Schema export and import",
            "CSV data import",
            "Table creation from JSON schema"
        ],
        "use_cases" => [
            "Database setup and provisioning",
            "User management",
            "Data migration",
            "Schema documentation",
            "Bulk data operations"
        ],
        "security" => [
            "Administrative privilege validation",
            "Secure password handling",
            "Input sanitization",
            "Database isolation"
        ]
    )
end

"""
Generate Orchestrator server documentation  
"""
function generate_orchestrator_docs()
    return Dict(
        "name" => "MCP Orchestrator Server",
        "description" => "Coordinates complex workflows across multiple MCP servers",
        "key_features" => [
            "Multi-server workflow orchestration",
            "Database analysis workflows",
            "File-to-database pipelines",
            "Server status monitoring",
            "Workflow result aggregation"
        ],
        "use_cases" => [
            "Complex data processing pipelines",
            "Multi-step database operations",
            "System health monitoring",
            "Coordinated backup procedures",
            "Cross-server data synchronization"
        ],
        "workflows" => [
            "analyze_database - Comprehensive database analysis",
            "create_database - Database creation with dependencies",
            "file_to_database - Automated data import pipelines"
        ]
    )
end

"""
Generate File server documentation
"""
function generate_file_docs()
    return Dict(
        "name" => "File Operations MCP Server",
        "description" => "Provides secure file system operations within configured directories",
        "key_features" => [
            "Directory listing with metadata",
            "File reading and writing",
            "Directory creation",
            "File and directory deletion",
            "Path security validation"
        ],
        "use_cases" => [
            "Configuration file management",
            "Log file analysis",
            "Data file processing", 
            "Directory structure management",
            "File content manipulation"
        ],
        "security" => [
            "Sandboxed file access",
            "Path traversal protection",
            "Base directory enforcement",
            "Input validation"
        ]
    )
end

"""
Generate generic server documentation
"""
function generate_generic_docs()
    return Dict(
        "name" => "Generic MCP Server",
        "description" => "Model Context Protocol compliant server with custom tools",
        "key_features" => [
            "MCP 2024-11-05 protocol compliance",
            "HTTP and stdio interfaces",
            "Custom tool implementations",
            "Error handling and logging"
        ]
    )
end

"""
Generate Claude Desktop integration guides
"""
function generate_claude_desktop_guides(server_type::String, config::HttpServerConfig)
    wsl_ip = get_wsl_ip()
    
    return Dict(
        "claude_desktop_config" => Dict(
            "description" => "Configuration for Claude Desktop to access this MCP server",
            "windows_config" => Dict(
                "powershell_command" => generate_powershell_command(server_type, config.port, wsl_ip),
                "config_location" => "%APPDATA%/Claude/claude_desktop_config.json"
            ),
            "direct_http" => Dict(
                "base_url" => "http://$(wsl_ip):$(config.port)",
                "endpoints" => Dict(
                    "health" => "GET /mcp/health",
                    "tools" => "POST /mcp/tools/list", 
                    "call_tool" => "POST /mcp/tools/call"
                )
            )
        ),
        "usage_patterns" => [
            "Use tools/list to discover available capabilities",
            "Call individual tools via tools/call endpoint",
            "Check server health before operations",
            "Review documentation at /mcp/docs endpoint"
        ],
        "troubleshooting" => Dict(
            "connection_issues" => [
                "Verify WSL IP address: $(wsl_ip)",
                "Ensure server is running on port $(config.port)",
                "Check Windows firewall settings",
                "Validate PowerShell execution policy"
            ],
            "common_errors" => [
                "404 Not Found - Check endpoint URL",
                "401 Unauthorized - Verify authentication token",
                "500 Internal Error - Check server logs"
            ]
        )
    )
end

"""
Generate PowerShell command for Claude Desktop
"""
function generate_powershell_command(server_type::String, port::Int, wsl_ip::String)
    server_name = "mcp-$(server_type)-http"
    
    return Dict(
        "server_name" => server_name,
        "command" => "powershell",
        "args" => [
            "-Command",
            "\$response = Invoke-RestMethod -Uri 'http://$(wsl_ip):$(port)/mcp/tools/call' -Method POST -ContentType 'application/json' -Body (ConvertTo-Json @{name=\$args[0]; arguments=(ConvertFrom-Json \$args[1])}); Write-Output (\$response.result.content[0].text)"
        ]
    )
end

"""
Generate MCP protocol information
"""
function generate_mcp_protocol_info()
    return Dict(
        "protocol_version" => "2024-11-05",
        "specification" => "Model Context Protocol (MCP)",
        "transport" => ["stdio", "HTTP"],
        "message_format" => "JSON-RPC 2.0",
        "key_methods" => [
            "initialize - Server initialization",
            "tools/list - List available tools",
            "tools/call - Execute a specific tool"
        ],
        "capabilities" => [
            "tools - Server provides executable tools",
            "resources - Server provides readable resources (optional)",
            "prompts - Server provides reusable prompts (optional)"
        ]
    )
end

"""
Generate usage examples for the server
"""
function generate_usage_examples(server_type::String, tools_list::Vector)
    examples = []
    
    for tool in tools_list
        tool_name = tool["name"]
        tool_desc = get(tool, "description", "")
        
        # Generate example based on tool name and server type
        example = if server_type == "postgres" && (tool_name == "execute_sql" || tool_name == "execute_query")
            Dict(
                "tool" => tool_name,
                "description" => tool_desc,
                "example_request" => Dict(
                    "name" => tool_name,
                    "arguments" => Dict("query" => "SELECT version();")
                ),
                "use_case" => "Get PostgreSQL version information"
            )
        elseif server_type == "db_admin" && tool_name == "create_database"
            Dict(
                "tool" => tool_name, 
                "description" => tool_desc,
                "example_request" => Dict(
                    "name" => tool_name,
                    "arguments" => Dict(
                        "database_name" => "my_new_db",
                        "owner" => "db_user"
                    )
                ),
                "use_case" => "Create a new database with specific owner"
            )
        elseif server_type == "file" && tool_name == "list_directory"
            Dict(
                "tool" => tool_name,
                "description" => tool_desc, 
                "example_request" => Dict(
                    "name" => tool_name,
                    "arguments" => Dict("path" => ".")
                ),
                "use_case" => "List contents of current directory"
            )
        elseif server_type == "orchestrator" && tool_name == "multi_server_status"
            Dict(
                "tool" => tool_name,
                "description" => tool_desc,
                "example_request" => Dict(
                    "name" => tool_name,
                    "arguments" => Dict()
                ),
                "use_case" => "Check status of all MCP servers"
            )
        else
            Dict(
                "tool" => tool_name,
                "description" => tool_desc,
                "example_request" => Dict(
                    "name" => tool_name,
                    "arguments" => Dict()
                ),
                "use_case" => "General tool usage"
            )
        end
        
        push!(examples, example)
    end
    
    return examples
end

"""
Generate HTML documentation
"""
function generate_html_documentation(doc_data::Dict)
    base_info = doc_data["base_info"]
    server_docs = doc_data["server_docs"]
    tools = doc_data["tools"]
    claude_guides = doc_data["claude_guides"]
    mcp_info = doc_data["mcp_protocol"]
    examples = doc_data["examples"]
    
    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>$(server_docs["name"]) - Documentation</title>
        <style>
            body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; margin: 0; padding: 20px; background: #f5f5f5; }
            .container { max-width: 1200px; margin: 0 auto; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
            .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 30px; border-radius: 8px 8px 0 0; }
            .content { padding: 30px; }
            h1, h2, h3 { color: #333; }
            .section { margin-bottom: 40px; }
            .badge { background: #007acc; color: white; padding: 4px 8px; border-radius: 4px; font-size: 0.8em; margin-right: 8px; }
            .endpoint { background: #f8f9fa; padding: 15px; border-radius: 6px; margin: 10px 0; border-left: 4px solid #007acc; }
            .tool { background: #f8f9fa; padding: 20px; margin: 15px 0; border-radius: 6px; border-left: 4px solid #28a745; }
            .example { background: #fff3cd; padding: 15px; border-radius: 6px; margin: 10px 0; border-left: 4px solid #ffc107; }
            .code { background: #f4f4f4; padding: 15px; border-radius: 4px; font-family: 'Monaco', 'Consolas', monospace; font-size: 0.9em; overflow-x: auto; }
            ul { padding-left: 20px; }
            .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
            @media (max-width: 768px) { .grid { grid-template-columns: 1fr; } }
            .warning { background: #f8d7da; color: #721c24; padding: 15px; border-radius: 6px; margin: 15px 0; border-left: 4px solid #dc3545; }
            .success { background: #d4edda; color: #155724; padding: 15px; border-radius: 6px; margin: 15px 0; border-left: 4px solid #28a745; }
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header">
                <h1>$(server_docs["name"])</h1>
                <p>$(server_docs["description"])</p>
                <div>
                    <span class="badge">MCP $(mcp_info["protocol_version"])</span>
                    <span class="badge">$(uppercasefirst(base_info["server_type"]))</span>
                    $(base_info["authentication"] ? "<span class=\"badge\">Auth Required</span>" : "")
                    $(base_info["cors"] ? "<span class=\"badge\">CORS Enabled</span>" : "")
                </div>
            </div>
            
            <div class="content">
                <!-- Server Overview -->
                <div class="section">
                    <h2>🚀 Server Overview</h2>
                    <div class="grid">
                        <div>
                            <h3>Key Features</h3>
                            <ul>
                            $(join(["<li>$(feature)</li>" for feature in server_docs["key_features"]], ""))
                            </ul>
                        </div>
                        <div>
                            <h3>Use Cases</h3>
                            <ul>
                            $(join(["<li>$(use_case)</li>" for use_case in server_docs["use_cases"]], ""))
                            </ul>
                        </div>
                    </div>
                </div>

                <!-- API Endpoints -->
                <div class="section">
                    <h2>🌐 API Endpoints</h2>
                    $(join([
                        "<div class=\"endpoint\"><strong>$(uppercase(method)) $(endpoint)</strong><br><small>$(desc)</small></div>"
                        for (method, endpoint, desc) in [
                            ("GET", base_info["endpoints"]["health"], "Check server health status"),
                            ("GET", base_info["endpoints"]["info"], "Get server information"),
                            ("GET", base_info["endpoints"]["docs"], "This documentation page"),
                            ("POST", base_info["endpoints"]["tools_list"], "List all available tools"),
                            ("POST", base_info["endpoints"]["tools_call"], "Execute a specific tool")
                        ]
                    ], ""))
                </div>

                <!-- Available Tools -->
                <div class="section">
                    <h2>🔧 Available Tools</h2>
                    $(join([
                        "<div class=\"tool\">
                            <h3>$(tool["name"])</h3>
                            <p>$(tool["description"])</p>
                            <div class=\"code\">$(JSON3.write(tool["inputSchema"]))</div>
                        </div>"
                        for tool in tools
                    ], ""))
                </div>

                <!-- Usage Examples -->
                <div class="section">
                    <h2>📝 Usage Examples</h2>
                    $(join([
                        "<div class=\"example\">
                            <h3>$(example["tool"]) - $(example["use_case"])</h3>
                            <p><strong>Description:</strong> $(example["description"])</p>
                            <div class=\"code\">curl -X POST http://server:port/mcp/tools/call \\<br>
  -H \"Content-Type: application/json\" \\<br>
  -d '$(JSON3.write(example["example_request"]))'</div>
                        </div>"
                        for example in examples
                    ], ""))
                </div>

                <!-- Claude Desktop Integration -->
                <div class="section">
                    <h2>🤖 Claude Desktop Integration</h2>
                    
                    <h3>Windows Configuration</h3>
                    <div class="success">
                        <p><strong>Config Location:</strong> $(claude_guides["claude_desktop_config"]["windows_config"]["config_location"])</p>
                    </div>
                    
                    <div class="code">
{
  "mcpServers": {
    "$(claude_guides["claude_desktop_config"]["windows_config"]["powershell_command"]["server_name"])": {
      "command": "$(claude_guides["claude_desktop_config"]["windows_config"]["powershell_command"]["command"])",
      "args": $(JSON3.write(claude_guides["claude_desktop_config"]["windows_config"]["powershell_command"]["args"])),
      "env": {},
      "description": "$(server_docs["name"]) - $(server_docs["description"])"
    }
  }
}
                    </div>

                    <h3>Direct HTTP Access</h3>
                    <div class="endpoint">
                        <strong>Base URL:</strong> $(claude_guides["claude_desktop_config"]["direct_http"]["base_url"])
                    </div>

                    <h3>Usage Patterns</h3>
                    <ul>
                    $(join(["<li>$(pattern)</li>" for pattern in claude_guides["usage_patterns"]], ""))
                    </ul>

                    <h3>Troubleshooting</h3>
                    <div class="warning">
                        <h4>Connection Issues:</h4>
                        <ul>
                        $(join(["<li>$(issue)</li>" for issue in claude_guides["troubleshooting"]["connection_issues"]], ""))
                        </ul>
                        
                        <h4>Common Errors:</h4>
                        <ul>
                        $(join(["<li>$(error)</li>" for error in claude_guides["troubleshooting"]["common_errors"]], ""))
                        </ul>
                    </div>
                </div>

                <!-- Security Information -->
                $(haskey(server_docs, "security") ? 
                    "<div class=\"section\">
                        <h2>🔒 Security Features</h2>
                        <ul>
                        $(join(["<li>$(feature)</li>" for feature in server_docs["security"]], ""))
                        </ul>
                    </div>" : "")

                <!-- MCP Protocol Info -->
                <div class="section">
                    <h2>📋 MCP Protocol Information</h2>
                    <div class="grid">
                        <div>
                            <h3>Protocol Details</h3>
                            <ul>
                                <li><strong>Version:</strong> $(mcp_info["protocol_version"])</li>
                                <li><strong>Transport:</strong> $(join(mcp_info["transport"], ", "))</li>
                                <li><strong>Message Format:</strong> $(mcp_info["message_format"])</li>
                            </ul>
                        </div>
                        <div>
                            <h3>Key Methods</h3>
                            <ul>
                            $(join(["<li>$(method)</li>" for method in mcp_info["key_methods"]], ""))
                            </ul>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </body>
    </html>
    """
    
    return html
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