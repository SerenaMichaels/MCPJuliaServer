# Site Configuration Manager
# Handles loading of site-specific configurations with proper precedence

module SiteConfig

export load_config, get_config, has_config

using Base: get
using Logging

# Configuration precedence (highest to lowest):
# 1. Environment variables
# 2. .env.local (local development)
# 3. .env.site (site-specific deployment)
# 4. .env (default configuration)

const CONFIG_FILES = [
    ".env",           # Default configuration (committed)
    ".env.site",      # Site-specific (not committed)
    ".env.local"      # Local development (not committed)
]

# Global configuration store
const SITE_CONFIG = Dict{String, String}()

"""
Load environment configuration files in order of precedence
"""
function load_config(base_dir::String = ".")
    # Clear existing config
    empty!(SITE_CONFIG)
    
    @info "Loading site configuration from $base_dir"
    
    # Load configuration files in reverse precedence order
    # (later files override earlier ones)
    for config_file in CONFIG_FILES
        config_path = joinpath(base_dir, config_file)
        if isfile(config_path)
            load_env_file(config_path)
            @info "Loaded configuration from $config_file"
        else
            @debug "Configuration file not found: $config_file"
        end
    end
    
    # Environment variables have highest precedence
    merge!(SITE_CONFIG, ENV)
    
    @info "Configuration loaded with $(length(SITE_CONFIG)) settings"
    return SITE_CONFIG
end

"""
Load a single .env file and parse its contents
"""
function load_env_file(file_path::String)
    try
        open(file_path, "r") do file
            for line in eachline(file)
                # Skip comments and empty lines
                line = strip(line)
                if isempty(line) || startswith(line, "#")
                    continue
                end
                
                # Parse KEY=VALUE pairs
                if contains(line, "=")
                    key, value = split(line, "=", limit=2)
                    key = strip(key)
                    value = strip(value)
                    
                    # Remove quotes if present
                    if (startswith(value, "\"") && endswith(value, "\"")) ||
                       (startswith(value, "'") && endswith(value, "'"))
                        value = value[2:end-1]
                    end
                    
                    # Only set if not already set (precedence)
                    if !haskey(SITE_CONFIG, key)
                        SITE_CONFIG[key] = value
                    end
                end
            end
        end
    catch e
        @warn "Error loading configuration file $file_path: $e"
    end
end

"""
Get configuration value with optional default
"""
function get_config(key::String, default::String = "")
    return get(SITE_CONFIG, key, default)
end

"""
Check if configuration key exists
"""
function has_config(key::String)
    return haskey(SITE_CONFIG, key)
end

"""
Get database configuration as a dictionary
"""
function get_db_config()
    return Dict{String,String}(
        "host" => get_config("POSTGRES_HOST", "localhost"),
        "port" => get_config("POSTGRES_PORT", "5432"),
        "user" => get_config("POSTGRES_USER", "postgres"),
        "password" => get_config("POSTGRES_PASSWORD", ""),
        "dbname" => get_config("POSTGRES_DB", "postgres")
    )
end

"""
Get file server configuration
"""
function get_file_server_config()
    base_dir = get_config("MCP_FILE_SERVER_BASE", "/opt/mcp-data")
    
    # Expand ~ to home directory if present
    if startswith(base_dir, "~")
        base_dir = expanduser(base_dir)
    end
    
    return base_dir
end

"""
Check if we're in development mode
"""
function is_development()
    dev_mode = get_config("MCP_DEV_MODE", "false")
    return lowercase(dev_mode) in ["true", "1", "yes", "on"]
end

"""
Check if debug communication is enabled
"""
function is_debug_communication()
    debug_mode = get_config("MCP_DEBUG_COMMUNICATION", "false")
    return lowercase(debug_mode) in ["true", "1", "yes", "on"]
end

"""
Get site information
"""
function get_site_info()
    return Dict{String,String}(
        "name" => get_config("SITE_NAME", "default-site"),
        "environment" => get_config("SITE_ENVIRONMENT", "development"),
        "deployment_id" => get_config("DEPLOYMENT_ID", "dev-$(Dates.format(Dates.now(), "yyyymmdd"))")
    )
end

"""
Validate required configuration
"""
function validate_config()
    errors = String[]
    
    # Check required database password
    if isempty(get_config("POSTGRES_PASSWORD"))
        push!(errors, "POSTGRES_PASSWORD must be set")
    end
    
    # Check file server base directory
    file_base = get_file_server_config()
    if !isdir(dirname(file_base))
        push!(errors, "MCP_FILE_SERVER_BASE parent directory does not exist: $(dirname(file_base))")
    end
    
    # Check Julia path
    julia_path = get_config("JULIA_PATH", "julia")
    if julia_path != "julia" && !isfile(julia_path)
        push!(errors, "JULIA_PATH does not exist: $julia_path")
    end
    
    if !isempty(errors)
        error("Configuration validation failed:\n" * join(errors, "\n"))
    end
    
    @info "Configuration validation passed"
    return true
end

end # module