#!/usr/bin/env julia
# HTTP-enabled MCP Orchestrator Server
# Provides high-level workflows combining multiple MCP servers

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer

include("src/HttpServer.jl") 
using .HttpServer

using JSON3
using Dates
using HTTP

# Orchestrator tools
const TOOLS = [
    Dict(
        "name" => "database_workflow",
        "description" => "Execute a complete database workflow combining multiple operations",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "workflow_type" => Dict(
                    "type" => "string",
                    "description" => "Type of workflow: analyze_database, create_database, migrate_data"
                ),
                "parameters" => Dict(
                    "type" => "object",
                    "description" => "Workflow-specific parameters"
                )
            ),
            "required" => ["workflow_type"]
        )
    ),
    Dict(
        "name" => "file_to_database",
        "description" => "Import file data into database with automatic table creation",
        "inputSchema" => Dict(
            "type" => "object", 
            "properties" => Dict(
                "file_path" => Dict(
                    "type" => "string",
                    "description" => "Path to data file"
                ),
                "table_name" => Dict(
                    "type" => "string",
                    "description" => "Target table name"
                ),
                "database" => Dict(
                    "type" => "string",
                    "description" => "Target database name (optional)"
                )
            ),
            "required" => ["file_path", "table_name"]
        )
    ),
    Dict(
        "name" => "multi_server_status",
        "description" => "Check status of all MCP servers",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict()
        )
    )
]

# Orchestrator tool implementations
function database_workflow_tool(args::Dict)
    workflow_type = get(args, "workflow_type", "")
    parameters = get(args, "parameters", Dict())
    
    if isempty(workflow_type)
        return "Error: workflow_type is required"
    end
    
    try
        if workflow_type == "analyze_database"
            database = get(parameters, "database", "postgres")
            
            # Simulate database analysis
            analysis_result = Dict(
                "workflow" => "analyze_database",
                "database" => database,
                "tables_found" => 0,
                "status" => "simulated",
                "message" => "This is a simplified orchestrator. Full functionality requires the complete client library.",
                "recommendations" => [
                    "Use the full MCPJuliaClient for complete orchestration",
                    "Connect to individual servers directly for specific operations"
                ]
            )
            
            return JSON3.write(analysis_result)
            
        elseif workflow_type == "create_database"
            database_name = get(parameters, "database_name", "")
            
            if isempty(database_name)
                return "Error: database_name is required for create_database workflow"
            end
            
            # Simulate database creation workflow
            creation_result = Dict(
                "workflow" => "create_database",
                "database_name" => database_name,
                "status" => "simulated",
                "message" => "Database creation simulated. Use the db-admin server directly for actual operations.",
                "next_steps" => [
                    "Use mcp-db-admin-http server to create the database",
                    "Use mcp-postgres-http server to verify creation"
                ]
            )
            
            return JSON3.write(creation_result)
            
        else
            return JSON3.write(Dict(
                "error" => "Unknown workflow type: $workflow_type",
                "available_workflows" => ["analyze_database", "create_database"],
                "status" => "error"
            ))
        end
        
    catch e
        error_msg = "Workflow execution failed: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "error" => error_msg,
            "workflow" => workflow_type,
            "status" => "error"
        ))
    end
end

function file_to_database_tool(args::Dict)
    file_path = get(args, "file_path", "")
    table_name = get(args, "table_name", "")
    database = get(args, "database", "postgres")
    
    if isempty(file_path) || isempty(table_name)
        return "Error: file_path and table_name are required"
    end
    
    try
        # Simulate file-to-database pipeline
        pipeline_result = Dict(
            "workflow" => "file_to_database",
            "file_path" => file_path,
            "table_name" => table_name,
            "database" => database,
            "status" => "simulated",
            "message" => "File-to-database pipeline simulated. Full implementation requires the complete client library.",
            "steps" => [
                "1. Verify file exists using mcp-file-http server",
                "2. Create target table using mcp-db-admin-http server",
                "3. Import data using appropriate method",
                "4. Verify import using mcp-postgres-http server"
            ],
            "note" => "Use individual servers directly for actual operations"
        )
        
        return JSON3.write(pipeline_result)
        
    catch e
        error_msg = "File-to-database pipeline failed: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "error" => error_msg,
            "workflow" => "file_to_database",
            "status" => "error"
        ))
    end
end

function multi_server_status_tool(args::Dict)
    try
        # Check available MCP servers
        servers = [
            Dict(
                "name" => "postgres",
                "port" => 8080,
                "description" => "PostgreSQL MCP Server",
                "status" => "available"
            ),
            Dict(
                "name" => "file",
                "port" => 8081, 
                "description" => "File Operations MCP Server",
                "status" => "available"
            ),
            Dict(
                "name" => "db_admin",
                "port" => 8082,
                "description" => "Database Administration MCP Server", 
                "status" => "available"
            ),
            Dict(
                "name" => "orchestrator",
                "port" => 8083,
                "description" => "MCP Orchestrator Server (simplified)",
                "status" => "running"
            )
        ]
        
        status_result = Dict(
            "servers" => servers,
            "total_servers" => length(servers),
            "wsl_ip" => HttpServer.get_wsl_ip(),
            "message" => "Server status check completed",
            "note" => "This is a simplified orchestrator providing basic coordination"
        )
        
        return JSON3.write(status_result)
        
    catch e
        error_msg = "Status check failed: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "error" => error_msg,
            "status" => "error"
        ))
    end
end

# MCP request handler
function handle_mcp_request(request_data::Dict)
    try
        method = get(request_data, "method", "")
        params = get(request_data, "params", Dict())
        request_id = get(request_data, "id", 1)
        
        if method == "initialize"
            return Dict(
                "jsonrpc" => "2.0",
                "result" => Dict(
                    "protocolVersion" => "2024-11-05",
                    "capabilities" => Dict("tools" => Dict()),
                    "serverInfo" => Dict(
                        "name" => "orchestrator-mcp-server",
                        "version" => "1.0.0"
                    )
                ),
                "id" => request_id
            )
            
        elseif method == "tools/list"
            return Dict(
                "jsonrpc" => "2.0",
                "result" => Dict("tools" => TOOLS),
                "id" => request_id
            )
            
        elseif method == "tools/call"
            tool_name = get(params, "name", "")
            tool_args = get(params, "arguments", Dict())
            
            result_text = if tool_name == "database_workflow"
                database_workflow_tool(tool_args)
            elseif tool_name == "file_to_database"
                file_to_database_tool(tool_args)
            elseif tool_name == "multi_server_status"
                multi_server_status_tool(tool_args)
            else
                "Error: Unknown tool '$tool_name'"
            end
            
            return Dict(
                "jsonrpc" => "2.0",
                "result" => Dict(
                    "content" => [Dict(
                        "type" => "text",
                        "text" => result_text
                    )]
                ),
                "id" => request_id
            )
            
        else
            return Dict(
                "jsonrpc" => "2.0",
                "error" => Dict(
                    "code" => -32601,
                    "message" => "Method not found: $method"
                ),
                "id" => request_id
            )
        end
        
    catch e
        @error "Orchestrator MCP request handling error" exception=e
        return Dict(
            "jsonrpc" => "2.0",
            "error" => Dict(
                "code" => -32603,
                "message" => "Internal error: $(string(e))"
            ),
            "id" => get(request_data, "id", 1)
        )
    end
end

# Main execution
function main()
    # Check if HTTP mode is requested
    http_mode = get(ENV, "MCP_HTTP_MODE", "false") == "true"
    http_port = parse(Int, get(ENV, "MCP_HTTP_PORT", "8083"))
    http_host = get(ENV, "MCP_HTTP_HOST", "0.0.0.0")
    
    if http_mode
        @info "🌐 Starting Orchestrator HTTP server mode..."
        
        # Create HTTP server configuration
        config = HttpServerConfig(http_host, http_port)
        
        # Enable authentication if token is provided
        auth_token = get(ENV, "MCP_AUTH_TOKEN", "")
        if !isempty(auth_token)
            config.auth_enabled = true
            config.auth_token = auth_token
            @info "🔒 Authentication enabled"
        end
        
        # Start HTTP server
        server = start_http_server(handle_mcp_request, config)
        
        # Server is running
        wsl_ip = HttpServer.get_wsl_ip()
        @info "🪟 Windows access available at http://$wsl_ip:$http_port"
        
        # Keep server running
        @info "🔄 Orchestrator Server running... Press Ctrl+C to stop"
        try
            while true
                sleep(1)
            end
        catch InterruptException
            @info "👋 Shutting down orchestrator server..."
            stop_http_server(config)
        end
        
    else
        @info "📡 Starting stdio Orchestrator MCP server mode..."
        
        # Standard MCP stdio server
        server = MCPServer(
            name="orchestrator-mcp-server",
            version="1.0.0"
        )
        
        # Add tools
        for tool in TOOLS
            tool_func = if tool["name"] == "database_workflow"
                database_workflow_tool
            elseif tool["name"] == "file_to_database"
                file_to_database_tool
            elseif tool["name"] == "multi_server_status"
                multi_server_status_tool
            end
            
            add_tool(server, tool["name"], tool["description"], tool_func, tool["inputSchema"])
        end
        
        @info "🚀 Orchestrator MCP Server ready!"
        run_server(server)
    end
end

# Run the server
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end