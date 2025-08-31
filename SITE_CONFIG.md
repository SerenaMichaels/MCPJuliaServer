# Site Configuration System

The MCP Julia Server suite uses a flexible site configuration system that allows you to maintain local development settings separate from deployment configurations without exposing sensitive information to version control.

## Configuration Precedence

Configuration is loaded in the following order (highest to lowest precedence):

1. **Environment Variables** - Always take highest precedence
2. **`.env.local`** - Local development settings (not committed)
3. **`.env.site`** - Site-specific deployment settings (not committed)
4. **`.env.example`** - Default template (committed, for reference)

## Configuration Files

### `.env.example` (Committed)
Template file showing all available configuration options with safe defaults. This file is committed to git and serves as documentation.

### `.env.local` (Not Committed)
Local development configuration. Use this for:
- Your personal database credentials
- Local file paths
- Development-specific settings
- Debug flags

```bash
cp .env.local.example .env.local
# Edit with your local settings
```

### `.env.site` (Not Committed)
Site-specific deployment configuration. Use this for:
- Production database credentials
- Site-specific file paths
- SSL certificates
- Monitoring endpoints
- Performance tuning

```bash
cp .env.site.example .env.site
# Edit with your site-specific settings
```

## Site Configuration Module

The `config/site_config.jl` module provides a centralized way to load and access configuration:

```julia
using .SiteConfig

# Load configuration with precedence
SiteConfig.load_config(".")

# Get database configuration
db_config = SiteConfig.get_db_config()

# Get specific values
julia_path = SiteConfig.get_config("JULIA_PATH", "julia")

# Check configuration
if SiteConfig.has_config("POSTGRES_PASSWORD")
    # Password is configured
end

# Validate all required configuration
SiteConfig.validate_config()
```

## Usage Examples

### Local Development Setup
```bash
# 1. Copy local template
cp .env.local.example .env.local

# 2. Edit with your settings
nano .env.local

# Example .env.local content:
POSTGRES_HOST=localhost
POSTGRES_PASSWORD=my_dev_password
JULIA_PATH=/usr/local/bin/julia
MCP_FILE_SERVER_BASE=/home/user/mcp-data
MCP_DEV_MODE=true
MCP_DEBUG_COMMUNICATION=true
```

### Production Deployment
```bash
# 1. Copy site template
cp .env.site.example .env.site

# 2. Edit with production settings
nano .env.site

# Example .env.site content:
POSTGRES_HOST=prod-db.company.com
POSTGRES_PASSWORD=secure_prod_password
JULIA_PATH=/opt/julia/bin/julia
MCP_FILE_SERVER_BASE=/opt/mcp-data
SITE_NAME=production-east-1
MONITORING_ENABLED=true
BACKUP_ENABLED=true
```

### Multi-Environment Setup
You can use different configuration files for different environments:

```bash
# Development
ln -s .env.local.dev .env.local

# Staging
ln -s .env.site.staging .env.site

# Production
ln -s .env.site.production .env.site
```

## Security Benefits

### Credential Isolation
- Local credentials stay on your development machine
- Production credentials stay on production servers
- No sensitive data in git history

### Site Customization
- Each deployment can have different configurations
- No need to modify code for different environments
- Easy configuration management

### Default Safety
- All sensitive defaults are safe/empty
- Validation ensures required values are set
- Clear error messages for missing configuration

## Configuration Validation

The system validates configuration on startup:

- **Required fields**: `POSTGRES_PASSWORD` must be set
- **File paths**: Validates that specified paths exist
- **Julia path**: Ensures Julia executable is accessible
- **Directory permissions**: Checks write access where needed

## Migration from Environment Variables

If you're currently using environment variables directly:

```julia
# Old way
password = get(ENV, "POSTGRES_PASSWORD", "")

# New way
using .SiteConfig
SiteConfig.load_config(".")
password = SiteConfig.get_config("POSTGRES_PASSWORD")
```

## Best Practices

### For Development
1. Copy `.env.local.example` to `.env.local`
2. Set your actual database password
3. Use local paths for file storage
4. Enable debug modes for troubleshooting

### For Production
1. Copy `.env.site.example` to `.env.site`
2. Use strong passwords and secure hosts
3. Set appropriate resource limits
4. Enable monitoring and logging
5. Configure backup settings

### For Version Control
1. Never commit `.env.local` or `.env.site`
2. Keep templates (`.env.*.example`) updated
3. Document new configuration options
4. Use secure defaults in templates

## Environment Variables Override

Environment variables always have the highest precedence, allowing for:

```bash
# Override specific values at runtime
POSTGRES_PASSWORD=runtime_password julia server.jl

# Docker environment variables
docker run -e POSTGRES_PASSWORD=secure_pass mcp-server

# Kubernetes secrets
env:
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: mcp-secrets
        key: db-password
```

This system provides maximum flexibility while maintaining security and preventing accidental credential exposure.