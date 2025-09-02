# Claude-to-Claude Communication Procedures

## 🤖⚡🤖 INTER-CLAUDE COMMUNICATION PROTOCOL

**Date:** September 2, 2025  
**System:** Claude Code (WSL) ↔ Claude Desktop (Windows)  
**Bridge Ports:** 8085 ↔ 8086  

---

## 🚨 KEY LIMITATION DISCOVERED

**MCP Protocol Constraint:** No push notifications or async events  
**Impact:** Claude Desktop cannot be automatically notified of new messages  
**Solution:** Human-mediated message polling system  

---

## 📡 COMMUNICATION PROCEDURES

### 1. Claude Code → Claude Desktop Message Sending

**Claude Code Steps:**
```bash
# Send message via bridge
curl -X POST http://localhost:8086/claude-bridge/message \
  -H "Content-Type: application/json" \
  -d '{
    "bridge_id": "claude-code-message-[timestamp]",
    "message_type": "BROADCAST_STATUS",
    "request_id": "msg-[unique-id]",
    "payload": {
      "message": "Your message content here",
      "priority": "normal|high|urgent"
    },
    "sender": "claude_code_wsl"
  }'

# Log in database for backup
curl -X POST http://localhost:8080/mcp/tools/call \
  -H "Content-Type: application/json" \
  -d '{
    "name": "log_accomplishment",
    "arguments": {
      "session_id": "0008",
      "repository": "MCPJuliaServers",
      "accomplishment_type": "inter_claude_message",
      "title": "Message for Claude Desktop: [Subject]",
      "description": "[Message content]"
    }
  }'
```

**Human Notification:**
"Claude Code has sent you a message - please check the bridge!"

### 2. Claude Desktop → Claude Code Message Retrieval

**Human Prompts Claude Desktop:**
- "Check if Claude Code sent you any messages"
- "What's in your message queue from Claude Code?"
- "Any new communications from Claude Code?"

**Claude Desktop Response Pattern:**
```sql
-- Check database for new messages
SELECT session_id, title, description, created_at 
FROM session_accomplishments 
WHERE accomplishment_type = 'inter_claude_message' 
AND created_at > '[last_check_timestamp]'
ORDER BY created_at DESC;
```

**OR check bridge directly:**
```bash
curl -s http://localhost:8086/claude-bridge/history
```

### 3. Claude Desktop → Claude Code Message Sending

**Current Method:** Human relays message  
**Future Enhancement:** Direct MCP tool integration  

**Human Process:**
1. Claude Desktop composes message in chat
2. Human copies message to Claude Code session  
3. Claude Code processes and responds

### 4. Priority Message Handling

**URGENT Messages:**
- Include "URGENT" in title/subject
- Human checks both systems more frequently
- Use database + bridge for redundancy

**Standard Messages:**
- Regular checking cycle (every 30 minutes)
- Bridge queue sufficient
- Standard priority processing

---

## 🔧 TECHNICAL SPECIFICATIONS

### Message Queue Locations
1. **Bridge Queue:** `http://localhost:8086/claude-bridge/history`
2. **Database Backup:** `session_accomplishments` table
3. **Status Endpoint:** `http://localhost:8086/claude-bridge/status`

### Message Types Supported
- `BROADCAST_STATUS` - General communication
- `REQUEST_VALIDATION` - Asking for feedback/validation
- `REQUEST_MCP_CALL` - Requesting tool execution
- `HEARTBEAT` - Connection testing

### Bridge Health Monitoring
```bash
# Check bridge status
curl -s http://localhost:8085/claude-bridge/health
curl -s http://localhost:8086/claude-bridge/health

# Monitor message count
curl -s http://localhost:8086/claude-bridge/status | grep message_history_count
```

---

## 🎯 WORKFLOW EXAMPLES

### Example 1: Project Coordination
**Claude Code:** "Ready to work on Blender integration - what's your status on MCP setup?"  
**Human:** Relays to Claude Desktop  
**Claude Desktop:** Responds with current MCP tool status  
**Human:** Relays response back to Claude Code  

### Example 2: Error Reporting
**Claude Code:** Encounters database connection issue  
**Claude Code:** Logs URGENT message in database + sends bridge message  
**Human:** Notified of urgent status  
**Human:** Prompts Claude Desktop to check  
**Claude Desktop:** Provides troubleshooting assistance  

### Example 3: Collaborative Development
**Claude Code:** "Finished bridge implementation - ready for testing"  
**Claude Desktop:** "Confirmed bridge working - let's proceed with robot coordination"  
**Human:** Facilitates back-and-forth planning discussion  

---

## 🚀 FUTURE ENHANCEMENTS

### Potential Improvements
1. **Polling MCP Tool:** Create tool for Claude Desktop to check messages
2. **Timed Reminders:** Human sets regular check intervals  
3. **Priority Alerts:** Database triggers for urgent messages
4. **WebSocket Integration:** Real-time notifications (if MCP supports)

### Current Limitations to Address
1. **Manual Intervention Required:** Human must facilitate communication
2. **No Real-time Alerts:** Delayed message discovery
3. **Asymmetric Communication:** Easier Claude Code → Claude Desktop than reverse

---

## 📋 COMMUNICATION CHECKLIST

### Before Sending Message:
- [ ] Determine urgency level
- [ ] Choose appropriate message type
- [ ] Test bridge connectivity
- [ ] Log in database as backup

### After Sending Message:
- [ ] Confirm bridge acceptance
- [ ] Notify human if urgent
- [ ] Log accomplishment in database
- [ ] Set expectation for response time

### For Receiving Messages:
- [ ] Check bridge history regularly
- [ ] Monitor database for new entries
- [ ] Respond via appropriate channel
- [ ] Confirm message receipt

---

## 🎉 SUCCESS METRICS

**Communication Success Defined By:**
- Message delivered to bridge ✅
- Message logged in database ✅  
- Human notified appropriately ✅
- Receiving Claude acknowledges message ✅
- Response generated and delivered ✅

---

*This protocol enables the first AI-to-AI collaborative development workflow while working within current MCP constraints.*