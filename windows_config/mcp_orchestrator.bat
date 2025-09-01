@echo off
setlocal enabledelayedexpansion
set "tool_name=%1"
set "arguments=%2"
if "%arguments%"=="" set "arguments={}"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"try { ^
  $response = Invoke-RestMethod -Uri 'http://172.27.85.131:8083/mcp/tools/call' ^
    -Method POST ^
    -ContentType 'application/json' ^
    -Body (ConvertTo-Json -Depth 10 @{name='%tool_name%'; arguments=ConvertFrom-Json '%arguments%'}); ^
  if($response.result) { ^
    Write-Output ($response.result | ConvertTo-Json -Depth 10 -Compress) ^
  } else { ^
    Write-Output ($response | ConvertTo-Json -Depth 10 -Compress) ^
  } ^
} catch { ^
  Write-Error $_.Exception.Message ^
}"