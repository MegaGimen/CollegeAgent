const fs = require('fs');
const file = '/home/collegeagent/collegeagent/flutter_app/lib/widgets/citation_badge.dart';
let content = fs.readFileSync(file, 'utf8');
content = content.replace(
  "r'\\[Source:\\s*[^\\]]+\\]|\\[\\d+(?:\\s*,\\s*\\d+(?:\\s*[\\-,]\\s*\\d+)?)?\\]|\\[\\d+(?:[,\\-]\\s*\\d+)*\\]'",
  "r'\\[Source:\\s*[^\\]]+\\]|\\[\\s*\\d+[^\\]]*\\]'"
);
fs.writeFileSync(file, content);
