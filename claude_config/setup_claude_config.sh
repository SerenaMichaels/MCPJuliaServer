#!/bin/bash
# Setup Claude Desktop Configuration for MCP Julia Server
# This script configures Claude Desktop to use the MCP Julia Server suite

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
TEMPLATE_FILE="$SCRIPT_DIR/claude_desktop_config_template.json"
CONFIG_FILE="$SCRIPT_DIR/claude_desktop_config.json"

# Claude Desktop config locations
CLAUDE_CONFIG_DIRS=(
    "$HOME/.config/Claude/claude_desktop_config.json"
    "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    "$HOME/AppData/Roaming/Claude/claude_desktop_config.json"
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

prompt_user() {
    local prompt="$1"
    local default="$2"
    local value=""
    
    if [[ -n "$default" ]]; then
        read -p "$prompt [$default]: " value
        value="${value:-$default}"
    else
        read -p "$prompt: " value
    fi
    
    echo "$value"
}

load_site_config() {
    log "Loading site configuration..."
    
    # Try to load from .env.local first, then .env.site, then .env
    local config_files=(".env.local" ".env.site" ".env")
    
    for config_file in "${config_files[@]}"; do
        local config_path="$SERVER_DIR/$config_file"
        if [[ -f "$config_path" ]]; then
            log "Loading configuration from $config_file"
            # Source the file but only export specific variables
            while IFS='=' read -r key value; do
                # Skip comments and empty lines
                [[ "$key" =~ ^[[:space:]]*# ]] && continue
                [[ -z "$key" ]] && continue
                
                # Remove quotes if present
                value=$(echo "$value" | sed 's/^["'\'']//' | sed 's/["'\'']$//')
                
                # Export specific variables we need
                case "$key" in
                    POSTGRES_HOST|POSTGRES_PORT|POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_DB|MCP_FILE_SERVER_BASE)
                        export "$key=$value"
                        ;;
                esac
            done < "$config_path"
            break
        fi
    done
}

create_config() {
    log "Creating Claude Desktop configuration..."
    
    # Load existing site configuration
    load_site_config
    
    # Get configuration values
    local server_path="${SERVER_DIR}"
    local db_host="${POSTGRES_HOST:-localhost}"
    local db_port="${POSTGRES_PORT:-5432}"
    local db_user="${POSTGRES_USER:-postgres}"
    local db_password="${POSTGRES_PASSWORD}"
    local db_name="${POSTGRES_DB:-postgres}"
    local file_base="${MCP_FILE_SERVER_BASE:-/opt/mcp-data}"
    
    # Prompt for missing values
    if [[ -z "$db_password" ]]; then
        db_password=$(prompt_user "Enter PostgreSQL password" "")
        if [[ -z "$db_password" ]]; then
            error "PostgreSQL password is required"
        fi
    fi
    
    # Confirm other values
    echo ""
    echo -e "${BLUE}Configuration Summary:${NC}"
    echo "Server Path: $server_path"
    echo "Database Host: $db_host"
    echo "Database User: $db_user"
    echo "Database Name: $db_name"
    echo "File Base Path: $file_base"
    echo ""
    
    read -p "Continue with this configuration? [Y/n]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log "Configuration cancelled"
        exit 0
    fi
    
    # Create configuration from template
    cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    
    # Replace placeholders
    sed -i "s|REPLACE_WITH_SERVER_PATH|$server_path|g" "$CONFIG_FILE"
    sed -i "s|REPLACE_WITH_DB_HOST|$db_host|g" "$CONFIG_FILE"
    sed -i "s|REPLACE_WITH_DB_USER|$db_user|g" "$CONFIG_FILE"
    sed -i "s|REPLACE_WITH_DB_PASSWORD|$db_password|g" "$CONFIG_FILE"
    sed -i "s|REPLACE_WITH_DB_NAME|$db_name|g" "$CONFIG_FILE"
    sed -i "s|REPLACE_WITH_FILE_BASE_PATH|$file_base|g" "$CONFIG_FILE"
    
    log "Configuration created at: $CONFIG_FILE"
}

install_claude_config() {
    log "Installing Claude Desktop configuration..."
    
    local installed=false
    
    for config_path in "${CLAUDE_CONFIG_DIRS[@]}"; do
        local config_dir=$(dirname "$config_path")
        
        if [[ -d "$config_dir" ]] || mkdir -p "$config_dir" 2>/dev/null; then
            log "Installing configuration to: $config_path"
            
            # Backup existing configuration
            if [[ -f "$config_path" ]]; then
                cp "$config_path" "$config_path.backup.$(date +%Y%m%d_%H%M%S)"
                log "Backed up existing configuration"
            fi
            
            # Install new configuration
            cp "$CONFIG_FILE" "$config_path"
            log "✅ Configuration installed successfully"
            installed=true
            break
        fi
    done
    
    if [[ "$installed" == "false" ]]; then
        warn "Could not find Claude Desktop configuration directory"
        echo "Please manually copy the configuration:"
        echo "  Source: $CONFIG_FILE"
        echo "  Destination: One of the following locations:"
        for config_path in "${CLAUDE_CONFIG_DIRS[@]}"; do
            echo "    - $config_path"
        done
    fi
}

test_julia_access() {
    log "Testing Julia and server access..."
    
    # Test Julia
    if ! command -v julia >/dev/null 2>&1; then
        error "Julia not found in PATH. Please install Julia or update PATH."
    fi
    
    local julia_version=$(julia --version 2>/dev/null || echo "unknown")
    log "Julia version: $julia_version"
    
    # Test server files
    local server_files=("postgres_example.jl" "file_server_example.jl" "db_admin_example.jl")
    for server_file in "${server_files[@]}"; do
        local server_path="$SERVER_DIR/$server_file"
        if [[ ! -f "$server_path" ]]; then
            error "Server file not found: $server_path"
        fi
        log "✅ Found server: $server_file"
    done
    
    # Test Julia packages
    cd "$SERVER_DIR"
    if julia --project=. -e "using Pkg; Pkg.status()" >/dev/null 2>&1; then
        log "✅ Julia packages are properly installed"
    else
        warn "Julia packages may need to be installed. Run:"
        echo "  cd $SERVER_DIR && julia --project=. -e 'using Pkg; Pkg.instantiate()'"
    fi
}

print_usage_instructions() {
    log "Claude Desktop MCP configuration completed!"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. Restart Claude Desktop application"
    echo "2. The MCP servers will be available in Claude with these capabilities:"
    echo ""
    echo -e "${BLUE}Available MCP Servers:${NC}"
    echo "📊 mcp-postgres-server:"
    echo "   - Execute SQL queries and database operations"
    echo "   - Advanced querying with filters and joins"
    echo "   - Transaction management"
    echo ""
    echo "📁 mcp-file-server:"
    echo "   - Read and write files"
    echo "   - Create directories and manage file structure"
    echo "   - Cross-platform file operations"
    echo ""
    echo "🔧 mcp-db-admin-server:"
    echo "   - Create and manage databases"
    echo "   - User and permission management"
    echo "   - Import/export data and schema"
    echo "   - Table creation from JSON schemas"
    echo ""
    echo -e "${BLUE}Configuration Files:${NC}"
    echo "  Local Config: $CONFIG_FILE"
    echo "  Claude Config: $(find_claude_config_path)"
    echo ""
    echo -e "${BLUE}Troubleshooting:${NC}"
    echo "- Check Claude Desktop logs for connection issues"
    echo "- Ensure database is running and accessible"
    echo "- Verify file paths have proper permissions"
    echo "- Test servers manually: julia --project=$SERVER_DIR $SERVER_DIR/postgres_example.jl"
}

find_claude_config_path() {
    for config_path in "${CLAUDE_CONFIG_DIRS[@]}"; do
        if [[ -f "$config_path" ]]; then
            echo "$config_path"
            return
        fi
    done
    echo "Not found"
}

main() {
    log "Setting up Claude Desktop configuration for MCP Julia Server..."
    
    create_config
    install_claude_config
    test_julia_access
    print_usage_instructions
}

# Check if template file exists
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    error "Template file not found: $TEMPLATE_FILE"
fi

# Run main function
main "$@"