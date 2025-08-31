// MCP Node.js wrapper for Julia HTTP servers
const http = require('http');
const serverUrl = process.argv[2] || 'http://172.27.85.131:8080';

// Read JSON input from stdin
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
    try {
        const request = JSON.parse(input);
        
        // Handle MCP initialization
        if (request.method === 'initialize') {
            const response = {
                jsonrpc: '2.0',
                id: request.id,
                result: {
                    protocolVersion: '2024-11-05',
                    capabilities: { tools: {} },
                    serverInfo: { name: 'mcp-julia-http', version: '1.0.0' }
                }
            };
            console.log(JSON.stringify(response));
            process.exit(0);
        }
        
        // Handle tools/list
        if (request.method === 'tools/list') {
            makeHttpRequest('POST', serverUrl + '/mcp/tools/list', null, (result) => {
                const response = {
                    jsonrpc: '2.0',
                    id: request.id,
                    result: result.result
                };
                console.log(JSON.stringify(response));
                process.exit(0);
            });
            return;
        }
        
        // Handle tools/call
        if (request.method === 'tools/call') {
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
                process.exit(0);
            });
            return;
        }
        
        // Handle notifications/initialized
        if (request.method === 'notifications/initialized') {
            process.exit(0);
        }
        
        // Unknown method
        const error = {
            jsonrpc: '2.0',
            id: request.id,
            error: { code: -32601, message: 'Method not found' }
        };
        console.log(JSON.stringify(error));
        process.exit(1);
        
    } catch (err) {
        const error = {
            jsonrpc: '2.0',
            id: null,
            error: { code: -32603, message: err.message }
        };
        console.log(JSON.stringify(error));
        process.exit(1);
    }
});

function makeHttpRequest(method, url, data, callback) {
    const postData = data ? JSON.stringify(data) : '';
    const options = {
        method: method,
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(postData)
        }
    };
    
    const req = http.request(url, options, (res) => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
            try {
                const result = JSON.parse(body);
                callback(result);
            } catch (err) {
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
        console.log(JSON.stringify({
            jsonrpc: '2.0',
            id: null,
            error: { code: -32603, message: err.message }
        }));
        process.exit(1);
    });
    
    if (postData) req.write(postData);
    req.end();
}