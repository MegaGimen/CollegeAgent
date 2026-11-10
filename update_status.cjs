const fs = require('fs');
const path = 'collegeagent/flutter_app/lib/widgets/message_bubble.dart';
let code = fs.readFileSync(path, 'utf8');

const oldStatusLogic = `    if (widget.message.toolCalls.any((tc) => tc.isLoading)) {
      final activeTool = widget.message.toolCalls.lastWhere((tc) => tc.isLoading);
      statusText = "calling tool: \${activeTool.name}...";
      isActive = true;
    } else if (widget.message.text.isEmpty) {
      statusText = "thinking...";
      isActive = true;
    } else {
      statusText = "Tool calls & thinking (\${widget.message.toolCalls.length})";
    }`;

const newStatusLogic = `    if (widget.message.toolCalls.any((tc) => tc.isLoading)) {
      final activeTool = widget.message.toolCalls.lastWhere((tc) => tc.isLoading);
      statusText = "calling tool: \${activeTool.name}...";
      isActive = true;
    } else if (widget.message.text.isEmpty) {
      statusText = "thinking...";
      isActive = true;
    } else {
      if (widget.message.toolCalls.isEmpty) {
        statusText = "Thinking process";
      } else {
        statusText = "Tool calls & thinking (\${widget.message.toolCalls.length})";
      }
    }`;

code = code.replace(oldStatusLogic, newStatusLogic);
fs.writeFileSync(path, code);
