# Julia MCP Server

A Model Context Protocol (MCP) server implementation in Julia that provides tools for AI agents to interact with.

## Overview

This project implements an MCP server following the JSON-RPC 2.0 specification over stdio transport. It provides a framework for creating custom tools that can be called by AI agents like Claude Code.

## Features

- JSON-RPC 2.0 communication over stdin/stdout
- MCP protocol implementation
- Extensible tool system
- Cross-platform support (Windows, Linux, WSL)
- Example tools included:
  - Calculator (basic math operations)
  - Random number generator  
  - System information
  - File server operations (list, read, write, delete files)
- Intelligent directory detection for file operations
- Secure sandboxed file access

## Project Structure

```
julia_mcp_server/
├── Project.toml           # Julia project configuration
├── src/
│   ├── JuliaMCPServer.jl # Main module
│   ├── jsonrpc.jl        # JSON-RPC implementation
│   ├── mcp.jl            # MCP protocol handlers
│   └── server.jl         # Server runtime
├── example.jl            # Example server with sample tools
├── file_server_example.jl # File server with filesystem tools
├── test_mcp.jl           # Test utilities
└── README.md
```

## Usage

### Running the Example Servers

**Basic Example Server (calculator, random, system info):**
```bash
cd julia_mcp_server
julia example.jl
```

**File Server Example (file operations):**
```bash
cd julia_mcp_server
julia file_server_example.jl
```

The file server automatically detects the operating system and uses appropriate defaults:
- **Windows**: `D:\MCP-Agents`  
- **WSL**: `/mnt/d/MCP-Agents` (if D: drive is mounted)
- **Linux**: `~/MCP-Agents`

You can override the default with an environment variable:
```bash
MCP_FILE_SERVER_BASE=/custom/path julia file_server_example.jl
```

The server will start and listen for JSON-RPC messages on stdin, responding on stdout.

### Testing the Server

You can test the server by sending JSON-RPC messages manually:

1. Initialize the server:
```json
{"jsonrpc": "2.0", "method": "initialize", "params": {}, "id": 1}
```

2. List available tools:
```json
{"jsonrpc": "2.0", "method": "tools/list", "params": {}, "id": 2}
```

3. Call a tool:
```json
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "calculator", "arguments": {"operation": "add", "a": 5, "b": 3}}, "id": 3}
```

**File Server Examples:**
```json
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "list_files", "arguments": {"path": "."}}, "id": 4}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "write_file", "arguments": {"path": "hello.txt", "content": "Hello World!"}}, "id": 5}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "hello.txt"}}, "id": 6}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "create_directory", "arguments": {"path": "my_folder"}}, "id": 7}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "delete_file", "arguments": {"path": "hello.txt"}}, "id": 8}
```

## Creating Custom Tools

To create a custom tool, define a function and add it to the server:

```julia
function my_custom_tool(args::Dict{String,Any})
    # Your tool logic here
    return "Tool result"
end

# Define the JSON schema for the tool's input
schema = Dict{String,Any}(
    "type" => "object",
    "properties" => Dict{String,Any}(
        "param1" => Dict{String,Any}(
            "type" => "string",
            "description" => "Description of parameter"
        )
    ),
    "required" => ["param1"]
)

# Add to server
add_tool!(server, MCPTool(
    "my_tool",
    "Description of what the tool does",
    schema,
    my_custom_tool
))
```

## MCP Protocol Support

This implementation supports the following MCP methods:

- `initialize` - Initialize the server connection
- `tools/list` - List available tools
- `tools/call` - Execute a specific tool

## Dependencies

- Julia 1.6+
- JSON3.jl - for JSON parsing and generation
- UUIDs.jl - for unique identifier generation

## License

This is a demonstration implementation of an MCP server in Julia.