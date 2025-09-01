# MCP Server Wrapper for Julia HTTP Servers
param(
    [Parameter(Position=0)]
    [string]$ServerUrl = "http://172.27.85.131:8080"
)

# Read JSON input from stdin
$inputStream = [Console]::OpenStandardInput()
$reader = New-Object System.IO.StreamReader($inputStream)
$input = $reader.ReadToEnd()
$reader.Close()

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
        } | ConvertTo-Json -Depth 10
        Write-Output $response
        exit 0
    }
    
    # Handle tools/list
    if ($request.method -eq "tools/list") {
        $toolsResponse = Invoke-RestMethod -Uri "$ServerUrl/mcp/tools/list" -Method POST -ContentType "application/json"
        $response = @{
            jsonrpc = "2.0"
            id = $request.id
            result = $toolsResponse.result
        } | ConvertTo-Json -Depth 10
        Write-Output $response
        exit 0
    }
    
    # Handle tools/call
    if ($request.method -eq "tools/call") {
        $callBody = @{
            name = $request.params.name
            arguments = if($request.params.arguments) { $request.params.arguments } else { @{} }
        } | ConvertTo-Json -Depth 10
        
        $callResponse = Invoke-RestMethod -Uri "$ServerUrl/mcp/tools/call" -Method POST -ContentType "application/json" -Body $callBody
        $response = @{
            jsonrpc = "2.0" 
            id = $request.id
            result = $callResponse.result
        } | ConvertTo-Json -Depth 10
        Write-Output $response
        exit 0
    }
    
    # Handle notifications/initialized (no response needed)
    if ($request.method -eq "notifications/initialized") {
        exit 0
    }
    
    # Unknown method
    $error = @{
        jsonrpc = "2.0"
        id = $request.id
        error = @{
            code = -32601
            message = "Method not found: $($request.method)"
        }
    } | ConvertTo-Json -Depth 10
    Write-Output $error
    exit 1
    
} catch {
    $error = @{
        jsonrpc = "2.0"
        id = if($request -and $request.id) { $request.id } else { $null }
        error = @{
            code = -32603
            message = "Internal error: $($_.Exception.Message)"
        }
    } | ConvertTo-Json -Depth 10
    Write-Output $error
    exit 1
}