// MCP Node.js wrapper for Julia HTTP servers - Fixed version
const http = require('http');
const serverUrl = process.argv[2] || 'http://172.27.85.131:8080';

// Debug logging to stderr
const debugLog = (msg) => {
    console.error(`[DEBUG] ${new Date().toISOString()}: ${msg}`);
};

debugLog(`Starting MCP wrapper for ${serverUrl}`);

// Read JSON input from stdin
let input = '';
let isReadingComplete = false;

process.stdin.setEncoding('utf8');

process.stdin.on('readable', () => {
    let chunk;
    while ((chunk = process.stdin.read()) !== null) {
        input += chunk;
    }
});

process.stdin.on('end', () => {
    if (isReadingComplete) return;
    isReadingComplete = true;
    
    debugLog(`Received input: ${input}`);
    processRequest(input);
});

// Handle timeout case
setTimeout(() => {
    if (!isReadingComplete) {
        debugLog('Timeout waiting for stdin, processing what we have');
        isReadingComplete = true;
        processRequest(input);
    }
}, 1000);

function processRequest(inputData) {
    try {
        if (!inputData.trim()) {
            debugLog('No input received');
            process.exit(1);
        }
        
        const request = JSON.parse(inputData);
        debugLog(`Processing method: ${request.method}`);
        
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
            process.exit(0);
        }
        
        // Handle tools/list
        if (request.method === 'tools/list') {
            debugLog('Handling tools/list request');
            makeHttpRequest('POST', serverUrl + '/mcp/tools/list', null, (result) => {
                const response = {
                    jsonrpc: '2.0',
                    id: request.id,
                    result: result.result
                };
                console.log(JSON.stringify(response));
                debugLog('Sent tools/list response');
                process.exit(0);
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
            makeHttpRequest('POST', serverUrl + '/mcp/tools/call', callData, (result) => {
                const response = {
                    jsonrpc: '2.0',
                    id: request.id,
                    result: result.result
                };
                console.log(JSON.stringify(response));
                debugLog('Sent tools/call response');
                process.exit(0);
            });
            return;
        }
        
        // Handle notifications/initialized
        if (request.method === 'notifications/initialized') {
            debugLog('Handling notifications/initialized');
            process.exit(0);
        }
        
        // Unknown method
        debugLog(`Unknown method: ${request.method}`);
        const error = {
            jsonrpc: '2.0',
            id: request.id,
            error: { code: -32601, message: `Method not found: ${request.method}` }
        };
        console.log(JSON.stringify(error));
        process.exit(1);
        
    } catch (err) {
        debugLog(`Error processing request: ${err.message}`);
        const error = {
            jsonrpc: '2.0',
            id: null,
            error: { code: -32603, message: `Internal error: ${err.message}` }
        };
        console.log(JSON.stringify(error));
        process.exit(1);
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
                debugLog(`HTTP response: ${body}`);
                const result = JSON.parse(body);
                callback(result);
            } catch (err) {
                debugLog(`Error parsing HTTP response: ${err.message}`);
                console.log(JSON.stringify({
                    jsonrpc: '2.0',
                    id: null,
                    error: { code: -32603, message: 'Invalid JSON response' }
                }));
                process.exit(1);
            }
        });
    });
    
    req.on('error', (err) => {
        debugLog(`HTTP request error: ${err.message}`);
        console.log(JSON.stringify({
            jsonrpc: '2.0',
            id: null,
            error: { code: -32603, message: `HTTP error: ${err.message}` }
        }));
        process.exit(1);
    });
    
    if (postData) req.write(postData);
    req.end();
}