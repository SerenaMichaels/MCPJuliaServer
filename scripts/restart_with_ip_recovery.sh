#!/usr/bin/env bash
"""
Restart MCP Servers with Smart IP Recovery
Automatically detects correct PostgreSQL host IP and restarts MCP servers
"""

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}🔄 MCP Server Restart with Smart IP Recovery${NC}"
echo "=" * 50

# Load environment
if [ -f "/mnt/d/MCP-Agents/configs/environment/master-environment.env" ]; then
    source /mnt/d/MCP-Agents/configs/environment/master-environment.env
    echo -e "${GREEN}✅ Environment loaded${NC}"
fi

cd /mnt/d/MCP-Agents/repos/MCPJuliaServers

echo -e "${YELLOW}🔍 Testing smart IP detection...${NC}"
/home/seren/julia-1.11.2/bin/julia --project=. test_smart_connection.jl

echo -e "${YELLOW}🛑 Stopping existing MCP servers...${NC}"

# Stop existing servers gracefully
pkill -f "http_postgres_server.jl" || echo "No postgres server running"
pkill -f "http_db_admin_server.jl" || echo "No db admin server running"
sleep 3

# Check if servers are stopped
if pgrep -f "http.*server.jl" > /dev/null; then
    echo -e "${RED}⚠️  Force killing remaining servers...${NC}"
    pkill -9 -f "http.*server.jl" || true
    sleep 2
fi

echo -e "${YELLOW}🚀 Starting PostgreSQL MCP server with smart IP recovery...${NC}"
MCP_HTTP_MODE=true MCP_HTTP_PORT=8080 nohup /home/seren/julia-1.11.2/bin/julia --project=. http_postgres_server.jl > postgres_server_recovery.log 2>&1 &
POSTGRES_PID=$!

echo -e "${YELLOW}🚀 Starting DB Admin MCP server...${NC}"
MCP_HTTP_MODE=true MCP_HTTP_PORT=8082 nohup /home/seren/julia-1.11.2/bin/julia --project=. http_db_admin_server.jl > db_admin_server_recovery.log 2>&1 &
DB_ADMIN_PID=$!

# Wait for servers to start
echo -e "${BLUE}⏳ Waiting for servers to initialize...${NC}"
sleep 10

# Test server health
echo -e "${BLUE}🏥 Testing server health...${NC}"

# Test PostgreSQL server
if curl -s http://localhost:8080/mcp/health > /dev/null; then
    echo -e "${GREEN}✅ PostgreSQL MCP Server (8080) - HEALTHY${NC}"
else
    echo -e "${RED}❌ PostgreSQL MCP Server (8080) - FAILED${NC}"
    echo "Log output:"
    tail -10 postgres_server_recovery.log
fi

# Test DB Admin server  
if curl -s http://localhost:8082/mcp/health > /dev/null; then
    echo -e "${GREEN}✅ DB Admin MCP Server (8082) - HEALTHY${NC}"
else
    echo -e "${RED}❌ DB Admin MCP Server (8082) - FAILED${NC}"
    echo "Log output:"
    tail -10 db_admin_server_recovery.log
fi

echo -e "${BLUE}📊 Server Status Summary:${NC}"
echo "PostgreSQL Server PID: $POSTGRES_PID"
echo "DB Admin Server PID: $DB_ADMIN_PID"
echo ""
echo -e "${GREEN}🎯 MCP Servers restarted with smart IP recovery!${NC}"
echo -e "${YELLOW}💡 Tip: Use 'julia monitor_db_connection.jl' to continuously monitor for IP changes${NC}"