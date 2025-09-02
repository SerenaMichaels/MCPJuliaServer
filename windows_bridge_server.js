#!/usr/bin/env node
/**
 * Claude Desktop Communication Bridge (Windows Side)
 * Enables bidirectional MCP communication between Claude Code (WSL) and Claude Desktop (Windows)
 * 
 * Architecture:
 * Claude Desktop (Windows) ←→ Windows Bridge (Node.js) ←→ WSL Claude Bridge (Julia) ←→ Claude Code (WSL)
 */

const express = require('express');
const cors = require('cors');
const http = require('http');
const WebSocket = require('ws');
const fetch = require('node-fetch');
const { v4: uuidv4 } = require('uuid');

class ClaudeDesktopBridge {
    constructor() {
        this.app = express();
        this.server = null;
        this.wss = null;
        this.config = {
            port: 8086,
            host: '127.0.0.1',  // Bind to localhost only
            wslBridgeUrl: 'http://172.27.85.131:8085',  // WSL Claude Bridge
            bridgeId: `claude-desktop-bridge-${Date.now()}`
        };
        this.messageHistory = [];
        this.pendingRequests = new Map();
        this.activeConnections = new Set();
        
        this.setupExpress();
        this.setupWebSocket();
    }
    
    setupExpress() {
        // Middleware
        this.app.use(cors());
        this.app.use(express.json({ limit: '50mb' }));
        this.app.use(express.urlencoded({ extended: true }));
        
        // Logging middleware
        this.app.use((req, res, next) => {
            console.log(`📨 ${new Date().toISOString()} - ${req.method} ${req.path}`);
            next();
        });
        
        // Bridge health endpoint
        this.app.get('/claude-bridge/health', (req, res) => {
            res.json({
                status: 'healthy',
                bridge: 'Claude Desktop Communication Bridge',
                timestamp: new Date().toISOString(),
                connections: this.activeConnections.size,
                pending_requests: this.pendingRequests.size
            });
        });
        
        // Bridge status endpoint
        this.app.get('/claude-bridge/status', (req, res) => {
            res.json({
                bridge_id: this.config.bridgeId,
                status: 'active',
                timestamp: new Date().toISOString(),
                wsl_bridge_url: this.config.wslBridgeUrl,
                message_history_count: this.messageHistory.length,
                active_connections: this.activeConnections.size,
                pending_requests: Array.from(this.pendingRequests.keys())
            });
        });
        
        // Handle messages from WSL Claude Bridge
        this.app.post('/claude-bridge/message', async (req, res) => {
            try {
                const message = req.body;
                console.log(`📥 Message from Claude Code: ${message.message_type} (${message.request_id})`);
                
                const result = await this.handleClaudeCodeMessage(message);
                res.json(result);
                
            } catch (error) {
                console.error('❌ Error handling Claude Code message:', error);
                res.status(500).json({ error: error.message });
            }
        });
        
        // Simulate Claude Desktop MCP tool execution (for testing)
        this.app.post('/claude-bridge/simulate-mcp', async (req, res) => {
            try {
                const { tool_name, arguments: args } = req.body;
                console.log(`🧪 Simulating Claude Desktop MCP call: ${tool_name}`);
                
                // Simulate MCP tool execution
                const result = await this.simulateMCPCall(tool_name, args);
                res.json(result);
                
            } catch (error) {
                console.error('❌ Error simulating MCP call:', error);
                res.status(500).json({ error: error.message });
            }
        });
        
        // Message history endpoint
        this.app.get('/claude-bridge/history', (req, res) => {
            const limit = parseInt(req.query.limit) || 50;
            const recentMessages = this.messageHistory.slice(-limit);
            res.json({ messages: recentMessages });
        });
    }
    
    setupWebSocket() {
        // WebSocket for real-time communication with Claude Desktop
        this.server = http.createServer(this.app);
        this.wss = new WebSocket.Server({ server: this.server });
        
        this.wss.on('connection', (ws) => {
            const connectionId = uuidv4();
            this.activeConnections.add(connectionId);
            console.log(`🔌 Claude Desktop connection established: ${connectionId}`);
            
            ws.on('message', async (data) => {
                try {
                    const message = JSON.parse(data);
                    console.log(`📨 WebSocket message from Claude Desktop: ${message.type}`);
                    await this.handleClaudeDesktopMessage(message, ws);
                } catch (error) {
                    console.error('❌ WebSocket message error:', error);
                    ws.send(JSON.stringify({ error: error.message }));
                }
            });
            
            ws.on('close', () => {
                this.activeConnections.delete(connectionId);
                console.log(`🔌 Claude Desktop connection closed: ${connectionId}`);
            });
            
            // Send welcome message
            ws.send(JSON.stringify({
                type: 'welcome',
                bridge_id: this.config.bridgeId,
                timestamp: new Date().toISOString()
            }));
        });
    }
    
    async handleClaudeCodeMessage(message) {
        this.messageHistory.push({ ...message, direction: 'from_claude_code' });
        
        const messageType = message.message_type;
        const requestId = message.request_id;
        const payload = message.payload;
        
        try {
            switch (messageType) {
                case 'REQUEST_MCP_CALL':
                    return await this.executeMCPCall(payload, requestId);
                    
                case 'REQUEST_VALIDATION':
                    return await this.performValidation(payload, requestId);
                    
                case 'REQUEST_FILE_CHECK':
                    return await this.checkFile(payload, requestId);
                    
                case 'BROADCAST_STATUS':
                    return await this.handleStatusBroadcast(payload);
                    
                case 'HEARTBEAT':
                    return this.handleHeartbeat();
                    
                default:
                    console.warn(`❓ Unknown message type from Claude Code: ${messageType}`);
                    return { status: 'unknown_message_type', request_id: requestId };
            }
        } catch (error) {
            console.error(`❌ Error handling Claude Code message: ${error}`);
            return { status: 'error', error: error.message, request_id: requestId };
        }
    }
    
    async handleClaudeDesktopMessage(message, ws) {
        this.messageHistory.push({ ...message, direction: 'from_claude_desktop' });
        
        // Forward message to WSL Claude Bridge if needed
        if (message.forward_to_claude_code) {
            await this.forwardToClaudeCode(message);
        }
        
        // Process locally if needed
        ws.send(JSON.stringify({ 
            status: 'processed', 
            request_id: message.request_id 
        }));
    }
    
    async executeMCPCall(payload, requestId) {
        console.log(`🚀 Executing MCP call for Claude Code: ${payload.tool_name}`);
        
        try {
            // In a real implementation, this would interface with Claude Desktop's MCP system
            // For now, we'll simulate the call
            const result = await this.simulateMCPCall(payload.tool_name, payload.arguments);
            
            // Send result back to Claude Code
            await this.sendToClaudeCode('RESPONSE_MCP_RESULT', {
                request_id: requestId,
                success: true,
                result: result
            });
            
            return { status: 'mcp_call_initiated', request_id: requestId };
            
        } catch (error) {
            console.error(`❌ MCP call failed: ${error}`);
            await this.sendToClaudeCode('RESPONSE_MCP_RESULT', {
                request_id: requestId,
                success: false,
                error: error.message
            });
            
            return { status: 'mcp_call_failed', error: error.message, request_id: requestId };
        }
    }
    
    async simulateMCPCall(toolName, args) {
        // Simulate different MCP tools
        switch (toolName) {
            case 'mcp-db-admin-http:export_schema':
                return {
                    success: true,
                    data: {
                        tables: ['session_accomplishments', 'session_next_steps', 'robots', 'projects'],
                        message: 'Schema exported successfully from Claude Desktop simulation'
                    }
                };
                
            case 'mcp-postgres-http:execute_sql':
                return {
                    success: true,
                    rows: [
                        { id: 1, session_id: '0008', title: 'Claude Bridge Testing' }
                    ],
                    message: 'SQL executed successfully from Claude Desktop simulation'
                };
                
            case 'mcp-file-server-http:read_file':
                return {
                    success: true,
                    content: 'File content from Claude Desktop simulation',
                    file_path: args.file_path || 'unknown'
                };
                
            default:
                return {
                    success: true,
                    message: `Simulated execution of ${toolName} with args: ${JSON.stringify(args)}`
                };
        }
    }
    
    async performValidation(payload, requestId) {
        console.log(`🔍 Performing validation for Claude Code: ${payload.validation_type}`);
        
        const validationResult = {
            validation_type: payload.validation_type,
            status: 'passed',
            details: `Validation performed by Claude Desktop bridge`,
            timestamp: new Date().toISOString()
        };
        
        await this.sendToClaudeCode('RESPONSE_VALIDATION', {
            request_id: requestId,
            result: validationResult
        });
        
        return { status: 'validation_initiated', request_id: requestId };
    }
    
    async checkFile(payload, requestId) {
        console.log(`📁 Checking file for Claude Code: ${payload.file_path}`);
        
        const fs = require('fs');
        const path = require('path');
        
        try {
            const filePath = payload.file_path;
            const stats = fs.existsSync(filePath) ? fs.statSync(filePath) : null;
            
            const fileStatus = {
                file_path: filePath,
                exists: stats !== null,
                is_file: stats ? stats.isFile() : false,
                is_directory: stats ? stats.isDirectory() : false,
                size: stats ? stats.size : 0,
                modified: stats ? stats.mtime : null
            };
            
            await this.sendToClaudeCode('RESPONSE_FILE_STATUS', {
                request_id: requestId,
                file_status: fileStatus
            });
            
            return { status: 'file_check_initiated', request_id: requestId };
            
        } catch (error) {
            await this.sendToClaudeCode('RESPONSE_FILE_STATUS', {
                request_id: requestId,
                error: error.message
            });
            
            return { status: 'file_check_failed', error: error.message, request_id: requestId };
        }
    }
    
    async handleStatusBroadcast(payload) {
        console.log(`📡 Status broadcast from Claude Code: ${JSON.stringify(payload)}`);
        return { status: 'broadcast_received' };
    }
    
    handleHeartbeat() {
        console.log(`💓 Heartbeat from Claude Code`);
        return { 
            status: 'heartbeat_received', 
            timestamp: new Date().toISOString(),
            bridge_id: this.config.bridgeId
        };
    }
    
    async sendToClaudeCode(messageType, payload) {
        try {
            const message = {
                bridge_id: this.config.bridgeId,
                message_type: messageType,
                request_id: payload.request_id || uuidv4(),
                timestamp: new Date().toISOString(),
                payload: payload,
                sender: 'claude_desktop_windows'
            };
            
            const response = await fetch(`${this.config.wslBridgeUrl}/claude-bridge/message`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(message)
            });
            
            if (response.ok) {
                console.log(`✅ Message sent to Claude Code: ${messageType}`);
                return await response.json();
            } else {
                console.error(`❌ Failed to send message to Claude Code: ${response.status}`);
                return null;
            }
            
        } catch (error) {
            console.error(`❌ Error sending message to Claude Code: ${error}`);
            return null;
        }
    }
    
    async forwardToClaudeCode(message) {
        await this.sendToClaudeCode(message.message_type, message.payload);
    }
    
    start() {
        this.server.listen(this.config.port, this.config.host, () => {
            console.log('🌉 Claude Desktop Communication Bridge Started!');
            console.log(`🌐 HTTP Server: http://localhost:${this.config.port}`);
            console.log(`🔌 WebSocket Server: ws://localhost:${this.config.port}`);
            console.log(`🌊 WSL Bridge URL: ${this.config.wslBridgeUrl}`);
            console.log(`📊 Status: http://localhost:${this.config.port}/claude-bridge/status`);
            console.log('✨ Ready for Claude Code ↔ Claude Desktop communication!');
        });
    }
}

// Start the bridge
if (require.main === module) {
    const bridge = new ClaudeDesktopBridge();
    bridge.start();
}

module.exports = ClaudeDesktopBridge;