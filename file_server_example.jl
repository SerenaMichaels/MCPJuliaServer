#!/usr/bin/env julia

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer

# Cross-platform default directory detection
function get_default_mcp_dir()
    # Check if MCP_FILE_SERVER_BASE is explicitly set
    env_base = get(ENV, "MCP_FILE_SERVER_BASE", nothing)
    if env_base !== nothing
        return env_base
    end
    
    # Detect operating system and set appropriate default
    if Sys.iswindows()
        # Native Windows
        return "D:\\MCP-Agents"
    elseif Sys.islinux() || Sys.isunix()
        # Check if we're in WSL by looking for Windows mount points
        wsl_d_mount = "/mnt/d/MCP-Agents"
        if isdir("/mnt/d/") && isdir(dirname(wsl_d_mount))
            # We're likely in WSL with D: drive mounted
            return wsl_d_mount
        else
            # Regular Linux - use home directory
            return joinpath(homedir(), "MCP-Agents")
        end
    else
        # Fallback for other systems
        return joinpath(homedir(), "MCP-Agents")
    end
end

# Base directory for file operations (security boundary)
const BASE_DIR = let
    default_dir = get_default_mcp_dir()
    
    # Create the directory if it doesn't exist
    try
        if !isdir(default_dir)
            mkpath(default_dir)
            println("📁 Created MCP-Agents directory: $default_dir")
        end
        default_dir
    catch e
        @warn "Could not create default directory $default_dir, falling back to current directory" exception=e
        pwd()
    end
end

function safe_path(path::String)
    # Resolve path and ensure it's within BASE_DIR
    abs_path = abspath(joinpath(BASE_DIR, path))
    base_abs = abspath(BASE_DIR)
    
    if !startswith(abs_path, base_abs)
        throw(ArgumentError("Access denied: Path outside allowed directory"))
    end
    
    return abs_path
end

function list_files_tool(args::Dict{String,Any})
    path = get(args, "path", ".")
    
    try
        safe_dir = safe_path(path)
        
        if !isdir(safe_dir)
            return "Error: Directory does not exist: $path"
        end
        
        items = String[]
        for item in readdir(safe_dir)
            item_path = joinpath(safe_dir, item)
            if isdir(item_path)
                push!(items, "📁 $item/")
            else
                size_kb = round(filesize(item_path) / 1024, digits=1)
                push!(items, "📄 $item ($(size_kb)KB)")
            end
        end
        
        if isempty(items)
            return "Directory is empty: $path"
        end
        
        return "Contents of '$path':\n" * join(items, "\n")
        
    catch e
        return "Error listing directory: $(string(e))"
    end
end

function read_file_tool(args::Dict{String,Any})
    file_path = get(args, "path", "")
    max_size = get(args, "max_size", 10000)  # 10KB default limit
    
    if isempty(file_path)
        return "Error: File path is required"
    end
    
    try
        safe_file = safe_path(file_path)
        
        if !isfile(safe_file)
            return "Error: File does not exist: $file_path"
        end
        
        file_size = filesize(safe_file)
        if file_size > max_size
            return "Error: File too large ($(file_size) bytes). Max size: $(max_size) bytes"
        end
        
        content = read(safe_file, String)
        return "File: $file_path\nSize: $(file_size) bytes\n\n$content"
        
    catch e
        return "Error reading file: $(string(e))"
    end
end

function write_file_tool(args::Dict{String,Any})
    file_path = get(args, "path", "")
    content = get(args, "content", "")
    overwrite = get(args, "overwrite", false)
    
    if isempty(file_path)
        return "Error: File path is required"
    end
    
    try
        safe_file = safe_path(file_path)
        
        if isfile(safe_file) && !overwrite
            return "Error: File exists. Set overwrite=true to replace it"
        end
        
        # Create parent directories if they don't exist
        parent_dir = dirname(safe_file)
        if !isdir(parent_dir)
            mkpath(parent_dir)
        end
        
        write(safe_file, content)
        file_size = filesize(safe_file)
        
        return "Successfully wrote $file_size bytes to: $file_path"
        
    catch e
        return "Error writing file: $(string(e))"
    end
end

function delete_file_tool(args::Dict{String,Any})
    file_path = get(args, "path", "")
    
    if isempty(file_path)
        return "Error: File path is required"
    end
    
    try
        safe_file = safe_path(file_path)
        
        if !ispath(safe_file)
            return "Error: File or directory does not exist: $file_path"
        end
        
        if isdir(safe_file)
            rm(safe_file, recursive=true)
            return "Successfully deleted directory: $file_path"
        else
            rm(safe_file)
            return "Successfully deleted file: $file_path"
        end
        
    catch e
        return "Error deleting: $(string(e))"
    end
end

function create_directory_tool(args::Dict{String,Any})
    dir_path = get(args, "path", "")
    
    if isempty(dir_path)
        return "Error: Directory path is required"
    end
    
    try
        safe_dir = safe_path(dir_path)
        
        if ispath(safe_dir)
            return "Error: Path already exists: $dir_path"
        end
        
        mkpath(safe_dir)
        return "Successfully created directory: $dir_path"
        
    catch e
        return "Error creating directory: $(string(e))"
    end
end

function main()
    server = MCPServer("Julia File Server", "0.1.0", "MCP server providing file system operations for a local directory")
    
    println("📁 File Server Base Directory: $BASE_DIR")
    
    # List files tool
    list_files_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "path" => Dict{String,Any}(
                "type" => "string",
                "description" => "Directory path to list (relative to base directory, default: '.')"
            )
        )
    )
    
    add_tool!(server, MCPTool(
        "list_files",
        "List files and directories in a specified path",
        list_files_schema,
        list_files_tool
    ))
    
    # Read file tool
    read_file_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "path" => Dict{String,Any}(
                "type" => "string",
                "description" => "File path to read"
            ),
            "max_size" => Dict{String,Any}(
                "type" => "integer",
                "description" => "Maximum file size in bytes (default: 10000)"
            )
        ),
        "required" => ["path"]
    )
    
    add_tool!(server, MCPTool(
        "read_file",
        "Read the contents of a text file",
        read_file_schema,
        read_file_tool
    ))
    
    # Write file tool
    write_file_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "path" => Dict{String,Any}(
                "type" => "string",
                "description" => "File path to write to"
            ),
            "content" => Dict{String,Any}(
                "type" => "string",
                "description" => "Content to write to the file"
            ),
            "overwrite" => Dict{String,Any}(
                "type" => "boolean",
                "description" => "Whether to overwrite existing files (default: false)"
            )
        ),
        "required" => ["path", "content"]
    )
    
    add_tool!(server, MCPTool(
        "write_file",
        "Write content to a file",
        write_file_schema,
        write_file_tool
    ))
    
    # Delete file tool
    delete_file_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "path" => Dict{String,Any}(
                "type" => "string",
                "description" => "Path of file or directory to delete"
            )
        ),
        "required" => ["path"]
    )
    
    add_tool!(server, MCPTool(
        "delete_file",
        "Delete a file or directory (recursive for directories)",
        delete_file_schema,
        delete_file_tool
    ))
    
    # Create directory tool
    create_dir_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "path" => Dict{String,Any}(
                "type" => "string",
                "description" => "Directory path to create"
            )
        ),
        "required" => ["path"]
    )
    
    add_tool!(server, MCPTool(
        "create_directory",
        "Create a new directory (creates parent directories as needed)",
        create_dir_schema,
        create_directory_tool
    ))
    
    start_server(server)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end