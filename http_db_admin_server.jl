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
    ),
    Dict(
        "name" => "log_accomplishment",
        "description" => "Log an accomplishment for a specific session and repository",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0007')"
                ),
                "repository" => Dict(
                    "type" => "string",
                    "description" => "Repository name (BotFarm, MCPJuliaServers, Job-God-Platform, CritterZOps)"
                ),
                "accomplishment_type" => Dict(
                    "type" => "string",
                    "description" => "Type of accomplishment (feature, bugfix, refactor, documentation, testing, integration)"
                ),
                "title" => Dict(
                    "type" => "string",
                    "description" => "Brief title of the accomplishment (max 200 chars)"
                ),
                "description" => Dict(
                    "type" => "string",
                    "description" => "Detailed description of what was accomplished"
                ),
                "success_level" => Dict(
                    "type" => "string",
                    "description" => "Level of success (completed, partial, blocked)"
                ),
                "files_created" => Dict(
                    "type" => "array",
                    "items" => Dict("type" => "string"),
                    "description" => "List of files created"
                ),
                "files_modified" => Dict(
                    "type" => "array", 
                    "items" => Dict("type" => "string"),
                    "description" => "List of files modified"
                ),
                "commit_hash" => Dict(
                    "type" => "string",
                    "description" => "Git commit hash if applicable"
                )
            ),
            "required" => ["session_id", "repository", "title"]
        )
    ),
    Dict(
        "name" => "note_next_step",
        "description" => "Record a next step for a session",
        "inputSchema" => Dict(
            "type" => "object", 
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0007')"
                ),
                "repository" => Dict(
                    "type" => "string",
                    "description" => "Repository name (optional)"
                ),
                "step_type" => Dict(
                    "type" => "string",
                    "description" => "Type of step (task, investigation, decision, integration)"
                ),
                "title" => Dict(
                    "type" => "string",
                    "description" => "Brief title of the next step (max 200 chars)"
                ),
                "description" => Dict(
                    "type" => "string",
                    "description" => "Detailed description of what needs to be done"
                ),
                "priority" => Dict(
                    "type" => "string",
                    "description" => "Priority level (critical, high, medium, low)"
                ),
                "estimated_effort" => Dict(
                    "type" => "string",
                    "description" => "Estimated effort (e.g., '2 hours', '1 day')"
                )
            ),
            "required" => ["session_id", "title"]
        )
    ),
    Dict(
        "name" => "get_session_status",
        "description" => "Get comprehensive session status across repositories",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string", 
                    "description" => "Session identifier (e.g., '0007')"
                ),
                "include_accomplishments" => Dict(
                    "type" => "boolean",
                    "description" => "Include accomplishments in response (default: true)"
                ),
                "include_next_steps" => Dict(
                    "type" => "boolean",
                    "description" => "Include next steps in response (default: true)"
                ),
                "repository_filter" => Dict(
                    "type" => "array",
                    "items" => Dict("type" => "string"),
                    "description" => "Filter by specific repositories"
                )
            ),
            "required" => ["session_id"]
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

function log_accomplishment_tool(args::Dict)
    session_id = get(args, "session_id", "")
    repository = get(args, "repository", "")
    title = get(args, "title", "")
    accomplishment_type = get(args, "accomplishment_type", "feature")
    description = get(args, "description", "")
    success_level = get(args, "success_level", "completed")
    files_created = get(args, "files_created", String[])
    files_modified = get(args, "files_modified", String[])
    commit_hash = get(args, "commit_hash", "")
    
    if isempty(session_id) || isempty(repository) || isempty(title)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id, repository, and title are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Create session_accomplishments table if it doesn't exist
        create_table_query = """
        CREATE TABLE IF NOT EXISTS session_accomplishments (
            id SERIAL PRIMARY KEY,
            session_id VARCHAR(20) NOT NULL,
            repository VARCHAR(100) NOT NULL,
            accomplishment_type VARCHAR(50) DEFAULT 'feature',
            title VARCHAR(200) NOT NULL,
            description TEXT,
            success_level VARCHAR(20) DEFAULT 'completed',
            files_created TEXT[],
            files_modified TEXT[],
            commit_hash VARCHAR(100),
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );
        """
        
        LibPQ.execute(conn, create_table_query)
        
        # Insert the accomplishment
        insert_query = """
        INSERT INTO session_accomplishments 
        (session_id, repository, accomplishment_type, title, description, 
         success_level, files_created, files_modified, commit_hash)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9)
        RETURNING id, created_at;
        """
        
        result = LibPQ.execute(conn, insert_query, [
            session_id, repository, accomplishment_type, title, description,
            success_level, files_created, files_modified, commit_hash
        ])
        
        row_data = Dict()
        for row in result
            row_data = Dict(zip(LibPQ.column_names(result), row))
            break
        end
        
        # return_connection(conn) # Not needed in simplified version
        
        return JSON3.write(Dict(
            "success" => true,
            "accomplishment_id" => row_data["id"],
            "created_at" => string(row_data["created_at"]),
            "message" => "Accomplishment logged successfully"
        ))
        
    catch e
        error_msg = "Failed to log accomplishment: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function note_next_step_tool(args::Dict)
    session_id = get(args, "session_id", "")
    repository = get(args, "repository", "")
    title = get(args, "title", "")
    step_type = get(args, "step_type", "task")
    description = get(args, "description", "")
    priority = get(args, "priority", "medium")
    estimated_effort = get(args, "estimated_effort", "")
    
    if isempty(session_id) || isempty(title)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id and title are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Create session_next_steps table if it doesn't exist
        create_table_query = """
        CREATE TABLE IF NOT EXISTS session_next_steps (
            id SERIAL PRIMARY KEY,
            session_id VARCHAR(20) NOT NULL,
            repository VARCHAR(100),
            step_type VARCHAR(50) DEFAULT 'task',
            title VARCHAR(200) NOT NULL,
            description TEXT,
            priority VARCHAR(20) DEFAULT 'medium',
            estimated_effort VARCHAR(50),
            status VARCHAR(20) DEFAULT 'pending',
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );
        """
        
        LibPQ.execute(conn, create_table_query)
        
        # Insert the next step
        insert_query = """
        INSERT INTO session_next_steps 
        (session_id, repository, step_type, title, description, priority, estimated_effort)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7)
        RETURNING id, created_at;
        """
        
        result = LibPQ.execute(conn, insert_query, [
            session_id, repository, step_type, title, description, priority, estimated_effort
        ])
        
        row_data = Dict()
        for row in result
            row_data = Dict(zip(LibPQ.column_names(result), row))
            break
        end
        
        # return_connection(conn) # Not needed in simplified version
        
        return JSON3.write(Dict(
            "success" => true,
            "step_id" => row_data["id"],
            "created_at" => string(row_data["created_at"]),
            "message" => "Next step recorded successfully"
        ))
        
    catch e
        error_msg = "Failed to record next step: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function get_session_status_tool(args::Dict)
    session_id = get(args, "session_id", "")
    include_accomplishments = get(args, "include_accomplishments", true)
    include_next_steps = get(args, "include_next_steps", true)
    repository_filter = get(args, "repository_filter", String[])
    
    if isempty(session_id)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id is required"
        ))
    end
    
    try
        conn = get_connection()
        status_data = Dict(
            "session_id" => session_id,
            "timestamp" => string(Dates.now())
        )
        
        # Get accomplishments if requested
        if include_accomplishments
            accomplishments_query = """
            SELECT id, repository, accomplishment_type, title, description, 
                   success_level, files_created, files_modified, commit_hash, created_at
            FROM session_accomplishments 
            WHERE session_id = \$1
            """ * (isempty(repository_filter) ? "" : " AND repository = ANY(\$2)") * """
            ORDER BY created_at DESC;
            """
            
            accomplishments_result = if isempty(repository_filter)
                LibPQ.execute(conn, accomplishments_query, [session_id])
            else
                LibPQ.execute(conn, accomplishments_query, [session_id, repository_filter])
            end
            
            accomplishments = []
            for row in accomplishments_result
                push!(accomplishments, Dict(zip(LibPQ.column_names(accomplishments_result), row)))
            end
            status_data["accomplishments"] = accomplishments
        end
        
        # Get next steps if requested
        if include_next_steps
            next_steps_query = """
            SELECT id, repository, step_type, title, description, 
                   priority, estimated_effort, status, created_at
            FROM session_next_steps 
            WHERE session_id = \$1
            """ * (isempty(repository_filter) ? "" : " AND repository = ANY(\$2)") * """
            ORDER BY 
                CASE priority 
                    WHEN 'critical' THEN 1
                    WHEN 'high' THEN 2  
                    WHEN 'medium' THEN 3
                    WHEN 'low' THEN 4
                    ELSE 5
                END, created_at DESC;
            """
            
            next_steps_result = if isempty(repository_filter)
                LibPQ.execute(conn, next_steps_query, [session_id])
            else
                LibPQ.execute(conn, next_steps_query, [session_id, repository_filter])
            end
            
            next_steps = []
            for row in next_steps_result
                push!(next_steps, Dict(zip(LibPQ.column_names(next_steps_result), row)))
            end
            status_data["next_steps"] = next_steps
        end
        
        # return_connection(conn) # Not needed in simplified version
        
        return JSON3.write(Dict(
            "success" => true,
            "data" => status_data
        ))
        
    catch e
        error_msg = "Failed to get session status: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
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
            elseif tool_name == "log_accomplishment"
                log_accomplishment_tool(tool_args)
            elseif tool_name == "note_next_step"
                note_next_step_tool(tool_args)
            elseif tool_name == "get_session_status"
                get_session_status_tool(tool_args)
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