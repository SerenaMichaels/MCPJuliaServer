#!/usr/bin/env julia
# HTTP-enabled File MCP Server
# Provides both stdio MCP interface and HTTP REST API for cross-platform access

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer

include("src/HttpServer.jl")
using .HttpServer

using JSON3
using HTTP
using Dates

# Load site configuration
include("config/site_config.jl")
using .SiteConfig

# Load configuration with site-specific precedence
SiteConfig.load_config(".")

# Get file server configuration
const FILE_BASE_DIR = SiteConfig.get_file_server_config()

# Validate configuration
SiteConfig.validate_config()

# Cross-platform default directory detection
function get_default_mcp_dir()
    # Use site configuration system
    return SiteConfig.get_file_server_config()
end

# MCP Tool definitions
const TOOLS = [
    Dict(
        "name" => "list_directory",
        "description" => "List contents of a directory with file details",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "path" => Dict(
                    "type" => "string",
                    "description" => "Directory path to list (relative to base directory)"
                )
            ),
            "required" => ["path"]
        )
    ),
    Dict(
        "name" => "read_file",
        "description" => "Read the contents of a text file",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "path" => Dict(
                    "type" => "string", 
                    "description" => "File path to read (relative to base directory)"
                )
            ),
            "required" => ["path"]
        )
    ),
    Dict(
        "name" => "write_file",
        "description" => "Write content to a file",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "path" => Dict(
                    "type" => "string",
                    "description" => "File path to write (relative to base directory)"
                ),
                "content" => Dict(
                    "type" => "string",
                    "description" => "Content to write to the file"
                )
            ),
            "required" => ["path", "content"]
        )
    ),
    Dict(
        "name" => "create_directory",
        "description" => "Create a new directory",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "path" => Dict(
                    "type" => "string",
                    "description" => "Directory path to create (relative to base directory)"
                )
            ),
            "required" => ["path"]
        )
    ),
    Dict(
        "name" => "delete_file",
        "description" => "Delete a file or directory",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "path" => Dict(
                    "type" => "string",
                    "description" => "File or directory path to delete (relative to base directory)"
                )
            ),
            "required" => ["path"]
        )
    )
]

# Security: Validate and sanitize paths
function validate_path(requested_path::String)
    # Get absolute base directory
    base_dir = abspath(FILE_BASE_DIR)
    
    # Resolve the requested path relative to base
    if isabs(requested_path)
        # If absolute path provided, ensure it's within base directory
        full_path = abspath(requested_path)
    else
        # Relative path - join with base directory  
        full_path = abspath(joinpath(base_dir, requested_path))
    end
    
    # Security check: ensure the resolved path is within base directory
    if !startswith(full_path, base_dir)
        throw(ArgumentError("Access denied: Path outside of allowed base directory"))
    end
    
    return full_path
end

# Tool implementations
function list_directory_tool(args::Dict)
    path = get(args, "path", ".")
    
    try
        full_path = validate_path(path)
        
        if !isdir(full_path)
            return "Error: Directory does not exist: $path"
        end
        
        entries = []
        for entry in readdir(full_path; join=false)
            entry_path = joinpath(full_path, entry)
            entry_info = Dict(
                "name" => entry,
                "type" => isdir(entry_path) ? "directory" : "file",
                "size" => isfile(entry_path) ? filesize(entry_path) : 0,
                "modified" => unix2datetime(mtime(entry_path))
            )
            push!(entries, entry_info)
        end
        
        return JSON3.write(Dict(
            "path" => path,
            "entries" => entries,
            "total_entries" => length(entries)
        ))
        
    catch e
        error_msg = "Failed to list directory: $(string(e))"
        @error error_msg
        return error_msg
    end
end

function read_file_tool(args::Dict)
    path = get(args, "path", "")
    
    if isempty(path)
        return "Error: File path is required"
    end
    
    try
        full_path = validate_path(path)
        
        if !isfile(full_path)
            return "Error: File does not exist: $path"
        end
        
        content = read(full_path, String)
        
        return JSON3.write(Dict(
            "path" => path,
            "content" => content,
            "size" => length(content)
        ))
        
    catch e
        error_msg = "Failed to read file: $(string(e))"
        @error error_msg
        return error_msg
    end
end

function write_file_tool(args::Dict)
    path = get(args, "path", "")
    content = get(args, "content", "")
    
    if isempty(path)
        return "Error: File path is required"
    end
    
    try
        full_path = validate_path(path)
        
        # Create parent directories if they don't exist
        parent_dir = dirname(full_path)
        if !isdir(parent_dir)
            mkpath(parent_dir)
        end
        
        write(full_path, content)
        
        return JSON3.write(Dict(
            "path" => path,
            "bytes_written" => length(content),
            "message" => "File written successfully"
        ))
        
    catch e
        error_msg = "Failed to write file: $(string(e))"
        @error error_msg
        return error_msg
    end
end

function create_directory_tool(args::Dict)
    path = get(args, "path", "")
    
    if isempty(path)
        return "Error: Directory path is required"
    end
    
    try
        full_path = validate_path(path)
        
        mkpath(full_path)
        
        return JSON3.write(Dict(
            "path" => path,
            "message" => "Directory created successfully"
        ))
        
    catch e
        error_msg = "Failed to create directory: $(string(e))"
        @error error_msg
        return error_msg
    end
end

function delete_file_tool(args::Dict)
    path = get(args, "path", "")
    
    if isempty(path)
        return "Error: File path is required"
    end
    
    try
        full_path = validate_path(path)
        
        if isdir(full_path)
            rm(full_path; recursive=true)
            return JSON3.write(Dict(
                "path" => path,
                "message" => "Directory deleted successfully"
            ))
        elseif isfile(full_path)
            rm(full_path)
            return JSON3.write(Dict(
                "path" => path,
                "message" => "File deleted successfully"
            ))
        else
            return "Error: File or directory does not exist: $path"
        end
        
    catch e
        error_msg = "Failed to delete: $(string(e))"
        @error error_msg
        return error_msg
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
                        "name" => "file-mcp-server",
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
            
            result_text = if tool_name == "list_directory"
                list_directory_tool(tool_args)
            elseif tool_name == "read_file"
                read_file_tool(tool_args)
            elseif tool_name == "write_file"
                write_file_tool(tool_args)
            elseif tool_name == "create_directory"
                create_directory_tool(tool_args)
            elseif tool_name == "delete_file"
                delete_file_tool(tool_args)
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

# Main execution
function main()
    # Check if HTTP mode is requested
    http_mode = get(ENV, "MCP_HTTP_MODE", "false") == "true"
    http_port = parse(Int, get(ENV, "MCP_HTTP_PORT", "8081"))
    http_host = get(ENV, "MCP_HTTP_HOST", "0.0.0.0")
    
    @info "📁 File Server Base Directory: $FILE_BASE_DIR"
    
    # Ensure base directory exists
    if !isdir(FILE_BASE_DIR)
        @info "Creating base directory: $FILE_BASE_DIR"
        mkpath(FILE_BASE_DIR)
    end
    
    if http_mode
        @info "🌐 Starting File HTTP server mode..."
        
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
        @info "🔄 File Server running... Press Ctrl+C to stop"
        try
            while true
                sleep(1)
            end
        catch InterruptException
            @info "👋 Shutting down file server..."
            stop_http_server(config)
        end
        
    else
        @info "📡 Starting stdio File MCP server mode..."
        
        # Standard MCP stdio server
        server = MCPServer(
            name="file-mcp-server",
            version="1.0.0"
        )
        
        # Add tools
        for tool in TOOLS
            tool_func = if tool["name"] == "list_directory"
                list_directory_tool
            elseif tool["name"] == "read_file"
                read_file_tool
            elseif tool["name"] == "write_file"
                write_file_tool
            elseif tool["name"] == "create_directory"
                create_directory_tool
            elseif tool["name"] == "delete_file"
                delete_file_tool
            end
            
            add_tool(server, tool["name"], tool["description"], tool_func, tool["inputSchema"])
        end
        
        @info "🚀 File MCP Server ready!"
        run_server(server)
    end
end

# Run the server
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end