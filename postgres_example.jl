#!/usr/bin/env julia

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer
using LibPQ

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
    max_size::Int
    current_size::Int
    
    ConnectionPool(max_size::Int = 5) = new(LibPQ.Connection[], max_size, 0)
end

const POOL = ConnectionPool()

function get_connection()
    try
        # Try to reuse existing connection
        if !isempty(POOL.connections)
            conn = pop!(POOL.connections)
            if LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK
                return conn
            else
                LibPQ.close(conn)
                POOL.current_size -= 1
            end
        end
        
        # Create new connection
        if POOL.current_size < POOL.max_size
            conn_string = "host=$(PG_CONFIG["host"]) port=$(PG_CONFIG["port"]) user=$(PG_CONFIG["user"]) password=$(PG_CONFIG["password"]) dbname=$(PG_CONFIG["dbname"])"
            conn = LibPQ.Connection(conn_string)
            
            if LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK
                POOL.current_size += 1
                return conn
            else
                error_msg = LibPQ.error_message(conn)
                LibPQ.close(conn)
                throw(ArgumentError("Failed to connect to PostgreSQL: $error_msg"))
            end
        else
            throw(ArgumentError("Connection pool exhausted"))
        end
    catch e
        throw(ArgumentError("Database connection failed: $(string(e))"))
    end
end

function return_connection(conn::LibPQ.Connection)
    if LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK && length(POOL.connections) < POOL.max_size
        push!(POOL.connections, conn)
    else
        LibPQ.close(conn)
        POOL.current_size -= 1
    end
end

function execute_query_tool(args::Dict{String,Any})
    query = get(args, "query", "")
    limit = get(args, "limit", 100)
    
    if isempty(query)
        return "Error: Query is required"
    end
    
    conn = nothing
    try
        conn = get_connection()
        
        # Execute query
        result = LibPQ.execute(conn, query)
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_TUPLES_OK
            # SELECT query - return data
            num_rows = LibPQ.num_rows(result)
            num_cols = LibPQ.num_columns(result)
            
            if num_rows == 0
                return "Query executed successfully. No rows returned."
            end
            
            # Get column names
            column_names = [LibPQ.column_name(result, i) for i in 1:num_cols]
            
            # Get data (limited)
            rows = []
            max_rows = min(num_rows, limit)
            
            for row_idx in 1:max_rows
                row_data = []
                for col_idx in 1:num_cols
                    value = LibPQ.getindex(result, row_idx, col_idx)
                    push!(row_data, something(value, "NULL"))
                end
                push!(rows, row_data)
            end
            
            # Format output
            output = "Query executed successfully.\n"
            output *= "Columns: " * join(column_names, ", ") * "\n"
            output *= "Rows returned: $num_rows" * (num_rows > limit ? " (showing first $limit)" : "") * "\n\n"
            
            # Add data in table format
            for (i, row) in enumerate(rows)
                output *= "Row $i: " * join(string.(row), " | ") * "\n"
            end
            
            return output
            
        elseif LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
            # INSERT/UPDATE/DELETE - return affected rows
            affected = LibPQ.cmd_tuples(result)
            return "Query executed successfully. Rows affected: $affected"
        else
            error_msg = LibPQ.error_message(result)
            return "Query execution failed: $error_msg"
        end
        
    catch e
        return "Error executing query: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function list_tables_tool(args::Dict{String,Any})
    schema = get(args, "schema", "public")
    
    conn = nothing
    try
        conn = get_connection()
        
        query = """
        SELECT table_name, table_type 
        FROM information_schema.tables 
        WHERE table_schema = \$1 
        ORDER BY table_name
        """
        
        result = LibPQ.execute(conn, query, [schema])
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_TUPLES_OK
            num_rows = LibPQ.num_rows(result)
            
            if num_rows == 0
                return "No tables found in schema '$schema'"
            end
            
            output = "Tables in schema '$schema':\n"
            for row_idx in 1:num_rows
                table_name = LibPQ.getindex(result, row_idx, 1)
                table_type = LibPQ.getindex(result, row_idx, 2)
                output *= "  $table_name ($table_type)\n"
            end
            
            return output
        else
            error_msg = LibPQ.error_message(result)
            return "Failed to list tables: $error_msg"
        end
        
    catch e
        return "Error listing tables: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function describe_table_tool(args::Dict{String,Any})
    table_name = get(args, "table", "")
    schema = get(args, "schema", "public")
    
    if isempty(table_name)
        return "Error: Table name is required"
    end
    
    conn = nothing
    try
        conn = get_connection()
        
        query = """
        SELECT 
            column_name, 
            data_type, 
            is_nullable, 
            column_default,
            character_maximum_length
        FROM information_schema.columns 
        WHERE table_schema = \$1 AND table_name = \$2
        ORDER BY ordinal_position
        """
        
        result = LibPQ.execute(conn, query, [schema, table_name])
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_TUPLES_OK
            num_rows = LibPQ.num_rows(result)
            
            if num_rows == 0
                return "Table '$schema.$table_name' not found or has no columns"
            end
            
            output = "Table: $schema.$table_name\n"
            output *= "Columns:\n"
            
            for row_idx in 1:num_rows
                col_name = LibPQ.getindex(result, row_idx, 1)
                data_type = LibPQ.getindex(result, row_idx, 2)
                is_nullable = LibPQ.getindex(result, row_idx, 3)
                col_default = something(LibPQ.getindex(result, row_idx, 4), "")
                max_length = something(LibPQ.getindex(result, row_idx, 5), "")
                
                type_info = data_type
                if !isempty(max_length) && max_length != "NULL"
                    type_info *= "($max_length)"
                end
                
                nullable = is_nullable == "YES" ? "NULL" : "NOT NULL"
                default_info = isempty(col_default) ? "" : " DEFAULT $col_default"
                
                output *= "  $col_name: $type_info $nullable$default_info\n"
            end
            
            return output
        else
            error_msg = LibPQ.error_message(result)
            return "Failed to describe table: $error_msg"
        end
        
    catch e
        return "Error describing table: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function list_databases_tool(args::Dict{String,Any})
    conn = nothing
    try
        conn = get_connection()
        
        query = """
        SELECT datname, pg_get_userbyid(datdba) as owner, encoding, datcollate, datctype 
        FROM pg_database 
        WHERE datistemplate = false
        ORDER BY datname
        """
        
        result = LibPQ.execute(conn, query)
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_TUPLES_OK
            num_rows = LibPQ.num_rows(result)
            
            output = "Available databases:\n"
            for row_idx in 1:num_rows
                db_name = LibPQ.getindex(result, row_idx, 1)
                owner = LibPQ.getindex(result, row_idx, 2)
                encoding = LibPQ.getindex(result, row_idx, 3)
                output *= "  $db_name (Owner: $owner, Encoding: $encoding)\n"
            end
            
            return output
        else
            error_msg = LibPQ.error_message(result)
            return "Failed to list databases: $error_msg"
        end
        
    catch e
        return "Error listing databases: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function execute_transaction_tool(args::Dict{String,Any})
    queries = get(args, "queries", String[])
    
    if isempty(queries)
        return "Error: At least one query is required"
    end
    
    conn = nothing
    try
        conn = get_connection()
        
        # Begin transaction
        LibPQ.execute(conn, "BEGIN")
        
        results = String[]
        
        for (i, query) in enumerate(queries)
            result = LibPQ.execute(conn, query)
            
            if LibPQ.status(result) == LibPQ.libpq_c.PGRES_TUPLES_OK
                num_rows = LibPQ.num_rows(result)
                push!(results, "Query $i: $num_rows rows returned")
            elseif LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
                affected = LibPQ.cmd_tuples(result)
                push!(results, "Query $i: $affected rows affected")
            else
                error_msg = LibPQ.error_message(result)
                # Rollback on error
                LibPQ.execute(conn, "ROLLBACK")
                return "Transaction failed at query $i: $error_msg. Transaction rolled back."
            end
        end
        
        # Commit transaction
        LibPQ.execute(conn, "COMMIT")
        
        output = "Transaction executed successfully:\n"
        for result_msg in results
            output *= "  $result_msg\n"
        end
        
        return output
        
    catch e
        try
            if conn !== nothing
                LibPQ.execute(conn, "ROLLBACK")
            end
        catch
            # Ignore rollback errors
        end
        return "Transaction failed: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function main()
    server = MCPServer("PostgreSQL MCP Server", "0.1.0", "MCP server providing PostgreSQL database operations")
    
    println("🐘 PostgreSQL MCP Server")
    println("Database: $(PG_CONFIG["host"]):$(PG_CONFIG["port"])/$(PG_CONFIG["dbname"])")
    println("User: $(PG_CONFIG["user"])")
    
    # Test initial connection
    try
        test_conn = get_connection()
        return_connection(test_conn)
        println("✅ Database connection successful")
    catch e
        println("❌ Database connection failed: $e")
        println("Please check your PostgreSQL configuration")
        return
    end
    
    # Execute Query Tool
    execute_query_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "query" => Dict{String,Any}(
                "type" => "string",
                "description" => "SQL query to execute (SELECT, INSERT, UPDATE, DELETE, etc.)"
            ),
            "limit" => Dict{String,Any}(
                "type" => "integer",
                "description" => "Maximum number of rows to return (default: 100)"
            )
        ),
        "required" => ["query"]
    )
    
    add_tool!(server, MCPTool(
        "execute_query",
        "Execute a SQL query against the PostgreSQL database",
        execute_query_schema,
        execute_query_tool
    ))
    
    # List Tables Tool
    list_tables_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "schema" => Dict{String,Any}(
                "type" => "string",
                "description" => "Database schema name (default: 'public')"
            )
        )
    )
    
    add_tool!(server, MCPTool(
        "list_tables",
        "List all tables in a database schema",
        list_tables_schema,
        list_tables_tool
    ))
    
    # Describe Table Tool
    describe_table_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "table" => Dict{String,Any}(
                "type" => "string",
                "description" => "Table name to describe"
            ),
            "schema" => Dict{String,Any}(
                "type" => "string",
                "description" => "Database schema name (default: 'public')"
            )
        ),
        "required" => ["table"]
    )
    
    add_tool!(server, MCPTool(
        "describe_table",
        "Get detailed information about a table's columns and schema",
        describe_table_schema,
        describe_table_tool
    ))
    
    # List Databases Tool
    list_databases_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}()
    )
    
    add_tool!(server, MCPTool(
        "list_databases",
        "List all available databases on the PostgreSQL server",
        list_databases_schema,
        list_databases_tool
    ))
    
    # Execute Transaction Tool
    execute_transaction_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "queries" => Dict{String,Any}(
                "type" => "array",
                "items" => Dict{String,Any}("type" => "string"),
                "description" => "Array of SQL queries to execute in a single transaction"
            )
        ),
        "required" => ["queries"]
    )
    
    add_tool!(server, MCPTool(
        "execute_transaction",
        "Execute multiple SQL queries in a single transaction (all succeed or all fail)",
        execute_transaction_schema,
        execute_transaction_tool
    ))
    
    start_server(server)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end