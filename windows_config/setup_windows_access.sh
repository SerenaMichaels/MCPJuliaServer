#!/bin/bash
# Setup Windows Claude Access to WSL MCP Servers
# This script configures HTTP endpoints for Windows Claude to access MCP servers in WSL

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(dirname "$SCRIPT_DIR")"
WSL_IP=""
BASE_PORT=8080

# Server configurations
declare -A SERVERS=(
    ["postgres"]="$SERVER_DIR/http_postgres_server.jl"
    ["file"]="$SERVER_DIR/http_file_server.jl" 
    ["db_admin"]="$SERVER_DIR/http_db_admin_server.jl"
    ["orchestrator"]="$SERVER_DIR/http_orchestrator_server.jl"
)

declare -A PORTS=(
    ["postgres"]=8080
    ["file"]=8081
    ["db_admin"]=8082
    ["orchestrator"]=8083
)

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Get WSL IP address for Windows access
get_wsl_ip() {
    log "Determining WSL IP address..."
    
    # Try different methods to get WSL IP
    local ip_methods=(
        "hostname -I | awk '{print \$1}'"
        "ip route get 8.8.8.8 | grep -oP 'src \\K[\\S]+'"
        "ifconfig eth0 | grep 'inet ' | awk '{print \$2}' | cut -d: -f2"
    )
    
    for method in "${ip_methods[@]}"; do
        local ip=$(eval "$method" 2>/dev/null | head -n1)
        if [[ -n "$ip" && "$ip" != "127.0.0.1" ]]; then
            WSL_IP="$ip"
            log "✅ WSL IP detected: $WSL_IP"
            return 0
        fi
    done
    
    # Fallback to localhost
    WSL_IP="127.0.0.1"
    warn "Could not determine WSL IP, using localhost: $WSL_IP"
}

# Check if required server files exist
check_server_files() {
    log "Checking server files..."
    
    local missing_files=()
    
    for server_name in "${!SERVERS[@]}"; do
        local server_file="${SERVERS[$server_name]}"
        if [[ ! -f "$server_file" ]]; then
            missing_files+=("$server_file")
        else
            log "✅ Found: $server_name server"
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        error "Missing server files: ${missing_files[*]}"
    fi
}

# Create HTTP server files if they don't exist
create_http_servers() {
    log "Creating HTTP server wrappers..."
    
    # Create HTTP file server
    if [[ ! -f "${SERVERS[file]}" ]]; then
        log "Creating HTTP file server..."
        cat > "${SERVERS[file]}" <<'EOF'
#!/usr/bin/env julia
# HTTP-enabled File MCP Server

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer

include("src/HttpServer.jl")
using .HttpServer

# Set HTTP mode
ENV["MCP_HTTP_MODE"] = "true"
ENV["MCP_HTTP_PORT"] = "8081"

# Include the original file server with HTTP support
include("file_server_example.jl")
EOF
        chmod +x "${SERVERS[file]}"
    fi
    
    # Create HTTP DB Admin server  
    if [[ ! -f "${SERVERS[db_admin]}" ]]; then
        log "Creating HTTP DB Admin server..."
        cat > "${SERVERS[db_admin]}" <<'EOF'
#!/usr/bin/env julia
# HTTP-enabled Database Administration MCP Server

using Pkg
Pkg.activate(".")

include("src/JuliaMCPServer.jl")
using .JuliaMCPServer

include("src/HttpServer.jl")
using .HttpServer

# Set HTTP mode
ENV["MCP_HTTP_MODE"] = "true"  
ENV["MCP_HTTP_PORT"] = "8082"

# Include the original DB admin server with HTTP support
include("db_admin_example.jl")
EOF
        chmod +x "${SERVERS[db_admin]}"
    fi
    
    # Create HTTP Orchestrator server
    if [[ ! -f "${SERVERS[orchestrator]}" ]]; then
        log "Creating HTTP Orchestrator server..."
        cat > "${SERVERS[orchestrator]}" <<'EOF'
#!/usr/bin/env julia
# HTTP-enabled MCP Orchestrator Server

using Pkg
Pkg.activate(".")

include("../MCPJuliaClient/src/MCPClient.jl")
using .MCPClient

include("src/HttpServer.jl") 
using .HttpServer

# Set HTTP mode
ENV["MCP_HTTP_MODE"] = "true"
ENV["MCP_HTTP_PORT"] = "8083"

# Include the orchestrator
include("../MCPJuliaClient/examples/claude_orchestrator.jl")
EOF
        chmod +x "${SERVERS[orchestrator]}"
    fi
}

# Generate Windows Claude configuration
generate_windows_config() {
    log "Generating Windows Claude Desktop configuration..."
    
    local config_file="$SCRIPT_DIR/claude_desktop_config_windows_ready.json"
    local template_file="$SCRIPT_DIR/claude_desktop_config_windows.json"
    
    if [[ ! -f "$template_file" ]]; then
        error "Template file not found: $template_file"
    fi
    
    # Replace WSL IP placeholder in template
    sed "s/WSL_IP_ADDRESS/$WSL_IP/g" "$template_file" > "$config_file"
    
    log "✅ Windows configuration generated: $config_file"
}

# Start HTTP servers
start_servers() {
    log "Starting HTTP MCP servers..."
    
    # Create logs directory
    mkdir -p "$SERVER_DIR/logs"
    
    # Start each server in background
    for server_name in "${!SERVERS[@]}"; do
        local server_file="${SERVERS[$server_name]}"
        local port="${PORTS[$server_name]}"
        local log_file="$SERVER_DIR/logs/${server_name}_http.log"
        
        if [[ -f "$server_file" ]]; then
            log "Starting $server_name server on port $port..."
            
            # Set environment variables for HTTP mode
            export MCP_HTTP_MODE=true
            export MCP_HTTP_PORT=$port
            export MCP_HTTP_HOST="0.0.0.0"
            
            # Start server in background
            nohup julia --project="$SERVER_DIR" "$server_file" > "$log_file" 2>&1 &
            local pid=$!
            
            # Save PID for later cleanup
            echo "$pid" > "$SERVER_DIR/logs/${server_name}_http.pid"
            
            log "✅ Started $server_name server (PID: $pid)"
            sleep 1  # Give server time to start
        else
            warn "Server file not found: $server_file"
        fi
    done
}

# Test server connectivity
test_servers() {
    log "Testing server connectivity..."
    
    sleep 3  # Give servers time to fully start
    
    for server_name in "${!PORTS[@]}"; do
        local port="${PORTS[$server_name]}"
        local url="http://$WSL_IP:$port/mcp/health"
        
        log "Testing $server_name server at $url..."
        
        if curl -s --connect-timeout 5 "$url" > /dev/null 2>&1; then
            log "✅ $server_name server is responding"
        else
            warn "❌ $server_name server is not responding at $url"
        fi
    done
}

# Stop all HTTP servers
stop_servers() {
    log "Stopping HTTP MCP servers..."
    
    for server_name in "${!SERVERS[@]}"; do
        local pid_file="$SERVER_DIR/logs/${server_name}_http.pid"
        
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                log "Stopping $server_name server (PID: $pid)..."
                kill "$pid"
                rm -f "$pid_file"
            fi
        fi
    done
    
    # Also kill any remaining julia HTTP servers
    pkill -f "MCP_HTTP_MODE=true" 2>/dev/null || true
}

# Print Windows setup instructions
print_windows_instructions() {
    local config_file="$SCRIPT_DIR/claude_desktop_config_windows_ready.json"
    
    echo ""
    echo -e "${BLUE}🪟 Windows Claude Desktop Setup Instructions${NC}"
    echo "=" * 60
    echo ""
    echo "1. Copy the generated configuration to your Windows Claude Desktop:"
    echo "   Source: $config_file"
    echo "   Destination: %APPDATA%\\Claude\\claude_desktop_config.json"
    echo ""
    echo "2. Restart Claude Desktop on Windows"
    echo ""
    echo -e "${BLUE}Server Endpoints:${NC}"
    for server_name in "${!PORTS[@]}"; do
        local port="${PORTS[$server_name]}"
        echo "   $server_name: http://$WSL_IP:$port"
    done
    echo ""
    echo -e "${BLUE}Available MCP Servers in Windows Claude:${NC}"
    echo "   📊 mcp-postgres-http    - SQL queries and database operations"
    echo "   📁 mcp-file-http        - File system operations"
    echo "   🔧 mcp-db-admin-http    - Database administration"
    echo "   🎯 mcp-orchestrator-http - Multi-server workflows"
    echo ""
    echo -e "${BLUE}Management Commands:${NC}"
    echo "   Start servers: $0 start"
    echo "   Stop servers:  $0 stop"
    echo "   Test servers:  $0 test"
    echo "   Status:        $0 status"
    echo ""
    echo -e "${BLUE}Troubleshooting:${NC}"
    echo "   - Ensure Windows can reach WSL IP: $WSL_IP"
    echo "   - Check Windows Firewall settings"
    echo "   - Verify Julia packages are installed in WSL"
    echo "   - Check server logs in: $SERVER_DIR/logs/"
    echo "=" * 60
}

# Show server status
show_status() {
    log "HTTP MCP Server Status:"
    echo ""
    
    for server_name in "${!PORTS[@]}"; do
        local port="${PORTS[$server_name]}"
        local pid_file="$SERVER_DIR/logs/${server_name}_http.pid"
        local url="http://$WSL_IP:$port/mcp/health"
        
        printf "%-15s " "$server_name:"
        
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                if curl -s --connect-timeout 2 "$url" > /dev/null 2>&1; then
                    echo -e "${GREEN}✅ Running (PID: $pid, Port: $port)${NC}"
                else
                    echo -e "${YELLOW}⚠️  Process running but not responding${NC}"
                fi
            else
                echo -e "${RED}❌ Stopped${NC}"
                rm -f "$pid_file"
            fi
        else
            echo -e "${RED}❌ Not started${NC}"
        fi
    done
}

# Main function
main() {
    local action="${1:-start}"
    
    case "$action" in
        "start")
            log "Setting up Windows access to WSL MCP servers..."
            get_wsl_ip
            check_server_files
            create_http_servers  
            generate_windows_config
            start_servers
            test_servers
            print_windows_instructions
            ;;
        "stop")
            stop_servers
            ;;
        "test")
            get_wsl_ip
            test_servers
            ;;
        "status")
            get_wsl_ip
            show_status
            ;;
        "restart")
            stop_servers
            sleep 2
            main "start"
            ;;
        *)
            echo "Usage: $0 {start|stop|test|status|restart}"
            exit 1
            ;;
    esac
}

# Handle script termination
cleanup() {
    log "Script interrupted, stopping servers..."
    stop_servers
    exit 1
}

trap cleanup INT TERM

# Run main function
main "$@"