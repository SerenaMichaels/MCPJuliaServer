#!/usr/bin/env julia

using HTTP
using JSON3
using Dates
using Logging

# Bridge configuration
const BRIDGE_CONFIG = Dict(
    "wsl_port" => 8085,
    "windows_port" => 8086,
    "bridge_id" => "claude-bridge-" * string(hash(now())),
    "message_history" => Dict{String, Any}[],
    "active_connections" => Dict{String, Any}(),
    "windows_bridge_url" => "http://localhost:8086"
)

# Message types for Claude-to-Claude communication
const MESSAGE_TYPES = [
    "REQUEST_MCP_CALL",      # Claude Code requests Claude Desktop to execute MCP tool
    "RESPONSE_MCP_RESULT",   # Claude Desktop responds with MCP tool result
    "REQUEST_VALIDATION",    # Claude Code asks Claude Desktop to validate something
    "RESPONSE_VALIDATION",   # Claude Desktop provides validation result
    "REQUEST_FILE_CHECK",    # Claude Code asks Claude Desktop about Windows file
    "RESPONSE_FILE_STATUS",  # Claude Desktop responds with file information
    "BROADCAST_STATUS",      # Either Claude broadcasts status to the other
    "HEARTBEAT"             # Connection keepalive
]

"""
Create a structured message for Claude-to-Claude communication
"""
function create_bridge_message(type::String, payload::Dict, request_id::String = "")
    if isempty(request_id)
        request_id = "msg-" * string(hash(now()))
    end
    
    message = Dict(
        "bridge_id" => BRIDGE_CONFIG["bridge_id"],
        "message_type" => type,
        "request_id" => request_id,
        "timestamp" => string(now()),
        "payload" => payload,
        "sender" => "claude_code_wsl"
    )
    
    push!(BRIDGE_CONFIG["message_history"], message)
    return message
end

"""
Send message to Claude Desktop via Windows Bridge
"""
function send_to_claude_desktop(type::String, payload::Dict; request_id::String = "")
    message = create_bridge_message(type, payload, request_id)
    
    try
        # Send HTTP request to Windows Bridge
        windows_url = BRIDGE_CONFIG["windows_bridge_url"] * "/claude-bridge/message"
        
        response = HTTP.post(windows_url, 
            ["Content-Type" => "application/json"],
            JSON3.write(message),
            timeout = 30
        )
        
        if response.status == 200
            result = JSON3.read(String(response.body))
            @info "✅ Message sent to Claude Desktop: $(message["request_id"])"
            return result
        else
            @error "❌ Failed to send message to Claude Desktop: HTTP $(response.status)"
            return nothing
        end
        
    catch e
        @warn "🔄 Windows Bridge not available, storing message for later: $e"
        # Store message for when bridge becomes available
        BRIDGE_CONFIG["active_connections"]["pending_$(message["request_id"])"] = message
        return nothing
    end
end

"""
Handle incoming message from Claude Desktop
"""
function handle_claude_desktop_message(message_data::Dict)
    try
        message_type = message_data["message_type"]
        request_id = message_data["request_id"]
        payload = message_data["payload"]
        
        @info "📨 Received message from Claude Desktop: $message_type ($request_id)"
        
        # Route message based on type
        if message_type == "RESPONSE_MCP_RESULT"
            # Handle MCP tool result from Claude Desktop
            @info "🎯 MCP Result received from Claude Desktop: $request_id"
            BRIDGE_CONFIG["active_connections"]["result_$request_id"] = payload
            
        elseif message_type == "RESPONSE_VALIDATION"
            # Handle validation result from Claude Desktop
            @info "✅ Validation result from Claude Desktop: $request_id"
            BRIDGE_CONFIG["active_connections"]["validation_$request_id"] = payload
            
        elseif message_type == "RESPONSE_FILE_STATUS"
            # Handle file status from Claude Desktop
            @info "📁 File status from Claude Desktop: $request_id"
            BRIDGE_CONFIG["active_connections"]["file_$request_id"] = payload
            
        elseif message_type == "BROADCAST_STATUS"
            # Handle status broadcast from Claude Desktop
            @info "📡 Status broadcast from Claude Desktop: $(get(payload, "status", "unknown"))"
            
        elseif message_type == "HEARTBEAT"
            # Respond to heartbeat
            send_to_claude_desktop("HEARTBEAT", Dict(
                "status" => "alive",
                "bridge_id" => BRIDGE_CONFIG["bridge_id"],
                "timestamp" => string(now())
            ))
            
        else
            @warn "Unknown message type from Claude Desktop: $message_type"
        end
        
        return Dict("status" => "processed", "request_id" => request_id)
        
    catch e
        @error "Failed to handle Claude Desktop message: $e"
        return Dict("status" => "error", "error" => string(e))
    end
end

"""
Request Claude Desktop to execute an MCP tool
"""
function request_claude_desktop_mcp(tool_name::String, arguments::Dict; timeout::Int = 60)
    request_id = "mcp-" * string(hash(now()))
    
    payload = Dict(
        "tool_name" => tool_name,
        "arguments" => arguments,
        "timeout" => timeout
    )
    
    @info "🚀 Requesting Claude Desktop MCP call: $tool_name"
    result = send_to_claude_desktop("REQUEST_MCP_CALL", payload, request_id = request_id)
    
    return (request_id, result)
end

"""
Start Claude Bridge HTTP server
"""
function start_claude_bridge(port::Int = 8085)
    @info "🌉 Starting Claude Communication Bridge on port $port"
    BRIDGE_CONFIG["wsl_port"] = port
    
    # Define HTTP routes for bridge communication
    function handle_bridge_request(req::HTTP.Request)
        try
            if req.method == "POST" && startswith(req.target, "/claude-bridge")
                
                if req.target == "/claude-bridge/message"
                    # Handle incoming message from Claude Desktop
                    message_data = JSON3.read(String(req.body))
                    result = handle_claude_desktop_message(message_data)
                    return HTTP.Response(200, JSON3.write(result))
                    
                elseif req.target == "/claude-bridge/status"
                    # Return bridge status
                    status = Dict(
                        "bridge_id" => BRIDGE_CONFIG["bridge_id"],
                        "status" => "active",
                        "timestamp" => string(now()),
                        "connections" => length(BRIDGE_CONFIG["active_connections"]),
                        "message_history_count" => length(BRIDGE_CONFIG["message_history"])
                    )
                    return HTTP.Response(200, JSON3.write(status))
                    
                elseif req.target == "/claude-bridge/history"
                    # Return message history
                    messages = BRIDGE_CONFIG["message_history"]
                    recent_messages = length(messages) > 50 ? messages[end-49:end] : messages
                    return HTTP.Response(200, JSON3.write(Dict(
                        "messages" => recent_messages
                    )))
                    
                else
                    return HTTP.Response(404, "Bridge endpoint not found")
                end
                
            elseif req.method == "GET" && startswith(req.target, "/claude-bridge")
                
                if req.target == "/claude-bridge/health"
                    # Health check
                    return HTTP.Response(200, JSON3.write(Dict(
                        "status" => "healthy",
                        "bridge" => "Claude Communication Bridge",
                        "timestamp" => string(now())
                    )))
                    
                elseif req.target == "/claude-bridge/status"
                    # Status check for GET requests too
                    status = Dict(
                        "bridge_id" => BRIDGE_CONFIG["bridge_id"],
                        "status" => "active", 
                        "timestamp" => string(now()),
                        "connections" => length(BRIDGE_CONFIG["active_connections"]),
                        "message_history_count" => length(BRIDGE_CONFIG["message_history"])
                    )
                    return HTTP.Response(200, JSON3.write(status))
                    
                elseif req.target == "/claude-bridge/history"
                    # History for GET requests  
                    messages = BRIDGE_CONFIG["message_history"]
                    recent_messages = length(messages) > 50 ? messages[end-49:end] : messages
                    return HTTP.Response(200, JSON3.write(Dict(
                        "messages" => recent_messages
                    )))
                    
                else
                    return HTTP.Response(404, "Bridge endpoint not found")
                end
                
            else
                return HTTP.Response(404, "Not found")
            end
            
        catch e
            @error "Bridge request error: $e"
            return HTTP.Response(500, JSON3.write(Dict("error" => string(e))))
        end
    end
    
    # Start HTTP server
    try
        @info "✅ Claude Bridge server started successfully"
        @info "🌐 Bridge accessible at: http://localhost:$port/claude-bridge/health"
        @info "📊 Status endpoint: http://localhost:$port/claude-bridge/status"
        
        return HTTP.serve(handle_bridge_request, "0.0.0.0", port)
        
    catch e
        @error "Failed to start Claude Bridge server: $e"
        rethrow(e)
    end
end

# Start the bridge if this script is run directly
if abspath(PROGRAM_FILE) == @__FILE__
    println("🌉 Starting Claude Communication Bridge...")
    server = start_claude_bridge(8085)
    println("🎯 Claude Bridge running! Press Ctrl+C to stop")
    wait()
end