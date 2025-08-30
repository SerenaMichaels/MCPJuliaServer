#!/usr/bin/env julia

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer
using LibPQ
using JSON3
using Dates

# PostgreSQL connection configuration
const PG_CONFIG = Dict{String,String}(
    "host" => get(ENV, "POSTGRES_HOST", "172.27.80.1"),
    "port" => get(ENV, "POSTGRES_PORT", "5432"),
    "user" => get(ENV, "POSTGRES_USER", "postgres"),
    "password" => get(ENV, "POSTGRES_PASSWORD", "New12@@DB"),
    "dbname" => get(ENV, "POSTGRES_DB", "postgres")
)

# Global connection pool
mutable struct ConnectionPool
    connections::Vector{LibPQ.Connection}
    max_size::Int
    current_size::Int
    
    ConnectionPool(max_size::Int = 5) = new(LibPQ.Connection[], max_size, 0)
end

const POOL = ConnectionPool()

function get_connection(dbname::String = PG_CONFIG["dbname"])
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
            conn_string = "host=$(PG_CONFIG["host"]) port=$(PG_CONFIG["port"]) user=$(PG_CONFIG["user"]) password=$(PG_CONFIG["password"]) dbname=$dbname"
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

# Database Administration Tools

function create_database_tool(args::Dict{String,Any})
    db_name = get(args, "name", "")
    owner = get(args, "owner", PG_CONFIG["user"])
    encoding = get(args, "encoding", "UTF8")
    template = get(args, "template", "template0")
    
    if isempty(db_name)
        return "Error: Database name is required"
    end
    
    # Validate database name
    if match(r"^[a-zA-Z_][a-zA-Z0-9_]*$", db_name) === nothing
        return "Error: Invalid database name. Must start with letter or underscore and contain only alphanumeric characters and underscores"
    end
    
    conn = nothing
    try
        # Connect to postgres database to create new database
        conn = get_connection("postgres")
        
        # Check if database already exists
        check_query = "SELECT 1 FROM pg_database WHERE datname = \$1"
        result = LibPQ.execute(conn, check_query, [db_name])
        
        if LibPQ.num_rows(result) > 0
            return "Database '$db_name' already exists"
        end
        
        # Create database
        create_query = "CREATE DATABASE \"$db_name\" WITH OWNER = \"$owner\" ENCODING = '$encoding' TEMPLATE = $template"
        result = LibPQ.execute(conn, create_query)
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
            return "Database '$db_name' created successfully with owner '$owner'"
        else
            error_msg = LibPQ.error_message(result)
            return "Failed to create database: $error_msg"
        end
        
    catch e
        return "Error creating database: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function drop_database_tool(args::Dict{String,Any})
    db_name = get(args, "name", "")
    force = get(args, "force", false)
    
    if isempty(db_name)
        return "Error: Database name is required"
    end
    
    # Prevent dropping system databases
    system_dbs = ["postgres", "template0", "template1"]
    if db_name in system_dbs
        return "Error: Cannot drop system database '$db_name'"
    end
    
    conn = nothing
    try
        conn = get_connection("postgres")
        
        # Check if database exists
        check_query = "SELECT 1 FROM pg_database WHERE datname = \$1"
        result = LibPQ.execute(conn, check_query, [db_name])
        
        if LibPQ.num_rows(result) == 0
            return "Database '$db_name' does not exist"
        end
        
        # Terminate connections if force is true
        if force
            terminate_query = """
            SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity 
            WHERE datname = \$1 AND pid <> pg_backend_pid()
            """
            LibPQ.execute(conn, terminate_query, [db_name])
        end
        
        # Drop database
        drop_query = "DROP DATABASE \"$db_name\""
        result = LibPQ.execute(conn, drop_query)
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
            return "Database '$db_name' dropped successfully"
        else
            error_msg = LibPQ.error_message(result)
            return "Failed to drop database: $error_msg"
        end
        
    catch e
        return "Error dropping database: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function create_user_tool(args::Dict{String,Any})
    username = get(args, "username", "")
    password = get(args, "password", "")
    superuser = get(args, "superuser", false)
    createdb = get(args, "createdb", false)
    createrole = get(args, "createrole", false)
    login = get(args, "login", true)
    
    if isempty(username)
        return "Error: Username is required"
    end
    
    if isempty(password)
        return "Error: Password is required"
    end
    
    conn = nothing
    try
        conn = get_connection()
        
        # Check if user already exists
        check_query = "SELECT 1 FROM pg_roles WHERE rolname = \$1"
        result = LibPQ.execute(conn, check_query, [username])
        
        if LibPQ.num_rows(result) > 0
            return "User '$username' already exists"
        end
        
        # Build CREATE ROLE command
        privileges = String[]
        superuser && push!(privileges, "SUPERUSER")
        createdb && push!(privileges, "CREATEDB")
        createrole && push!(privileges, "CREATEROLE")
        login && push!(privileges, "LOGIN")
        
        privileges_str = isempty(privileges) ? "" : " " * join(privileges, " ")
        
        create_query = "CREATE ROLE \"$username\" WITH PASSWORD '\$1'$privileges_str"
        result = LibPQ.execute(conn, create_query, [password])
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
            return "User '$username' created successfully with privileges: $(join(privileges, ", "))"
        else
            error_msg = LibPQ.error_message(result)
            return "Failed to create user: $error_msg"
        end
        
    catch e
        return "Error creating user: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function drop_user_tool(args::Dict{String,Any})
    username = get(args, "username", "")
    
    if isempty(username)
        return "Error: Username is required"
    end
    
    # Prevent dropping current user
    if username == PG_CONFIG["user"]
        return "Error: Cannot drop current user '$username'"
    end
    
    conn = nothing
    try
        conn = get_connection()
        
        # Check if user exists
        check_query = "SELECT 1 FROM pg_roles WHERE rolname = \$1"
        result = LibPQ.execute(conn, check_query, [username])
        
        if LibPQ.num_rows(result) == 0
            return "User '$username' does not exist"
        end
        
        # Drop user
        drop_query = "DROP ROLE \"$username\""
        result = LibPQ.execute(conn, drop_query)
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
            return "User '$username' dropped successfully"
        else
            error_msg = LibPQ.error_message(result)
            return "Failed to drop user: $error_msg"
        end
        
    catch e
        return "Error dropping user: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function grant_privileges_tool(args::Dict{String,Any})
    username = get(args, "username", "")
    database = get(args, "database", "")
    privileges = get(args, "privileges", String[])
    table_name = get(args, "table", "")
    
    if isempty(username)
        return "Error: Username is required"
    end
    
    if isempty(privileges)
        return "Error: At least one privilege is required"
    end
    
    conn = nothing
    try
        target_db = isempty(database) ? PG_CONFIG["dbname"] : database
        conn = get_connection(target_db)
        
        # Build GRANT command
        privileges_str = join(privileges, ", ")
        
        if !isempty(table_name)
            # Grant table-level privileges
            grant_query = "GRANT $privileges_str ON TABLE \"$table_name\" TO \"$username\""
        elseif !isempty(database)
            # Grant database-level privileges
            grant_query = "GRANT $privileges_str ON DATABASE \"$database\" TO \"$username\""
        else
            return "Error: Either database or table must be specified"
        end
        
        result = LibPQ.execute(conn, grant_query)
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
            target = !isempty(table_name) ? "table '$table_name'" : "database '$database'"
            return "Privileges '$(join(privileges, ", "))' granted to user '$username' on $target"
        else
            error_msg = LibPQ.error_message(result)
            return "Failed to grant privileges: $error_msg"
        end
        
    catch e
        return "Error granting privileges: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function create_table_from_json_tool(args::Dict{String,Any})
    table_name = get(args, "table", "")
    schema_json = get(args, "schema", "")
    schema_name = get(args, "schema_name", "public")
    
    if isempty(table_name)
        return "Error: Table name is required"
    end
    
    if isempty(schema_json)
        return "Error: JSON schema is required"
    end
    
    conn = nothing
    try
        conn = get_connection()
        
        # Parse JSON schema
        schema = JSON3.read(schema_json)
        
        if !haskey(schema, "properties")
            return "Error: JSON schema must have 'properties' field"
        end
        
        # Build CREATE TABLE statement
        columns = String[]
        
        for (field_name, field_def) in schema["properties"]
            col_type = json_type_to_sql(Dict(field_def))
            nullable = get(field_def, "nullable", true) ? "" : " NOT NULL"
            default_val = haskey(field_def, "default") ? " DEFAULT '$(field_def["default"])'" : ""
            
            push!(columns, "\"$field_name\" $col_type$nullable$default_val")
        end
        
        # Add primary key if specified
        if haskey(schema, "primary_key")
            pk_cols = isa(schema["primary_key"], String) ? [schema["primary_key"]] : schema["primary_key"]
            pk_str = join(["\"$col\"" for col in pk_cols], ", ")
            push!(columns, "PRIMARY KEY ($pk_str)")
        end
        
        columns_str = join(columns, ",\n    ")
        create_query = "CREATE TABLE \"$schema_name\".\"$table_name\" (\n    $columns_str\n)"
        
        result = LibPQ.execute(conn, create_query)
        
        if LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
            return "Table '$schema_name.$table_name' created successfully from JSON schema\n\nSQL:\n$create_query"
        else
            error_msg = LibPQ.error_message(result)
            return "Failed to create table: $error_msg\n\nSQL:\n$create_query"
        end
        
    catch e
        return "Error creating table from JSON: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function json_type_to_sql(field_def::Dict)
    json_type = get(field_def, "type", "string")
    format = get(field_def, "format", "")
    max_length = get(field_def, "maxLength", nothing)
    
    if json_type == "string"
        if format == "date"
            return "DATE"
        elseif format == "datetime" || format == "date-time"
            return "TIMESTAMP"
        elseif format == "time"
            return "TIME"
        elseif format == "email"
            return "VARCHAR(255)"
        elseif format == "uuid"
            return "UUID"
        else
            if max_length !== nothing
                return "VARCHAR($max_length)"
            else
                return "TEXT"
            end
        end
    elseif json_type == "integer"
        return "INTEGER"
    elseif json_type == "number"
        return "DECIMAL"
    elseif json_type == "boolean"
        return "BOOLEAN"
    elseif json_type == "array"
        return "JSONB"
    elseif json_type == "object"
        return "JSONB"
    else
        return "TEXT"
    end
end

function export_schema_tool(args::Dict{String,Any})
    database = get(args, "database", PG_CONFIG["dbname"])
    schema_name = get(args, "schema", "public")
    format = get(args, "format", "sql")  # sql or json
    
    conn = nothing
    try
        conn = get_connection(database)
        
        if format == "json"
            return export_schema_as_json(conn, schema_name)
        else
            return export_schema_as_sql(conn, schema_name)
        end
        
    catch e
        return "Error exporting schema: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function export_schema_as_sql(conn::LibPQ.Connection, schema_name::String)
    # Get all tables in schema
    tables_query = """
    SELECT table_name 
    FROM information_schema.tables 
    WHERE table_schema = \$1 AND table_type = 'BASE TABLE'
    ORDER BY table_name
    """
    
    result = LibPQ.execute(conn, tables_query, [schema_name])
    
    if LibPQ.num_rows(result) == 0
        return "No tables found in schema '$schema_name'"
    end
    
    sql_output = "-- Schema export for '$schema_name'\n-- Generated: $(Dates.now())\n\n"
    
    for row_idx in 1:LibPQ.num_rows(result)
        table_name = LibPQ.getindex(result, row_idx, 1)
        
        # Get table creation SQL
        create_table_query = """
        SELECT 
            'CREATE TABLE "' || n.nspname || '"."' || c.relname || '" (' ||
            array_to_string(
                array_agg(
                    '"' || a.attname || '" ' || 
                    format_type(a.atttypid, a.atttypmod) ||
                    CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
                    CASE WHEN a.atthasdef THEN ' DEFAULT ' || pg_get_expr(ad.adbin, ad.adrelid) ELSE '' END
                    ORDER BY a.attnum
                ),
                E',\\n    '
            ) || 
            ');'
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        LEFT JOIN pg_attrdef ad ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
        WHERE n.nspname = \$1 AND c.relname = \$2 AND a.attnum > 0 AND NOT a.attisdropped
        GROUP BY n.nspname, c.relname
        """
        
        create_result = LibPQ.execute(conn, create_table_query, [schema_name, table_name])
        
        if LibPQ.num_rows(create_result) > 0
            create_sql = LibPQ.getindex(create_result, 1, 1)
            sql_output *= "-- Table: $table_name\n$create_sql\n\n"
        end
    end
    
    return sql_output
end

function export_schema_as_json(conn::LibPQ.Connection, schema_name::String)
    # Get all tables with their column information
    columns_query = """
    SELECT 
        c.table_name,
        c.column_name,
        c.data_type,
        c.is_nullable,
        c.column_default,
        c.character_maximum_length,
        c.numeric_precision,
        c.numeric_scale
    FROM information_schema.columns c
    JOIN information_schema.tables t ON c.table_name = t.table_name AND c.table_schema = t.table_schema
    WHERE c.table_schema = \$1 AND t.table_type = 'BASE TABLE'
    ORDER BY c.table_name, c.ordinal_position
    """
    
    result = LibPQ.execute(conn, columns_query, [schema_name])
    
    if LibPQ.num_rows(result) == 0
        return "No tables found in schema '$schema_name'"
    end
    
    tables = Dict{String, Any}()
    
    for row_idx in 1:LibPQ.num_rows(result)
        table_name = LibPQ.getindex(result, row_idx, 1)
        column_name = LibPQ.getindex(result, row_idx, 2)
        data_type = LibPQ.getindex(result, row_idx, 3)
        is_nullable = LibPQ.getindex(result, row_idx, 4)
        column_default = something(LibPQ.getindex(result, row_idx, 5), nothing)
        max_length = something(LibPQ.getindex(result, row_idx, 6), nothing)
        
        if !haskey(tables, table_name)
            tables[table_name] = Dict(
                "type" => "object",
                "properties" => Dict{String, Any}()
            )
        end
        
        # Convert SQL type to JSON schema type
        json_type = sql_type_to_json(data_type)
        
        column_def = Dict{String, Any}("type" => json_type)
        
        if is_nullable == "NO"
            column_def["nullable"] = false
        end
        
        if column_default !== nothing
            column_def["default"] = column_default
        end
        
        if max_length !== nothing
            column_def["maxLength"] = max_length
        end
        
        tables[table_name]["properties"][column_name] = column_def
    end
    
    schema_export = Dict(
        "schema" => schema_name,
        "exported_at" => string(Dates.now()),
        "tables" => tables
    )
    
    return JSON3.write(schema_export, allow_inf=true)
end

function sql_type_to_json(sql_type::String)
    if startswith(sql_type, "character") || startswith(sql_type, "varchar") || sql_type == "text"
        return "string"
    elseif sql_type == "integer" || sql_type == "bigint" || sql_type == "smallint"
        return "integer"
    elseif sql_type == "numeric" || sql_type == "decimal" || sql_type == "real" || sql_type == "double precision"
        return "number"
    elseif sql_type == "boolean"
        return "boolean"
    elseif sql_type == "date"
        return "string"  # with format: date
    elseif startswith(sql_type, "timestamp")
        return "string"  # with format: date-time
    elseif sql_type == "jsonb" || sql_type == "json"
        return "object"
    else
        return "string"
    end
end

function import_data_tool(args::Dict{String,Any})
    table_name = get(args, "table", "")
    data = get(args, "data", "")
    format = get(args, "format", "json")  # json or csv
    schema_name = get(args, "schema", "public")
    
    if isempty(table_name)
        return "Error: Table name is required"
    end
    
    if isempty(data)
        return "Error: Data is required"
    end
    
    conn = nothing
    try
        conn = get_connection()
        
        if format == "json"
            return import_json_data(conn, schema_name, table_name, data)
        elseif format == "csv"
            return import_csv_data(conn, schema_name, table_name, data)
        else
            return "Error: Unsupported format '$format'. Use 'json' or 'csv'"
        end
        
    catch e
        return "Error importing data: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function import_json_data(conn::LibPQ.Connection, schema_name::String, table_name::String, json_data::String)
    # Parse JSON data
    data = JSON3.read(json_data)
    
    # Handle both single object and array of objects
    records = isa(data, Vector) ? data : [data]
    
    if isempty(records)
        return "No data to import"
    end
    
    # Get column names from first record
    columns = collect(string.(keys(records[1])))
    columns_str = join(["\"$col\"" for col in columns], ", ")
    placeholders = join(["\$$i" for i in 1:length(columns)], ", ")
    
    insert_query = "INSERT INTO \"$schema_name\".\"$table_name\" ($columns_str) VALUES ($placeholders)"
    
    # Begin transaction
    LibPQ.execute(conn, "BEGIN")
    
    try
        inserted_count = 0
        for record in records
            values = [hasproperty(record, Symbol(col)) ? getproperty(record, Symbol(col)) : nothing for col in columns]
            result = LibPQ.execute(conn, insert_query, values)
            
            if LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
                inserted_count += 1
            else
                error_msg = LibPQ.error_message(result)
                LibPQ.execute(conn, "ROLLBACK")
                return "Failed to insert record: $error_msg"
            end
        end
        
        LibPQ.execute(conn, "COMMIT")
        return "Successfully imported $inserted_count records into '$schema_name.$table_name'"
        
    catch e
        LibPQ.execute(conn, "ROLLBACK")
        return "Import failed: $(string(e))"
    end
end

function import_csv_data(conn::LibPQ.Connection, schema_name::String, table_name::String, csv_data::String)
    lines = split(csv_data, '\n')
    
    if length(lines) < 2
        return "CSV data must have at least a header row and one data row"
    end
    
    # Parse header
    header = strip.(split(lines[1], ','))
    columns_str = join(["\"$col\"" for col in header], ", ")
    placeholders = join(["\$$i" for i in 1:length(header)], ", ")
    
    insert_query = "INSERT INTO \"$schema_name\".\"$table_name\" ($columns_str) VALUES ($placeholders)"
    
    # Begin transaction
    LibPQ.execute(conn, "BEGIN")
    
    try
        inserted_count = 0
        for line_idx in 2:length(lines)
            line = strip(lines[line_idx])
            if isempty(line)
                continue
            end
            
            values = strip.(split(line, ','))
            if length(values) != length(header)
                LibPQ.execute(conn, "ROLLBACK")
                return "Row $line_idx has $(length(values)) values but expected $(length(header))"
            end
            
            result = LibPQ.execute(conn, insert_query, values)
            
            if LibPQ.status(result) == LibPQ.libpq_c.PGRES_COMMAND_OK
                inserted_count += 1
            else
                error_msg = LibPQ.error_message(result)
                LibPQ.execute(conn, "ROLLBACK")
                return "Failed to insert row $line_idx: $error_msg"
            end
        end
        
        LibPQ.execute(conn, "COMMIT")
        return "Successfully imported $inserted_count records into '$schema_name.$table_name'"
        
    catch e
        LibPQ.execute(conn, "ROLLBACK")
        return "Import failed: $(string(e))"
    end
end

function export_data_tool(args::Dict{String,Any})
    table_name = get(args, "table", "")
    format = get(args, "format", "json")  # json or csv
    schema_name = get(args, "schema", "public")
    limit = get(args, "limit", 1000)
    where_clause = get(args, "where", "")
    
    if isempty(table_name)
        return "Error: Table name is required"
    end
    
    conn = nothing
    try
        conn = get_connection()
        
        # Build query
        query = "SELECT * FROM \"$schema_name\".\"$table_name\""
        
        if !isempty(where_clause)
            query *= " WHERE $where_clause"
        end
        
        query *= " LIMIT $limit"
        
        result = LibPQ.execute(conn, query)
        
        if LibPQ.status(result) != LibPQ.libpq_c.PGRES_TUPLES_OK
            error_msg = LibPQ.error_message(result)
            return "Failed to export data: $error_msg"
        end
        
        num_rows = LibPQ.num_rows(result)
        num_cols = LibPQ.num_columns(result)
        
        if num_rows == 0
            return "No data found in table '$schema_name.$table_name'"
        end
        
        # Get column names
        column_names = [LibPQ.column_name(result, i) for i in 1:num_cols]
        
        if format == "json"
            return export_data_as_json(result, column_names, num_rows, num_cols)
        elseif format == "csv"
            return export_data_as_csv(result, column_names, num_rows, num_cols)
        else
            return "Error: Unsupported format '$format'. Use 'json' or 'csv'"
        end
        
    catch e
        return "Error exporting data: $(string(e))"
    finally
        if conn !== nothing
            return_connection(conn)
        end
    end
end

function export_data_as_json(result, column_names, num_rows, num_cols)
    records = []
    
    for row_idx in 1:num_rows
        record = Dict{String, Any}()
        for col_idx in 1:num_cols
            value = LibPQ.getindex(result, row_idx, col_idx)
            record[column_names[col_idx]] = something(value, nothing)
        end
        push!(records, record)
    end
    
    return JSON3.write(records, allow_inf=true)
end

function export_data_as_csv(result, column_names, num_rows, num_cols)
    # Header
    csv_output = join(column_names, ",") * "\n"
    
    # Data rows
    for row_idx in 1:num_rows
        row_values = []
        for col_idx in 1:num_cols
            value = LibPQ.getindex(result, row_idx, col_idx)
            push!(row_values, something(value, ""))
        end
        csv_output *= join(row_values, ",") * "\n"
    end
    
    return csv_output
end

function main()
    server = MCPServer("Database Admin MCP Server", "0.1.0", "MCP server providing comprehensive PostgreSQL database administration tools")
    
    println("🗄️  Database Admin MCP Server")
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
    
    # Create Database Tool
    create_database_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "name" => Dict{String,Any}(
                "type" => "string",
                "description" => "Name of the database to create"
            ),
            "owner" => Dict{String,Any}(
                "type" => "string",
                "description" => "Owner of the database (default: current user)"
            ),
            "encoding" => Dict{String,Any}(
                "type" => "string",
                "description" => "Database encoding (default: UTF8)"
            ),
            "template" => Dict{String,Any}(
                "type" => "string",
                "description" => "Template database (default: template0)"
            )
        ),
        "required" => ["name"]
    )
    
    add_tool!(server, MCPTool(
        "create_database",
        "Create a new PostgreSQL database",
        create_database_schema,
        create_database_tool
    ))
    
    # Drop Database Tool
    drop_database_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "name" => Dict{String,Any}(
                "type" => "string",
                "description" => "Name of the database to drop"
            ),
            "force" => Dict{String,Any}(
                "type" => "boolean",
                "description" => "Force drop by terminating active connections (default: false)"
            )
        ),
        "required" => ["name"]
    )
    
    add_tool!(server, MCPTool(
        "drop_database",
        "Drop a PostgreSQL database",
        drop_database_schema,
        drop_database_tool
    ))
    
    # Create User Tool
    create_user_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "username" => Dict{String,Any}(
                "type" => "string",
                "description" => "Username for the new user"
            ),
            "password" => Dict{String,Any}(
                "type" => "string",
                "description" => "Password for the new user"
            ),
            "superuser" => Dict{String,Any}(
                "type" => "boolean",
                "description" => "Grant superuser privileges (default: false)"
            ),
            "createdb" => Dict{String,Any}(
                "type" => "boolean",
                "description" => "Grant create database privileges (default: false)"
            ),
            "createrole" => Dict{String,Any}(
                "type" => "boolean",
                "description" => "Grant create role privileges (default: false)"
            ),
            "login" => Dict{String,Any}(
                "type" => "boolean",
                "description" => "Allow user to login (default: true)"
            )
        ),
        "required" => ["username", "password"]
    )
    
    add_tool!(server, MCPTool(
        "create_user",
        "Create a new PostgreSQL user/role",
        create_user_schema,
        create_user_tool
    ))
    
    # Drop User Tool
    drop_user_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "username" => Dict{String,Any}(
                "type" => "string",
                "description" => "Username to drop"
            )
        ),
        "required" => ["username"]
    )
    
    add_tool!(server, MCPTool(
        "drop_user",
        "Drop a PostgreSQL user/role",
        drop_user_schema,
        drop_user_tool
    ))
    
    # Grant Privileges Tool
    grant_privileges_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "username" => Dict{String,Any}(
                "type" => "string",
                "description" => "Username to grant privileges to"
            ),
            "privileges" => Dict{String,Any}(
                "type" => "array",
                "items" => Dict{String,Any}("type" => "string"),
                "description" => "List of privileges to grant (e.g., ['SELECT', 'INSERT', 'UPDATE'])"
            ),
            "database" => Dict{String,Any}(
                "type" => "string",
                "description" => "Database name (for database-level privileges)"
            ),
            "table" => Dict{String,Any}(
                "type" => "string",
                "description" => "Table name (for table-level privileges)"
            )
        ),
        "required" => ["username", "privileges"]
    )
    
    add_tool!(server, MCPTool(
        "grant_privileges",
        "Grant privileges to a user on database or table",
        grant_privileges_schema,
        grant_privileges_tool
    ))
    
    # Create Table from JSON Schema Tool
    create_table_json_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "table" => Dict{String,Any}(
                "type" => "string",
                "description" => "Name of the table to create"
            ),
            "schema" => Dict{String,Any}(
                "type" => "string",
                "description" => "JSON schema definition for the table structure"
            ),
            "schema_name" => Dict{String,Any}(
                "type" => "string",
                "description" => "Database schema name (default: public)"
            )
        ),
        "required" => ["table", "schema"]
    )
    
    add_tool!(server, MCPTool(
        "create_table_from_json",
        "Create a table from JSON schema definition",
        create_table_json_schema,
        create_table_from_json_tool
    ))
    
    # Export Schema Tool
    export_schema_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "database" => Dict{String,Any}(
                "type" => "string",
                "description" => "Database name (default: current database)"
            ),
            "schema" => Dict{String,Any}(
                "type" => "string",
                "description" => "Schema name (default: public)"
            ),
            "format" => Dict{String,Any}(
                "type" => "string",
                "description" => "Export format: 'sql' or 'json' (default: sql)"
            )
        )
    )
    
    add_tool!(server, MCPTool(
        "export_schema",
        "Export database schema as SQL DDL or JSON",
        export_schema_schema,
        export_schema_tool
    ))
    
    # Import Data Tool
    import_data_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "table" => Dict{String,Any}(
                "type" => "string",
                "description" => "Target table name"
            ),
            "data" => Dict{String,Any}(
                "type" => "string",
                "description" => "Data to import (JSON array or CSV text)"
            ),
            "format" => Dict{String,Any}(
                "type" => "string",
                "description" => "Data format: 'json' or 'csv' (default: json)"
            ),
            "schema" => Dict{String,Any}(
                "type" => "string",
                "description" => "Schema name (default: public)"
            )
        ),
        "required" => ["table", "data"]
    )
    
    add_tool!(server, MCPTool(
        "import_data",
        "Import data into a table from JSON or CSV",
        import_data_schema,
        import_data_tool
    ))
    
    # Export Data Tool
    export_data_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "table" => Dict{String,Any}(
                "type" => "string",
                "description" => "Table name to export"
            ),
            "format" => Dict{String,Any}(
                "type" => "string",
                "description" => "Export format: 'json' or 'csv' (default: json)"
            ),
            "schema" => Dict{String,Any}(
                "type" => "string",
                "description" => "Schema name (default: public)"
            ),
            "limit" => Dict{String,Any}(
                "type" => "integer",
                "description" => "Maximum number of rows to export (default: 1000)"
            ),
            "where" => Dict{String,Any}(
                "type" => "string",
                "description" => "WHERE clause for filtering data"
            )
        ),
        "required" => ["table"]
    )
    
    add_tool!(server, MCPTool(
        "export_data",
        "Export table data as JSON or CSV",
        export_data_schema,
        export_data_tool
    ))
    
    start_server(server)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end