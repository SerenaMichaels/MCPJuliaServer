# MCP Server Wrapper for Julia HTTP Servers
param(
    [Parameter(Position=0)]
    [string]$ServerUrl = "http://172.27.85.131:8080"
)

# Read JSON-RPC requests from stdin
$input = [Console]::In.ReadToEnd()

try {
    $request = $input | ConvertFrom-Json
    
    # Handle MCP initialization
    if ($request.method -eq "initialize") {
        $response = @{
            jsonrpc = "2.0"
            id = $request.id
            result = @{
                protocolVersion = "2024-11-05"
                capabilities = @{
                    tools = @{}
                }
                serverInfo = @{
                    name = "mcp-julia-http"
                    version = "1.0.0"
                }
            }
        }
        Write-Output ($response | ConvertTo-Json -Depth 10)
        return
    }
    
    # Handle tools/list
    if ($request.method -eq "tools/list") {
        $toolsResponse = Invoke-RestMethod -Uri "$ServerUrl/mcp/tools/list" -Method POST
        $response = @{
            jsonrpc = "2.0"
            id = $request.id
            result = $toolsResponse.result
        }
        Write-Output ($response | ConvertTo-Json -Depth 10)
        return
    }
    
    # Handle tools/call
    if ($request.method -eq "tools/call") {
        $callResponse = Invoke-RestMethod -Uri "$ServerUrl/mcp/tools/call" -Method POST -ContentType "application/json" -Body ($request.params | ConvertTo-Json -Depth 10)
        $response = @{
            jsonrpc = "2.0" 
            id = $request.id
            result = $callResponse.result
        }
        Write-Output ($response | ConvertTo-Json -Depth 10)
        return
    }
    
    # Handle notifications
    if ($request.method -eq "notifications/initialized") {
        return
    }
    
    # Unknown method
    $error = @{
        jsonrpc = "2.0"
        id = $request.id
        error = @{
            code = -32601
            message = "Method not found: $($request.method)"
        }
    }
    Write-Output ($error | ConvertTo-Json -Depth 10)
    
} catch {
    $error = @{
        jsonrpc = "2.0"
        id = if($request.id) { $request.id } else { $null }
        error = @{
            code = -32603
            message = "Internal error: $($_.Exception.Message)"
        }
    }
    Write-Output ($error | ConvertTo-Json -Depth 10)
}