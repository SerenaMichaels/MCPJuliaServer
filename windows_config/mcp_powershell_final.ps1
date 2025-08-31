# MCP PowerShell wrapper - Final working version
param(
    [string]$ServerUrl = "http://172.27.85.131:8080"
)

# Read from stdin properly
$inputData = ""
if ($Host.UI.RawUI.KeyAvailable -eq $false) {
    # Running in pipe mode, read all input
    $inputData = [System.Console]::In.ReadToEnd()
} else {
    # Try alternative stdin reading
    $inputData = $input | Out-String
}

# If still empty, try reading line by line
if ([string]::IsNullOrWhiteSpace($inputData)) {
    $lines = @()
    while (($line = [System.Console]::ReadLine()) -ne $null) {
        $lines += $line
    }
    $inputData = $lines -join "`n"
}

try {
    $request = $inputData | ConvertFrom-Json
    
    if ($request.method -eq "initialize") {
        $response = @{
            jsonrpc = "2.0"
            id = $request.id
            result = @{
                protocolVersion = "2024-11-05"
                capabilities = @{ tools = @{} }
                serverInfo = @{ 
                    name = "mcp-julia-http"
                    version = "1.0.0" 
                }
            }
        }
        Write-Output ($response | ConvertTo-Json -Depth 10 -Compress)
        exit 0
    }
    
    if ($request.method -eq "tools/list") {
        $response = Invoke-RestMethod -Uri "$ServerUrl/mcp/tools/list" -Method POST -ContentType "application/json"
        $result = @{
            jsonrpc = "2.0"
            id = $request.id
            result = $response.result
        }
        Write-Output ($result | ConvertTo-Json -Depth 10 -Compress)
        exit 0
    }
    
    if ($request.method -eq "tools/call") {
        $callData = @{
            name = $request.params.name
            arguments = if ($request.params.arguments) { $request.params.arguments } else { @{} }
        }
        $body = $callData | ConvertTo-Json -Depth 10
        $response = Invoke-RestMethod -Uri "$ServerUrl/mcp/tools/call" -Method POST -ContentType "application/json" -Body $body
        $result = @{
            jsonrpc = "2.0"
            id = $request.id
            result = $response.result
        }
        Write-Output ($result | ConvertTo-Json -Depth 10 -Compress)
        exit 0
    }
    
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
    }
    Write-Output ($error | ConvertTo-Json -Depth 10 -Compress)
    exit 1
    
} catch {
    # Log error to stderr for debugging
    Write-Error "Error: $($_.Exception.Message)" -ErrorAction Continue
    
    $error = @{
        jsonrpc = "2.0"
        id = $null
        error = @{
            code = -32603
            message = "Internal error: $($_.Exception.Message)"
        }
    }
    Write-Output ($error | ConvertTo-Json -Depth 10 -Compress)
    exit 1
}