#!/usr/bin/env julia

using HTTP
using JSON3
using Dates

println("🧪 Testing Claude Code ↔ Claude Desktop Communication Bridge")
println("=" ^ 60)

# Test 1: Health checks
println("\n📋 Test 1: Health Checks")
println("-" ^ 30)

# Test WSL Bridge health
try
    wsl_health = HTTP.get("http://localhost:8085/claude-bridge/health")
    wsl_result = JSON3.read(String(wsl_health.body))
    println("✅ WSL Claude Bridge: $(wsl_result["status"])")
catch e
    println("❌ WSL Claude Bridge: Failed - $e")
end

# Test Windows Bridge health
try
    windows_health = HTTP.get("http://localhost:8086/claude-bridge/health")
    windows_result = JSON3.read(String(windows_health.body))
    println("✅ Windows Claude Bridge: $(windows_result["status"])")
catch e
    println("❌ Windows Claude Bridge: Failed - $e")
end

# Test 2: Bridge Status
println("\n📊 Test 2: Bridge Status")
println("-" ^ 30)

try
    wsl_status = HTTP.get("http://localhost:8085/claude-bridge/status")
    wsl_status_result = JSON3.read(String(wsl_status.body))
    println("🌉 WSL Bridge ID: $(wsl_status_result["bridge_id"])")
    println("📈 Message History Count: $(wsl_status_result["message_history_count"])")
catch e
    println("❌ WSL Status check failed: $e")
end

try
    windows_status = HTTP.get("http://localhost:8086/claude-bridge/status") 
    windows_status_result = JSON3.read(String(windows_status.body))
    println("🪟 Windows Bridge ID: $(windows_status_result["bridge_id"])")
    println("🔗 Active Connections: $(windows_status_result["active_connections"])")
catch e
    println("❌ Windows Status check failed: $e")
end

# Test 3: Send test message from Claude Code to Windows Bridge
println("\n🚀 Test 3: Claude Code → Windows Bridge Communication")
println("-" ^ 50)

test_message = Dict(
    "bridge_id" => "test-bridge",
    "message_type" => "REQUEST_MCP_CALL",
    "request_id" => "test-$(hash(now()))",
    "timestamp" => string(now()),
    "payload" => Dict(
        "tool_name" => "mcp-db-admin-http:export_schema",
        "arguments" => Dict(),
        "timeout" => 30
    ),
    "sender" => "claude_code_test"
)

try
    response = HTTP.post("http://localhost:8086/claude-bridge/message",
        ["Content-Type" => "application/json"],
        JSON3.write(test_message)
    )
    
    if response.status == 200
        result = JSON3.read(String(response.body))
        println("✅ Test MCP call initiated: $(result["status"])")
        println("📋 Request ID: $(result["request_id"])")
    else
        println("❌ Test message failed: HTTP $(response.status)")
    end
catch e
    println("❌ Failed to send test message: $e")
end

# Test 4: Test Windows Bridge → WSL Bridge communication
println("\n🔄 Test 4: Windows Bridge → Claude Code Communication") 
println("-" ^ 50)

test_response_message = Dict(
    "bridge_id" => "test-windows-bridge", 
    "message_type" => "RESPONSE_MCP_RESULT",
    "request_id" => "test-response-$(hash(now()))",
    "timestamp" => string(now()),
    "payload" => Dict(
        "success" => true,
        "result" => Dict(
            "message" => "Test communication successful!",
            "data" => ["test", "data", "from", "windows"]
        )
    ),
    "sender" => "claude_desktop_test"
)

try
    response = HTTP.post("http://localhost:8085/claude-bridge/message",
        ["Content-Type" => "application/json"],
        JSON3.write(test_response_message)
    )
    
    if response.status == 200
        result = JSON3.read(String(response.body))
        println("✅ Test response processed: $(result["status"])")
        println("📋 Request ID: $(result["request_id"])")
    else
        println("❌ Test response failed: HTTP $(response.status)")  
    end
catch e
    println("❌ Failed to send test response: $e")
end

# Test 5: Verify message history
println("\n📜 Test 5: Message History Verification")
println("-" ^ 40)

try
    history = HTTP.get("http://localhost:8085/claude-bridge/history")
    history_result = JSON3.read(String(history.body))
    message_count = length(history_result["messages"])
    println("📊 WSL Bridge Message History: $message_count messages")
    
    if message_count > 0
        latest = history_result["messages"][end]
        println("🕒 Latest Message Type: $(latest["message_type"])")
        println("👤 Latest Sender: $(latest["sender"])")
    end
catch e
    println("❌ Failed to get message history: $e")
end

println("\n🎯 Bridge Communication Test Complete!")
println("=" ^ 60)