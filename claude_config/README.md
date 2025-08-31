# Claude Desktop MCP Configuration

This directory contains configuration files to enable Claude Desktop to directly access and use the MCP Julia Server suite.

## Quick Setup

### Automated Setup (Recommended)
```bash
# Run the setup script
./claude_config/setup_claude_config.sh
```

The script will:
- Load your existing site configuration
- Create a Claude-compatible configuration file
- Install it to the appropriate Claude Desktop location
- Test server accessibility

### Manual Setup
1. Copy and edit the template:
   ```bash
   cp claude_config/claude_desktop_config_template.json claude_config/claude_desktop_config.json
   # Edit the file with your specific paths and credentials
   ```

2. Copy to Claude Desktop config location:
   ```bash
   # Linux
   cp claude_config/claude_desktop_config.json ~/.config/Claude/claude_desktop_config.json
   
   # macOS
   cp claude_config/claude_desktop_config.json ~/Library/Application\ Support/Claude/claude_desktop_config.json
   
   # Windows
   copy claude_config\claude_desktop_config.json %APPDATA%\Claude\claude_desktop_config.json
   ```

3. Restart Claude Desktop

## Available MCP Servers

Once configured, Claude will have access to these MCP servers:

### 📊 mcp-postgres-server
**Capabilities:**
- Execute SQL queries with advanced filtering
- Database introspection (list tables, describe schemas)
- Transaction management
- Complex joins and aggregations
- Data analysis and reporting

**Example Usage:**
```
"List all tables in the database"
"Execute this SQL query: SELECT * FROM users WHERE created_at > '2024-01-01'"
"Describe the structure of the products table"
```

### 📁 mcp-file-server  
**Capabilities:**
- Read and write files with security controls
- Directory management and navigation
- Cross-platform file operations
- File system introspection
- Secure path validation

**Example Usage:**
```
"Read the contents of /path/to/data.csv"
"Create a new directory called 'reports'"
"Write this data to a file called analysis.json"
"List all files in the current directory"
```

### 🔧 mcp-db-admin-server
**Capabilities:**
- Database creation and management
- User and permission management
- Schema import/export operations
- CSV data import with automatic table creation
- Table creation from JSON schemas
- Database migration tools

**Example Usage:**
```
"Create a new database called 'analytics'"
"Create a user 'analyst' with read-only permissions"
"Import this CSV file into a new table"
"Export the schema of the production database"
```

## Configuration Files

### `claude_desktop_config.json`
Your active Claude Desktop configuration (not committed to git for security).

### `claude_desktop_config_template.json`
Template with placeholders that the setup script uses.

### `claude_desktop_config_local.json`
Your local development configuration with actual credentials.

## Security Considerations

- **Local Configuration**: The actual configuration file contains your database credentials and is not committed to git
- **Template Only**: Only the template with placeholders is version controlled
- **Secure Defaults**: All sensitive values must be explicitly configured
- **Path Validation**: File operations are restricted to safe directories

## Troubleshooting

### Common Issues

**"MCP server failed to start"**
- Check that Julia is installed and in PATH
- Verify server file paths are correct
- Ensure PostgreSQL is running and accessible
- Check database credentials

**"Permission denied errors"**
- Verify file paths have correct permissions
- Check that `MCP_FILE_SERVER_BASE` directory exists and is writable
- Ensure Julia has access to the project directory

**"Database connection failed"**
- Confirm PostgreSQL is running
- Verify host, port, username, and password
- Check firewall settings if using remote database
- Test connection manually: `psql -h host -U user -d database`

### Testing Server Connectivity

Test each server manually:

```bash
# Test PostgreSQL server
julia --project=/path/to/server /path/to/server/postgres_example.jl

# Test file server  
julia --project=/path/to/server /path/to/server/file_server_example.jl

# Test database admin server
julia --project=/path/to/server /path/to/server/db_admin_example.jl
```

### Viewing Claude Desktop Logs

Check Claude Desktop logs for detailed error information:

- **Linux**: Check system logs or Claude application logs
- **macOS**: `~/Library/Logs/Claude/`  
- **Windows**: Check Event Viewer or Claude application logs

### Updating Configuration

To update your configuration:

1. Edit `claude_config/claude_desktop_config.json`
2. Restart Claude Desktop application
3. Test functionality with a simple request

Or re-run the setup script to regenerate configuration:
```bash
./claude_config/setup_claude_config.sh
```

## Advanced Configuration

### Custom Server Locations
If you installed the servers in a different location, update the paths in the configuration:

```json
{
  "mcpServers": {
    "mcp-postgres-server": {
      "args": [
        "--project=/custom/path/to/server",
        "/custom/path/to/server/postgres_example.jl"
      ]
    }
  }
}
```

### Environment Variables
You can override configuration using environment variables:

```json
{
  "env": {
    "POSTGRES_HOST": "production-db.company.com",
    "POSTGRES_PASSWORD": "production_password",
    "MCP_FILE_SERVER_BASE": "/production/data/path"
  }
}
```

### Development vs Production
Use different configuration files for different environments:

```bash
# Development
cp claude_desktop_config_dev.json ~/.config/Claude/claude_desktop_config.json

# Production
cp claude_desktop_config_prod.json ~/.config/Claude/claude_desktop_config.json
```

## Integration Examples

### Data Analysis Workflow
```
1. "List all tables in the analytics database"
2. "Describe the structure of the sales_data table"  
3. "Execute this query: SELECT product, SUM(revenue) FROM sales_data GROUP BY product ORDER BY revenue DESC"
4. "Save these results to a file called product_revenue.csv"
```

### ETL Pipeline
```
1. "Read the raw data from /data/imports/daily_sales.csv"
2. "Create a new table called processed_sales with these columns: [schema]"
3. "Import the CSV data into the processed_sales table"
4. "Execute data validation queries to check for consistency"
```

### Database Migration
```
1. "Export the schema from the legacy_system database"
2. "Create a new database called modern_system"
3. "Import the schema into the new database"
4. "Migrate data from legacy_system.customers to modern_system.customers"
```

This configuration provides Claude with powerful database and file system capabilities while maintaining security and flexibility.