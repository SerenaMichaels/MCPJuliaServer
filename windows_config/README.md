# Windows Claude Desktop Access to WSL MCP Servers

This directory contains configuration and scripts to enable Claude Desktop running on Windows to access MCP servers running in WSL (Windows Subsystem for Linux).

## Quick Setup

### Automated Setup (Recommended)
```bash
# In WSL, run the setup script
./windows_config/setup_windows_access.sh start
```

This will:
1. Detect your WSL IP address
2. Create HTTP-enabled versions of all MCP servers
3. Start servers on different ports (8080-8083)
4. Generate Windows Claude Desktop configuration
5. Provide setup instructions

### Manual Setup
1. Start individual HTTP servers:
   ```bash
   # PostgreSQL server on port 8080
   MCP_HTTP_MODE=true MCP_HTTP_PORT=8080 julia --project=. http_postgres_server.jl
   
   # File server on port 8081
   MCP_HTTP_MODE=true MCP_HTTP_PORT=8081 julia --project=. http_file_server.jl
   ```

2. Copy the generated Windows configuration to Claude Desktop

## Architecture

### WSL Side (Linux)
- **HTTP MCP Servers**: Modified servers that provide both stdio and HTTP APIs
- **Port Allocation**: 
  - PostgreSQL: 8080
  - File Operations: 8081  
  - Database Admin: 8082
  - Orchestrator: 8083
- **Network Binding**: Servers bind to `0.0.0.0` to accept Windows connections

### Windows Side
- **Claude Desktop**: Uses PowerShell HTTP commands to communicate with WSL servers
- **Configuration**: Custom `claude_desktop_config.json` with HTTP-based MCP definitions
- **Connectivity**: Connects to WSL IP address over HTTP

## Network Configuration

### WSL IP Detection
The setup script automatically detects the WSL IP address using:
1. `hostname -I` (primary method)
2. `ip route get 8.8.8.8` (fallback)
3. `ifconfig eth0` (legacy fallback)

### Port Configuration
Each MCP server runs on a dedicated port to avoid conflicts:

| Server | Port | Endpoint |
|--------|------|----------|
| PostgreSQL | 8080 | `/mcp/tools/call` |
| File Operations | 8081 | `/mcp/tools/call` |
| Database Admin | 8082 | `/mcp/tools/call` |
| Orchestrator | 8083 | `/mcp/orchestrator` |

### HTTP API Endpoints
All servers expose these REST endpoints:
- `GET /mcp/health` - Health check
- `GET /mcp/info` - Server information
- `POST /mcp/initialize` - MCP initialization
- `POST /mcp/tools/list` - List available tools
- `POST /mcp/tools/call` - Execute tool

## Windows Claude Configuration

The generated configuration uses PowerShell commands to make HTTP requests:

```json
{
  "mcpServers": {
    "mcp-postgres-http": {
      "command": "powershell",
      "args": [
        "-Command",
        "$response = Invoke-RestMethod -Uri 'http://WSL_IP:8080/mcp/tools/call' -Method POST -ContentType 'application/json' -Body (ConvertTo-Json @{name=$args[0]; arguments=(ConvertFrom-Json $args[1])}); Write-Output ($response.result.content[0].text)"
      ],
      "description": "PostgreSQL MCP Server via HTTP from WSL"
    }
  }
}
```

## Security Considerations

### Network Security
- **WSL Network**: Traffic stays within the local machine (Windows ↔ WSL)
- **No External Access**: Servers bind to WSL's internal network interface
- **Firewall**: Windows Firewall may need configuration for WSL communication

### Authentication (Optional)
Enable authentication by setting an environment variable:
```bash
export MCP_AUTH_TOKEN=your_secure_token_here
./windows_config/setup_windows_access.sh start
```

### CORS
Cross-Origin Resource Sharing (CORS) is enabled by default for local development.

## Management Commands

### Server Management
```bash
# Start all HTTP servers
./windows_config/setup_windows_access.sh start

# Stop all HTTP servers
./windows_config/setup_windows_access.sh stop

# Check server status
./windows_config/setup_windows_access.sh status

# Test server connectivity
./windows_config/setup_windows_access.sh test

# Restart all servers
./windows_config/setup_windows_access.sh restart
```

### Individual Server Control
```bash
# Start single server with custom configuration
MCP_HTTP_MODE=true MCP_HTTP_PORT=8080 MCP_HTTP_HOST=0.0.0.0 julia --project=. http_postgres_server.jl

# Check if server is responding
curl http://WSL_IP:8080/mcp/health
```

## Troubleshooting

### Common Issues

#### "Connection refused" from Windows
**Cause**: Windows cannot reach WSL IP or server not started
**Solutions**:
1. Check WSL IP: `hostname -I` in WSL
2. Verify server is running: `./windows_config/setup_windows_access.sh status`
3. Test from WSL: `curl http://localhost:8080/mcp/health`
4. Check Windows Firewall settings

#### "Server not responding" 
**Cause**: Server crashed or failed to start
**Solutions**:
1. Check server logs: `tail -f logs/*_http.log`
2. Verify Julia packages: `julia --project=. -e "using Pkg; Pkg.status()"`
3. Test database connection: Check PostgreSQL is running
4. Restart servers: `./windows_config/setup_windows_access.sh restart`

#### "Permission denied" errors
**Cause**: Port binding or file access issues  
**Solutions**:
1. Use ports > 1024 (default: 8080-8083)
2. Check file permissions: `ls -la http_*_server.jl`
3. Run with proper user permissions

#### "Julia not found" in Windows
**Cause**: PowerShell configuration issue
**Solutions**:
1. Use the HTTP endpoints directly via curl/PowerShell
2. The servers run in WSL, not Windows - Julia only needs to be in WSL

### Debug Mode
Enable detailed logging:
```bash
export MCP_DEBUG_COMMUNICATION=true
./windows_config/setup_windows_access.sh start
```

### Log Analysis
Check individual server logs:
```bash
# PostgreSQL server logs
tail -f logs/postgres_http.log

# File server logs  
tail -f logs/file_http.log

# All HTTP server logs
tail -f logs/*_http.log
```

### Network Testing
Test connectivity from different locations:
```bash
# From WSL (should work)
curl http://localhost:8080/mcp/health

# From WSL using external IP (should work)
curl http://$(hostname -I | awk '{print $1}'):8080/mcp/health

# From Windows PowerShell (should work if properly configured)
Invoke-RestMethod -Uri http://WSL_IP:8080/mcp/health
```

## Performance Considerations

### Connection Pooling
Each HTTP server maintains its own connection pool to the underlying resources (database, file system).

### Concurrent Requests
HTTP servers can handle multiple concurrent requests, unlike stdio MCP which is single-threaded.

### Resource Usage
- **Memory**: Each HTTP server uses additional memory for HTTP handling
- **CPU**: Minimal overhead for HTTP request processing
- **Network**: Local network traffic only (Windows ↔ WSL)

## Advanced Configuration

### Custom Ports
Modify port assignments by editing the setup script:
```bash
declare -A PORTS=(
    ["postgres"]=9080
    ["file"]=9081
    ["db_admin"]=9082
    ["orchestrator"]=9083
)
```

### SSL/TLS (Optional)
For enhanced security, configure HTTPS:
```bash
export MCP_SSL_ENABLED=true
export MCP_SSL_CERT_PATH=/path/to/cert.pem
export MCP_SSL_KEY_PATH=/path/to/key.pem
```

### Load Balancing
For high-availability setups, run multiple instances:
```bash
# Start multiple PostgreSQL servers
MCP_HTTP_PORT=8080 julia --project=. http_postgres_server.jl &
MCP_HTTP_PORT=8090 julia --project=. http_postgres_server.jl &
```

This configuration provides seamless access from Windows Claude Desktop to WSL-hosted MCP servers while maintaining security and performance.