import multer from 'multer';
import { parseDocumentToMarkdown } from './doc_parser.js';
import path from 'node:path';
import fs from 'node:fs';
import { createHash } from 'node:crypto';

const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    const uploadDir = '/tmp/uploads';
    if (!fs.existsSync(uploadDir)) {
      fs.mkdirSync(uploadDir, { recursive: true });
    }
    cb(null, uploadDir);
  },
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname);
    const uniqueSuffix = Date.now() + '-' + Math.round(Math.random() * 1E9);
    cb(null, uniqueSuffix + ext);
  }
});
const upload = multer({ storage });
const MCP_DIR = '/home/collegeagent/networker/MCP';

export function setupPersonalVaultRoutes(app) {
  app.post('/api/vault/personal/upload', upload.single('file'), async (req, res) => {
    try {
      const { userId } = req.body;
      if (!userId || !req.file) return res.status(400).json({ error: 'Missing userId or file' });

      const privateVaultDir = path.join(MCP_DIR, 'private_vaults', userId);
      const privateIndexPath = path.join(privateVaultDir, 'index.json');
      
      if (!fs.existsSync(privateVaultDir)) {
        fs.mkdirSync(privateVaultDir, { recursive: true });
      }

      let privateIndex = { nodes: {}, edges: [] };
      if (fs.existsSync(privateIndexPath)) {
        privateIndex = JSON.parse(fs.readFileSync(privateIndexPath, 'utf-8'));
      }

      const originalName = req.file.originalname;
      const parsedMarkdown = await parseDocumentToMarkdown(req.file.path, req.file.mimetype, originalName);

      const nodeId = 'personal_' + createHash('md5').update(originalName + Date.now()).digest('hex').substring(0, 16);
      const safeFilename = `${nodeId}.md`;

      privateIndex.nodes[nodeId] = {
        id: nodeId,
        title: originalName,
        source: 'personal',
        source_type: 'personal',
        date: new Date().toISOString(),
        path: safeFilename,
        content: parsedMarkdown,
        outboundLinks: []
      };

      fs.writeFileSync(path.join(privateVaultDir, safeFilename), parsedMarkdown);
      fs.writeFileSync(privateIndexPath, JSON.stringify(privateIndex, null, 2));
      fs.unlinkSync(req.file.path);

      // Trigger AutoRAG reindex
      try {
        await fetch('http://127.0.0.1:8002/reindex', { method: 'POST' });
      } catch (e) {
        console.error('Failed to trigger reindex:', e.message);
      }

      res.json({ success: true, node: privateIndex.nodes[nodeId] });
    } catch (e) {
      console.error('Upload error:', e);
      res.status(500).json({ error: e.message });
    }
  });

  app.get('/api/vault/personal', (req, res) => {
    const { userId } = req.query;
    if (!userId) return res.status(400).json({ error: 'Missing userId' });
    
    const privateIndexPath = path.join(MCP_DIR, 'private_vaults', userId, 'index.json');
    if (!fs.existsSync(privateIndexPath)) return res.json({ files: [] });
    
    const privateIndex = JSON.parse(fs.readFileSync(privateIndexPath, 'utf-8'));
    const files = Object.values(privateIndex.nodes)
      .filter(n => n.source_type === 'personal' || n.source === 'personal')
      .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
      
    res.json({ files });
  });

  app.delete('/api/vault/personal/:nodeId', (req, res) => {
    const { userId } = req.query;
    const { nodeId } = req.params;
    if (!userId || !nodeId) return res.status(400).json({ error: 'Missing userId or nodeId' });
    
    const privateVaultDir = path.join(MCP_DIR, 'private_vaults', userId);
    const privateIndexPath = path.join(privateVaultDir, 'index.json');
    if (!fs.existsSync(privateIndexPath)) return res.json({ success: true });
    
    const privateIndex = JSON.parse(fs.readFileSync(privateIndexPath, 'utf-8'));
    if (privateIndex.nodes[nodeId]) {
      const filePath = path.join(privateVaultDir, privateIndex.nodes[nodeId].path);
      if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
      delete privateIndex.nodes[nodeId];
      fs.writeFileSync(privateIndexPath, JSON.stringify(privateIndex, null, 2));
      
      // Trigger AutoRAG reindex
      try {
        fetch('http://127.0.0.1:8002/reindex', { method: 'POST' });
      } catch (e) {}
    }
    res.json({ success: true });
  });
}
