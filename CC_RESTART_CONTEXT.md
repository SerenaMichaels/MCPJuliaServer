# 🔧 CLAUDE CODE (CC) RESTART CONTEXT

## 🆔 **WHO I AM**
- **I am:** Claude Code (CC)
- **Environment:** WSL Linux environment  
- **Partner:** Claude Desktop (CD) on Windows - ACTIVE collaboration
- **Role:** Backend infrastructure, Julia/database operations, WSL-side development
- **Project:** BotFarm - Revolutionary AI-to-AI Collaboration System

## 🏗️ **MCP SERVER ENHANCEMENT PATTERN - CRITICAL PROCEDURE**

### ⚡ **FOUNDATIONAL PRINCIPLE**
**NEVER CREATE SIDE SCRIPTS - ALWAYS ENHANCE MCP SERVERS DIRECTLY**

When I need new functionality:
1. ✅ **DO:** Add tools/functions directly to existing MCP servers
2. ❌ **DON'T:** Create temporary Julia scripts in /tmp
3. ✅ **DO:** Follow the established server architecture pattern
4. ❌ **DON'T:** Use quick workarounds that bypass proper server infrastructure

### 📋 **MCP SERVER ENHANCEMENT PROCEDURE**

#### Step 1: Identify Target Server
- **PostgreSQL MCP:** `/mnt/d/MCP-Agents/repos/MCPJuliaServers/http_postgres_server.jl`
- **File Operations:** `/mnt/d/MCP-Agents/repos/MCPJuliaServers/http_file_server.jl`
- **Database Admin:** `/mnt/d/MCP-Agents/repos/MCPJuliaServers/http_db_admin_server.jl`

#### Step 2: Add Tool Definition to TOOLS Array
```julia
# Location: Line ~143 in http_postgres_server.jl
const TOOLS = [
    # ... existing tools ...
    Dict(
        "name" => "your_new_tool",
        "description" => "Clear description of functionality",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "required_param" => Dict(
                    "type" => "string",
                    "description" => "Parameter description"
                )
            ),
            "required" => ["required_param"]
        )
    )
]
```

#### Step 3: Implement Tool Function
```julia
# Location: After existing tool functions (~line 745)
function your_new_tool_function(args::Dict)
    # Validate inputs
    param = get(args, "required_param", "")
    if isempty(param)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "required_param is required"
        ))
    end
    
    try
        # Database connection
        conn = get_connection()
        
        # Your functionality here
        result = # ... implementation
        
        return JSON3.write(Dict(
            "success" => true,
            # ... result data
        ))
        
    catch e
        error_msg = "Failed to execute: $(string(e))"
        @error error_msg
        return JSON3.write(Dict(
            "success" => false,
            "error" => error_msg
        ))
    end
end
```

#### Step 4: Add Tool to Request Handler
```julia
# Location: In handle_mcp_request function (~line 867)
elseif tool_name == "your_new_tool"
    your_new_tool_function(tool_args)
```

#### Step 5: Restart Server
```bash
# Kill existing server
pkill -f http_postgres_server

# Restart with environment variables
MCP_HTTP_MODE=true MCP_HTTP_PORT=8080 MCP_HTTP_HOST=0.0.0.0 \
/home/seren/julia-1.11.2/bin/julia --project=. http_postgres_server.jl > postgres_server.log 2>&1 &
```

#### Step 6: Test New Functionality
```bash
curl -s -X POST http://172.27.85.131:8080/mcp/tools/call \
  -H "Content-Type: application/json" \
  -d '{
    "name": "your_new_tool",
    "arguments": {
      "required_param": "test_value"
    }
  }' | python3 -m json.tool
```

### 🎯 **SUCCESSFUL IMPLEMENTATION EXAMPLE**

**Created:** `send_bridge_message` tool for AI-to-AI communication

**What it accomplishes:**
- Direct database communication between CC and CD
- Proper schema management (auto-creates missing columns)
- Structured message format with priority/category
- Eliminates need for temporary scripts

**Usage:**
```bash
curl -s -X POST http://172.27.85.131:8080/mcp/tools/call \
  -H "Content-Type: application/json" \
  -d '{
    "name": "send_bridge_message",
    "arguments": {
      "session_id": "0008",
      "from": "CC",
      "to": "CD",
      "subject": "Message Subject",
      "message": "Message content",
      "priority": "HIGH",
      "category": "category_name"
    }
  }'
```

**Result:** Message stored in database with ID, retrievable by CD via their MCP server.

## 🚀 **SERVER STATUS & ENDPOINTS**

**PostgreSQL MCP Server:**
- **Host:** 172.27.85.131:8080
- **Health:** `GET http://172.27.85.131:8080/mcp/health`
- **Tools List:** `POST http://172.27.85.131:8080/mcp/tools/list`
- **Tool Call:** `POST http://172.27.85.131:8080/mcp/tools/call`

**Available Tools:**
- `execute_sql` - Direct SQL execution
- `send_bridge_message` - AI-to-AI communication
- `log_accomplishment` - Session progress tracking
- `note_next_step` - Task management
- `get_session_status` - Session overview
- `list_tables` - Database schema exploration
- `describe_table` - Table structure analysis

## 🎯 **CURRENT PROJECT STATUS**

**Session 0008 Focus:** Direct Blender MCP connection and 3D object creation
- ✅ Bridge communication: FULLY FUNCTIONAL
- ✅ Database schema issues: RESOLVED
- ✅ MCP server enhancement pattern: ESTABLISHED
- ⏳ Current: CD testing botfarm-blender-direct MCP server (development mode)
- 🎪 Goal: Create visible 3D objects in Serena's running Blender instance

**Key Achievement:** Established permanent infrastructure enhancement pattern instead of temporary workarounds.

---
**This pattern ensures sustainable, maintainable development that builds on our foundational tools.**