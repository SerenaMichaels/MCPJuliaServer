// MCP Node.js wrapper for Julia HTTP servers - Final working version
const http = require('http');
const readline = require('readline');
const serverUrl = process.argv[2] || 'http://172.27.85.131:8080';

// Debug logging to stderr
const debugLog = (msg) => {
    console.error(`[DEBUG] ${new Date().toISOString()}: ${msg}`);
};

debugLog(`Starting persistent MCP wrapper for ${serverUrl}`);

// Create readline interface for line-by-line JSON-RPC processing
const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false
});

// Handle each line as a JSON-RPC request
rl.on('line', (line) => {
    if (!line.trim()) return;
    
    debugLog(`Received line: ${line}`);
    processRequest(line);
});

rl.on('close', () => {
    debugLog('Input stream closed');
    process.exit(0);
});

function processRequest(inputData) {
    try {
        const request = JSON.parse(inputData);
        debugLog(`Processing method: ${request.method} with id: ${request.id}`);
        
        // Handle MCP initialization
        if (request.method === 'initialize') {
            debugLog('Handling initialize request');
            const response = {
                jsonrpc: '2.0',
                id: request.id,
                result: {
                    protocolVersion: '2024-11-05',
                    capabilities: { 
                        tools: {}
                    },
                    serverInfo: { 
                        name: 'mcp-julia-http', 
                        version: '1.0.0' 
                    }
                }
            };
            console.log(JSON.stringify(response));
            debugLog('Sent initialize response');
            return;
        }
        
        // Handle tools/list
        if (request.method === 'tools/list') {
            debugLog('Handling tools/list request');
            makeHttpRequest('POST', serverUrl + '/mcp/tools/list', null, (httpResult) => {
                // Extract the actual result from the Julia server response
                const actualResult = httpResult.result?.result || httpResult.result;
                const response = {
                    jsonrpc: '2.0',
                    id: request.id,
                    result: actualResult
                };
                console.log(JSON.stringify(response));
                debugLog(`Sent tools/list response: ${JSON.stringify(actualResult.tools?.map(t => t.name))}`);
            });
            return;
        }
        
        // Handle tools/call
        if (request.method === 'tools/call') {
            debugLog(`Handling tools/call for tool: ${request.params.name}`);
            const callData = {
                name: request.params.name,
                arguments: request.params.arguments || {}
            };
            makeHttpRequest('POST', serverUrl + '/mcp/tools/call', callData, (httpResult) => {
                // Extract the actual result from the Julia server response
                const actualResult = httpResult.result?.result || httpResult.result;
                const response = {
                    jsonrpc: '2.0',
                    id: request.id,
                    result: actualResult
                };
                console.log(JSON.stringify(response));
                debugLog('Sent tools/call response');
            });
            return;
        }
        
        // Handle prompts/list (not supported)
        if (request.method === 'prompts/list') {
            debugLog('Handling prompts/list request - not supported');
            const response = {
                jsonrpc: '2.0',
                id: request.id,
                result: { prompts: [] }
            };
            console.log(JSON.stringify(response));
            return;
        }
        
        // Handle resources/list (not supported)
        if (request.method === 'resources/list') {
            debugLog('Handling resources/list request - not supported');
            const response = {
                jsonrpc: '2.0',
                id: request.id,
                result: { resources: [] }
            };
            console.log(JSON.stringify(response));
            return;
        }
        
        // Handle notifications/initialized
        if (request.method === 'notifications/initialized') {
            debugLog('Handling notifications/initialized');
            // No response needed for notifications
            return;
        }
        
        // Unknown method
        debugLog(`Unknown method: ${request.method}`);
        const error = {
            jsonrpc: '2.0',
            id: request.id,
            error: { code: -32601, message: `Method not found: ${request.method}` }
        };
        console.log(JSON.stringify(error));
        
    } catch (err) {
        debugLog(`Error processing request: ${err.message}`);
        const error = {
            jsonrpc: '2.0',
            id: null,
            error: { code: -32603, message: `Internal error: ${err.message}` }
        };
        console.log(JSON.stringify(error));
    }
}

function makeHttpRequest(method, url, data, callback) {
    const postData = data ? JSON.stringify(data) : '';
    const options = {
        method: method,
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(postData)
        }
    };
    
    debugLog(`Making HTTP ${method} request to ${url}`);
    
    const req = http.request(url, options, (res) => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
            try {
                debugLog(`HTTP response: ${body.substring(0, 500)}...`);
                const result = JSON.parse(body);
                callback(result);
            } catch (err) {
                debugLog(`Error parsing HTTP response: ${err.message}`);
                callback({
                    result: {
                        error: { code: -32603, message: 'Invalid JSON response' }
                    }
                });
            }
        });
    });
    
    req.on('error', (err) => {
        debugLog(`HTTP request error: ${err.message}`);
        callback({
            result: {
                error: { code: -32603, message: `HTTP error: ${err.message}` }
            }
        });
    });
    
    if (postData) req.write(postData);
    req.end();
}