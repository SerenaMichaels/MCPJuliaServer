struct MCPTool
    name::String
    description::String
    input_schema::Dict{String,Any}
    handler::Function
end

struct MCPServerInfo
    name::String
    version::String
    description::String
end

mutable struct MCPServer
    info::MCPServerInfo
    tools::Dict{String, MCPTool}
    
    function MCPServer(name::String, version::String, description::String)
        new(MCPServerInfo(name, version, description), Dict{String, MCPTool}())
    end
end

function add_tool!(server::MCPServer, tool::MCPTool)
    server.tools[tool.name] = tool
end

function handle_initialize(server::MCPServer, params::Union{Dict{String,Any}, Nothing})
    return Dict{String,Any}(
        "protocolVersion" => "2024-11-05",
        "capabilities" => Dict{String,Any}(
            "tools" => Dict{String,Any}()
        ),
        "serverInfo" => Dict{String,Any}(
            "name" => server.info.name,
            "version" => server.info.version,
            "description" => server.info.description
        )
    )
end

function handle_tools_list(server::MCPServer, params::Union{Dict{String,Any}, Nothing})
    tools_list = []
    for (name, tool) in server.tools
        push!(tools_list, Dict{String,Any}(
            "name" => tool.name,
            "description" => tool.description,
            "inputSchema" => tool.input_schema
        ))
    end
    
    return Dict{String,Any}("tools" => tools_list)
end

function handle_tools_call(server::MCPServer, params::Union{Dict{String,Any}, Nothing})
    if params === nothing || !haskey(params, "name")
        return create_jsonrpc_error(-32602, "Invalid params: missing tool name", nothing)
    end
    
    tool_name = params["name"]
    tool_arguments = get(params, "arguments", Dict{String,Any}())
    
    if !haskey(server.tools, tool_name)
        return create_jsonrpc_error(-32601, "Tool not found: $tool_name", nothing)
    end
    
    tool = server.tools[tool_name]
    
    try
        result = tool.handler(tool_arguments)
        return Dict{String,Any}(
            "content" => [
                Dict{String,Any}(
                    "type" => "text",
                    "text" => string(result)
                )
            ]
        )
    catch e
        @error "Tool execution failed" tool=tool_name exception=e
        return create_jsonrpc_error(-32000, "Tool execution failed: $(string(e))", nothing)
    end
end

function handle_mcp_request(server::MCPServer, request::JSONRPCRequest)
    try
        if request.method == "initialize"
            result = handle_initialize(server, request.params)
            return create_jsonrpc_response(result, request.id)
        elseif request.method == "tools/list"
            result = handle_tools_list(server, request.params)
            return create_jsonrpc_response(result, request.id)
        elseif request.method == "tools/call"
            result = handle_tools_call(server, request.params)
            if result isa JSONRPCResponse
                return result
            else
                return create_jsonrpc_response(result, request.id)
            end
        else
            return create_jsonrpc_error(-32601, "Method not found: $(request.method)", request.id)
        end
    catch e
        @error "Error handling MCP request" method=request.method exception=e
        return create_jsonrpc_error(-32603, "Internal error", request.id)
    end
end