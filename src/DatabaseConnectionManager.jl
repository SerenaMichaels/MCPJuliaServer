#!/usr/bin/env julia
"""
Database Connection Manager with Dynamic IP Detection
Automatically detects and recovers from WSL IP changes that break PostgreSQL connectivity
"""

module DatabaseConnectionManager

export detect_and_recover_connection, get_windows_host_ip, test_connection

using LibPQ
using Dates

# Cache for connection parameters
mutable struct ConnectionState
    current_host::String
    last_successful_connection::DateTime
    connection_attempts::Int
    max_attempts::Int
    
    ConnectionState() = new("", DateTime(1900), 0, 3)
end

const CONNECTION_STATE = ConnectionState()

"""
Get potential Windows host IPs for PostgreSQL connection
Returns array of IP addresses to try in order of preference
"""
function get_windows_host_ips()::Vector{String}
    ips = String[]
    
    try
        # Method 1: Default gateway (most reliable for WSL→Windows)
        gateway_result = read(`ip route show default`, String)
        gateway_match = match(r"default via (\d+\.\d+\.\d+\.\d+)", gateway_result)
        if gateway_match !== nothing
            push!(ips, gateway_match.captures[1])
        end
    catch e
        @debug "Failed to get default gateway: $e"
    end
    
    try
        # Method 2: WSL bridge network (172.x.x.1 pattern)
        route_result = read(`ip route`, String)
        for line in split(route_result, '\n')
            bridge_match = match(r"(\d+\.\d+\.\d+\.\d+)/\d+ dev eth\d+ proto kernel scope link src (\d+\.\d+\.\d+\.\d+)", line)
            if bridge_match !== nothing
                # Try .1 address in the same subnet
                subnet_parts = split(bridge_match.captures[1], '.')
                if length(subnet_parts) >= 3
                    bridge_ip = join(subnet_parts[1:3], ".") * ".1"
                    if bridge_ip ∉ ips
                        push!(ips, bridge_ip)
                    end
                end
            end
        end
    catch e
        @debug "Failed to detect bridge IPs: $e"
    end
    
    try
        # Method 3: Nameserver from resolv.conf
        resolv_content = read("/etc/resolv.conf", String)
        for line in split(resolv_content, '\n')
            nameserver_match = match(r"nameserver\s+(\d+\.\d+\.\d+\.\d+)", line)
            if nameserver_match !== nothing && nameserver_match.captures[1] ∉ ips
                push!(ips, nameserver_match.captures[1])
            end
        end
    catch e
        @debug "Failed to read resolv.conf: $e"
    end
    
    # Fallback options
    fallback_ips = ["localhost", "127.0.0.1", "host.docker.internal"]
    for ip in fallback_ips
        if ip ∉ ips
            push!(ips, ip)
        end
    end
    
    return ips
end

"""
Test PostgreSQL connection with given parameters
Returns (success::Bool, connection::Union{LibPQ.Connection, Nothing})
"""
function test_connection(host::String, port::Int, user::String, password::String, dbname::String)
    try
        conn_string = "host=$host port=$port user=$user password=$password dbname=$dbname connect_timeout=5"
        @debug "Testing connection to $host:$port/$dbname"
        
        conn = LibPQ.Connection(conn_string)
        
        if LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK
            # Test with a simple query
            result = LibPQ.execute(conn, "SELECT 1 as test")
            if LibPQ.status(result) == LibPQ.libpq_c.PGRES_TUPLES_OK
                @info "✅ Successfully connected to PostgreSQL at $host:$port/$dbname"
                return (true, conn)
            end
        end
        
        LibPQ.close(conn)
    catch e
        @debug "Connection failed to $host:$port/$dbname: $e"
    end
    
    return (false, nothing)
end

"""
Detect IP change and attempt to recover database connection
Returns (success::Bool, new_host::String, connection::Union{LibPQ.Connection, Nothing})
"""
function detect_and_recover_connection(current_host::String, port::Int, user::String, password::String, dbname::String)
    @info "🔍 Database connection failed. Detecting potential IP changes..."
    
    # First, try the current host again (might be temporary)
    CONNECTION_STATE.connection_attempts += 1
    if CONNECTION_STATE.connection_attempts <= CONNECTION_STATE.max_attempts
        success, conn = test_connection(current_host, port, user, password, dbname)
        if success
            @info "✅ Connection recovered to existing host: $current_host"
            CONNECTION_STATE.last_successful_connection = now()
            CONNECTION_STATE.connection_attempts = 0
            return (true, current_host, conn)
        end
    end
    
    # Get potential Windows host IPs
    candidate_ips = get_windows_host_ips()
    @info "🌐 Testing $(length(candidate_ips)) potential host IPs: $(join(candidate_ips, ", "))"
    
    # Test each candidate IP
    for host_ip in candidate_ips
        if host_ip == current_host
            continue  # Already tried above
        end
        
        success, conn = test_connection(host_ip, port, user, password, dbname)
        if success
            @info "🎯 Found working PostgreSQL connection: $current_host → $host_ip"
            CONNECTION_STATE.current_host = host_ip
            CONNECTION_STATE.last_successful_connection = now()
            CONNECTION_STATE.connection_attempts = 0
            
            # Update .env.local file with working IP
            update_env_file(host_ip)
            
            return (true, host_ip, conn)
        end
    end
    
    @error "❌ Could not establish PostgreSQL connection to any host. Tried: $(join(candidate_ips, ", "))"
    return (false, current_host, nothing)
end

"""
Update .env.local file with new working PostgreSQL host
"""
function update_env_file(new_host::String)
    try
        env_file = ".env.local"
        if isfile(env_file)
            content = read(env_file, String)
            
            # Replace POSTGRES_HOST line
            updated_content = replace(content, r"POSTGRES_HOST=.*" => "POSTGRES_HOST=$new_host")
            
            # Add comment with timestamp
            timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
            if !contains(updated_content, "# Auto-updated")
                updated_content = "# Auto-updated PostgreSQL host on $timestamp\n" * updated_content
            end
            
            write(env_file, updated_content)
            @info "📝 Updated $env_file with POSTGRES_HOST=$new_host"
        end
    catch e
        @warn "Failed to update .env.local file: $e"
    end
end

"""
Smart connection getter that automatically recovers from IP changes
"""
function get_smart_connection(config::Dict{String,String})
    host = get(config, "host", "localhost")
    port = parse(Int, get(config, "port", "5432"))
    user = get(config, "user", "postgres")
    password = get(config, "password", "")
    dbname = get(config, "dbname", "postgres")
    
    # Try normal connection first
    success, conn = test_connection(host, port, user, password, dbname)
    if success
        CONNECTION_STATE.last_successful_connection = now()
        CONNECTION_STATE.connection_attempts = 0
        return conn
    end
    
    # Attempt IP recovery
    success, new_host, conn = detect_and_recover_connection(host, port, user, password, dbname)
    if success
        return conn
    end
    
    # All recovery attempts failed
    throw(ArgumentError("Could not establish PostgreSQL connection after trying IP recovery. Check PostgreSQL server status."))
end

end # module