"""
MCP-Agents Centralized Environment Management (Julia)
Session 0012 - Environment Compliance Framework

Provides consistent environment variable expansion and loading across all
Julia MCP servers. Ensures all servers use the master environment configuration.
"""
module MCPEnvironment

using JSON

export load_master_environment!, expand_environment_variables, get_server_port, get_server_host, get_wsl_ip, validate_required_vars, load_config_with_expansion

const MASTER_ENV_FILE = "/mnt/d/MCP-Agents/configs/environment/master-environment.env"
const PORT_MAP = Dict(
    "postgres" => "MCP_POSTGRES_PORT",
    "file" => "MCP_FILE_PORT",
    "dbadmin" => "MCP_DBADMIN_PORT", 
    "orchestrator" => "MCP_ORCHESTRATOR_PORT",
    "botfarm" => "MCP_BOTFARM_PORT",
    "physics" => "MCP_PHYSICS_PORT",
    "agricultural" => "MCP_AGRICULTURAL_PORT",
    "assembly_recipe" => "MCP_ASSEMBLY_RECIPE_PORT",
    "component_import" => "MCP_COMPONENT_IMPORT_PORT"
)

"""
Load and source the master environment file into ENV
"""
function load_master_environment!()
    if !isfile(MASTER_ENV_FILE)
        error("Master environment file not found: $MASTER_ENV_FILE")
    end
    
    @info "Loading master environment from $MASTER_ENV_FILE"
    
    # Read and parse the bash environment file
    for line in eachline(MASTER_ENV_FILE)
        line = strip(line)
        
        # Skip comments, empty lines, and echo statements
        if isempty(line) || startswith(line, '#') || startswith(line, "echo")
            continue
        end
        
        # Process export statements
        if startswith(line, "export ")
            # Remove 'export ' prefix
            line = line[8:end]
            
            # Split on first '=' to handle values with '=' in them
            if contains(line, '=')
                key, value = split(line, '=', limit=2)
                
                # Remove quotes if present
                value = strip(value, ['"', '\''])
                
                # Expand variables in the value (convert SubString to String)
                value = expand_bash_variables(String(value))
                
                # Set in ENV
                ENV[key] = value
            end
        end
    end
    
    @info "✅ Master environment loaded successfully"
    return true
end

"""
Expand bash-style variables in values (\$VAR and \${VAR} syntax)
"""
function expand_bash_variables(value::String)
    # Handle \$VAR and \${VAR} syntax
    result = value
    
    # Pattern for \${VAR}
    result = replace(result, r"\$\{([^}]+)\}" => s -> begin
        m = match(r"\$\{([^}]+)\}", s)
        var_name = m.captures[1]
        return get(ENV, var_name, "\${$var_name}")
    end)
    
    # Pattern for \$VAR (word boundaries)
    result = replace(result, r"\$([A-Za-z_][A-Za-z0-9_]*)" => s -> begin
        m = match(r"\$([A-Za-z_][A-Za-z0-9_]*)", s)
        var_name = m.captures[1]
        return get(ENV, var_name, "\$$var_name")
    end)
    
    return result
end

"""
Recursively expand environment variables in configuration objects
"""
function expand_environment_variables(obj)
    if isa(obj, Dict)
        return Dict(k => expand_environment_variables(v) for (k, v) in obj)
    elseif isa(obj, Vector)
        return [expand_environment_variables(item) for item in obj]
    elseif isa(obj, String) && startswith(obj, '\$')
        env_var = obj[2:end]  # Remove \$ prefix
        value = get(ENV, env_var, nothing)
        if value === nothing
            error("Environment variable $env_var not set. Ensure master environment is loaded.")
        end
        # Try to convert to Int if it looks like a number
        try
            return parse(Int, value)
        catch
            return value
        end
    else
        return obj
    end
end

"""
Load JSON configuration with environment variable expansion
"""
function load_config_with_expansion(config_path::String)
    if !isfile(config_path)
        error("Configuration file not found: $config_path")
    end
    
    config = JSON.parsefile(config_path)
    expanded_config = expand_environment_variables(config)
    return expanded_config
end

"""
Get port for a specific server type
"""
function get_server_port(server_type::String)
    env_var = get(PORT_MAP, server_type, nothing)
    if env_var === nothing
        error("Unknown server type: $server_type")
    end
    
    port_str = get(ENV, env_var, nothing)
    if port_str === nothing
        error("Environment variable $env_var not set")
    end
    
    try
        return parse(Int, port_str)
    catch
        error("Invalid port value for $env_var: $port_str")
    end
end

"""
Get server host from environment
"""
function get_server_host()
    host = get(ENV, "MCP_SERVER_HOST", nothing)
    if host === nothing
        error("Environment variable MCP_SERVER_HOST not set")
    end
    return host
end

"""
Get WSL IP address from environment
"""
function get_wsl_ip()
    ip = get(ENV, "MCP_WSL_IP", nothing)
    if ip === nothing
        error("Environment variable MCP_WSL_IP not set")
    end
    return ip
end

"""
Validate that all required environment variables are set
"""
function validate_required_vars(required_vars::Vector{String})
    missing_vars = String[]
    for var in required_vars
        if !haskey(ENV, var)
            push!(missing_vars, var)
        end
    end
    
    if !isempty(missing_vars)
        error("Missing required environment variables: $missing_vars")
    end
    
    return true
end

# Auto-load master environment when module is imported
function __init__()
    try
        load_master_environment!()
        @info "🌍 MCP Environment Module initialized"
    catch e
        @error "Failed to load master environment: $e"
        rethrow(e)
    end
end

end # module