#!/usr/bin/env julia
# Test database targeting functionality

using Pkg
Pkg.activate(".")

using LibPQ

# Load site configuration
include("config/site_config.jl")
using .SiteConfig

# Load configuration
SiteConfig.load_config(".")

# Test database connection functionality
function test_connection_to_database(database_name::String)
    try
        println("Testing connection to database: $database_name")
        
        host = SiteConfig.get_config("POSTGRES_HOST")
        port = SiteConfig.get_config("POSTGRES_PORT") 
        user = SiteConfig.get_config("POSTGRES_USER")
        password = SiteConfig.get_config("POSTGRES_PASSWORD")
        
        println("Connection parameters:")
        println("  Host: $host")
        println("  Port: $port") 
        println("  User: $user")
        println("  Database: $database_name")
        
        conn = LibPQ.Connection(
            "host=$host port=$port dbname=$database_name user=$user password=$password"
        )
        
        # Test the connection with a simple query
        result = LibPQ.execute(conn, "SELECT current_database() as connected_db, version() as pg_version")
        
        for row in result
            println("✅ Successfully connected to database: $(row[1])")
            println("   PostgreSQL version: $(row[2])")
        end
        
        LibPQ.close(conn)
        return true
        
    catch e
        println("❌ Connection failed: $(string(e))")
        return false
    end
end

function main()
    println("=== Database Targeting Test ===")
    
    # Test connection to default postgres database
    println("\n1. Testing default postgres database:")
    test_connection_to_database("postgres")
    
    # Test connection to TestDB if it exists
    println("\n2. Testing TestDB database:")
    test_connection_to_database("TestDB")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end