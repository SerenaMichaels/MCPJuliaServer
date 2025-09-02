#!/usr/bin/env julia
"""
Claude Communication Bridge
Enables bidirectional MCP communication between Claude Code (WSL) and Claude Desktop (Windows)

Architecture:
┌─────────────────┐    HTTP/WebSocket    ┌─────────────────┐
│   Claude Code   │ ←─────────────────→ │ Claude Desktop  │
│     (WSL)       │                     │   (Windows)     │
└─────────────────┘                     └─────────────────┘
        ↕                                        ↕
┌─────────────────┐                     ┌─────────────────┐
│  Claude Bridge  │ ←─── TCP/HTTP ───→ │ Windows Bridge  │
│   MCP Server    │                     │   HTTP Proxy    │
│   (Port 8085)   │                     │   (Port 8086)   │
└─────────────────┘                     └─────────────────┘
"""

module ClaudeBridge

export start_claude_bridge, send_to_claude_desktop, register_claude_code_callback

using HTTP
using JSON3
using WebSockets
using Dates
using Logging

# Bridge configuration
mutable struct BridgeConfig
    wsl_port::Int
    windows_port::Int
    bridge_id::String
    claude_code_callbacks::Dict{String, Function}
    claude_desktop_callbacks::Dict{String, Function}
    active_connections::Dict{String, Any}
    message_history::Vector{Dict{String, Any}}
    
    BridgeConfig() = new(
        8085,  # WSL Claude Bridge port
        8086,  # Windows Bridge port (to be implemented)
        "claude-bridge-" * string(hash(now())),
        Dict{String, Function}(),
        Dict{String, Function}(),
        Dict{String, Any}(),
        Vector{Dict{String, Any}}()
    )
end

const BRIDGE = BridgeConfig()

"""
Message types for Claude-to-Claude communication
"""
@enum MessageType begin
    REQUEST_MCP_CALL      # Claude Code requests Claude Desktop to execute MCP tool
    RESPONSE_MCP_RESULT   # Claude Desktop responds with MCP tool result
    REQUEST_VALIDATION    # Claude Code asks Claude Desktop to validate something
    RESPONSE_VALIDATION   # Claude Desktop provides validation result
    REQUEST_FILE_CHECK    # Claude Code asks Claude Desktop about Windows file
    RESPONSE_FILE_STATUS  # Claude Desktop responds with file information
    BROADCAST_STATUS      # Either Claude broadcasts status to the other
    HEARTBEAT            # Connection keepalive
end

"""
Create a structured message for Claude-to-Claude communication
"""
function create_bridge_message(type::MessageType, payload::Dict, request_id::String = "")
    if isempty(request_id)
        request_id = "msg-" * string(hash(now()))
    end
    
    message = Dict(
        "bridge_id" => BRIDGE.bridge_id,
        "message_type" => string(type),
        "request_id" => request_id,
        "timestamp" => string(now()),
        "payload" => payload,
        "sender" => "claude_code_wsl"
    )
    
    push!(BRIDGE.message_history, message)
    return message
end

"""
Send message to Claude Desktop via Windows Bridge
"""
function send_to_claude_desktop(type::MessageType, payload::Dict; request_id::String = "")
    message = create_bridge_message(type, payload, request_id)
    
    try
        # Send HTTP request to Windows Bridge (to be implemented)
        windows_url = "http://localhost:$(BRIDGE.windows_port)/claude-bridge/message"
        
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
        BRIDGE.active_connections["pending_$(message["request_id"])"] = message
        return nothing
    end
end

"""
Handle incoming message from Claude Desktop
"""
function handle_claude_desktop_message(message_data::Dict)
    try
        message_type = MessageType(Symbol(message_data["message_type"]))
        request_id = message_data["request_id"]
        payload = message_data["payload"]
        
        @info "📨 Received message from Claude Desktop: $message_type ($request_id)"
        
        # Route message based on type
        if message_type == RESPONSE_MCP_RESULT
            # Handle MCP tool result from Claude Desktop
            handle_mcp_result(request_id, payload)
            
        elseif message_type == RESPONSE_VALIDATION
            # Handle validation result from Claude Desktop
            handle_validation_result(request_id, payload)
            
        elseif message_type == RESPONSE_FILE_STATUS
            # Handle file status from Claude Desktop
            handle_file_status(request_id, payload)
            
        elseif message_type == BROADCAST_STATUS
            # Handle status broadcast from Claude Desktop
            handle_status_broadcast(payload)
            
        elseif message_type == HEARTBEAT
            # Respond to heartbeat
            send_heartbeat_response()
            
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
Register callback for specific message types from Claude Desktop
"""
function register_claude_code_callback(message_type::String, callback::Function)
    BRIDGE.claude_code_callbacks[message_type] = callback
    @info "📝 Registered Claude Code callback for: $message_type"
end

"""
Handle MCP result from Claude Desktop
"""
function handle_mcp_result(request_id::String, payload::Dict)
    @info "🎯 MCP Result received from Claude Desktop: $request_id"
    
    # Execute registered callback if exists
    if haskey(BRIDGE.claude_code_callbacks, "mcp_result")
        BRIDGE.claude_code_callbacks["mcp_result"](request_id, payload)
    end
    
    # Store result for retrieval
    BRIDGE.active_connections["result_$request_id"] = payload
end

"""
Handle validation result from Claude Desktop
"""
function handle_validation_result(request_id::String, payload::Dict)
    @info "✅ Validation result from Claude Desktop: $request_id"
    
    if haskey(BRIDGE.claude_code_callbacks, "validation_result")
        BRIDGE.claude_code_callbacks["validation_result"](request_id, payload)
    end
    
    BRIDGE.active_connections["validation_$request_id"] = payload
end

"""
Handle file status from Claude Desktop
"""
function handle_file_status(request_id::String, payload::Dict)
    @info "📁 File status from Claude Desktop: $request_id"
    
    if haskey(BRIDGE.claude_code_callbacks, "file_status")
        BRIDGE.claude_code_callbacks["file_status"](request_id, payload)
    end
    
    BRIDGE.active_connections["file_$request_id"] = payload
end

"""
Handle status broadcast from Claude Desktop
"""
function handle_status_broadcast(payload::Dict)
    @info "📡 Status broadcast from Claude Desktop: $(get(payload, "status", "unknown"))"
    
    if haskey(BRIDGE.claude_code_callbacks, "status_broadcast")
        BRIDGE.claude_code_callbacks["status_broadcast"](payload)
    end
end

"""
Send heartbeat response to Claude Desktop
"""
function send_heartbeat_response()
    send_to_claude_desktop(HEARTBEAT, Dict(
        "status" => "alive",
        "bridge_id" => BRIDGE.bridge_id,
        "timestamp" => string(now())
    ))
end

"""
Start Claude Bridge HTTP server
"""
function start_claude_bridge(port::Int = 8085)
    @info "🌉 Starting Claude Communication Bridge on port $port"
    BRIDGE.wsl_port = port
    
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
                        "bridge_id" => BRIDGE.bridge_id,
                        "status" => "active",
                        "timestamp" => string(now()),
                        "connections" => length(BRIDGE.active_connections),
                        "message_history_count" => length(BRIDGE.message_history)
                    )
                    return HTTP.Response(200, JSON3.write(status))
                    
                elseif req.target == "/claude-bridge/history"
                    # Return message history
                    return HTTP.Response(200, JSON3.write(Dict(
                        "messages" => BRIDGE.message_history[max(1, end-50):end]  # Last 50 messages
                    )))
                    
                else
                    return HTTP.Response(404, "Bridge endpoint not found")
                end
                
            elseif req.method == "GET" && req.target == "/claude-bridge/health"
                # Health check
                return HTTP.Response(200, JSON3.write(Dict(
                    "status" => "healthy",
                    "bridge" => "Claude Communication Bridge",
                    "timestamp" => string(now())
                )))
                
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
        server = HTTP.serve(handle_bridge_request, "0.0.0.0", port)
        @info "✅ Claude Bridge server started successfully"
        @info "🌐 Bridge accessible at: http://localhost:$port/claude-bridge/health"
        @info "📊 Status endpoint: http://localhost:$port/claude-bridge/status"
        return server
        
    catch e
        @error "Failed to start Claude Bridge server: $e"
        rethrow(e)
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
    result = send_to_claude_desktop(REQUEST_MCP_CALL, payload, request_id = request_id)
    
    return (request_id, result)
end

"""
Request Claude Desktop to validate something
"""
function request_claude_desktop_validation(validation_type::String, data::Dict)
    request_id = "val-" * string(hash(now()))
    
    payload = Dict(
        "validation_type" => validation_type,
        "data" => data
    )
    
    @info "🔍 Requesting Claude Desktop validation: $validation_type"
    result = send_to_claude_desktop(REQUEST_VALIDATION, payload, request_id = request_id)
    
    return (request_id, result)
end

"""
Request Claude Desktop file status
"""
function request_claude_desktop_file_check(file_path::String)
    request_id = "file-" * string(hash(now()))
    
    payload = Dict(
        "file_path" => file_path,
        "check_type" => "status"
    )
    
    @info "📁 Requesting Claude Desktop file check: $file_path"
    result = send_to_claude_desktop(REQUEST_FILE_CHECK, payload, request_id = request_id)
    
    return (request_id, result)
end

end # module