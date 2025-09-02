#!/usr/bin/env julia
"""
Test script for Smart Database Connection Recovery
"""

using Pkg
Pkg.activate(".")

include("src/DatabaseConnectionManager.jl")
using .DatabaseConnectionManager

# Load site configuration
include("config/site_config.jl")
using .SiteConfig

println("🧪 Testing Smart Database Connection Recovery")
println("=" ^ 50)

# Load configuration
SiteConfig.load_config(".")
const PG_CONFIG = SiteConfig.get_db_config()

println("📋 Current Configuration:")
println("  Host: $(PG_CONFIG["host"])")
println("  Port: $(PG_CONFIG["port"])")
println("  Database: $(PG_CONFIG["dbname"])")
println("  User: $(PG_CONFIG["user"])")
println()

println("🌐 Detecting Windows Host IPs...")
candidate_ips = DatabaseConnectionManager.get_windows_host_ips()
for (i, ip) in enumerate(candidate_ips)
    println("  $i. $ip")
end
println()

println("🔗 Testing Current Connection...")
success, conn = DatabaseConnectionManager.test_connection(
    PG_CONFIG["host"],
    parse(Int, PG_CONFIG["port"]),
    PG_CONFIG["user"], 
    PG_CONFIG["password"],
    PG_CONFIG["dbname"]
)

if success
    println("✅ Current connection is working!")
    using LibPQ
    LibPQ.close(conn)
else
    println("❌ Current connection failed. Testing recovery...")
    
    success, new_host, conn = DatabaseConnectionManager.detect_and_recover_connection(
        PG_CONFIG["host"],
        parse(Int, PG_CONFIG["port"]),
        PG_CONFIG["user"],
        PG_CONFIG["password"], 
        PG_CONFIG["dbname"]
    )
    
    if success
        println("🎯 Recovery successful! New host: $new_host")
        using LibPQ
        LibPQ.close(conn)
    else
        println("💥 Recovery failed!")
    end
end

println()
println("🧪 Smart connection test completed!")