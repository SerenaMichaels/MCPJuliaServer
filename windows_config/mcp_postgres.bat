@echo off
setlocal enabledelayedexpansion

REM Read stdin input into a variable
set "input="
for /f "delims=" %%i in ('powershell -Command "Get-Content -Raw -Path \"con\""') do set "input=%%i"

REM Process with PowerShell
powershell -ExecutionPolicy Bypass -Command ^
"$input = $env:input; ^
try { ^
  $request = $input | ConvertFrom-Json; ^
  if ($request.method -eq 'initialize') { ^
    $response = @{ ^
      jsonrpc = '2.0'; ^
      id = $request.id; ^
      result = @{ ^
        protocolVersion = '2024-11-05'; ^
        capabilities = @{ tools = @{} }; ^
        serverInfo = @{ name = 'mcp-julia-http'; version = '1.0.0' } ^
      } ^
    } | ConvertTo-Json -Depth 10; ^
    Write-Output $response; ^
  } elseif ($request.method -eq 'tools/list') { ^
    $toolsResponse = Invoke-RestMethod -Uri 'http://172.27.85.131:8080/mcp/tools/list' -Method POST -ContentType 'application/json'; ^
    $response = @{ jsonrpc = '2.0'; id = $request.id; result = $toolsResponse.result } | ConvertTo-Json -Depth 10; ^
    Write-Output $response; ^
  } elseif ($request.method -eq 'tools/call') { ^
    $callBody = @{ name = $request.params.name; arguments = if($request.params.arguments) { $request.params.arguments } else { @{} } } | ConvertTo-Json -Depth 10; ^
    $callResponse = Invoke-RestMethod -Uri 'http://172.27.85.131:8080/mcp/tools/call' -Method POST -ContentType 'application/json' -Body $callBody; ^
    $response = @{ jsonrpc = '2.0'; id = $request.id; result = $callResponse.result } | ConvertTo-Json -Depth 10; ^
    Write-Output $response; ^
  } elseif ($request.method -eq 'notifications/initialized') { ^
    exit 0; ^
  } else { ^
    $error = @{ jsonrpc = '2.0'; id = $request.id; error = @{ code = -32601; message = 'Method not found' } } | ConvertTo-Json -Depth 10; ^
    Write-Output $error; ^
  } ^
} catch { ^
  $error = @{ jsonrpc = '2.0'; id = $null; error = @{ code = -32603; message = $_.Exception.Message } } | ConvertTo-Json -Depth 10; ^
  Write-Output $error; ^
}"