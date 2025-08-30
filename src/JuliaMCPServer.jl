module JuliaMCPServer

using JSON3
using UUIDs

export MCPServer, MCPTool, start_server, add_tool!

include("jsonrpc.jl")
include("mcp.jl")
include("server.jl")

end