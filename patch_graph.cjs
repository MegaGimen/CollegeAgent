const fs = require('fs');
const file = '/home/collegeagent/collegeagent/flutter_app/lib/models/message.dart';
let content = fs.readFileSync(file, 'utf8');

content = content.replace(/class GraphNode \{/, 'class GraphNode {\n  final int? sourceId;');
content = content.replace(/this\.nodeId,/, 'this.sourceId,\n    this.nodeId,');
content = content.replace(/nodeId: json\['nodeId'\] as String\?,/, 'sourceId: json[\'sourceId\'] as int?,\n      nodeId: json[\'nodeId\'] as String?,');

content = content.replace(/class GraphLink \{/, 'class GraphLink {\n  final int? sourceId;');
content = content.replace(/this\.nodeId\}\);/, 'this.nodeId, this.sourceId});');
content = content.replace(/nodeId: json\['nodeId'\] as String\?,/, 'sourceId: json[\'sourceId\'] as int?,\n      nodeId: json[\'nodeId\'] as String?,');

fs.writeFileSync(file, content);
console.log('patched GraphNode and GraphLink');
