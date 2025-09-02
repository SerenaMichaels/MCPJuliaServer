#!/usr/bin/env julia
"""
Database Connection Monitor
Continuously monitors database connectivity and updates configuration when IP changes detected
"""

using Pkg
Pkg.activate(".")

include("src/DatabaseConnectionManager.jl")
using .DatabaseConnectionManager

# Load site configuration
include("config/site_config.jl")
using .SiteConfig

using Dates

"""
Monitor database connection and automatically update configuration on IP changes
"""
function monitor_database_connection()
    println("🔍 Starting Database Connection Monitor")
    println("=" ^ 50)
    
    SiteConfig.load_config(".")
    config = SiteConfig.get_db_config()
    
    check_interval = 30  # seconds
    last_check_time = DateTime(1900)
    
    while true
        current_time = now()
        
        # Check connection every interval
        if (current_time - last_check_time).value / 1000 >= check_interval
            print("$(Dates.format(current_time, "HH:MM:SS")) - Testing connection to $(config["host"])...")
            
            success, conn = DatabaseConnectionManager.test_connection(
                config["host"],
                parse(Int, config["port"]),
                config["user"],
                config["password"],
                config["dbname"]
            )
            
            if success
                println(" ✅ OK")
                using LibPQ
                LibPQ.close(conn)
            else
                println(" ❌ FAILED")
                println("🔄 Attempting IP recovery...")
                
                success, new_host, conn = DatabaseConnectionManager.detect_and_recover_connection(
                    config["host"],
                    parse(Int, config["port"]),
                    config["user"],
                    config["password"],
                    config["dbname"]
                )
                
                if success
                    println("🎯 Recovery successful! New host: $(config["host"]) → $new_host")
                    config["host"] = new_host
                    
                    # Close the test connection
                    using LibPQ
                    LibPQ.close(conn)
                    
                    # Log the IP change
                    println("📝 IP change detected and resolved at $(Dates.format(current_time, "yyyy-mm-dd HH:MM:SS"))")
                else
                    println("💥 Recovery failed! Database may be down.")
                end
            end
            
            last_check_time = current_time
        end
        
        sleep(5)  # Check every 5 seconds for timing, but only test connection every 30s
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        monitor_database_connection()
    catch InterruptException
        println("\n👋 Database monitor stopped.")
    catch e
        println("❌ Monitor error: $e")
    end
end