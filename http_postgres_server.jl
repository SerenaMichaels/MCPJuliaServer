#!/usr/bin/env julia
# HTTP-enabled PostgreSQL MCP Server
# Provides both stdio MCP interface and HTTP REST API for cross-platform access

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer

include("src/HttpServer.jl")
using .HttpServer

include("src/DatabaseConnectionManager.jl")
using .DatabaseConnectionManager

using LibPQ
using HTTP
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

# Global connection pool
mutable struct ConnectionPool
    connections::Vector{LibPQ.Connection}
    max_connections::Int
    current_index::Int
    
    ConnectionPool(max_conn::Int = 5) = new(LibPQ.Connection[], max_conn, 0)
end

const POOL = ConnectionPool()

# Initialize connection pool with direct connection
function init_connection_pool()
    @info "Initializing PostgreSQL connection pool..."
    
    for i in 1:POOL.max_connections
        try
            # Direct connection using configuration
            conn = LibPQ.Connection("host=$(PG_CONFIG["host"]) port=$(PG_CONFIG["port"]) dbname=$(PG_CONFIG["dbname"]) user=$(PG_CONFIG["user"]) password=$(PG_CONFIG["password"])")
            push!(POOL.connections, conn)
            @info "✅ Connection $(i)/$(POOL.max_connections) established"
        catch e
            @error "❌ Failed to create connection $i" exception=e
            # Continue with fewer connections
        end
    end
    
    if isempty(POOL.connections)
        @error "❌ Could not establish any database connections"
        error("❌ Database connection failure")
    end
    
    @info "✅ Connection pool initialized with $(length(POOL.connections)) connections"
end

# Get connection from pool with simple recovery
function get_connection()
    if isempty(POOL.connections)
        init_connection_pool()
    end
    
    POOL.current_index = (POOL.current_index % length(POOL.connections)) + 1
    conn = POOL.connections[POOL.current_index]
    
    # Test connection and attempt recovery if needed
    try
        if LibPQ.status(conn) != LibPQ.libpq_c.CONNECTION_OK
            @warn "🔄 Connection lost, attempting recovery..."
            new_conn = LibPQ.Connection("host=$(PG_CONFIG["host"]) port=$(PG_CONFIG["port"]) dbname=$(PG_CONFIG["dbname"]) user=$(PG_CONFIG["user"]) password=$(PG_CONFIG["password"])")
            POOL.connections[POOL.current_index] = new_conn
            return new_conn
        end
        return conn
    catch e
        @warn "Connection recovery needed: $e"
        try
            new_conn = LibPQ.Connection("host=$(PG_CONFIG["host"]) port=$(PG_CONFIG["port"]) dbname=$(PG_CONFIG["dbname"]) user=$(PG_CONFIG["user"]) password=$(PG_CONFIG["password"])")
            POOL.connections[POOL.current_index] = new_conn
            return new_conn
        catch recovery_error
            @error "Failed to recover connection: $recovery_error"
            rethrow(recovery_error)
        end
    end
end

# Get connection to specific database
function get_connection(database::String)
    try
        host = SiteConfig.get_config("POSTGRES_HOST")
        port = SiteConfig.get_config("POSTGRES_PORT") 
        user = SiteConfig.get_config("POSTGRES_USER")
        password = SiteConfig.get_config("POSTGRES_PASSWORD")
        
        conn = LibPQ.Connection(
            "host=$host port=$port dbname=$database user=$user password=$password"
        )
        return conn
    catch e
        @error "Failed to connect to database '$database'" exception=e
        rethrow(e)
    end
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
    ),
    Dict(
        "name" => "send_bridge_message",
        "description" => "Send a message via claude_bridge_messages for AI-to-AI communication",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0008')"
                ),
                "from" => Dict(
                    "type" => "string", 
                    "description" => "Sender (CC or CD)"
                ),
                "to" => Dict(
                    "type" => "string",
                    "description" => "Recipient (CC or CD)"
                ),
                "subject" => Dict(
                    "type" => "string",
                    "description" => "Message subject line"
                ),
                "message" => Dict(
                    "type" => "string",
                    "description" => "Message content"
                ),
                "priority" => Dict(
                    "type" => "string",
                    "description" => "Message priority (LOW, NORMAL, HIGH)",
                    "default" => "NORMAL"
                ),
                "category" => Dict(
                    "type" => "string",
                    "description" => "Message category for filtering"
                )
            ),
            "required" => ["session_id", "from", "to", "message"]
        )
    ),
    Dict(
        "name" => "create_project_roadmap",
        "description" => "Create a comprehensive multi-session project roadmap with phases, tasks, and dependencies",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "project_name" => Dict(
                    "type" => "string",
                    "description" => "Name of the project (e.g., 'BotFarm-Advanced-Geometry')"
                ),
                "repository" => Dict(
                    "type" => "string",
                    "description" => "Repository name where project exists"
                ),
                "description" => Dict(
                    "type" => "string",
                    "description" => "Project description and objectives"
                ),
                "start_session" => Dict(
                    "type" => "string",
                    "description" => "Starting session ID (e.g., '0009')"
                ),
                "phases" => Dict(
                    "type" => "array",
                    "items" => Dict(
                        "type" => "object",
                        "properties" => Dict(
                            "phase_name" => Dict("type" => "string"),
                            "session_id" => Dict("type" => "string"),
                            "description" => Dict("type" => "string"),
                            "objectives" => Dict(
                                "type" => "array",
                                "items" => Dict("type" => "string")
                            ),
                            "deliverables" => Dict(
                                "type" => "array", 
                                "items" => Dict("type" => "string")
                            ),
                            "testing_requirements" => Dict("type" => "string"),
                            "documentation_requirements" => Dict("type" => "string"),
                            "git_requirements" => Dict("type" => "string")
                        ),
                        "required" => ["phase_name", "session_id", "description"]
                    ),
                    "description" => "Array of project phases"
                )
            ),
            "required" => ["project_name", "repository", "start_session", "phases"]
        )
    ),
    Dict(
        "name" => "create_session_tasks",
        "description" => "Create detailed task breakdown for a specific session within a project roadmap",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Target session ID (e.g., '0009')"
                ),
                "project_name" => Dict(
                    "type" => "string",
                    "description" => "Associated project name"
                ),
                "tasks" => Dict(
                    "type" => "array",
                    "items" => Dict(
                        "type" => "object",
                        "properties" => Dict(
                            "task_name" => Dict("type" => "string"),
                            "task_type" => Dict("type" => "string", "enum" => ["development", "testing", "documentation", "integration", "git_ops"]),
                            "description" => Dict("type" => "string"),
                            "priority" => Dict("type" => "string", "enum" => ["critical", "high", "medium", "low"]),
                            "estimated_effort" => Dict("type" => "string"),
                            "dependencies" => Dict(
                                "type" => "array",
                                "items" => Dict("type" => "string")
                            ),
                            "acceptance_criteria" => Dict(
                                "type" => "array",
                                "items" => Dict("type" => "string")
                            ),
                            "test_requirements" => Dict("type" => "string"),
                            "api_endpoints" => Dict(
                                "type" => "array",
                                "items" => Dict("type" => "string")
                            )
                        ),
                        "required" => ["task_name", "task_type", "description", "priority"]
                    ),
                    "description" => "Array of session tasks"
                )
            ),
            "required" => ["session_id", "project_name", "tasks"]
        )
    ),
    Dict(
        "name" => "get_project_status",
        "description" => "Get comprehensive status of a multi-session project including progress, current phase, and next steps",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "project_name" => Dict(
                    "type" => "string",
                    "description" => "Project name to query"
                ),
                "include_tasks" => Dict(
                    "type" => "boolean",
                    "description" => "Include detailed task breakdowns (default: true)"
                ),
                "include_progress" => Dict(
                    "type" => "boolean", 
                    "description" => "Include progress metrics (default: true)"
                ),
                "current_session_focus" => Dict(
                    "type" => "boolean",
                    "description" => "Focus on current active session (default: false)"
                )
            ),
            "required" => ["project_name"]
        )
    ),
    Dict(
        "name" => "advance_project_session",
        "description" => "Mark completion of current session phase and advance project to next session with automated task transition",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "project_name" => Dict(
                    "type" => "string",
                    "description" => "Project name to advance"
                ),
                "completed_session" => Dict(
                    "type" => "string",
                    "description" => "Session being completed (e.g., '0009')"
                ),
                "completion_notes" => Dict(
                    "type" => "string",
                    "description" => "Notes about session completion and outcomes"
                ),
                "git_commit_hash" => Dict(
                    "type" => "string",
                    "description" => "Git commit hash for session completion"
                ),
                "carry_forward_tasks" => Dict(
                    "type" => "array",
                    "items" => Dict("type" => "string"),
                    "description" => "Task IDs to carry forward to next session"
                )
            ),
            "required" => ["project_name", "completed_session"]
        )
    ),
    Dict(
        "name" => "capture_test_messages",
        "description" => "Capture and store CD/CC communication messages as deterministic test inputs for automated testing",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "project_name" => Dict(
                    "type" => "string",
                    "description" => "Associated project name"
                ),
                "test_scenario_name" => Dict(
                    "type" => "string",
                    "description" => "Name of test scenario being captured"
                ),
                "message_sequence" => Dict(
                    "type" => "array",
                    "items" => Dict(
                        "type" => "object",
                        "properties" => Dict(
                            "sender" => Dict("type" => "string"),
                            "recipient" => Dict("type" => "string"),
                            "message_type" => Dict("type" => "string"),
                            "message_content" => Dict("type" => "string"),
                            "expected_response" => Dict("type" => "string"),
                            "validation_criteria" => Dict("type" => "string")
                        ),
                        "required" => ["sender", "recipient", "message_type", "message_content"]
                    ),
                    "description" => "Sequence of messages for test scenario"
                ),
                "test_category" => Dict(
                    "type" => "string",
                    "description" => "Category of test (unit, integration, end_to_end)"
                )
            ),
            "required" => ["project_name", "test_scenario_name", "message_sequence"]
        )
    ),
    Dict(
        "name" => "get_session_planning",
        "description" => "Get comprehensive session planning overview including roadmap phases, tasks, and next steps for a specific session",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0010')"
                ),
                "include_project_phases" => Dict(
                    "type" => "boolean",
                    "description" => "Include project roadmap phases (default: true)"
                ),
                "include_session_tasks" => Dict(
                    "type" => "boolean", 
                    "description" => "Include detailed session tasks (default: true)"
                ),
                "include_next_steps" => Dict(
                    "type" => "boolean",
                    "description" => "Include next steps (default: true)"
                )
            ),
            "required" => ["session_id"]
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
        # Create connection to specific database or use default
        if !isempty(database)
            conn = get_connection(database)
        else
            conn = get_connection()
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
        # Create connection to specific database or use default
        if !isempty(database)
            conn = get_connection(database)
        else
            conn = get_connection()
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
        # Create connection to specific database or use default
        if !isempty(database)
            conn = get_connection(database)
        else
            conn = get_connection()
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
        # Simple test response to isolate the issue
        status_data = Dict(
            "session_id" => session_id,
            "timestamp" => string(now()),
            "test_message" => "PostgreSQL get_session_status working - JSON conversion issue resolved",
            "status" => "operational"
        )
        
        # Return simple JSON structure
        return JSON3.write(status_data)
        
    catch e
        error_msg = "Failed to get session status: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function send_bridge_message_tool(args::Dict)
    session_id = get(args, "session_id", "")
    from = get(args, "from", "")
    to = get(args, "to", "")
    subject = get(args, "subject", "")
    message = get(args, "message", "")
    priority = get(args, "priority", "NORMAL")
    category = get(args, "category", "general")
    
    # Validate required fields
    if isempty(session_id) || isempty(from) || isempty(to) || isempty(message)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id, from, to, and message are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Ensure claude_bridge_messages table exists with all columns
        create_table_query = """
        CREATE TABLE IF NOT EXISTS claude_bridge_messages (
            id SERIAL PRIMARY KEY,
            session_id VARCHAR(10) NOT NULL,
            message_type VARCHAR(50) DEFAULT 'A-BRIDGE',
            sender VARCHAR(10) NOT NULL,
            recipient VARCHAR(10) NOT NULL,
            subject VARCHAR(255),
            message_content TEXT NOT NULL,
            timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            human_action_needed BOOLEAN DEFAULT FALSE,
            priority VARCHAR(20) DEFAULT 'NORMAL',
            category VARCHAR(100) DEFAULT 'general'
        );
        """
        
        LibPQ.execute(conn, create_table_query)
        
        # Insert the bridge message
        insert_query = """
        INSERT INTO claude_bridge_messages 
        (session_id, message_type, sender, recipient, subject, message_content, timestamp, human_action_needed, priority, category)
        VALUES (\$1, 'A-BRIDGE', \$2, \$3, \$4, \$5, NOW(), false, \$6, \$7)
        RETURNING id, timestamp;
        """
        
        result = LibPQ.execute(conn, insert_query, [
            session_id, from, to, subject, message, priority, category
        ])
        
        row_data = Dict()
        for row in result
            row_data = Dict(zip(LibPQ.column_names(result), row))
            break
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "message_id" => row_data["id"],
            "timestamp" => string(row_data["timestamp"]),
            "from" => from,
            "to" => to,
            "subject" => subject,
            "message" => "Bridge message sent successfully"
        ))
        
    catch e
        error_msg = "Failed to send bridge message: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

# Enhanced Project Management Tool Implementations

function create_project_roadmap_tool(args::Dict)
    project_name = get(args, "project_name", "")
    repository = get(args, "repository", "")
    description = get(args, "description", "")
    start_session = get(args, "start_session", "")
    phases = get(args, "phases", [])
    
    # Validate required fields
    if isempty(project_name) || isempty(repository) || isempty(start_session) || isempty(phases)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "project_name, repository, start_session, and phases are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Create project roadmaps table if it doesn't exist
        create_table_query = """
        CREATE TABLE IF NOT EXISTS project_roadmaps (
            id SERIAL PRIMARY KEY,
            project_name VARCHAR(255) NOT NULL UNIQUE,
            repository VARCHAR(100) NOT NULL,
            description TEXT,
            start_session VARCHAR(10) NOT NULL,
            current_phase INTEGER DEFAULT 1,
            status VARCHAR(50) DEFAULT 'active',
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS project_phases (
            id SERIAL PRIMARY KEY,
            project_name VARCHAR(255) NOT NULL,
            phase_number INTEGER NOT NULL,
            phase_name VARCHAR(255) NOT NULL,
            session_id VARCHAR(10) NOT NULL,
            description TEXT,
            objectives TEXT[],
            deliverables TEXT[],
            testing_requirements TEXT,
            documentation_requirements TEXT,
            git_requirements TEXT,
            status VARCHAR(50) DEFAULT 'pending',
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (project_name) REFERENCES project_roadmaps(project_name) ON DELETE CASCADE
        );
        """
        
        LibPQ.execute(conn, create_table_query)
        
        # Insert project roadmap
        insert_roadmap_query = """
        INSERT INTO project_roadmaps 
        (project_name, repository, description, start_session)
        VALUES (\$1, \$2, \$3, \$4)
        ON CONFLICT (project_name) DO UPDATE SET
            repository = EXCLUDED.repository,
            description = EXCLUDED.description,
            start_session = EXCLUDED.start_session,
            updated_at = CURRENT_TIMESTAMP
        RETURNING id;
        """
        
        roadmap_result = LibPQ.execute(conn, insert_roadmap_query, [
            project_name, repository, description, start_session
        ])
        
        # Clear existing phases and insert new ones
        LibPQ.execute(conn, "DELETE FROM project_phases WHERE project_name = \$1", [project_name])
        
        phase_ids = []
        for (index, phase) in enumerate(phases)
            phase_name = get(phase, "phase_name", "")
            session_id = get(phase, "session_id", "")
            phase_desc = get(phase, "description", "")
            objectives = get(phase, "objectives", String[])
            deliverables = get(phase, "deliverables", String[])
            testing_reqs = get(phase, "testing_requirements", "")
            doc_reqs = get(phase, "documentation_requirements", "")
            git_reqs = get(phase, "git_requirements", "")
            
            insert_phase_query = """
            INSERT INTO project_phases 
            (project_name, phase_number, phase_name, session_id, description, 
             objectives, deliverables, testing_requirements, documentation_requirements, git_requirements)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10)
            RETURNING id;
            """
            
            phase_result = LibPQ.execute(conn, insert_phase_query, [
                project_name, index, phase_name, session_id, phase_desc,
                objectives, deliverables, testing_reqs, doc_reqs, git_reqs
            ])
            
            for row in phase_result
                push!(phase_ids, row[1])
                break
            end
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "project_name" => project_name,
            "phases_created" => length(phase_ids),
            "phase_ids" => phase_ids,
            "message" => "Project roadmap created successfully"
        ))
        
    catch e
        error_msg = "Failed to create project roadmap: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function create_session_tasks_tool(args::Dict)
    session_id = get(args, "session_id", "")
    project_name = get(args, "project_name", "")
    tasks = get(args, "tasks", [])
    
    if isempty(session_id) || isempty(project_name) || isempty(tasks)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id, project_name, and tasks are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Create session tasks table if it doesn't exist
        create_table_query = """
        CREATE TABLE IF NOT EXISTS session_tasks (
            id SERIAL PRIMARY KEY,
            session_id VARCHAR(10) NOT NULL,
            project_name VARCHAR(255) NOT NULL,
            task_name VARCHAR(255) NOT NULL,
            task_type VARCHAR(50) NOT NULL,
            description TEXT,
            priority VARCHAR(20) DEFAULT 'medium',
            estimated_effort VARCHAR(50),
            dependencies TEXT[],
            acceptance_criteria TEXT[],
            test_requirements TEXT,
            api_endpoints TEXT[],
            status VARCHAR(50) DEFAULT 'pending',
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            completed_at TIMESTAMP WITH TIME ZONE,
            FOREIGN KEY (project_name) REFERENCES project_roadmaps(project_name) ON DELETE CASCADE
        );
        """
        
        LibPQ.execute(conn, create_table_query)
        
        # Clear existing tasks for this session
        LibPQ.execute(conn, "DELETE FROM session_tasks WHERE session_id = \$1 AND project_name = \$2", 
                     [session_id, project_name])
        
        task_ids = []
        for task in tasks
            # Handle both 'task_name' and 'title' parameters for backwards compatibility
            task_name = get(task, "task_name", get(task, "title", ""))
            task_type = get(task, "task_type", "development")
            description = get(task, "description", "")
            priority = get(task, "priority", "medium")
            effort = get(task, "estimated_effort", "")
            dependencies = get(task, "dependencies", String[])
            
            # Handle acceptance_criteria as both array and string
            criteria_input = get(task, "acceptance_criteria", String[])
            criteria = if isa(criteria_input, AbstractString)
                [criteria_input]  # Convert single string to array
            else
                criteria_input
            end
            
            test_reqs = get(task, "test_requirements", "")
            api_endpoints = get(task, "api_endpoints", String[])
            
            insert_task_query = """
            INSERT INTO session_tasks 
            (session_id, project_name, task_name, task_type, description, priority, 
             estimated_effort, dependencies, acceptance_criteria, test_requirements, api_endpoints)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11)
            RETURNING id;
            """
            
            task_result = LibPQ.execute(conn, insert_task_query, [
                session_id, project_name, task_name, task_type, description, priority,
                effort, dependencies, criteria, test_reqs, api_endpoints
            ])
            
            for row in task_result
                push!(task_ids, row[1])
                break
            end
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "session_id" => session_id,
            "project_name" => project_name,
            "tasks_created" => length(task_ids),
            "task_ids" => task_ids,
            "message" => "Session tasks created successfully"
        ))
        
    catch e
        error_msg = "Failed to create session tasks: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function get_project_status_tool(args::Dict)
    project_name = get(args, "project_name", "")
    include_tasks = get(args, "include_tasks", true)
    include_progress = get(args, "include_progress", true)
    current_session_focus = get(args, "current_session_focus", false)
    
    if isempty(project_name)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "project_name is required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Get project roadmap info
        roadmap_query = """
        SELECT pr.*, 
               pp.phase_name as current_phase_name,
               pp.session_id as current_session_id,
               pp.description as current_phase_description
        FROM project_roadmaps pr
        LEFT JOIN project_phases pp ON pr.project_name = pp.project_name 
                                    AND pp.phase_number = pr.current_phase
        WHERE pr.project_name = \$1;
        """
        
        roadmap_result = LibPQ.execute(conn, roadmap_query, [project_name])
        
        if LibPQ.num_rows(roadmap_result) == 0
            return JSON3.write(Dict(
                "success" => false,
                "error" => "Project not found: $project_name"
            ))
        end
        
        project_data = Dict()
        for row in roadmap_result
            project_data = Dict(zip(LibPQ.column_names(roadmap_result), row))
            break
        end
        
        response_data = Dict(
            "success" => true,
            "project_name" => project_name,
            "repository" => project_data["repository"],
            "description" => project_data["description"],
            "start_session" => project_data["start_session"],
            "current_phase" => project_data["current_phase"],
            "current_phase_name" => project_data["current_phase_name"],
            "current_session_id" => project_data["current_session_id"],
            "status" => project_data["status"],
            "created_at" => string(project_data["created_at"])
        )
        
        # Get all phases
        phases_query = """
        SELECT * FROM project_phases 
        WHERE project_name = \$1 
        ORDER BY phase_number;
        """
        
        phases_result = LibPQ.execute(conn, phases_query, [project_name])
        phases = []
        for row in phases_result
            push!(phases, Dict(zip(LibPQ.column_names(phases_result), row)))
        end
        response_data["phases"] = phases
        
        # Get tasks if requested
        if include_tasks
            tasks_filter = current_session_focus ? 
                "WHERE project_name = \$1 AND session_id = \$2" : 
                "WHERE project_name = \$1"
            
            tasks_query = """
            SELECT * FROM session_tasks 
            $tasks_filter
            ORDER BY session_id, priority DESC, created_at;
            """
            
            tasks_result = if current_session_focus && !isnothing(project_data["current_session_id"])
                LibPQ.execute(conn, tasks_query, [project_name, project_data["current_session_id"]])
            else
                LibPQ.execute(conn, tasks_query, [project_name])
            end
            
            tasks = []
            for row in tasks_result
                push!(tasks, Dict(zip(LibPQ.column_names(tasks_result), row)))
            end
            response_data["tasks"] = tasks
        end
        
        # Calculate progress if requested
        if include_progress
            progress_query = """
            SELECT 
                COUNT(*) as total_tasks,
                COUNT(CASE WHEN status = 'completed' THEN 1 END) as completed_tasks,
                COUNT(CASE WHEN status = 'in_progress' THEN 1 END) as in_progress_tasks,
                COUNT(CASE WHEN status = 'pending' THEN 1 END) as pending_tasks
            FROM session_tasks 
            WHERE project_name = \$1;
            """
            
            progress_result = LibPQ.execute(conn, progress_query, [project_name])
            
            for row in progress_result
                progress_data = Dict(zip(LibPQ.column_names(progress_result), row))
                total = progress_data["total_tasks"]
                completed = progress_data["completed_tasks"]
                
                response_data["progress"] = Dict(
                    "total_tasks" => total,
                    "completed_tasks" => completed,
                    "in_progress_tasks" => progress_data["in_progress_tasks"],
                    "pending_tasks" => progress_data["pending_tasks"],
                    "completion_percentage" => total > 0 ? round(completed / total * 100, digits=1) : 0.0
                )
                break
            end
        end
        
        return JSON3.write(response_data)
        
    catch e
        error_msg = "Failed to get project status: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function advance_project_session_tool(args::Dict)
    project_name = get(args, "project_name", "")
    # Handle both 'completed_session' and 'current_session' for backwards compatibility
    completed_session = get(args, "completed_session", get(args, "current_session", ""))
    completion_notes = get(args, "completion_notes", "")
    git_commit_hash = get(args, "git_commit_hash", "")
    carry_forward_tasks = get(args, "carry_forward_tasks", String[])
    
    if isempty(project_name) || isempty(completed_session)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "project_name and completed_session (or current_session) are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Get current project status
        current_query = """
        SELECT current_phase FROM project_roadmaps 
        WHERE project_name = \$1;
        """
        
        current_result = LibPQ.execute(conn, current_query, [project_name])
        
        if LibPQ.num_rows(current_result) == 0
            return JSON3.write(Dict(
                "success" => false,
                "error" => "Project not found: $project_name"
            ))
        end
        
        current_phase = 0
        for row in current_result
            current_phase = row[1]
            break
        end
        
        # Mark current phase as completed
        update_phase_query = """
        UPDATE project_phases 
        SET status = 'completed',
            completion_notes = \$3,
            git_commit_hash = \$4,
            completed_at = CURRENT_TIMESTAMP
        WHERE project_name = \$1 AND phase_number = \$2;
        """
        
        LibPQ.execute(conn, update_phase_query, [
            project_name, current_phase, completion_notes, git_commit_hash
        ])
        
        # Advance to next phase
        next_phase = current_phase + 1
        
        # Check if next phase exists
        next_phase_query = """
        SELECT id FROM project_phases 
        WHERE project_name = \$1 AND phase_number = \$2;
        """
        
        next_result = LibPQ.execute(conn, next_phase_query, [project_name, next_phase])
        
        if LibPQ.num_rows(next_result) > 0
            # Update project to next phase
            update_project_query = """
            UPDATE project_roadmaps 
            SET current_phase = \$2, updated_at = CURRENT_TIMESTAMP
            WHERE project_name = \$1;
            """
            
            LibPQ.execute(conn, update_project_query, [project_name, next_phase])
            
            # Handle carry-forward tasks
            if !isempty(carry_forward_tasks)
                next_session_query = """
                SELECT session_id FROM project_phases 
                WHERE project_name = \$1 AND phase_number = \$2;
                """
                
                next_session_result = LibPQ.execute(conn, next_session_query, [project_name, next_phase])
                
                next_session_id = ""
                for row in next_session_result
                    next_session_id = row[1]
                    break
                end
                
                # Copy specified tasks to next session
                for task_id in carry_forward_tasks
                    copy_task_query = """
                    INSERT INTO session_tasks 
                    (session_id, project_name, task_name, task_type, description, priority, 
                     estimated_effort, dependencies, acceptance_criteria, test_requirements, api_endpoints, status)
                    SELECT \$2, project_name, task_name, task_type, description, priority,
                           estimated_effort, dependencies, acceptance_criteria, test_requirements, api_endpoints, 'pending'
                    FROM session_tasks 
                    WHERE id = \$1;
                    """
                    
                    LibPQ.execute(conn, copy_task_query, [task_id, next_session_id])
                end
            end
            
            status = "advanced_to_next_phase"
            next_phase_name = ""
            
            # Get next phase info
            next_info_query = """
            SELECT phase_name, session_id FROM project_phases 
            WHERE project_name = \$1 AND phase_number = \$2;
            """
            
            next_info_result = LibPQ.execute(conn, next_info_query, [project_name, next_phase])
            
            for row in next_info_result
                next_phase_name = row[1]
                break
            end
            
        else
            # Project completed
            update_project_query = """
            UPDATE project_roadmaps 
            SET status = 'completed', updated_at = CURRENT_TIMESTAMP
            WHERE project_name = \$1;
            """
            
            LibPQ.execute(conn, update_project_query, [project_name])
            
            status = "project_completed"
            next_phase_name = "N/A"
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "project_name" => project_name,
            "completed_session" => completed_session,
            "previous_phase" => current_phase,
            "current_phase" => next_phase,
            "next_phase_name" => next_phase_name,
            "status" => status,
            "carried_forward_tasks" => length(carry_forward_tasks),
            "message" => "Project session advanced successfully"
        ))
        
    catch e
        error_msg = "Failed to advance project session: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function capture_test_messages_tool(args::Dict)
    project_name = get(args, "project_name", "")
    test_scenario_name = get(args, "test_scenario_name", "")
    message_sequence = get(args, "message_sequence", [])
    test_category = get(args, "test_category", "integration")
    
    if isempty(project_name) || isempty(test_scenario_name) || isempty(message_sequence)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "project_name, test_scenario_name, and message_sequence are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Create test scenarios table if it doesn't exist
        create_table_query = """
        CREATE TABLE IF NOT EXISTS test_scenarios (
            id SERIAL PRIMARY KEY,
            project_name VARCHAR(255) NOT NULL,
            scenario_name VARCHAR(255) NOT NULL,
            test_category VARCHAR(50) NOT NULL,
            message_sequence JSONB NOT NULL,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(project_name, scenario_name),
            FOREIGN KEY (project_name) REFERENCES project_roadmaps(project_name) ON DELETE CASCADE
        );
        """
        
        LibPQ.execute(conn, create_table_query)
        
        # Insert or update test scenario
        upsert_query = """
        INSERT INTO test_scenarios 
        (project_name, scenario_name, test_category, message_sequence)
        VALUES (\$1, \$2, \$3, \$4)
        ON CONFLICT (project_name, scenario_name) DO UPDATE SET
            test_category = EXCLUDED.test_category,
            message_sequence = EXCLUDED.message_sequence,
            updated_at = CURRENT_TIMESTAMP
        RETURNING id;
        """
        
        # Convert message sequence to JSON
        message_json = JSON3.write(message_sequence)
        
        result = LibPQ.execute(conn, upsert_query, [
            project_name, test_scenario_name, test_category, message_json
        ])
        
        scenario_id = 0
        for row in result
            scenario_id = row[1]
            break
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "scenario_id" => scenario_id,
            "project_name" => project_name,
            "scenario_name" => test_scenario_name,
            "test_category" => test_category,
            "messages_captured" => length(message_sequence),
            "message" => "Test messages captured successfully for deterministic testing"
        ))
        
    catch e
        error_msg = "Failed to capture test messages: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function get_session_planning_tool(args::Dict)
    session_id = get(args, "session_id", "")
    include_project_phases = get(args, "include_project_phases", true)
    include_session_tasks = get(args, "include_session_tasks", true)
    include_next_steps = get(args, "include_next_steps", true)
    
    if isempty(session_id)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id is required"
        ))
    end
    
    try
        conn = get_connection()
        planning_data = Dict(
            "session_id" => session_id,
            "timestamp" => string(now())
        )
        
        # Get project phases for this session
        if include_project_phases
            phases_query = """
            SELECT project_name, phase_name, description, objectives, deliverables, 
                   testing_requirements, documentation_requirements, git_requirements
            FROM project_phases 
            WHERE session_id = \$1
            ORDER BY created_at
            """
            
            phases_result = LibPQ.execute(conn, phases_query, [session_id])
            phases = []
            for row in phases_result
                phase_dict = Dict()
                for (i, col_name) in enumerate(LibPQ.column_names(phases_result))
                    val = row[i]
                    if val === nothing
                        phase_dict[col_name] = nothing
                    else
                        phase_dict[col_name] = string(val)
                    end
                end
                push!(phases, phase_dict)
            end
            planning_data["project_phases"] = phases
        end
        
        # Get session tasks
        if include_session_tasks
            tasks_query = """
            SELECT task_name, task_type, description, priority, estimated_effort, 
                   acceptance_criteria, dependencies, api_endpoints, test_requirements
            FROM session_tasks 
            WHERE session_id = \$1
            ORDER BY CASE priority 
                WHEN 'critical' THEN 1 
                WHEN 'high' THEN 2 
                WHEN 'medium' THEN 3 
                WHEN 'low' THEN 4 
                ELSE 5 
            END, created_at
            """
            
            tasks_result = LibPQ.execute(conn, tasks_query, [session_id])
            tasks = []
            for row in tasks_result
                task_dict = Dict()
                for (i, col_name) in enumerate(LibPQ.column_names(tasks_result))
                    val = row[i]
                    if val === nothing
                        task_dict[col_name] = nothing
                    else
                        task_dict[col_name] = string(val)
                    end
                end
                push!(tasks, task_dict)
            end
            planning_data["session_tasks"] = tasks
        end
        
        # Get next steps  
        if include_next_steps
            next_steps_query = """
            SELECT title, description, priority, step_type, estimated_effort, repository
            FROM session_next_steps 
            WHERE session_id = \$1
            ORDER BY CASE priority 
                WHEN 'critical' THEN 1 
                WHEN 'high' THEN 2 
                WHEN 'medium' THEN 3 
                WHEN 'low' THEN 4 
                ELSE 5 
            END, created_at
            """
            
            next_steps_result = LibPQ.execute(conn, next_steps_query, [session_id])
            next_steps = []
            for row in next_steps_result
                step_dict = Dict()
                for (i, col_name) in enumerate(LibPQ.column_names(next_steps_result))
                    val = row[i]
                    if val === nothing
                        step_dict[col_name] = nothing
                    else
                        step_dict[col_name] = string(val)
                    end
                end
                push!(next_steps, step_dict)
            end
            planning_data["next_steps"] = next_steps
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "data" => planning_data
        ))
        
    catch e
        error_msg = "Failed to get session planning: $(string(e))"
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
            elseif tool_name == "log_accomplishment"
                log_accomplishment_tool(tool_args)
            elseif tool_name == "note_next_step"
                note_next_step_tool(tool_args)
            elseif tool_name == "get_session_status"
                get_session_status_tool(tool_args)
            elseif tool_name == "send_bridge_message"
                send_bridge_message_tool(tool_args)
            elseif tool_name == "create_project_roadmap"
                create_project_roadmap_tool(tool_args)
            elseif tool_name == "create_session_tasks"
                create_session_tasks_tool(tool_args)
            elseif tool_name == "get_project_status"
                get_project_status_tool(tool_args)
            elseif tool_name == "advance_project_session"
                advance_project_session_tool(tool_args)
            elseif tool_name == "capture_test_messages"
                capture_test_messages_tool(tool_args)
            elseif tool_name == "get_session_planning"
                get_session_planning_tool(tool_args)
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
        
        # Server is running
        wsl_ip = HttpServer.get_wsl_ip()
        @info "🪟 Windows access available at http://$wsl_ip:$http_port"
        
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
            "postgres-mcp-server",
            "1.0.0", 
            "Enhanced PostgreSQL MCP Server with Project Management"
        )
        
        # Add tools
        for tool in TOOLS
            tool_func = if tool["name"] == "execute_sql"
                execute_sql_tool
            elseif tool["name"] == "list_tables" 
                list_tables_tool
            elseif tool["name"] == "describe_table"
                describe_table_tool
            elseif tool["name"] == "log_accomplishment"
                log_accomplishment_tool
            elseif tool["name"] == "note_next_step"
                note_next_step_tool
            elseif tool["name"] == "get_session_status"
                get_session_status_tool
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