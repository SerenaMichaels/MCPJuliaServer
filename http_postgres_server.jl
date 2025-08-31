#!/usr/bin/env julia
# HTTP-enabled PostgreSQL MCP Server
# Provides both stdio MCP interface and HTTP REST API for cross-platform access

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer

include("src/HttpServer.jl")
using .HttpServer

using LibPQ
using HTTP
using JSON3

# Load site configuration
include("config/site_config.jl")
using .SiteConfig

# Load configuration with site-specific precedence
SiteConfig.load_config(".")

# Get database configuration with site-specific settings
const PG_CONFIG = SiteConfig.get_db_config()

# Validate configuration
SiteConfig.validate_config()

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
    @info "Initializing PostgreSQL connection pool..."
    
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
            @info "✅ Connection $(i)/$(POOL.max_connections) established"
        catch e
            @error "❌ Failed to create connection $i" exception=e
            # Continue with fewer connections
        end
    end
    
    if isempty(POOL.connections)
        error("❌ Could not establish any database connections")
    end
    
    @info "✅ Connection pool initialized with $(length(POOL.connections)) connections"
end

# Get connection from pool
function get_connection()
    if isempty(POOL.connections)
        init_connection_pool()
    end
    
    POOL.current_index = (POOL.current_index % length(POOL.connections)) + 1
    return POOL.connections[POOL.current_index]
end

# MCP Tool definitions (same as original)
const TOOLS = [
    Dict(
        "name" => "execute_sql",
        "description" => "Execute SQL query on PostgreSQL database with optional database targeting",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "query" => Dict(
                    "type" => "string",
                    "description" => "SQL query to execute"
                ),
                "database" => Dict(
                    "type" => "string", 
                    "description" => "Optional database name to connect to"
                )
            ),
            "required" => ["query"]
        )
    ),
    Dict(
        "name" => "list_tables",
        "description" => "List all tables in the database with their schemas",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "database" => Dict(
                    "type" => "string",
                    "description" => "Optional database name"
                )
            )
        )
    ),
    Dict(
        "name" => "describe_table", 
        "description" => "Get detailed information about a specific table including columns, types, and constraints",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "table_name" => Dict(
                    "type" => "string",
                    "description" => "Name of the table to describe"
                ),
                "database" => Dict(
                    "type" => "string",
                    "description" => "Optional database name"
                )
            ),
            "required" => ["table_name"]
        )
    )
]

# Tool implementations (same as original)
function execute_sql_tool(args::Dict)
    query = get(args, "query", "")
    database = get(args, "database", "")
    
    if isempty(query)
        return "Error: SQL query is required"
    end
    
    try
        conn = get_connection()
        
        # Switch database if specified
        if !isempty(database)
            LibPQ.execute(conn, "\\c $database")
        end
        
        result = LibPQ.execute(conn, query)
        
        if result isa LibPQ.Result
            # Convert result to readable format
            rows = []
            for row in result
                push!(rows, Dict(zip(LibPQ.column_names(result), row)))
            end
            
            return JSON3.write(Dict(
                "success" => true,
                "rows" => rows,
                "row_count" => length(rows),
                "query" => query
            ))
        else
            return JSON3.write(Dict(
                "success" => true,
                "message" => "Query executed successfully",
                "query" => query
            ))
        end
        
    catch e
        error_msg = "SQL execution failed: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg,
            "query" => query
        ))
    end
end

function list_tables_tool(args::Dict)
    database = get(args, "database", "")
    
    try
        conn = get_connection()
        
        if !isempty(database)
            LibPQ.execute(conn, "\\c $database")
        end
        
        query = """
        SELECT 
            schemaname,
            tablename as table_name,
            tableowner as owner,
            hasindexes as has_indexes,
            hasrules as has_rules,
            hastriggers as has_triggers
        FROM pg_tables 
        WHERE schemaname NOT IN ('information_schema', 'pg_catalog')
        ORDER BY schemaname, tablename;
        """
        
        result = LibPQ.execute(conn, query)
        
        tables = []
        for row in result
            push!(tables, Dict(zip(LibPQ.column_names(result), row)))
        end
        
        return JSON3.write(tables)
        
    catch e
        error_msg = "Failed to list tables: $(string(e))"
        @error error_msg
        return error_msg
    end
end

function describe_table_tool(args::Dict)
    table_name = get(args, "table_name", "")
    database = get(args, "database", "")
    
    if isempty(table_name)
        return "Error: table_name is required"
    end
    
    try
        conn = get_connection()
        
        if !isempty(database)
            LibPQ.execute(conn, "\\c $database")
        end
        
        # Get column information
        column_query = """
        SELECT 
            column_name,
            data_type,
            character_maximum_length,
            is_nullable,
            column_default,
            ordinal_position
        FROM information_schema.columns 
        WHERE table_name = '$table_name'
        ORDER BY ordinal_position;
        """
        
        result = LibPQ.execute(conn, column_query)
        
        columns = []
        for row in result
            push!(columns, Dict(zip(LibPQ.column_names(result), row)))
        end
        
        # Get table size and row count
        size_query = """
        SELECT 
            pg_size_pretty(pg_total_relation_size('$table_name')) as table_size,
            (SELECT COUNT(*) FROM $table_name) as row_count;
        """
        
        size_result = LibPQ.execute(conn, size_query)
        size_info = Dict()
        for row in size_result
            size_info = Dict(zip(LibPQ.column_names(size_result), row))
            break
        end
        
        table_info = Dict(
            "table_name" => table_name,
            "columns" => columns,
            "table_size" => get(size_info, "table_size", "unknown"),
            "row_count" => get(size_info, "row_count", 0)
        )
        
        return JSON3.write(table_info)
        
    catch e
        error_msg = "Failed to describe table: $(string(e))"
        @error error_msg
        return error_msg
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
                        "name" => "postgres-mcp-server",
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
            
            result_text = if tool_name == "execute_sql"
                execute_sql_tool(tool_args)
            elseif tool_name == "list_tables"
                list_tables_tool(tool_args)
            elseif tool_name == "describe_table"
                describe_table_tool(tool_args)
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
        @error "MCP request handling error" exception=e
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
    @info "🧹 Cleaning up connections..."
    for conn in POOL.connections
        try
            LibPQ.close(conn)
        catch e
            @warn "Error closing connection" exception=e
        end
    end
    empty!(POOL.connections)
end

# Main execution
function main()
    # Check if HTTP mode is requested
    http_mode = get(ENV, "MCP_HTTP_MODE", "false") == "true"
    http_port = parse(Int, get(ENV, "MCP_HTTP_PORT", "8080"))
    http_host = get(ENV, "MCP_HTTP_HOST", "0.0.0.0")
    
    # Initialize database connection pool
    init_connection_pool()
    
    # Register cleanup
    atexit(cleanup)
    
    if http_mode
        @info "🌐 Starting HTTP server mode..."
        
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
        
        # Print Windows connection instructions
        print_windows_instructions(config)
        
        # Keep server running
        @info "🔄 Server running... Press Ctrl+C to stop"
        try
            while true
                sleep(1)
            end
        catch InterruptException
            @info "👋 Shutting down server..."
            stop_http_server(config)
        end
        
    else
        @info "📡 Starting stdio MCP server mode..."
        
        # Standard MCP stdio server
        server = MCPServer(
            name="postgres-mcp-server",
            version="1.0.0"
        )
        
        # Add tools
        for tool in TOOLS
            tool_func = if tool["name"] == "execute_sql"
                execute_sql_tool
            elseif tool["name"] == "list_tables" 
                list_tables_tool
            elseif tool["name"] == "describe_table"
                describe_table_tool
            end
            
            add_tool(server, tool["name"], tool["description"], tool_func, tool["inputSchema"])
        end
        
        @info "🚀 PostgreSQL MCP Server ready!"
        run_server(server)
    end
end

# Run the server
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end