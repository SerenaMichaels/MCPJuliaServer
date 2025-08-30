#!/bin/bash
# MCP Julia Server Installation Script
# Supports: Ubuntu, Debian, CentOS, Fedora, macOS

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
JULIA_VERSION="1.11.2"
INSTALL_DIR="/opt/mcp-julia-server"
DATA_DIR="/opt/mcp-data"
SERVICE_USER="mcpserver"

# Functions
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

detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            OS="debian"
            PKG_MANAGER="apt-get"
        elif command -v dnf >/dev/null 2>&1; then
            OS="fedora"
            PKG_MANAGER="dnf"
        elif command -v yum >/dev/null 2>&1; then
            OS="centos"
            PKG_MANAGER="yum"
        else
            error "Unsupported Linux distribution"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        PKG_MANAGER="brew"
    else
        error "Unsupported operating system: $OSTYPE"
    fi
    log "Detected OS: $OS"
}

check_requirements() {
    log "Checking system requirements..."
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root for security reasons"
    fi
    
    # Check for required commands
    local required_commands=("git" "curl" "sudo")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Required command '$cmd' not found"
        fi
    done
}

install_system_deps() {
    log "Installing system dependencies..."
    
    case $OS in
        "debian")
            sudo apt-get update
            sudo apt-get install -y \
                build-essential \
                curl \
                git \
                postgresql \
                postgresql-contrib \
                libpq-dev \
                ca-certificates \
                gnupg \
                lsb-release
            ;;
        "fedora")
            sudo dnf update -y
            sudo dnf install -y \
                gcc-c++ \
                make \
                curl \
                git \
                postgresql \
                postgresql-server \
                postgresql-contrib \
                postgresql-devel \
                ca-certificates
            ;;
        "centos")
            sudo yum update -y
            sudo yum install -y epel-release
            sudo yum install -y \
                gcc-c++ \
                make \
                curl \
                git \
                postgresql \
                postgresql-server \
                postgresql-contrib \
                postgresql-devel \
                ca-certificates
            ;;
        "macos")
            if ! command -v brew >/dev/null 2>&1; then
                log "Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            brew install postgresql git curl
            ;;
    esac
}

install_julia() {
    log "Installing Julia..."
    
    if command -v julia >/dev/null 2>&1; then
        local julia_version=$(julia --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        log "Julia $julia_version already installed"
        return
    fi
    
    local julia_url
    case $(uname -m) in
        "x86_64")
            julia_url="https://julialang-s3.julialang.org/bin/linux/x64/$(echo $JULIA_VERSION | cut -d. -f1-2)/julia-${JULIA_VERSION}-linux-x86_64.tar.gz"
            ;;
        "aarch64"|"arm64")
            julia_url="https://julialang-s3.julialang.org/bin/linux/aarch64/$(echo $JULIA_VERSION | cut -d. -f1-2)/julia-${JULIA_VERSION}-linux-aarch64.tar.gz"
            ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            ;;
    esac
    
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    log "Downloading Julia $JULIA_VERSION..."
    curl -fsSL "$julia_url" -o julia.tar.gz
    
    log "Extracting Julia..."
    tar -xzf julia.tar.gz
    
    log "Installing Julia to /usr/local..."
    sudo mv julia-*/ /usr/local/julia
    sudo ln -sf /usr/local/julia/bin/julia /usr/local/bin/julia
    
    cd - >/dev/null
    rm -rf "$temp_dir"
    
    # Verify installation
    if julia --version >/dev/null 2>&1; then
        log "Julia installed successfully: $(julia --version)"
    else
        error "Julia installation failed"
    fi
}

setup_postgresql() {
    log "Setting up PostgreSQL..."
    
    case $OS in
        "debian")
            sudo systemctl start postgresql
            sudo systemctl enable postgresql
            ;;
        "fedora"|"centos")
            if [[ "$OS" == "centos" ]]; then
                sudo postgresql-setup --initdb
            fi
            sudo systemctl start postgresql
            sudo systemctl enable postgresql
            ;;
        "macos")
            brew services start postgresql
            ;;
    esac
    
    # Wait for PostgreSQL to start
    sleep 5
    
    # Create database user and database
    log "Creating database user and database..."
    sudo -u postgres psql -c "CREATE USER IF NOT EXISTS $SERVICE_USER WITH PASSWORD 'mcp_default_password';" 2>/dev/null || true
    sudo -u postgres createdb -O $SERVICE_USER mcpserver 2>/dev/null || true
    
    log "PostgreSQL setup completed"
}

create_service_user() {
    log "Creating service user..."
    
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        case $OS in
            "debian"|"fedora"|"centos")
                sudo useradd -r -s /bin/false -d /nonexistent $SERVICE_USER
                ;;
            "macos")
                warn "Service user creation on macOS requires manual setup"
                ;;
        esac
    fi
}

install_mcp_server() {
    log "Installing MCP Julia Server..."
    
    # Create installation directory
    sudo mkdir -p "$INSTALL_DIR"
    sudo mkdir -p "$DATA_DIR"
    
    # Clone repository
    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
        sudo git clone https://github.com/SerenaMichaels/MCPJuliaServer.git "$INSTALL_DIR"
    else
        sudo git -C "$INSTALL_DIR" pull origin main
    fi
    
    # Set ownership
    sudo chown -R $SERVICE_USER:$SERVICE_USER "$INSTALL_DIR"
    sudo chown -R $SERVICE_USER:$SERVICE_USER "$DATA_DIR"
    
    # Install Julia dependencies
    cd "$INSTALL_DIR"
    sudo -u $SERVICE_USER julia --project=. -e "using Pkg; Pkg.instantiate()"
    
    # Create configuration
    if [[ ! -f "$INSTALL_DIR/.env" ]]; then
        sudo -u $SERVICE_USER cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
        log "Created .env configuration file - please edit $INSTALL_DIR/.env with your settings"
    fi
}

setup_systemd_service() {
    if [[ "$OS" == "macos" ]]; then
        warn "Systemd not available on macOS - skipping service setup"
        return
    fi
    
    log "Setting up systemd service..."
    
    sudo tee /etc/systemd/system/mcp-julia-server.service >/dev/null <<EOF
[Unit]
Description=MCP Julia Server
After=postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
Environment=PATH=/usr/local/bin:/usr/bin:/bin
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=/usr/local/bin/julia --project=. postgres_example.jl
Restart=always
RestartSec=10

# Security settings
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$DATA_DIR $INSTALL_DIR/logs

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable mcp-julia-server
    
    log "Systemd service created. Start with: sudo systemctl start mcp-julia-server"
}

create_scripts() {
    log "Creating utility scripts..."
    
    # Start script
    sudo tee "$INSTALL_DIR/start.sh" >/dev/null <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
source .env 2>/dev/null || true
exec julia --project=. postgres_example.jl
EOF
    
    # Status script
    sudo tee "$INSTALL_DIR/status.sh" >/dev/null <<'EOF'
#!/bin/bash
echo "=== MCP Julia Server Status ==="
systemctl is-active mcp-julia-server || echo "Service not running"
echo ""
echo "=== Recent Logs ==="
journalctl -u mcp-julia-server -n 10 --no-pager
EOF
    
    sudo chmod +x "$INSTALL_DIR"/*.sh
    sudo chown $SERVICE_USER:$SERVICE_USER "$INSTALL_DIR"/*.sh
}

run_tests() {
    log "Running installation tests..."
    
    cd "$INSTALL_DIR"
    
    # Test Julia packages
    sudo -u $SERVICE_USER julia --project=. -e "
    using Pkg
    Pkg.status()
    println(\"✅ Julia packages OK\")
    "
    
    # Test PostgreSQL connection (if configured)
    if [[ -f .env ]]; then
        source .env
        if [[ -n "$POSTGRES_PASSWORD" && "$POSTGRES_PASSWORD" != "your_secure_password" ]]; then
            sudo -u $SERVICE_USER julia --project=. -e "
            using LibPQ
            try
                conn = LibPQ.Connection(\"host=$POSTGRES_HOST user=$POSTGRES_USER password=$POSTGRES_PASSWORD dbname=$POSTGRES_DB\")
                LibPQ.close(conn)
                println(\"✅ PostgreSQL connection OK\")
            catch e
                println(\"⚠️ PostgreSQL connection failed: \", e)
                println(\"Please configure database settings in .env\")
            end
            " 2>/dev/null || warn "PostgreSQL connection test skipped - configure .env first"
        fi
    fi
    
    log "Installation tests completed"
}

print_next_steps() {
    log "Installation completed successfully!"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. Configure your database settings:"
    echo "   sudo -u $SERVICE_USER nano $INSTALL_DIR/.env"
    echo ""
    echo "2. Start the service:"
    echo "   sudo systemctl start mcp-julia-server"
    echo ""
    echo "3. Check service status:"
    echo "   sudo systemctl status mcp-julia-server"
    echo ""
    echo "4. View logs:"
    echo "   journalctl -u mcp-julia-server -f"
    echo ""
    echo -e "${BLUE}Files and Directories:${NC}"
    echo "  Installation: $INSTALL_DIR"
    echo "  Data: $DATA_DIR"
    echo "  Configuration: $INSTALL_DIR/.env"
    echo "  Service: /etc/systemd/system/mcp-julia-server.service"
    echo ""
    echo -e "${BLUE}Documentation:${NC}"
    echo "  Installation Guide: $INSTALL_DIR/INSTALL.md"
    echo "  Repository: https://github.com/SerenaMichaels/MCPJuliaServer"
}

# Main installation process
main() {
    log "Starting MCP Julia Server installation..."
    
    detect_os
    check_requirements
    install_system_deps
    install_julia
    setup_postgresql
    create_service_user
    install_mcp_server
    setup_systemd_service
    create_scripts
    run_tests
    print_next_steps
}

# Run main function
main "$@"