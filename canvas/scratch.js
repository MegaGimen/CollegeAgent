const fs = require('fs');
const token = fs.readFileSync('tokens.db', 'utf8').match(/113340~[a-zA-Z0-9]+/)?.[0]; // Hacky token extraction
if (!token) console.log('No token found');
