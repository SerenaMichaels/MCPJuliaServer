#!/bin/bash
# MCP Julia Server Service Setup Script
# This script installs and configures systemd services for MCP servers

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/opt/mcp-julia-server"
SERVICE_USER="mcpserver"
SERVICE_FILES=(
    "mcp-postgres-server.service"
    "mcp-file-server.service"
    "mcp-db-admin-server.service"
    "mcp-servers.target"
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

check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

check_installation() {
    log "Checking MCP server installation..."
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        error "MCP server not found at $INSTALL_DIR. Please install the server first."
    fi
    
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        error "Service user '$SERVICE_USER' not found. Please run the main installation script first."
    fi
    
    log "Installation verified"
}

install_service_files() {
    log "Installing systemd service files..."
    
    local systemd_dir="$INSTALL_DIR/systemd"
    
    if [[ ! -d "$systemd_dir" ]]; then
        error "Systemd directory not found at $systemd_dir"
    fi
    
    for service_file in "${SERVICE_FILES[@]}"; do
        log "Installing $service_file"
        cp "$systemd_dir/$service_file" "/etc/systemd/system/"
        chmod 644 "/etc/systemd/system/$service_file"
    done
}

create_log_directories() {
    log "Creating log directories..."
    
    mkdir -p /var/log/mcp
    chown $SERVICE_USER:$SERVICE_USER /var/log/mcp
    chmod 755 /var/log/mcp
    
    # Create logs directory in installation
    mkdir -p "$INSTALL_DIR/logs"
    chown $SERVICE_USER:$SERVICE_USER "$INSTALL_DIR/logs"
    chmod 755 "$INSTALL_DIR/logs"
}

configure_logrotate() {
    log "Configuring log rotation..."
    
    cat > /etc/logrotate.d/mcp-servers <<EOF
/var/log/mcp/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 $SERVICE_USER $SERVICE_USER
    postrotate
        systemctl reload mcp-postgres-server mcp-file-server mcp-db-admin-server 2>/dev/null || true
    endscript
}

$INSTALL_DIR/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 $SERVICE_USER $SERVICE_USER
    copytruncate
}
EOF
}

reload_systemd() {
    log "Reloading systemd configuration..."
    systemctl daemon-reload
}

enable_services() {
    log "Enabling MCP services for startup..."
    
    # Enable individual services
    for service_file in "${SERVICE_FILES[@]}"; do
        if [[ "$service_file" != *.target ]]; then
            service_name=$(basename "$service_file")
            log "Enabling $service_name"
            systemctl enable "$service_name"
        fi
    done
    
    # Enable the target
    systemctl enable mcp-servers.target
}

test_configuration() {
    log "Testing service configuration..."
    
    for service_file in "${SERVICE_FILES[@]}"; do
        if [[ "$service_file" != *.target ]]; then
            service_name=$(basename "$service_file")
            log "Checking $service_name configuration"
            systemctl cat "$service_name" >/dev/null
        fi
    done
    
    log "Configuration test passed"
}

display_management_commands() {
    log "Service management commands:"
    echo ""
    echo -e "${BLUE}Start all MCP servers:${NC}"
    echo "  sudo systemctl start mcp-servers.target"
    echo ""
    echo -e "${BLUE}Stop all MCP servers:${NC}"
    echo "  sudo systemctl stop mcp-servers.target"
    echo ""
    echo -e "${BLUE}Check status:${NC}"
    echo "  sudo systemctl status mcp-servers.target"
    echo "  sudo systemctl status mcp-postgres-server"
    echo "  sudo systemctl status mcp-file-server"
    echo "  sudo systemctl status mcp-db-admin-server"
    echo ""
    echo -e "${BLUE}View logs:${NC}"
    echo "  sudo journalctl -u mcp-postgres-server -f"
    echo "  sudo journalctl -u mcp-file-server -f"
    echo "  sudo journalctl -u mcp-db-admin-server -f"
    echo ""
    echo -e "${BLUE}Restart services:${NC}"
    echo "  sudo systemctl restart mcp-servers.target"
    echo ""
    echo -e "${BLUE}Disable services:${NC}"
    echo "  sudo systemctl disable mcp-servers.target"
    echo "  sudo systemctl disable mcp-postgres-server mcp-file-server mcp-db-admin-server"
}

main() {
    log "Setting up MCP Julia Server systemd services..."
    
    check_privileges
    check_installation
    install_service_files
    create_log_directories
    configure_logrotate
    reload_systemd
    enable_services
    test_configuration
    
    log "Service setup completed successfully!"
    echo ""
    echo -e "${GREEN}✅ MCP servers will now start automatically on boot${NC}"
    echo ""
    display_management_commands
}

# Run main function
main "$@"