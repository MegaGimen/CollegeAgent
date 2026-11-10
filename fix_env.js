const fs = require('fs');
const p = '/home/collegeagent/networker/MCP/server.js';
let code = fs.readFileSync(p, 'utf8');

code = code.replace('import "dotenv/config";', `import dotenv from 'dotenv';
import { fileURLToPath } from 'url';
import path from 'path';
const __filename_mcp_env = fileURLToPath(import.meta.url);
const __dirname_mcp_env = path.dirname(__filename_mcp_env);
dotenv.config({ path: path.join(__dirname_mcp_env, '..', '.env') });
`);

fs.writeFileSync(p, code);
