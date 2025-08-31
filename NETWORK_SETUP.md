# Network Access Setup for Multiple Machines

This guide explains how to access Julia MCP servers from other machines on your local network.

## Current Server Status
- **Server Machine**: WSL on Windows (IP: 172.27.85.131)  
- **Servers Running**: Ports 8080-8083 (listening on all interfaces)
- **Network**: Local area network (Wi-Fi/Ethernet)

## Setup for Second Windows Laptop

### Step 1: Find Your Server Machine's Network IP

On your **main Windows machine** (the one running WSL), open Command Prompt and run:
```cmd
ipconfig
```

Look for either:
- **Wireless LAN adapter Wi-Fi**: IPv4 Address (e.g., 192.168.1.100)
- **Ethernet adapter**: IPv4 Address (e.g., 192.168.1.100)

### Step 2: Test Network Connectivity

From your **second laptop**, open Command Prompt and test:
```cmd
# Replace 192.168.1.100 with your server machine's actual IP
ping 192.168.1.100
curl http://192.168.1.100:8080/mcp/health
```

If the ping works but curl fails, Windows Firewall is likely blocking the ports.

### Step 3: Configure Windows Firewall (if needed)

On your **main Windows machine**, open PowerShell as Administrator and run:
```powershell
# Allow Julia MCP server ports through Windows Firewall
New-NetFirewallRule -DisplayName "Julia MCP Servers" -Direction Inbound -Port 8080,8081,8082,8083 -Protocol TCP -Action Allow
```

### Step 4: Install Claude Desktop on Second Laptop

1. Download and install Claude Desktop
2. Install Node.js on the second laptop
3. Copy the MCP configuration files

### Step 5: Configure Claude Desktop on Second Laptop

**Option A: Copy configuration files from main machine**
```cmd
# From your main machine, copy these files to the second laptop:
# C:\Users\seren\mcp_node_wrapper.js
# %APPDATA%\Claude\claude_desktop_config.json
```

**Option B: Create new configuration**

1. **Create `mcp_node_wrapper.js`** in `C:\Users\[USERNAME]\` with the server machine's network IP:
   - Change `http://172.27.85.131:8080` to `http://192.168.1.100:8080` (use actual IP)
   - Copy the wrapper from: https://github.com/SerenaMichaels/MCPJuliaServer/blob/main/windows_config/mcp_node_wrapper.js

2. **Create Claude config** at `%APPDATA%\Claude\claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "mcp-postgres-http": {
      "command": "node",
      "args": ["C:\\Users\\[USERNAME]\\mcp_node_wrapper.js", "http://192.168.1.100:8080"],
      "env": {},
      "description": "PostgreSQL MCP Server via HTTP"
    },
    "mcp-file-http": {
      "command": "node", 
      "args": ["C:\\Users\\[USERNAME]\\mcp_node_wrapper.js", "http://192.168.1.100:8081"],
      "env": {},
      "description": "File Operations MCP Server via HTTP"
    },
    "mcp-db-admin-http": {
      "command": "node",
      "args": ["C:\\Users\\[USERNAME]\\mcp_node_wrapper.js", "http://192.168.1.100:8082"],
      "env": {},
      "description": "Database Administration MCP Server via HTTP"
    },
    "mcp-orchestrator-http": {
      "command": "node",
      "args": ["C:\\Users\\[USERNAME]\\mcp_node_wrapper.js", "http://192.168.1.100:8083"],
      "env": {},
      "description": "MCP Orchestrator via HTTP"
    }
  }
}
```

### Step 6: Test the Setup

1. Restart Claude Desktop on the second laptop
2. Test with: "What MCP servers do you have available?"
3. Test database: "Execute this query: SELECT version()"

## Alternative: Port Forwarding Setup

If direct network access doesn't work, you can use SSH port forwarding:

```cmd
# From second laptop, forward ports through SSH
ssh -L 8080:localhost:8080 -L 8081:localhost:8081 -L 8082:localhost:8082 -L 8083:localhost:8083 user@192.168.1.100
```

Then use `localhost` in the configuration instead of the network IP.

## Troubleshooting

1. **Firewall Issues**: Check Windows Defender Firewall on both machines
2. **Network Discovery**: Enable network discovery in Windows network settings  
3. **Port Conflicts**: Ensure ports 8080-8083 aren't used by other services
4. **Router Configuration**: Some routers block inter-device communication (AP isolation)

## Security Considerations

- **Local Network Only**: These servers should only be accessible on your local network
- **No Authentication**: The HTTP servers don't have built-in authentication
- **Database Access**: The PostgreSQL server uses the configured database credentials
- **File Access**: File operations are sandboxed to configured directories

For production environments, consider adding:
- HTTPS/TLS encryption
- Authentication tokens
- Network access control lists
- VPN tunneling for remote access