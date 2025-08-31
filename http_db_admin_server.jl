#!/usr/bin/env julia
# HTTP-enabled Database Administration MCP Server

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer

include("src/HttpServer.jl")
using .HttpServer

using LibPQ
using JSON3
using Dates

# Load site configuration
include("config/site_config.jl")
using .SiteConfig

# Load configuration with site-specific precedence
SiteConfig.load_config(".")

# Get database configuration with site-specific settings
const PG_CONFIG = SiteConfig.get_db_config()

# Validate configuration
SiteConfig.validate_config()

# Copy the tools and functions from db_admin_example.jl
const TOOLS = [
    Dict(
        "name" => "create_database",
        "description" => "Create a new database",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "database_name" => Dict(
                    "type" => "string",
                    "description" => "Name of the database to create"
                ),
                "owner" => Dict(
                    "type" => "string",
                    "description" => "Database owner (optional)"
                )
            ),
            "required" => ["database_name"]
        )
    ),
    Dict(
        "name" => "create_user",
        "description" => "Create a new database user",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "username" => Dict(
                    "type" => "string",
                    "description" => "Username for the new user"
                ),
                "password" => Dict(
                    "type" => "string",
                    "description" => "Password for the new user"
                ),
                "superuser" => Dict(
                    "type" => "boolean",
                    "description" => "Whether the user should be a superuser"
                )
            ),
            "required" => ["username", "password"]
        )
    ),
    Dict(
        "name" => "export_schema",
        "description" => "Export database schema as SQL",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "database" => Dict(
                    "type" => "string",
                    "description" => "Database name to export schema from"
                ),
                "output_file" => Dict(
                    "type" => "string",
                    "description" => "Output file path (optional)"
                )
            ),
            "required" => ["database"]
        )
    ),
    Dict(
        "name" => "import_csv",
        "description" => "Import CSV data into a table",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "csv_file" => Dict(
                    "type" => "string",
                    "description" => "Path to CSV file"
                ),
                "table_name" => Dict(
                    "type" => "string",
                    "description" => "Target table name"
                ),
                "database" => Dict(
                    "type" => "string",
                    "description" => "Database name (optional)"
                ),
                "delimiter" => Dict(
                    "type" => "string",
                    "description" => "CSV delimiter (default: comma)"
                )
            ),
            "required" => ["csv_file", "table_name"]
        )
    ),
    Dict(
        "name" => "create_table_from_schema",
        "description" => "Create table from JSON schema",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "table_name" => Dict(
                    "type" => "string",
                    "description" => "Name of table to create"
                ),
                "schema_json" => Dict(
                    "type" => "string",
                    "description" => "JSON schema definition"
                ),
                "database" => Dict(
                    "type" => "string",
                    "description" => "Database name (optional)"
                )
            ),
            "required" => ["table_name", "schema_json"]
        )
    )
]

# Global connection pool
mutable struct ConnectionPool
    connections::Vector{LibPQ.Connection}
    max_connections::Int
    current_index::Int
    
    ConnectionPool(max_conn::Int = 5) = new(LibPQ.Connection[], max_conn, 0)
end

const POOL = ConnectionPool()

# Initialize connection pool
function init_connection_pool()
    @info "Initializing DB Admin connection pool..."
    
    for i in 1:POOL.max_connections
        try
            conn = LibPQ.Connection(
                "host=$(PG_CONFIG["host"]) " *
                "port=$(PG_CONFIG["port"]) " *
                "user=$(PG_CONFIG["user"]) " *
                "password=$(PG_CONFIG["password"]) " *
                "dbname=$(PG_CONFIG["dbname"])"
            )
            push!(POOL.connections, conn)
            @info "✅ DB Admin Connection $(i)/$(POOL.max_connections) established"
        catch e
            @error "❌ Failed to create DB admin connection $i" exception=e
        end
    end
    
    if isempty(POOL.connections)
        error("❌ Could not establish any DB admin connections")
    end
    
    @info "✅ DB Admin connection pool initialized with $(length(POOL.connections)) connections"
end

# Get connection from pool
function get_connection()
    if isempty(POOL.connections)
        init_connection_pool()
    end
    
    POOL.current_index = (POOL.current_index % length(POOL.connections)) + 1
    return POOL.connections[POOL.current_index]
end

# Simplified tool implementations
function create_database_tool(args::Dict)
    database_name = get(args, "database_name", "")
    owner = get(args, "owner", "")
    
    if isempty(database_name)
        return "Error: database_name is required"
    end
    
    try
        conn = get_connection()
        
        # Create database
        query = "CREATE DATABASE \"$database_name\""
        if !isempty(owner)
            query *= " OWNER \"$owner\""
        end
        
        LibPQ.execute(conn, query)
        
        return JSON3.write(Dict(
            "success" => true,
            "message" => "Database '$database_name' created successfully",
            "database_name" => database_name
        ))
        
    catch e
        error_msg = "Failed to create database: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function create_user_tool(args::Dict)
    username = get(args, "username", "")
    password = get(args, "password", "")
    superuser = get(args, "superuser", false)
    
    if isempty(username) || isempty(password)
        return "Error: username and password are required"
    end
    
    try
        conn = get_connection()
        
        # Create user
        query = "CREATE USER \"$username\" WITH PASSWORD '$password'"
        if superuser
            query *= " SUPERUSER"
        end
        
        LibPQ.execute(conn, query)
        
        return JSON3.write(Dict(
            "success" => true,
            "message" => "User '$username' created successfully",
            "username" => username,
            "superuser" => superuser
        ))
        
    catch e
        error_msg = "Failed to create user: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function export_schema_tool(args::Dict)
    database = get(args, "database", "")
    output_file = get(args, "output_file", "")
    
    if isempty(database)
        return "Error: database is required"
    end
    
    try
        conn = get_connection()
        
        # Get all tables
        query = """
        SELECT schemaname, tablename 
        FROM pg_tables 
        WHERE schemaname NOT IN ('information_schema', 'pg_catalog')
        ORDER BY schemaname, tablename
        """
        
        result = LibPQ.execute(conn, query)
        
        schema_info = []
        for row in result
            table_info = Dict(zip(LibPQ.column_names(result), row))
            push!(schema_info, table_info)
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "database" => database,
            "schema" => schema_info,
            "table_count" => length(schema_info)
        ))
        
    catch e
        error_msg = "Failed to export schema: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function import_csv_tool(args::Dict)
    csv_file = get(args, "csv_file", "")
    table_name = get(args, "table_name", "")
    database = get(args, "database", "")
    delimiter = get(args, "delimiter", ",")
    
    if isempty(csv_file) || isempty(table_name)
        return "Error: csv_file and table_name are required"
    end
    
    return JSON3.write(Dict(
        "success" => false,
        "error" => "CSV import not yet implemented in simplified version",
        "note" => "Use the full db_admin_example.jl for complete functionality"
    ))
end

function create_table_from_schema_tool(args::Dict)
    table_name = get(args, "table_name", "")
    schema_json = get(args, "schema_json", "")
    database = get(args, "database", "")
    
    if isempty(table_name) || isempty(schema_json)
        return "Error: table_name and schema_json are required"
    end
    
    return JSON3.write(Dict(
        "success" => false,
        "error" => "JSON schema table creation not yet implemented in simplified version",
        "note" => "Use the full db_admin_example.jl for complete functionality"
    ))
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
                        "name" => "db-admin-mcp-server",
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
            
            result_text = if tool_name == "create_database"
                create_database_tool(tool_args)
            elseif tool_name == "create_user"
                create_user_tool(tool_args)
            elseif tool_name == "export_schema"
                export_schema_tool(tool_args)
            elseif tool_name == "import_csv"
                import_csv_tool(tool_args)
            elseif tool_name == "create_table_from_schema"
                create_table_from_schema_tool(tool_args)
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
        @error "DB Admin MCP request handling error" exception=e
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

# Cleanup function
function cleanup()
    @info "🧹 Cleaning up DB admin connections..."
    for conn in POOL.connections
        try
            LibPQ.close(conn)
        catch e
            @warn "Error closing DB admin connection" exception=e
        end
    end
    empty!(POOL.connections)
end

# Main execution
function main()
    # Check if HTTP mode is requested
    http_mode = get(ENV, "MCP_HTTP_MODE", "false") == "true"
    http_port = parse(Int, get(ENV, "MCP_HTTP_PORT", "8082"))
    http_host = get(ENV, "MCP_HTTP_HOST", "0.0.0.0")
    
    # Initialize database connection pool
    init_connection_pool()
    
    # Register cleanup
    atexit(cleanup)
    
    if http_mode
        @info "🌐 Starting DB Admin HTTP server mode..."
        
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
        @info "🔄 DB Admin Server running... Press Ctrl+C to stop"
        try
            while true
                sleep(1)
            end
        catch InterruptException
            @info "👋 Shutting down DB admin server..."
            stop_http_server(config)
        end
        
    else
        @info "📡 Starting stdio DB Admin MCP server mode..."
        
        # Standard MCP stdio server
        server = MCPServer(
            name="db-admin-mcp-server",
            version="1.0.0"
        )
        
        # Add tools
        for tool in TOOLS
            tool_func = if tool["name"] == "create_database"
                create_database_tool
            elseif tool["name"] == "create_user"
                create_user_tool
            elseif tool["name"] == "export_schema"
                export_schema_tool
            elseif tool["name"] == "import_csv"
                import_csv_tool
            elseif tool["name"] == "create_table_from_schema"
                create_table_from_schema_tool
            end
            
            add_tool(server, tool["name"], tool["description"], tool_func, tool["inputSchema"])
        end
        
        @info "🚀 DB Admin MCP Server ready!"
        run_server(server)
    end
end

# Run the server
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end