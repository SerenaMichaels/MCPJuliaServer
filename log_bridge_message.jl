#!/usr/bin/env julia
"""
A-BRIDGE Message Logger
Logs autonomous communication messages for diagnostics and audit trails
"""

using HTTP
using JSON3
using Dates

"""
Log A-BRIDGE message to database for diagnostics
"""
function log_bridge_message(session_id, message_type, classification, sender, recipient, message_content, payload_dict; bridge_id="", request_id="", human_action_needed=false)
    
    # Prepare SQL insert
    sql_data = Dict(
        "query" => """
        INSERT INTO claude_bridge_messages 
        (session_id, message_type, classification, sender, recipient, bridge_id, request_id, message_content, payload, human_action_needed)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10)
        RETURNING id, timestamp;
        """,
        "parameters" => [
            session_id,
            message_type, 
            classification,
            sender,
            recipient,
            bridge_id,
            request_id,
            message_content,
            JSON3.write(payload_dict),
            human_action_needed
        ],
        "database" => "botfarm"
    )
    
    try
        # Execute SQL via MCP
        response = HTTP.post("http://localhost:8080/mcp/tools/call",
            ["Content-Type" => "application/json"],
            JSON3.write(Dict(
                "name" => "execute_sql",
                "arguments" => sql_data
            ))
        )
        
        if response.status == 200
            result = JSON3.read(String(response.body))
            println("✅ A-BRIDGE message logged: $(classification) - $(message_type)")
            return true
        else
            println("❌ Failed to log A-BRIDGE message: HTTP $(response.status)")
            return false
        end
        
    catch e
        println("❌ Error logging A-BRIDGE message: $e")
        return false
    end
end

"""
Send A-BRIDGE message with automatic logging
"""
function send_a_bridge_message(recipient, message_content, task_context="", progress_update="", next_step="")
    
    # Generate message components
    bridge_id = "a-bridge-$(hash(now()))"
    request_id = "auto-$(hash(now()))"
    
    payload = Dict(
        "classification" => "A-BRIDGE",
        "task_context" => task_context,
        "message" => message_content,
        "progress_update" => progress_update,
        "next_step" => next_step,
        "timestamp" => string(now()),
        "human_action_needed" => false
    )
    
    # Send to bridge
    bridge_message = Dict(
        "bridge_id" => bridge_id,
        "message_type" => "BROADCAST_STATUS",
        "request_id" => request_id,
        "timestamp" => string(now()),
        "payload" => payload,
        "sender" => "claude_code_wsl"
    )
    
    try
        # Send to Windows bridge
        response = HTTP.post("http://localhost:8086/claude-bridge/message",
            ["Content-Type" => "application/json"],
            JSON3.write(bridge_message)
        )
        
        # Log to database for diagnostics
        log_success = log_bridge_message(
            "0008",
            "BROADCAST_STATUS", 
            "A-BRIDGE",
            "claude_code_wsl",
            recipient,
            message_content,
            payload,
            bridge_id = bridge_id,
            request_id = request_id,
            human_action_needed = false
        )
        
        if response.status == 200 && log_success
            println("✅ A-BRIDGE message sent and logged successfully")
            return true
        else
            println("⚠️  A-BRIDGE message sent but logging failed")
            return false
        end
        
    catch e
        println("❌ Failed to send A-BRIDGE message: $e")
        return false
    end
end

"""
Send H-LOOP message with automatic logging
"""
function send_h_loop_message(message_content, reason, context, next_decision_needed="")
    
    bridge_id = "h-loop-$(hash(now()))"
    request_id = "strategic-$(hash(now()))"
    
    payload = Dict(
        "classification" => "H-LOOP",
        "reason" => reason,
        "message" => message_content,
        "context" => context,
        "human_action_needed" => true,
        "next_decision_needed" => next_decision_needed,
        "timestamp" => string(now())
    )
    
    bridge_message = Dict(
        "bridge_id" => bridge_id,
        "message_type" => "BROADCAST_STATUS", 
        "request_id" => request_id,
        "timestamp" => string(now()),
        "payload" => payload,
        "sender" => "claude_code_wsl"
    )
    
    try
        # Send to Windows bridge
        response = HTTP.post("http://localhost:8086/claude-bridge/message",
            ["Content-Type" => "application/json"],
            JSON3.write(bridge_message)
        )
        
        # Log to database
        log_success = log_bridge_message(
            "0008",
            "BROADCAST_STATUS",
            "H-LOOP", 
            "claude_code_wsl",
            "claude_desktop_windows",
            message_content,
            payload,
            bridge_id = bridge_id,
            request_id = request_id,
            human_action_needed = true
        )
        
        if response.status == 200 && log_success
            println("🚨 H-LOOP message sent and logged - Human notification required!")
            return true
        else
            println("⚠️  H-LOOP message sent but logging failed")
            return false
        end
        
    catch e
        println("❌ Failed to send H-LOOP message: $e")
        return false
    end
end

# Example usage
if abspath(PROGRAM_FILE) == @__FILE__
    println("Testing A-BRIDGE logging system...")
    
    # Test A-BRIDGE message
    send_a_bridge_message(
        "claude_desktop_windows",
        "Testing enhanced A-BRIDGE logging system with database persistence",
        "Diagnostic System Testing",
        "A-BRIDGE logging system implemented and ready for testing",
        "Validate message appears in claude_bridge_messages table"
    )
    
    println("✅ A-BRIDGE logging test complete!")
end