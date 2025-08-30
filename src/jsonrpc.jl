struct JSONRPCRequest
    jsonrpc::String
    method::String
    params::Union{Dict{String,Any}, Vector{Any}, Nothing}
    id::Union{String, Int, Nothing}
end

struct JSONRPCResponse
    jsonrpc::String
    result::Union{Dict{String,Any}, Vector{Any}, Nothing}
    error::Union{Dict{String,Any}, Nothing}
    id::Union{String, Int, Nothing}
end

struct JSONRPCError
    code::Int
    message::String
    data::Union{Dict{String,Any}, Nothing}
end

function parse_jsonrpc_request(json_str::String)
    try
        data = JSON3.read(json_str, Dict{String,Any})
        return JSONRPCRequest(
            get(data, "jsonrpc", "2.0"),
            data["method"],
            get(data, "params", nothing),
            get(data, "id", nothing)
        )
    catch e
        @error "Failed to parse JSON-RPC request" exception=e
        return nothing
    end
end

function create_jsonrpc_response(result::Any, id::Union{String, Int, Nothing})
    return JSONRPCResponse("2.0", result, nothing, id)
end

function create_jsonrpc_error(code::Int, message::String, id::Union{String, Int, Nothing}, data=nothing)
    error_obj = JSONRPCError(code, message, data)
    return JSONRPCResponse("2.0", nothing, Dict("code" => code, "message" => message, "data" => data), id)
end

function serialize_jsonrpc_response(response::JSONRPCResponse)
    result = Dict{String,Any}(
        "jsonrpc" => response.jsonrpc,
        "id" => response.id
    )
    
    if response.error !== nothing
        result["error"] = response.error
    else
        result["result"] = response.result
    end
    
    return JSON3.write(result)
end