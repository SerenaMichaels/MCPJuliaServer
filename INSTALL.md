# MCPJuliaServer Installation Guide

This guide provides comprehensive installation instructions for the MCP Julia Server suite across different platforms.

## Quick Install

### Prerequisites
- Julia 1.6+ 
- PostgreSQL 12+ (for database servers)
- Git

### One-Line Install (Linux/macOS)
```bash
curl -fsSL https://raw.githubusercontent.com/SerenaMichaels/MCPJuliaServer/main/scripts/install.sh | bash
```

### Manual Installation
```bash
# 1. Clone repository
git clone https://github.com/SerenaMichaels/MCPJuliaServer.git
cd MCPJuliaServer

# 2. Install dependencies
julia --project=. -e "using Pkg; Pkg.instantiate()"

# 3. Configure environment
cp .env.example .env
# Edit .env with your settings

# 4. Test installation
./scripts/test-install.sh
```

## Platform-Specific Installation

### Ubuntu/Debian

#### System Dependencies
```bash
# Update package list
sudo apt update

# Install Julia
curl -fsSL https://install.julialang.org | sh
# OR install from package manager (may be older version)
sudo apt install julia

# Install PostgreSQL
sudo apt install postgresql postgresql-contrib

# Install development tools
sudo apt install build-essential git curl
```

#### PostgreSQL Setup
```bash
# Start PostgreSQL service
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Create database user
sudo -u postgres createuser --interactive --pwprompt mcpuser

# Create database
sudo -u postgres createdb -O mcpuser mcpserver
```

### CentOS/RHEL/Fedora

#### System Dependencies
```bash
# Fedora
sudo dnf install julia postgresql postgresql-server postgresql-contrib git curl gcc-c++

# CentOS/RHEL (enable EPEL first)
sudo dnf install epel-release
sudo dnf install postgresql postgresql-server postgresql-contrib git curl gcc-c++

# Install Julia (if not available in repos)
curl -fsSL https://install.julialang.org | sh
```

#### PostgreSQL Setup
```bash
# Initialize database (CentOS/RHEL only)
sudo postgresql-setup --initdb

# Start services
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Configure authentication (edit /var/lib/pgsql/data/pg_hba.conf)
sudo sed -i 's/ident$/md5/g' /var/lib/pgsql/data/pg_hba.conf
sudo systemctl restart postgresql

# Create user and database
sudo -u postgres psql -c "CREATE USER mcpuser WITH PASSWORD 'secure_password';"
sudo -u postgres createdb -O mcpuser mcpserver
```

### Windows

#### Using Windows Subsystem for Linux (WSL) - Recommended
```powershell
# Install WSL2 if not already installed
wsl --install -d Ubuntu-20.04

# Follow Ubuntu installation instructions above
```

#### Native Windows Installation
```powershell
# Install Julia from https://julialang.org/downloads/
# Install PostgreSQL from https://www.postgresql.org/download/windows/

# Install Git
winget install Git.Git

# Clone repository
git clone https://github.com/SerenaMichaels/MCPJuliaServer.git
cd MCPJuliaServer

# Install Julia dependencies
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

#### PostgreSQL Windows Setup
1. Download and install PostgreSQL from the official website
2. During installation, set a secure password for the postgres user
3. Add PostgreSQL bin directory to PATH
4. Create database:
   ```cmd
   createdb -U postgres mcpserver
   ```

### Docker Installation

#### Quick Start with Docker
```bash
# Build container
docker build -t mcp-julia-server .

# Run with database
docker-compose up -d

# Or run standalone (requires external PostgreSQL)
docker run -e POSTGRES_HOST=host.docker.internal \
           -e POSTGRES_PASSWORD=yourpassword \
           -p 3000:3000 \
           mcp-julia-server
```

#### Docker Compose
```yaml
version: '3.8'
services:
  mcp-server:
    build: .
    ports:
      - "3000:3000"
    environment:
      - POSTGRES_HOST=postgres
      - POSTGRES_PASSWORD=secure_password
    depends_on:
      - postgres
    
  postgres:
    image: postgres:15
    environment:
      POSTGRES_PASSWORD: secure_password
      POSTGRES_DB: mcpserver
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

volumes:
  postgres_data:
```

## Configuration

### Environment Variables

Create `.env` file from template:
```bash
cp .env.example .env
```

#### Required Variables
```bash
# PostgreSQL Database
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_USER=postgres
POSTGRES_PASSWORD=your_secure_password
POSTGRES_DB=mcpserver

# File Server
MCP_FILE_SERVER_BASE=/opt/mcp-data

# Julia
JULIA_PATH=/usr/local/bin/julia
```

#### Platform-Specific Paths

**Linux:**
```bash
MCP_FILE_SERVER_BASE=/opt/mcp-data
JULIA_PATH=/usr/local/bin/julia
```

**Windows:**
```bash
MCP_FILE_SERVER_BASE=C:\mcp-data
JULIA_PATH=C:\Users\%USERNAME%\AppData\Local\Programs\Julia\Julia-1.11.2\bin\julia.exe
```

**WSL:**
```bash
MCP_FILE_SERVER_BASE=/mnt/c/mcp-data
JULIA_PATH=/usr/local/bin/julia
```

### Security Configuration

#### Database Security
```bash
# Create dedicated database user
sudo -u postgres psql -c "
CREATE USER mcpuser WITH PASSWORD 'secure_random_password';
CREATE DATABASE mcpserver OWNER mcpuser;
GRANT ALL PRIVILEGES ON DATABASE mcpserver TO mcpuser;
"
```

#### File Permissions
```bash
# Create secure data directory
sudo mkdir -p /opt/mcp-data
sudo chown $(whoami):$(whoami) /opt/mcp-data
chmod 750 /opt/mcp-data
```

## Verification

### Test Installation
```bash
# Run test suite
./scripts/test-install.sh

# Test individual servers
julia --project=. postgres_example.jl &
echo '{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}' | nc localhost 3000

# Test file operations
julia --project=. file_server_example.jl
```

### Health Check
```bash
# Check all dependencies
julia --project=. -e "
using Pkg
Pkg.status()
println(\"✅ Julia dependencies OK\")

using LibPQ
conn = LibPQ.Connection(\"host=localhost user=$POSTGRES_USER password=$POSTGRES_PASSWORD\")
LibPQ.close(conn)
println(\"✅ PostgreSQL connection OK\")
"
```

## Troubleshooting

### Common Issues

#### Julia Not Found
```bash
# Add Julia to PATH
export PATH=\"\$PATH:/opt/julia/bin\"
echo 'export PATH=\"\$PATH:/opt/julia/bin\"' >> ~/.bashrc
```

#### PostgreSQL Connection Failed
```bash
# Check PostgreSQL status
sudo systemctl status postgresql

# Check configuration
sudo -u postgres psql -c "SELECT version();"

# Verify user permissions
sudo -u postgres psql -c "\\du"
```

#### Permission Denied
```bash
# Fix file permissions
chmod +x *.jl
sudo chown -R $(whoami):$(whoami) /opt/mcp-data
```

#### LibPQ Build Issues
```bash
# Install development headers
# Ubuntu/Debian:
sudo apt install libpq-dev

# CentOS/Fedora:
sudo dnf install postgresql-devel

# Rebuild Julia packages
julia --project=. -e "using Pkg; Pkg.build(\"LibPQ\")"
```

### Log Analysis
```bash
# View server logs
journalctl -u mcp-julia-server -f

# Check Julia package logs
julia --project=. -e "using Pkg; Pkg.test(\"LibPQ\")"
```

## Deployment Options

### Systemd Service (Linux)
```bash
# Copy service file
sudo cp scripts/mcp-julia-server.service /etc/systemd/system/

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable mcp-julia-server
sudo systemctl start mcp-julia-server
```

### Process Manager (PM2)
```bash
# Install PM2
npm install -g pm2

# Start servers
pm2 start ecosystem.config.js
pm2 save
pm2 startup
```

### Container Deployment
```bash
# Build production image
docker build -f Dockerfile.prod -t mcp-server:latest .

# Deploy with kubernetes
kubectl apply -f k8s/
```

## Maintenance

### Updates
```bash
# Update Julia packages
julia --project=. -e "using Pkg; Pkg.update()"

# Update system packages
sudo apt update && sudo apt upgrade  # Ubuntu/Debian
sudo dnf update                       # Fedora/CentOS
```

### Backup
```bash
# Backup database
pg_dump -U mcpuser mcpserver > backup.sql

# Backup configuration
tar -czf mcp-config-backup.tar.gz .env logs/
```

### Monitoring
```bash
# System resources
htop
iostat -x 1

# Database performance
sudo -u postgres psql -c "SELECT * FROM pg_stat_activity;"

# Server logs
tail -f logs/mcp-server.log
```

## Support

### Getting Help
- Check logs in `/var/log/mcp-julia-server/`
- Run diagnostic script: `./scripts/diagnose.sh`
- Submit issues: [GitHub Issues](https://github.com/SerenaMichaels/MCPJuliaServer/issues)

### Community
- Documentation: [GitHub Wiki](https://github.com/SerenaMichaels/MCPJuliaServer/wiki)
- Discussions: [GitHub Discussions](https://github.com/SerenaMichaels/MCPJuliaServer/discussions)