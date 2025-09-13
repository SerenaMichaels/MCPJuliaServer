#!/usr/bin/env julia
# HTTP-enabled PostgreSQL MCP Server
# Provides both stdio MCP interface and HTTP REST API for cross-platform access

using Pkg
Pkg.activate(".")

include("src/MCPEnvironment.jl")
using .MCPEnvironment

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

# ============================================================================
# SCHEMA-DRIVEN DATABASE ACCESS SYSTEM
# ============================================================================

# Database schema management - loads from BotFarm SCHEMA.md file
struct ColumnSchema
    name::String
    type::String
    nullable::Bool
    default_value::Union{String, Nothing}
    description::String
end

struct TableSchema
    name::String
    columns::Vector{ColumnSchema}
    purpose::String
end

# Global schema cache
const SCHEMA_CACHE = Dict{String, TableSchema}()
const SCHEMA_VERSION = "1.0.0"
const SCHEMA_PATH = "/mnt/d/MCP-Agents/repos/BotFarm/database/SCHEMA.md"

# Parse SCHEMA.md file to extract table definitions
function parse_schema_file(schema_path::String = SCHEMA_PATH)
    @info "Loading database schema from: $schema_path"
    
    if !isfile(schema_path)
        @error "Schema file not found: $schema_path"
        return Dict{String, TableSchema}()
    end
    
    schema_dict = Dict{String, TableSchema}()
    
    try
        content = read(schema_path, String)
        lines = split(content, '\n')
        
        current_table = nothing
        current_purpose = ""
        columns = ColumnSchema[]
        in_table_section = false
        
        for line in lines
            line = strip(line)
            
            # Match table headers: #### table_name
            table_match = match(r"^#### ([a-z_]+)$", line)
            if table_match !== nothing
                # Save previous table if exists
                if current_table !== nothing
                    schema_dict[current_table] = TableSchema(current_table, copy(columns), current_purpose)
                end
                
                current_table = table_match[1]
                columns = ColumnSchema[]
                current_purpose = ""
                in_table_section = true
                continue
            end
            
            # Match purpose line: **Purpose**: Description
            purpose_match = match(r"^\*\*Purpose\*\*: (.+)$", line)
            if purpose_match !== nothing && in_table_section
                current_purpose = purpose_match[1]
                continue
            end
            
            # Skip table header row and separator
            if line == "| Column | Type | Nullable | Default | Description |" || 
               line == "|--------|------|----------|---------|-------------|"
                continue
            end
            
            # Parse column definition row
            if startswith(line, "|") && in_table_section && !isempty(line)
                parts = [strip(part) for part in split(line, '|')][2:end-1] # Remove empty first/last
                if length(parts) == 5
                    col_name = parts[1]
                    col_type = parts[2] 
                    nullable = parts[3] == "YES"
                    default_val = parts[4] == "-" ? nothing : parts[4]
                    description = parts[5]
                    
                    push!(columns, ColumnSchema(col_name, col_type, nullable, default_val, description))
                end
            end
            
            # End of table section
            if isempty(line) && in_table_section && !isempty(columns)
                in_table_section = false
            end
        end
        
        # Save final table
        if current_table !== nothing
            schema_dict[current_table] = TableSchema(current_table, copy(columns), current_purpose)
        end
        
        @info "✅ Loaded $(length(schema_dict)) table schemas from SCHEMA.md"
        
    catch e
        @error "Failed to parse schema file: $e"
        return Dict{String, TableSchema}()
    end
    
    return schema_dict
end

# Convert PostgreSQL result value to appropriate Julia type based on schema
function convert_pg_value(value, column_schema::ColumnSchema)
    if value === nothing
        return column_schema.nullable ? nothing : ""
    end
    
    # Handle different PostgreSQL types
    col_type_lower = lowercase(column_schema.type)
    
    if startswith(col_type_lower, "varchar") || col_type_lower == "text"
        return string(value)
    elseif col_type_lower == "integer" || col_type_lower == "int"
        return value isa Integer ? value : parse(Int, string(value))
    elseif col_type_lower == "boolean"
        return value isa Bool ? value : (string(value) in ["t", "true", "1"])
    elseif startswith(col_type_lower, "timestamp")
        return string(value) # Keep as string for JSON serialization
    elseif col_type_lower == "array"
        # PostgreSQL arrays - convert to JSON-serializable format
        if value isa AbstractVector
            return [String(item) for item in value] # Ensure all elements are String type
        else
            # Parse PostgreSQL array format like {item1,item2,item3}
            array_str = string(value)
            if startswith(array_str, "{") && endswith(array_str, "}")
                # Remove braces and split by comma
                inner = array_str[2:end-1]
                if isempty(inner)
                    return String[]
                else
                    return [String(strip(item, ['"', ' '])) for item in split(inner, ",")]
                end
            else
                return [String(array_str)]
            end
        end
    elseif col_type_lower == "jsonb" || col_type_lower == "json"
        # Handle JSON fields - keep as string for now, can be parsed later if needed
        return string(value)
    else
        # Default: convert to string
        return string(value)
    end
end

# Robust database query function with schema-driven result conversion
function execute_query_with_schema(conn, query::String, params::Vector = String[], table_names::Vector{String} = String[])
    try
        # Apply schema compliance translation before executing query
        original_query = query
        translated_query = translate_query_for_schema_compliance(query)
        
        # Log translation if query was modified
        if translated_query != original_query
            @info "🔧 Schema compliance translation applied (with_schema)" original=original_query translated=translated_query
        end
        
        result = LibPQ.execute(conn, translated_query, params)
        
        # If no table names provided, return raw result conversion
        if isempty(table_names)
            rows = []
            for row in result
                row_dict = Dict{String, Any}()
                for (i, col_name) in enumerate(LibPQ.column_names(result))
                    row_dict[col_name] = row[i] === nothing ? nothing : string(row[i])
                end
                push!(rows, row_dict)
            end
            return rows
        end
        
        # Schema-driven conversion for specific tables
        primary_table = table_names[1]
        if !haskey(SCHEMA_CACHE, primary_table)
            @warn "Schema not found for table: $primary_table, falling back to string conversion"
            # Fallback to string conversion
            rows = []
            for row in result
                row_dict = Dict{String, Any}()
                for (i, col_name) in enumerate(LibPQ.column_names(result))
                    row_dict[col_name] = row[i] === nothing ? "" : string(row[i])
                end
                push!(rows, row_dict)
            end
            return rows
        end
        
        table_schema = SCHEMA_CACHE[primary_table]
        column_schemas = Dict(col.name => col for col in table_schema.columns)
        
        rows = []
        for row in result
            row_dict = Dict{String, Any}()
            for (i, col_name) in enumerate(LibPQ.column_names(result))
                if haskey(column_schemas, col_name)
                    row_dict[col_name] = convert_pg_value(row[i], column_schemas[col_name])
                else
                    # Column not in schema, use string conversion
                    row_dict[col_name] = row[i] === nothing ? "" : string(row[i])
                end
            end
            push!(rows, row_dict)
        end
        
        return rows
        
    catch e
        # Enhanced diagnostic error reporting for schema queries  
        stack_trace = catch_backtrace()
        calling_function = "execute_query_with_schema"
        
        error_type = typeof(e)
        error_details = string(e)
        
        # Extract SQL query snippet for context
        query_preview = length(query) > 200 ? query[1:200] * "..." : query
        
        enhanced_error_msg = """
        ❌ SCHEMA QUERY EXECUTION FAILURE - FULL DIAGNOSTICS:
        
        🔍 ERROR DETAILS:
           Type: $(error_type)
           Message: $(error_details)
           Function: $(calling_function)
           Timestamp: $(Dates.now())
        
        📝 QUERY CONTEXT:
           Query Length: $(length(query)) characters
           Query Preview: $(query_preview)
           Table Names Provided: $(table_names)
           Parameters: $(params)
        
        🧬 STACK TRACE:
           $(join(string.(stack_trace[1:min(5, length(stack_trace))]), "\n           "))
        
        🔧 SCHEMA STATUS:
           Schema Cache Size: $(length(SCHEMA_CACHE)) tables
           Tables Referenced: $(extract_table_names(query))
           Available Tables: $(join(collect(keys(SCHEMA_CACHE)), ", "))
        """
        
        @error enhanced_error_msg
        rethrow(e)
    end
end

# Extract table names from SQL query for diagnostics
function extract_table_names(query::String)
    table_names = String[]
    
    # Simple regex patterns to find table names
    # Match "FROM table_name" and "JOIN table_name"
    from_pattern = r"(?i)(?:FROM|JOIN)\s+([a-zA-Z_][a-zA-Z0-9_]*)"
    matches = eachmatch(from_pattern, query)
    
    for match in matches
        table_name = match.captures[1]
        if table_name !== nothing && !(table_name in table_names)
            push!(table_names, table_name)
        end
    end
    
    # Also check for INSERT INTO and UPDATE statements
    insert_pattern = r"(?i)INSERT\s+INTO\s+([a-zA-Z_][a-zA-Z0-9_]*)"
    update_pattern = r"(?i)UPDATE\s+([a-zA-Z_][a-zA-Z0-9_]*)"
    
    for pattern in [insert_pattern, update_pattern]
        matches = eachmatch(pattern, query)
        for match in matches
            table_name = match.captures[1]
            if table_name !== nothing && !(table_name in table_names)
                push!(table_names, table_name)
            end
        end
    end
    
    return isempty(table_names) ? ["[no tables detected]"] : table_names
end

# Initialize schema cache
function init_schema_cache()
    @info "Initializing database schema cache..."
    global SCHEMA_CACHE
    schema_dict = parse_schema_file()
    merge!(SCHEMA_CACHE, schema_dict)
    @info "✅ Schema cache initialized with $(length(SCHEMA_CACHE)) tables"
end

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
    
    # Initialize schema cache after connection pool is ready
    init_schema_cache()
end

# Schema compliance translation layer
function translate_query_for_schema_compliance(query::String)
    """
    Translate queries to use correct table and column names according to official SCHEMA.md
    This handles external clients that may use outdated or incorrect naming conventions.
    """
    translated_query = query
    
    # Table name translations
    table_mappings = Dict(
        "accomplishments" => "session_accomplishments",
        "blender_assets" => "components", 
        "current_session" => "project_phases", # Use project_phases as proxy for session tracking
        "assets.blender_assets" => "components"
    )
    
    # Column name translations by table context
    column_mappings = Dict(
        "project_phases" => Dict(
            "updated_at" => "created_at"
        ),
        "claude_bridge_messages" => Dict(
            "message" => "message_content",
            "created_at" => "timestamp"  # claude_bridge_messages uses timestamp, not created_at
        ),
        "session_accomplishments" => Dict(
            "timestamp" => "created_at"
        ),
        "components" => Dict(
            "name" => "component_name",
            "file_path" => "cad_file_path"
        )
    )
    
    # Apply table name translations
    for (old_table, new_table) in table_mappings
        # Handle FROM clauses
        translated_query = replace(translated_query, r"\bFROM\s+" * old_table * r"\b" => "FROM " * new_table)
        # Handle JOIN clauses  
        translated_query = replace(translated_query, r"\bJOIN\s+" * old_table * r"\b" => "JOIN " * new_table)
        # Handle table references in subqueries
        translated_query = replace(translated_query, r"\b" * old_table * r"\." => new_table * ".")
    end
    
    # Apply column name translations with context awareness
    for (table_name, col_mappings) in column_mappings
        # Only apply column translations if the query references this table
        if occursin(table_name, translated_query)
            for (old_col, new_col) in col_mappings
                # Match column references with word boundaries to avoid partial matches
                translated_query = replace(translated_query, r"\b" * old_col * r"\b" => new_col)
            end
        end
    end
    
    # Handle database references - remove "assets." prefix since everything is in botfarm database
    translated_query = replace(translated_query, r"\bassets\." => "")
    
    # Special case: current_session table doesn't exist, map to appropriate project_phases query
    if occursin("current_session", query) && occursin("ORDER BY", query)
        # Replace current_session queries with project_phases queries for active session tracking
        translated_query = replace(translated_query, 
            r"SELECT \* FROM current_session ORDER BY updated_at DESC LIMIT.*" => 
            "SELECT session_id, phase_name, status, created_at FROM project_phases WHERE status IN ('active', 'in_progress') ORDER BY created_at DESC LIMIT 1")
    end
    
    return translated_query
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

# Update session status file to keep it synchronized with database
function update_session_status_file(session_id::String)
    status_file_path = "/mnt/d/MCP-Agents/data/CURRENT_SESSION_STATUS.json"
    
    try
        conn = get_connection()
        
        # Get current session focus and major accomplishments
        session_query = """
        SELECT title, description 
        FROM session_accomplishments 
        WHERE session_id = \$1 
        ORDER BY created_at DESC 
        LIMIT 10
        """
        
        result = LibPQ.execute(conn, session_query, [session_id])
        accomplishments = []
        session_focus = "System Development"
        
        for (i, row) in enumerate(result)
            title = row[1] === nothing ? "Untitled" : string(row[1])
            description = row[2] === nothing ? "" : string(row[2])
            push!(accomplishments, title)
            
            # Use first accomplishment title as potential session focus
            if i == 1 && occursin("Session", title)
                session_focus = title
            end
        end
        
        # Get next steps
        next_steps_query = """
        SELECT title, description 
        FROM session_next_steps 
        WHERE session_id = \$1 AND status = 'pending'
        ORDER BY priority DESC, created_at 
        LIMIT 5
        """
        
        next_result = LibPQ.execute(conn, next_steps_query, [session_id])
        next_objectives = []
        
        for row in next_result
            title = row[1] === nothing ? "Untitled" : string(row[1])
            push!(next_objectives, title)
        end
        
        # Create simple status update
        timestamp = string(now())
        simple_update = Dict(
            "session_id" => session_id,
            "session_focus" => session_focus,
            "last_updated" => timestamp,
            "system_status" => "operational_with_auto_sync",
            "major_accomplishments" => accomplishments[1:min(3, length(accomplishments))],
            "next_objectives" => next_objectives[1:min(3, length(next_objectives))],
            "sync_note" => "Auto-updated by PostgreSQL MCP session management tools"
        )
        
        # Write simple JSON to avoid complex data structure issues
        json_string = JSON3.write(simple_update)
        open(status_file_path, "w") do f
            write(f, json_string)
        end
        
        @info "✅ Session status file updated for session $session_id"
        return true
        
    catch e
        @warn "⚠️ Failed to update session status file: $e"
        return false
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
    ),
    Dict(
        "name" => "add_subtask",
        "description" => "Add a subtask to an existing next step or create a new bundled task group",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0010')"
                ),
                "parent_title" => Dict(
                    "type" => "string", 
                    "description" => "Title of parent task/step (optional - creates new group if not found)"
                ),
                "subtask_title" => Dict(
                    "type" => "string",
                    "description" => "Title of the new subtask"
                ),
                "description" => Dict(
                    "type" => "string",
                    "description" => "Detailed description of the subtask"
                ),
                "priority" => Dict(
                    "type" => "string",
                    "enum" => ["critical", "high", "medium", "low"],
                    "description" => "Priority level (default: medium)"
                ),
                "estimated_effort" => Dict(
                    "type" => "string",
                    "description" => "Estimated effort (e.g., '1 hour', '30 minutes')"
                )
            ),
            "required" => ["session_id", "subtask_title", "description"]
        )
    ),
    Dict(
        "name" => "complete_task_bundle",
        "description" => "Mark multiple related tasks as completed and log as accomplishment in single operation",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0010')"
                ),
                "task_titles" => Dict(
                    "type" => "array",
                    "items" => Dict("type" => "string"),
                    "description" => "Array of task titles to mark as completed"
                ),
                "bundle_title" => Dict(
                    "type" => "string",
                    "description" => "Title for the completion accomplishment"
                ),
                "bundle_description" => Dict(
                    "type" => "string", 
                    "description" => "Description of what was accomplished"
                ),
                "repository" => Dict(
                    "type" => "string",
                    "description" => "Repository name (BotFarm, MCPJuliaServers, etc.)"
                ),
                "files_modified" => Dict(
                    "type" => "array",
                    "items" => Dict("type" => "string"),
                    "description" => "List of files modified (optional)"
                )
            ),
            "required" => ["session_id", "task_titles", "bundle_title", "bundle_description", "repository"]
        )
    ),
    Dict(
        "name" => "session_checkpoint",
        "description" => "Create a session checkpoint with status summary and progress snapshot",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0010')"
                ),
                "checkpoint_name" => Dict(
                    "type" => "string",
                    "description" => "Name/identifier for this checkpoint"
                ),
                "summary" => Dict(
                    "type" => "string",
                    "description" => "Summary of current session progress"
                ),
                "include_bridge_message" => Dict(
                    "type" => "boolean",
                    "description" => "Send checkpoint notification to CD via bridge (default: true)"
                )
            ),
            "required" => ["session_id", "checkpoint_name", "summary"]
        )
    ),
    Dict(
        "name" => "get_phase_requirements",
        "description" => "Get detailed requirements for a specific project phase",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0010')"
                ),
                "phase_name" => Dict(
                    "type" => "string",
                    "description" => "Phase name to get requirements for"
                )
            ),
            "required" => ["session_id", "phase_name"]
        )
    ),
    Dict(
        "name" => "list_phases",
        "description" => "List all phases for a session with status overview",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0010')"
                )
            ),
            "required" => ["session_id"]
        )
    ),
    Dict(
        "name" => "initialize_session",
        "description" => "Initialize a session by setting it to active and resetting its tasks/next steps to pending",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier to initialize (e.g., '0012')"
                )
            ),
            "required" => ["session_id"]
        )
    ),
    Dict(
        "name" => "update_phase_status",
        "description" => "Update the status of a project phase",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0010')"
                ),
                "phase_name" => Dict(
                    "type" => "string",
                    "description" => "Phase name to update"
                ),
                "status" => Dict(
                    "type" => "string",
                    "description" => "New status (pending, in_progress, completed, blocked)"
                )
            ),
            "required" => ["session_id", "phase_name", "status"]
        )
    ),
    Dict(
        "name" => "get_project_roadmap",
        "description" => "Get comprehensive project roadmap with all phases and sessions",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "project_name" => Dict(
                    "type" => "string",
                    "description" => "Optional project name filter (default: all projects)"
                ),
                "include_completed" => Dict(
                    "type" => "boolean",
                    "description" => "Include completed phases (default: true)"
                ),
                "session_range" => Dict(
                    "type" => "object",
                    "properties" => Dict(
                        "start_session" => Dict("type" => "string"),
                        "end_session" => Dict("type" => "string")
                    ),
                    "description" => "Optional session range filter (e.g., start: '0010', end: '0015')"
                )
            )
        )
    ),
    Dict(
        "name" => "get_session_summary", 
        "description" => "Get detailed summary of a specific session with accomplishments and planning",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "session_id" => Dict(
                    "type" => "string",
                    "description" => "Session identifier (e.g., '0012')"
                ),
                "include_tasks" => Dict(
                    "type" => "boolean", 
                    "description" => "Include session tasks (default: true)"
                ),
                "include_phases" => Dict(
                    "type" => "boolean",
                    "description" => "Include project phases for this session (default: true)"
                ),
                "include_metrics" => Dict(
                    "type" => "boolean",
                    "description" => "Include completion metrics and statistics (default: true)"
                )
            ),
            "required" => ["session_id"]
        )
    ),
    Dict(
        "name" => "plan_next_session",
        "description" => "Create planning for the next session based on current progress",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "current_session_id" => Dict(
                    "type" => "string",
                    "description" => "Current session identifier (e.g., '0012')"
                ),
                "next_session_id" => Dict(
                    "type" => "string",
                    "description" => "Next session identifier (e.g., '0013')"
                ),
                "focus_area" => Dict(
                    "type" => "string",
                    "description" => "Primary focus area for next session"
                ),
                "carry_forward_incomplete" => Dict(
                    "type" => "boolean",
                    "description" => "Carry forward incomplete tasks from current session (default: true)"
                )
            ),
            "required" => ["current_session_id", "next_session_id"]
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
        # Apply schema compliance translation before executing query
        original_query = query
        translated_query = translate_query_for_schema_compliance(query)
        
        # Log translation if query was modified
        if translated_query != original_query
            @info "🔧 Schema compliance translation applied" original=original_query translated=translated_query
        end
        
        # Create connection to specific database or use default
        if !isempty(database)
            conn = get_connection(database)
        else
            conn = get_connection()
        end
        
        result = LibPQ.execute(conn, translated_query)
        
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
        # Enhanced diagnostic error reporting
        stack_trace = catch_backtrace()
        calling_function = "execute_sql_tool"
        
        # Get more detailed error information
        error_type = typeof(e)
        error_details = string(e)
        
        # Extract SQL query snippet for context
        query_preview = length(query) > 200 ? query[1:200] * "..." : query
        
        # Enhanced error message with full diagnostics
        error_msg = """
        ❌ SQL EXECUTION FAILURE - FULL DIAGNOSTICS:
        
        🔍 ERROR DETAILS:
           Type: $(error_type)
           Message: $(error_details)
           Function: $(calling_function)
           Timestamp: $(Dates.now())
        
        📝 QUERY CONTEXT:
           Database: $(database)
           Query Length: $(length(query)) characters
           Query Preview: $(query_preview)
        
        🧬 STACK TRACE:
           $(join(string.(stack_trace[1:min(5, length(stack_trace))]), "\n           "))
        
        🔧 SCHEMA COMPLIANCE CHECK:
           Tables Referenced: $(extract_table_names(query))
           Available Tables: $(length(SCHEMA_CACHE)) loaded from schema
        """
        
        @error error_msg
        
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg,
            "error_type" => string(error_type),
            "error_details" => error_details,
            "query" => query,
            "query_length" => length(query),
            "timestamp" => string(Dates.now()),
            "calling_function" => calling_function,
            "available_tables" => collect(keys(SCHEMA_CACHE))
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
        conn = get_connection()
        
        # Get session accomplishments using schema-driven query
        accomplishments = []
        if include_accomplishments
            accomplishments_query = "SELECT title, description, accomplishment_type, success_level, created_at FROM session_accomplishments WHERE session_id = \$1 ORDER BY created_at DESC LIMIT 10"
            accomplishments = execute_query_with_schema(conn, accomplishments_query, [session_id], ["session_accomplishments"])
            # Rename accomplishment_type to type for compatibility
            for acc in accomplishments
                if haskey(acc, "accomplishment_type")
                    acc["type"] = acc["accomplishment_type"]
                    delete!(acc, "accomplishment_type")
                end
            end
        end
        
        # Get session next steps using schema-driven query
        next_steps = []
        if include_next_steps
            steps_query = "SELECT title, description, priority, step_type, estimated_effort FROM session_next_steps WHERE session_id = \$1 AND status != 'completed' ORDER BY priority DESC, created_at"
            next_steps = execute_query_with_schema(conn, steps_query, [session_id], ["session_next_steps"])
            # Rename step_type to type for compatibility
            for step in next_steps
                if haskey(step, "step_type")
                    step["type"] = step["step_type"]
                    delete!(step, "step_type")
                end
            end
        end
        
        # Get session tasks using schema-driven query
        tasks_query = "SELECT task_name, description, priority, status, estimated_effort FROM session_tasks WHERE session_id = \$1 ORDER BY priority DESC, created_at"
        tasks = execute_query_with_schema(conn, tasks_query, [session_id], ["session_tasks"])
        # Rename task_name to name for compatibility
        for task in tasks
            if haskey(task, "task_name")
                task["name"] = task["task_name"]
                delete!(task, "task_name")
            end
        end
        
        # Get project phase info using schema-driven query
        phase_query = "SELECT phase_name, description, objectives, deliverables, status FROM project_phases WHERE session_id = \$1 LIMIT 1"
        phase_results = execute_query_with_schema(conn, phase_query, [session_id], ["project_phases"])
        phase_info = nothing
        if !isempty(phase_results)
            phase = phase_results[1]
            phase_info = Dict(
                "name" => get(phase, "phase_name", ""),
                "description" => get(phase, "description", ""),
                "objectives" => get(phase, "objectives", ""),
                "deliverables" => get(phase, "deliverables", ""),
                "status" => get(phase, "status", "")
            )
        end
        
        # Build comprehensive status response
        status_data = Dict(
            "session_id" => session_id,
            "timestamp" => string(now()),
            "success" => true,
            "phase" => phase_info,
            "tasks" => tasks,
            "accomplishments" => accomplishments,
            "next_steps" => next_steps,
            "summary" => Dict(
                "total_accomplishments" => length(accomplishments),
                "pending_steps" => length(next_steps),
                "total_tasks" => length(tasks),
                "completed_tasks" => count(t -> get(t, "status", "") == "completed", tasks)
            )
        )
        
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
        
        # Create a fresh, guaranteed JSON-serializable result dictionary
        result_data = Dict{String, Any}(
            "session_id" => session_id,
            "timestamp" => string(now())
        )
        
        # Get project phases using schema-driven query
        if include_project_phases
            phases_query = """
            SELECT project_name, phase_name, description, objectives, deliverables, 
                   testing_requirements, documentation_requirements, git_requirements
            FROM project_phases 
            WHERE session_id = \$1
            ORDER BY created_at
            """
            phases_raw = execute_query_with_schema(conn, phases_query, [session_id], ["project_phases"])
            
            # Ensure each phase dict is JSON-serializable
            phases_clean = []
            for phase in phases_raw
                phase_clean = Dict{String, Any}()
                for (key, value) in phase
                    phase_clean[String(key)] = value
                end
                push!(phases_clean, phase_clean)
            end
            result_data["project_phases"] = phases_clean
        end
        
        # Get session tasks using schema-driven query
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
            tasks_raw = execute_query_with_schema(conn, tasks_query, [session_id], ["session_tasks"])
            
            # Ensure each task dict is JSON-serializable
            tasks_clean = []
            for task in tasks_raw
                task_clean = Dict{String, Any}()
                for (key, value) in task
                    task_clean[String(key)] = value
                end
                push!(tasks_clean, task_clean)
            end
            result_data["session_tasks"] = tasks_clean
        end
        
        # Get next steps using schema-driven query
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
            next_steps_raw = execute_query_with_schema(conn, next_steps_query, [session_id], ["session_next_steps"])
            
            # Ensure each step dict is JSON-serializable
            next_steps_clean = []
            for step in next_steps_raw
                step_clean = Dict{String, Any}()
                for (key, value) in step
                    step_clean[String(key)] = value
                end
                push!(next_steps_clean, step_clean)
            end
            result_data["next_steps"] = next_steps_clean
        end
        
        # Update session status file
        update_session_status_file(session_id)
        
        # Return the clean, serializable data
        return JSON3.write(result_data)
        
    catch e
        error_msg = "Failed to get session planning: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function add_subtask_tool(args::Dict)
    session_id = get(args, "session_id", "")
    parent_title = get(args, "parent_title", "")
    subtask_title = get(args, "subtask_title", "")
    description = get(args, "description", "")
    priority = get(args, "priority", "medium")
    estimated_effort = get(args, "estimated_effort", "")
    
    if isempty(session_id) || isempty(subtask_title) || isempty(description)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id, subtask_title, and description are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Add the subtask as a next step
        insert_query = """
        INSERT INTO session_next_steps (session_id, title, description, priority, step_type, estimated_effort, status)
        VALUES (\$1, \$2, \$3, \$4, 'task', \$5, 'pending')
        RETURNING id
        """
        
        full_title = if !isempty(parent_title)
            "[$parent_title] $subtask_title"
        else
            subtask_title
        end
        
        result = LibPQ.execute(conn, insert_query, [session_id, full_title, description, priority, estimated_effort])
        
        step_id = nothing
        for row in result
            step_id = row[1]
            break
        end
        
        # Update session status file 
        update_session_status_file(session_id)
        
        return JSON3.write(Dict(
            "success" => true,
            "message" => "Subtask added successfully",
            "step_id" => step_id,
            "title" => full_title
        ))
        
    catch e
        error_msg = "Failed to add subtask: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function complete_task_bundle_tool(args::Dict)
    session_id = get(args, "session_id", "")
    task_titles = get(args, "task_titles", [])
    bundle_title = get(args, "bundle_title", "")
    bundle_description = get(args, "bundle_description", "")
    repository = get(args, "repository", "")
    files_modified = get(args, "files_modified", [])
    
    if isempty(session_id) || isempty(task_titles) || isempty(bundle_title) || isempty(bundle_description) || isempty(repository)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id, task_titles, bundle_title, bundle_description, and repository are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Mark tasks as completed
        completed_count = 0
        for title in task_titles
            update_query = """
            UPDATE session_next_steps 
            SET status = 'completed'
            WHERE session_id = \$1 AND title = \$2
            """
            LibPQ.execute(conn, update_query, [session_id, title])
            completed_count += 1
        end
        
        # Log as accomplishment
        accomplishment_query = """
        INSERT INTO session_accomplishments (session_id, repository, accomplishment_type, title, description, success_level, files_modified)
        VALUES (\$1, \$2, 'task_bundle', \$3, \$4, 'completed', \$5)
        RETURNING id
        """
        
        # Convert Julia array to PostgreSQL array format
        files_array = length(files_modified) > 0 ? files_modified : String[]
        
        result = LibPQ.execute(conn, accomplishment_query, [session_id, repository, bundle_title, bundle_description, files_array])
        
        accomplishment_id = nothing
        for row in result
            accomplishment_id = row[1]
            break
        end
        
        # Update session status file
        update_session_status_file(session_id)
        
        return JSON3.write(Dict(
            "success" => true,
            "message" => "Task bundle completed successfully",
            "tasks_completed" => completed_count,
            "accomplishment_id" => accomplishment_id
        ))
        
    catch e
        error_msg = "Failed to complete task bundle: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function session_checkpoint_tool(args::Dict)
    session_id = get(args, "session_id", "")
    checkpoint_name = get(args, "checkpoint_name", "")
    summary = get(args, "summary", "")
    include_bridge_message = get(args, "include_bridge_message", true)
    
    if isempty(session_id) || isempty(checkpoint_name) || isempty(summary)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id, checkpoint_name, and summary are required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Log checkpoint as accomplishment
        checkpoint_query = """
        INSERT INTO session_accomplishments (session_id, repository, accomplishment_type, title, description, success_level)
        VALUES (\$1, 'MCPJuliaServers', 'checkpoint', \$2, \$3, 'completed')
        RETURNING id
        """
        
        checkpoint_title = "📊 SESSION CHECKPOINT: $checkpoint_name"
        
        result = LibPQ.execute(conn, checkpoint_query, [session_id, checkpoint_title, summary])
        
        accomplishment_id = nothing
        for row in result
            accomplishment_id = row[1]
            break
        end
        
        # Send bridge message if requested
        if include_bridge_message
            bridge_query = """
            INSERT INTO claude_bridge_messages (session_id, sender, recipient, subject, message_content, priority, category)
            VALUES (\$1, 'CC', 'CD', \$2, \$3, 'NORMAL', 'checkpoint')
            RETURNING id
            """
            
            bridge_subject = "SESSION CHECKPOINT: $checkpoint_name"
            bridge_message = "SESSION CHECKPOINT CREATED: $summary Checkpoint logged as Accomplishment #$accomplishment_id. Current session progress documented for coordination."
            
            bridge_result = LibPQ.execute(conn, bridge_query, [session_id, bridge_subject, bridge_message])
            
            bridge_id = nothing
            for row in bridge_result
                bridge_id = row[1]
                break
            end
        end
        
        # Update session status file
        update_session_status_file(session_id)
        
        return JSON3.write(Dict(
            "success" => true,
            "message" => "Session checkpoint created successfully",
            "accomplishment_id" => accomplishment_id,
            "bridge_message_sent" => include_bridge_message
        ))
        
    catch e
        error_msg = "Failed to create session checkpoint: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function get_phase_requirements_tool(args::Dict)
    session_id = get(args, "session_id", "")
    phase_name = get(args, "phase_name", "")
    
    if isempty(session_id) || isempty(phase_name)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id and phase_name are required"
        ))
    end
    
    try
        conn = get_connection()
        
        phase_query = """
        SELECT project_name, phase_name, description, objectives, deliverables, 
               testing_requirements, documentation_requirements, git_requirements, status
        FROM project_phases 
        WHERE session_id = \$1 AND phase_name = \$2
        """
        
        result = LibPQ.execute(conn, phase_query, [session_id, phase_name])
        
        if isempty(result)
            return JSON3.write(Dict(
                "success" => false,
                "error" => "Phase not found"
            ))
        end
        
        row = first(result)
        
        # Convert PostgreSQL array strings to JSON arrays
        function parse_pg_array(pg_str)
            if pg_str === nothing || pg_str == ""
                return []
            end
            # Remove outer braces and split by comma, then clean quotes
            content = strip(pg_str, ['{', '}'])
            if isempty(content)
                return []
            end
            items = split(content, "\",\"")
            # Clean up first and last items
            items[1] = strip(items[1], ['"'])
            if length(items) > 1
                items[end] = strip(items[end], ['"'])
            end
            return items
        end
        
        objectives_array = parse_pg_array(row[4])
        deliverables_array = parse_pg_array(row[5])
        
        phase_data = Dict(
            "project_name" => row[1],
            "phase_name" => row[2], 
            "description" => row[3],
            "objectives" => objectives_array,
            "deliverables" => deliverables_array,
            "testing_requirements" => row[6],
            "documentation_requirements" => row[7],
            "git_requirements" => row[8],
            "status" => row[9]
        )
        
        # Update session status file
        update_session_status_file(session_id)
        
        return JSON3.write(Dict(
            "success" => true,
            "phase" => phase_data
        ))
        
    catch e
        error_msg = "Failed to get phase requirements: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function list_phases_tool(args::Dict)
    session_id = get(args, "session_id", "")
    
    if isempty(session_id)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id is required"
        ))
    end
    
    try
        conn = get_connection()
        
        phases_query = """
        SELECT phase_number, phase_name, description, status, created_at
        FROM project_phases 
        WHERE session_id = \$1
        ORDER BY phase_number
        """
        
        result = LibPQ.execute(conn, phases_query, [session_id])
        
        phases = []
        for row in result
            phase_dict = Dict(
                "phase_number" => row[1],
                "phase_name" => row[2],
                "description" => row[3],
                "status" => row[4],
                "created_at" => string(row[5])
            )
            push!(phases, phase_dict)
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "session_id" => session_id,
            "phases" => phases,
            "total_phases" => length(phases)
        ))
        
    catch e
        error_msg = "Failed to list phases: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function initialize_session_tool(args::Dict)
    session_id = get(args, "session_id", "")
    
    if isempty(session_id)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id is required"
        ))
    end
    
    try
        conn = get_connection()
        
        # Set the specified session's phase to active
        update_active_query = """
        UPDATE project_phases 
        SET status = 'active'
        WHERE session_id = \$1
        RETURNING phase_name
        """
        
        # Set all other sessions to pending
        reset_others_query = """
        UPDATE project_phases 
        SET status = 'pending'
        WHERE session_id != \$1 AND status = 'active'
        """
        
        # Execute queries
        LibPQ.execute(conn, reset_others_query, [session_id])
        result = LibPQ.execute(conn, update_active_query, [session_id])
        
        phase_name = ""
        found_session = false
        for row in result
            phase_name = row[1] === nothing ? "" : string(row[1])
            found_session = true
            break
        end
        
        if !found_session
            return JSON3.write(Dict(
                "success" => false,
                "error" => "Session not found: $session_id"
            ))
        end
        
        # Clear any completed session tasks and next steps for fresh start
        clear_tasks_query = "UPDATE session_tasks SET status = 'pending' WHERE session_id = \$1 AND status = 'completed'"
        clear_steps_query = "UPDATE session_next_steps SET status = 'pending' WHERE session_id = \$1 AND status = 'completed'"
        
        LibPQ.execute(conn, clear_tasks_query, [session_id])
        LibPQ.execute(conn, clear_steps_query, [session_id])
        
        return JSON3.write(Dict(
            "success" => true,
            "session_id" => session_id,
            "phase_name" => string(phase_name),
            "status" => "active",
            "message" => "Session $session_id initialized and set to active. All other sessions set to pending."
        ))
        
    catch e
        error_msg = "Failed to initialize session: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

function update_phase_status_tool(args::Dict)
    session_id = get(args, "session_id", "")
    phase_name = get(args, "phase_name", "")
    status = get(args, "status", "")
    
    if isempty(session_id) || isempty(phase_name) || isempty(status)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id, phase_name, and status are required"
        ))
    end
    
    try
        conn = get_connection()
        
        update_query = """
        UPDATE project_phases 
        SET status = \$1
        WHERE session_id = \$2 AND phase_name = \$3
        RETURNING id
        """
        
        result = LibPQ.execute(conn, update_query, [status, session_id, phase_name])
        
        if isempty(result)
            return JSON3.write(Dict(
                "success" => false,
                "error" => "Phase not found or not updated"
            ))
        end
        
        # Update session status file
        update_session_status_file(session_id)
        
        return JSON3.write(Dict(
            "success" => true,
            "message" => "Phase status updated successfully",
            "session_id" => session_id,
            "phase_name" => phase_name,
            "new_status" => status
        ))
        
    catch e
        error_msg = "Failed to update phase status: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

# Get comprehensive project roadmap with all phases and sessions
function get_project_roadmap_tool(args::Dict)
    project_name = get(args, "project_name", "")
    include_completed = get(args, "include_completed", true)
    session_range = get(args, "session_range", Dict())
    
    try
        conn = get_connection()
        
        # Build WHERE clause
        where_conditions = String[]
        query_params = []
        
        if !isempty(project_name)
            push!(where_conditions, "project_name = \$$(length(query_params) + 1)")
            push!(query_params, project_name)
        end
        
        if !include_completed
            push!(where_conditions, "status != 'completed'")
        end
        
        if haskey(session_range, "start_session") && !isempty(get(session_range, "start_session", ""))
            push!(where_conditions, "session_id >= \$$(length(query_params) + 1)")
            push!(query_params, get(session_range, "start_session", ""))
        end
        
        if haskey(session_range, "end_session") && !isempty(get(session_range, "end_session", ""))
            push!(where_conditions, "session_id <= \$$(length(query_params) + 1)")
            push!(query_params, get(session_range, "end_session", ""))
        end
        
        where_clause = isempty(where_conditions) ? "" : "WHERE " * join(where_conditions, " AND ")
        
        query = """
        SELECT session_id, project_name, phase_number, phase_name, 
               description, status, created_at, completed_at,
               objectives, deliverables
        FROM project_phases 
        $where_clause
        ORDER BY session_id, phase_number
        """
        
        result = LibPQ.execute(conn, query, query_params)
        
        roadmap = Dict()
        total_phases = 0
        
        for row in result
            total_phases += 1
            session_id = row[1] === nothing ? "unknown" : string(row[1])
            
            if !haskey(roadmap, session_id)
                roadmap[session_id] = Dict(
                    "project_name" => row[2] === nothing ? "" : string(row[2]),
                    "phases" => []
                )
            end
            
            phase_info = Dict(
                "phase_number" => row[3] === nothing ? 0 : Int(row[3]),
                "phase_name" => row[4] === nothing ? "" : string(row[4]),
                "description" => row[5] === nothing ? "" : string(row[5]),
                "status" => row[6] === nothing ? "" : string(row[6]),
                "created_at" => row[7] === nothing ? "" : string(row[7]),
                "completed_at" => row[8] === nothing ? "" : string(row[8]),
                "objectives" => row[9] === nothing ? [] : row[9],
                "deliverables" => row[10] === nothing ? [] : row[10]
            )
            
            push!(roadmap[session_id]["phases"], phase_info)
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "roadmap" => roadmap,
            "total_sessions" => length(keys(roadmap)),
            "total_phases" => total_phases,
            "filters_applied" => Dict(
                "project_name" => project_name,
                "include_completed" => include_completed,
                "session_range" => session_range
            )
        ))
        
    catch e
        error_msg = "Failed to get project roadmap: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

# Get detailed summary of a specific session
function get_session_summary_tool(args::Dict)
    session_id = get(args, "session_id", "")
    include_tasks = get(args, "include_tasks", true)
    include_phases = get(args, "include_phases", true)
    include_metrics = get(args, "include_metrics", true)
    
    if isempty(session_id)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "session_id is required"
        ))
    end
    
    try
        conn = get_connection()
        
        summary = Dict(
            "session_id" => session_id,
            "summary_generated_at" => string(now())
        )
        
        # Get accomplishments
        accomplishments_query = """
        SELECT accomplishment_type, title, description, success_level, 
               files_created, files_modified, commit_hash, created_at
        FROM session_accomplishments 
        WHERE session_id = \$1 
        ORDER BY created_at DESC
        """
        
        result = LibPQ.execute(conn, accomplishments_query, [session_id])
        accomplishments = []
        
        for row in result
            push!(accomplishments, Dict(
                "type" => row[1] === nothing ? "" : string(row[1]),
                "title" => row[2] === nothing ? "" : string(row[2]),
                "description" => row[3] === nothing ? "" : string(row[3]),
                "success_level" => row[4] === nothing ? "" : string(row[4]),
                "files_created" => row[5] === nothing ? [] : row[5],
                "files_modified" => row[6] === nothing ? [] : row[6],
                "commit_hash" => row[7] === nothing ? "" : string(row[7]),
                "created_at" => row[8] === nothing ? "" : string(row[8])
            ))
        end
        
        summary["accomplishments"] = accomplishments
        
        # Get next steps
        next_steps_query = """
        SELECT step_type, title, description, priority, estimated_effort, status
        FROM session_next_steps 
        WHERE session_id = \$1 
        ORDER BY priority DESC, created_at
        """
        
        result = LibPQ.execute(conn, next_steps_query, [session_id])
        next_steps = []
        
        for row in result
            push!(next_steps, Dict(
                "type" => row[1] === nothing ? "" : string(row[1]),
                "title" => row[2] === nothing ? "" : string(row[2]),
                "description" => row[3] === nothing ? "" : string(row[3]),
                "priority" => row[4] === nothing ? "" : string(row[4]),
                "estimated_effort" => row[5] === nothing ? "" : string(row[5]),
                "status" => row[6] === nothing ? "" : string(row[6])
            ))
        end
        
        summary["next_steps"] = next_steps
        
        # Optionally include tasks
        if include_tasks
            tasks_query = """
            SELECT task_name, task_type, description, priority, 
                   estimated_effort, status, dependencies, acceptance_criteria
            FROM session_tasks 
            WHERE session_id = \$1 
            ORDER BY priority DESC, created_at
            """
            
            result = LibPQ.execute(conn, tasks_query, [session_id])
            tasks = []
            
            for row in result
                push!(tasks, Dict(
                    "name" => row[1] === nothing ? "" : string(row[1]),
                    "type" => row[2] === nothing ? "" : string(row[2]),
                    "description" => row[3] === nothing ? "" : string(row[3]),
                    "priority" => row[4] === nothing ? "" : string(row[4]),
                    "estimated_effort" => row[5] === nothing ? "" : string(row[5]),
                    "status" => row[6] === nothing ? "" : string(row[6]),
                    "dependencies" => row[7] === nothing ? [] : row[7],
                    "acceptance_criteria" => row[8] === nothing ? [] : row[8]
                ))
            end
            
            summary["tasks"] = tasks
        end
        
        # Optionally include phases
        if include_phases
            phases_query = """
            SELECT project_name, phase_number, phase_name, description, 
                   status, objectives, deliverables
            FROM project_phases 
            WHERE session_id = \$1 
            ORDER BY phase_number
            """
            
            result = LibPQ.execute(conn, phases_query, [session_id])
            phases = []
            
            for row in result
                push!(phases, Dict(
                    "project_name" => row[1] === nothing ? "" : string(row[1]),
                    "phase_number" => row[2] === nothing ? 0 : Int(row[2]),
                    "phase_name" => row[3] === nothing ? "" : string(row[3]),
                    "description" => row[4] === nothing ? "" : string(row[4]),
                    "status" => row[5] === nothing ? "" : string(row[5]),
                    "objectives" => row[6] === nothing ? [] : row[6],
                    "deliverables" => row[7] === nothing ? [] : row[7]
                ))
            end
            
            summary["phases"] = phases
        end
        
        # Optionally include metrics
        if include_metrics
            summary["metrics"] = Dict(
                "total_accomplishments" => length(accomplishments),
                "total_next_steps" => length(next_steps),
                "completed_accomplishments" => count(a -> get(a, "success_level", "") == "completed", accomplishments),
                "pending_next_steps" => count(ns -> get(ns, "status", "") == "pending", next_steps)
            )
        end
        
        return JSON3.write(Dict(
            "success" => true,
            "session_summary" => summary
        ))
        
    catch e
        error_msg = "Failed to get session summary: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end

# Create planning for next session based on current progress
function plan_next_session_tool(args::Dict)
    current_session_id = get(args, "current_session_id", "")
    next_session_id = get(args, "next_session_id", "")
    focus_area = get(args, "focus_area", "")
    carry_forward_incomplete = get(args, "carry_forward_incomplete", true)
    
    if isempty(current_session_id) || isempty(next_session_id)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "current_session_id and next_session_id are required"
        ))
    end
    
    try
        conn = get_connection()
        
        planning_summary = Dict(
            "current_session" => current_session_id,
            "next_session" => next_session_id,
            "focus_area" => focus_area,
            "planning_generated_at" => string(now())
        )
        
        # Get incomplete tasks from current session if requested
        if carry_forward_incomplete
            incomplete_tasks_query = """
            SELECT task_name, task_type, description, priority, estimated_effort,
                   dependencies, acceptance_criteria, test_requirements
            FROM session_tasks 
            WHERE session_id = \$1 AND status NOT IN ('completed', 'cancelled')
            ORDER BY priority DESC
            """
            
            result = LibPQ.execute(conn, incomplete_tasks_query, [current_session_id])
            carry_forward_tasks = []
            
            for row in result
                push!(carry_forward_tasks, Dict(
                    "name" => row[1] === nothing ? "" : string(row[1]),
                    "type" => row[2] === nothing ? "" : string(row[2]),
                    "description" => row[3] === nothing ? "" : string(row[3]),
                    "priority" => row[4] === nothing ? "medium" : string(row[4]),
                    "estimated_effort" => row[5] === nothing ? "" : string(row[5]),
                    "dependencies" => row[6] === nothing ? [] : row[6],
                    "acceptance_criteria" => row[7] === nothing ? [] : row[7],
                    "test_requirements" => row[8] === nothing ? "" : string(row[8]),
                    "carried_from" => current_session_id
                ))
            end
            
            planning_summary["carry_forward_tasks"] = carry_forward_tasks
        end
        
        # Get pending next steps from current session
        next_steps_query = """
        SELECT step_type, title, description, priority, estimated_effort
        FROM session_next_steps 
        WHERE session_id = \$1 AND status = 'pending'
        ORDER BY priority DESC
        """
        
        result = LibPQ.execute(conn, next_steps_query, [current_session_id])
        suggested_next_steps = []
        
        for row in result
            push!(suggested_next_steps, Dict(
                "type" => row[1] === nothing ? "task" : string(row[1]),
                "title" => row[2] === nothing ? "" : string(row[2]),
                "description" => row[3] === nothing ? "" : string(row[3]),
                "priority" => row[4] === nothing ? "medium" : string(row[4]),
                "estimated_effort" => row[5] === nothing ? "" : string(row[5]),
                "source" => "next_steps_from_" * current_session_id
            ))
        end
        
        planning_summary["suggested_next_steps"] = suggested_next_steps
        
        # Planning recommendations
        total_items = length(get(planning_summary, "carry_forward_tasks", [])) + 
                     length(suggested_next_steps)
        
        planning_summary["recommendations"] = Dict(
            "total_items_to_plan" => total_items,
            "focus_suggestion" => isempty(focus_area) ? 
                "Consider defining a focus area for the next session" : focus_area,
            "planning_notes" => [
                "Review carry-forward tasks for continued relevance",
                "Prioritize items based on current project needs",
                "Consider dependencies when scheduling tasks",
                "Update task descriptions if requirements have changed"
            ]
        )
        
        return JSON3.write(Dict(
            "success" => true,
            "session_planning" => planning_summary
        ))
        
    catch e
        error_msg = "Failed to create session planning: $(string(e))"
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
            elseif tool_name == "add_subtask"
                add_subtask_tool(tool_args)
            elseif tool_name == "complete_task_bundle"
                complete_task_bundle_tool(tool_args)
            elseif tool_name == "session_checkpoint"
                session_checkpoint_tool(tool_args)
            elseif tool_name == "get_phase_requirements"
                get_phase_requirements_tool(tool_args)
            elseif tool_name == "list_phases"
                list_phases_tool(tool_args)
            elseif tool_name == "initialize_session"
                initialize_session_tool(tool_args)
            elseif tool_name == "update_phase_status"
                update_phase_status_tool(tool_args)
            elseif tool_name == "get_project_roadmap"
                get_project_roadmap_tool(tool_args)
            elseif tool_name == "get_session_summary"
                get_session_summary_tool(tool_args)
            elseif tool_name == "plan_next_session"
                plan_next_session_tool(tool_args)
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
    http_port = get_server_port("postgres")
    http_host = get_server_host()
    
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