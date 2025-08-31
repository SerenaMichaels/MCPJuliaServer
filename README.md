# Julia MCP Server

A Model Context Protocol (MCP) server implementation in Julia that provides tools for AI agents to interact with.

**✅ VERIFIED WORKING:** Successfully tested with Claude Desktop on Windows via WSL with full Node.js MCP wrapper integration.

## Overview

This project implements an MCP server following the JSON-RPC 2.0 specification over stdio transport. It provides a framework for creating custom tools that can be called by AI agents like Claude Code. Features complete Windows Claude Desktop integration via HTTP bridge and Node.js MCP wrapper.

## Features

### Core MCP Functionality
- JSON-RPC 2.0 communication over stdin/stdout
- MCP protocol implementation
- Extensible tool system
- Cross-platform support (Windows, Linux, macOS, WSL)

### MCP Server Suite
- **PostgreSQL Server**: Advanced database operations, queries, transactions
- **File Server**: Secure file operations with cross-platform path handling
- **Database Admin Server**: Database/user management, schema operations, import/export
- **HTTP Bridge**: REST API endpoints for Windows Claude Desktop access

### Available Tools
- **Database Operations**: SQL queries, table management, connection pooling
- **File Operations**: Read, write, create directories with security sandboxing  
- **Database Administration**: Create/drop databases, user management, privileges
- **Data Import/Export**: JSON and CSV support with schema validation
- **JSON Schema to SQL**: Automatic table creation from JSON schemas
- **Cross-Database Migration**: Transfer data between database instances

### Windows Integration & Documentation
- **HTTP Endpoints**: REST API access for Windows Claude Desktop
- **WSL Bridge**: Seamless Windows ↔ WSL communication
- **Auto Configuration**: Automatic WSL IP detection and Claude config generation
- **PowerShell Integration**: Native Windows HTTP commands
- **Dual Mode Servers**: Both stdio MCP and HTTP REST API support
- **Self-Documenting**: Each server provides comprehensive documentation at `/mcp/docs`

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
├── postgres_example.jl   # PostgreSQL database server
├── db_admin_example.jl   # Database administration server
├── test_mcp.jl           # Test utilities
└── README.md
```

## Quick Start

### For Claude Desktop Users

#### WSL/Linux Users
1. **One-line installation and setup:**
   ```bash
   curl -fsSL https://raw.githubusercontent.com/SerenaMichaels/MCPJuliaServer/main/scripts/install.sh | bash
   ```

2. **Configure Claude Desktop:**
   ```bash
   ./claude_config/setup_claude_config.sh
   ```

3. **Start servers automatically (optional):**
   ```bash
   sudo ./scripts/setup-services.sh
   ```

#### Windows Users (Claude Desktop on Windows → WSL Servers)

If you're running Claude Desktop on Windows but want to use MCP servers in WSL:

1. **In WSL - Install and setup servers:**
   ```bash
   # Install the MCP servers in WSL
   curl -fsSL https://raw.githubusercontent.com/SerenaMichaels/MCPJuliaServer/main/scripts/install.sh | bash
   
   # Setup HTTP endpoints for Windows access
   ./windows_config/setup_windows_access.sh start
   ```
   
   This will:
   - Start HTTP servers on ports 8080-8083
   - Auto-detect your WSL IP address 
   - Generate Windows Claude Desktop configuration
   - Display setup instructions

2. **In Windows - Configure Claude Desktop:**
   - Copy the generated configuration file to Windows
   - Location: `%APPDATA%\Claude\claude_desktop_config.json`
   - Restart Claude Desktop

3. **Available Windows MCP Servers:**
   - **📊 mcp-postgres-http**: SQL queries and database operations
   - **📁 mcp-file-http**: File system operations in WSL
   - **🔧 mcp-db-admin-http**: Database administration
   - **🎯 mcp-orchestrator-http**: Multi-server workflows

### Claude Desktop Configuration Details

Each MCP server provides complete Claude Desktop configuration in its documentation. Access the docs at:
- **PostgreSQL:** http://YOUR_WSL_IP:8080/ (auto-redirects to docs)
- **File Operations:** http://YOUR_WSL_IP:8081/ (auto-redirects to docs)
- **Database Admin:** http://YOUR_WSL_IP:8082/ (auto-redirects to docs)
- **Orchestrator:** http://YOUR_WSL_IP:8083/ (auto-redirects to docs)

**Direct documentation URLs:**
- **PostgreSQL:** http://YOUR_WSL_IP:8080/mcp/docs
- **File Operations:** http://YOUR_WSL_IP:8081/mcp/docs
- **Database Admin:** http://YOUR_WSL_IP:8082/mcp/docs
- **Orchestrator:** http://YOUR_WSL_IP:8083/mcp/docs

**Sample Claude Desktop Configuration:**
```json
{
  "mcpServers": {
    "mcp-postgres-http": {
      "command": "node",
      "args": ["-e", "const http = require('http'); const data = JSON.stringify({name: process.argv[2], arguments: JSON.parse(process.argv[3] || '{}')}); const req = http.request('http://172.27.85.131:8080/mcp/tools/call', {method: 'POST', headers: {'Content-Type': 'application/json', 'Content-Length': data.length}}, res => {let body = ''; res.on('data', d => body += d); res.on('end', () => {try {const result = JSON.parse(body); console.log(JSON.stringify(result.result || result));} catch(e) {console.log(body);}});}); req.write(data); req.end();"],
      "env": {},
      "description": "PostgreSQL MCP Server via HTTP - Execute SQL queries and database operations"
    },
    "mcp-file-http": {
      "command": "node",
      "args": ["-e", "const http = require('http'); const data = JSON.stringify({name: process.argv[2], arguments: JSON.parse(process.argv[3] || '{}')}); const req = http.request('http://172.27.85.131:8081/mcp/tools/call', {method: 'POST', headers: {'Content-Type': 'application/json', 'Content-Length': data.length}}, res => {let body = ''; res.on('data', d => body += d); res.on('end', () => {try {const result = JSON.parse(body); console.log(JSON.stringify(result.result || result));} catch(e) {console.log(body);}});}); req.write(data); req.end();"],
      "env": {},
      "description": "File Operations MCP Server via HTTP - Read, write, and manage files"
    },
    "mcp-db-admin-http": {
      "command": "node",
      "args": ["-e", "const http = require('http'); const data = JSON.stringify({name: process.argv[2], arguments: JSON.parse(process.argv[3] || '{}')}); const req = http.request('http://172.27.85.131:8082/mcp/tools/call', {method: 'POST', headers: {'Content-Type': 'application/json', 'Content-Length': data.length}}, res => {let body = ''; res.on('data', d => body += d); res.on('end', () => {try {const result = JSON.parse(body); console.log(JSON.stringify(result.result || result));} catch(e) {console.log(body);}});}); req.write(data); req.end();"],
      "env": {},
      "description": "Database Administration MCP Server via HTTP - Create databases, manage users"
    },
    "mcp-orchestrator-http": {
      "command": "node", 
      "args": ["-e", "const http = require('http'); const data = JSON.stringify({name: process.argv[2], arguments: JSON.parse(process.argv[3] || '{}')}); const req = http.request('http://172.27.85.131:8083/mcp/tools/call', {method: 'POST', headers: {'Content-Type': 'application/json', 'Content-Length': data.length}}, res => {let body = ''; res.on('data', d => body += d); res.on('end', () => {try {const result = JSON.parse(body); console.log(JSON.stringify(result.result || result));} catch(e) {console.log(body);}});}); req.write(data); req.end();"],
      "env": {},
      "description": "MCP Orchestrator via HTTP - Execute multi-server workflows and complex operations"
    }
  }
}
```

**Important Notes:**
- Replace `172.27.85.131` with your actual WSL IP address (get it with `hostname -I` in WSL)  
- The configuration is automatically generated with the correct IP when you run `setup_windows_access.sh`
- **Node.js is required** on Windows for the MCP wrapper to work properly
- After installing Node.js and copying the configuration, restart Claude Desktop completely

**Verified Working Setup:**
✅ **4 MCP Servers Available in Claude Desktop:**
- **PostgreSQL MCP Server** - Execute SQL queries, list tables, describe schemas
- **File Operations MCP Server** - Read, write, manage files and directories (default mount: `D:\MCP-Agents`)
- **Database Administration MCP Server** - Create databases, import/export data
- **MCP Orchestrator Server** - Multi-server workflows and automation

**Troubleshooting:**
- If servers show "failed" in Claude Desktop, check that Node.js is installed on Windows
- Restart Claude Desktop after any configuration changes
- Check server logs at `%APPDATA%\Claude\logs\mcp-server-*.log` for debugging

**Windows Server Management:**
```bash
# In WSL - manage HTTP servers
./windows_config/setup_windows_access.sh status   # Check status
./windows_config/setup_windows_access.sh stop     # Stop servers
./windows_config/setup_windows_access.sh restart  # Restart servers
```

#### Native Windows Users
For native Windows installation (no WSL), see [Windows Installation Guide](INSTALL.md#windows).

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

**PostgreSQL Database Server (database operations):**
```bash
cd julia_mcp_server
julia postgres_example.jl
```

**Database Administration Server (database management):**
```bash
cd julia_mcp_server
julia db_admin_example.jl
```

The file server automatically detects the operating system and uses appropriate defaults:
- **Windows**: `D:\MCP-Agents`  
- **WSL**: `/mnt/d/MCP-Agents` (if D: drive is mounted)
- **Linux**: `~/MCP-Agents`

You can override the default with an environment variable:
```bash
MCP_FILE_SERVER_BASE=/custom/path julia file_server_example.jl
```

The PostgreSQL server can be configured with environment variables:
```bash
POSTGRES_HOST=localhost \
POSTGRES_PORT=5432 \
POSTGRES_USER=postgres \
POSTGRES_PASSWORD=mypassword \
POSTGRES_DB=mydatabase \
julia postgres_example.jl
```

Both PostgreSQL servers use the same configuration format. The database admin server includes all the features of the basic PostgreSQL server plus advanced administration tools.

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

**PostgreSQL Database Examples:**
```json
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "list_databases", "arguments": {}}, "id": 9}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "list_tables", "arguments": {"schema": "public"}}, "id": 10}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "execute_query", "arguments": {"query": "SELECT version()"}}, "id": 11}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "describe_table", "arguments": {"table": "users", "schema": "public"}}, "id": 12}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "execute_transaction", "arguments": {"queries": ["CREATE TABLE test (id INT)", "INSERT INTO test VALUES (1)", "DROP TABLE test"]}}, "id": 13}
```

**Database Administration Examples:**
```json
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "create_database", "arguments": {"name": "my_new_db", "owner": "postgres"}}, "id": 14}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "create_user", "arguments": {"username": "app_user", "password": "secret123", "createdb": true}}, "id": 15}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "grant_privileges", "arguments": {"username": "app_user", "database": "my_new_db", "privileges": ["CONNECT", "CREATE"]}}, "id": 16}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "create_table_from_json", "arguments": {"table": "users", "schema": "{\"properties\":{\"id\":{\"type\":\"integer\"},\"name\":{\"type\":\"string\"}},\"primary_key\":[\"id\"]}"}}, "id": 17}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "import_data", "arguments": {"table": "users", "data": "[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]", "format": "json"}}, "id": 18}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "export_data", "arguments": {"table": "users", "format": "csv", "limit": 100}}, "id": 19}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "export_schema", "arguments": {"database": "my_new_db", "format": "sql"}}, "id": 20}
{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "drop_database", "arguments": {"name": "my_new_db", "force": true}}, "id": 21}
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
- LibPQ.jl - for PostgreSQL database connectivity (postgres_example.jl only)
- HTTP.jl - for HTTP server functionality (Windows bridge)

## Windows-Specific Troubleshooting

### Common Windows + WSL Issues

**"Connection refused" from Windows Claude**
```bash
# In WSL - check server status
./windows_config/setup_windows_access.sh status

# Test connectivity from WSL
curl http://localhost:8080/mcp/health

# Check WSL IP address  
hostname -I
```

**"Server not responding"**
```bash
# Check server logs
tail -f logs/*_http.log

# Restart servers
./windows_config/setup_windows_access.sh restart

# Verify Julia packages
julia --project=. -e "using Pkg; Pkg.status()"
```

**"PowerShell execution errors"**
- Ensure PowerShell execution policy allows scripts
- Check Windows Firewall settings for WSL communication
- Verify the WSL IP address in your Claude config matches current IP

**Network connectivity test:**
```powershell
# From Windows PowerShell - test WSL server
Invoke-RestMethod -Uri http://YOUR_WSL_IP:8080/mcp/health
```

### Windows Firewall Configuration

If Windows Claude cannot reach WSL servers:

1. **Windows Settings** → **Privacy & Security** → **Windows Security** → **Firewall & network protection**
2. **Allow an app through firewall**  
3. Add PowerShell and allow private network access
4. Or temporarily disable firewall for testing

### WSL Network Issues

**WSL IP changes after reboot:**
```bash
# Get current WSL IP
hostname -I | awk '{print $1}'

# Update Windows Claude config with new IP
./windows_config/setup_windows_access.sh start
```

**Port conflicts:**
```bash
# Check if ports are in use
netstat -tulpn | grep :8080

# Use different ports if needed
MCP_HTTP_PORT=9080 ./windows_config/setup_windows_access.sh start
```

### Detailed Logs

Enable debug logging for troubleshooting:
```bash
export MCP_DEBUG_COMMUNICATION=true
export MCP_HTTP_DEBUG=true
./windows_config/setup_windows_access.sh start
```

## Server Documentation & API Reference

Each MCP server provides comprehensive self-documenting capabilities:

### 📖 Live Documentation Endpoints
**Easy Access URLs (with auto-redirect):**
- **PostgreSQL Server:** http://YOUR_WSL_IP:8080/
- **File Operations Server:** http://YOUR_WSL_IP:8081/
- **Database Admin Server:** http://YOUR_WSL_IP:8082/
- **Orchestrator Server:** http://YOUR_WSL_IP:8083/

**Direct Documentation URLs:**
- **PostgreSQL Server:** http://YOUR_WSL_IP:8080/mcp/docs
- **File Operations Server:** http://YOUR_WSL_IP:8081/mcp/docs
- **Database Admin Server:** http://YOUR_WSL_IP:8082/mcp/docs
- **Orchestrator Server:** http://YOUR_WSL_IP:8083/mcp/docs

### 🌐 API Endpoints (All Servers)
- **GET /** - Auto-redirect to documentation (HTTP 302)
- **GET /mcp/health** - Server health check
- **GET /mcp/info** - Server information and capabilities
- **GET /mcp/docs** - Complete interactive documentation
- **POST /mcp/tools/list** - List all available tools with schemas
- **POST /mcp/tools/call** - Execute a specific tool
- **POST /mcp/orchestrator** - Direct workflow execution (orchestrator only)

### 📋 Documentation Features
- **Auto-Generated**: Documentation is generated from actual server capabilities
- **Tool Schemas**: Complete JSON schemas for all tools with examples
- **Claude Desktop Integration**: Copy-paste ready PowerShell configurations
- **WSL IP Detection**: Automatically detects and displays current WSL IP
- **Server-Specific Guides**: Tailored documentation for each server type
- **Troubleshooting**: Common issues and solutions
- **Professional UI**: Responsive HTML interface with syntax highlighting
- **User-Friendly URLs**: Root URLs automatically redirect to documentation
- **Better Error Messages**: Clear guidance when accessing invalid endpoints

### 🤖 For Claude Desktop Users
Claude can query the documentation endpoints to:
- Discover server capabilities dynamically
- Get complete tool schemas for better argument validation  
- Access troubleshooting guides
- Generate better plans based on available tools

**Example: Claude querying server documentation:**
```
Claude can visit http://172.27.85.131:8080/mcp/docs to see all PostgreSQL server capabilities,
tool schemas, and usage examples, enabling more efficient query planning.
```

## Additional Documentation

- **Installation Guide**: [INSTALL.md](INSTALL.md)
- **Site Configuration**: [SITE_CONFIG.md](SITE_CONFIG.md)
- **Windows Setup**: [windows_config/README.md](windows_config/README.md)
- **Claude Configuration**: [claude_config/README.md](claude_config/README.md)

## License

This is a demonstration implementation of an MCP server in Julia.