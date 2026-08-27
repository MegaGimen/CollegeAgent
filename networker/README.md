# ⚕ Networker — Webpage Graph & Obsidian Vault Builder

Networker is an automated website crawler and link visualizer. It crawls a target site recursively using **Playwright Chromium**, extracts internal page links, and stores them in a format ready to be opened as an **Obsidian Vault**.

---

## Features

1. **Multi-Task Runner**: Every website mapping session is run as an isolated background task. You can track, select, and abort tasks individually.
2. **Anchor-Text (Title) Predictions**: Uses parent link anchor texts as node labels for pending links, which are resolved to actual page titles once visited.
3. **Obsidian Integration**: Writes standard Obsidian Markdown files with Wikilinks (`[[Link]]`) inside distinct vault folders (e.g. `vault/host_name_task_123/`).
4. **Task Persistence**: Automatically recovers historical crawl sessions from the `vault/` folders on disk when the server boots.
5. **Real-time SSE Dashboard**: Real-time log streams, metrics, and conditional Vis.js graph mapping when tasks complete.
6. **Packaged ZIP Downloads**: Allows remote users to download a `.zip` archive of any completed vault to import and view locally in Obsidian.

---

## Technical Stack

- **Runtime**: Node.js (v24+)
- **Backend**: Express.js
- **Browser Automation**: Playwright (Chromium)
- **Frontend**: HTML5, Vanilla CSS, Lucide Icons, Vis.js Network Graph
- **System Service**: systemd (configured for autostart)

---

## Directory Structure

```text
networker/
├── public/
│   └── index.html      # Front-end dashboard
├── vault/              # Mapped website vault folders (persistent storage)
├── package.json        # Dependencies (Express, Playwright, Cors)
├── README.md           # Developer & user guide
└── server.js           # Express server & queue crawler engine
```

---

## System Installation & systemd Service

Networker runs as a persistent background daemon managed by **systemd**.

### Service Configuration File
Located at `/etc/systemd/system/networker.service`:

```ini
[Unit]
Description=Networker Webpage Graph and Obsidian Vault Builder
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/home/collegeagent/networker
ExecStart=/root/.nvm/versions/node/v24.12.0/bin/node server.js
Restart=on-failure
RestartSec=5
Environment=PORT=4090

[Install]
WantedBy=multi-user.target
```

### Process Management Commands

```bash
# Reload changes made to the systemd config
systemctl daemon-reload

# Start the service
systemctl start networker.service

# Stop the service
systemctl stop networker.service

# Enable autostart on system boot
systemctl enable networker.service

# Disable autostart
systemctl disable networker.service

# View real-time service logs
journalctl -u networker.service -f -n 100
```

---

## How to Test and Run

1. Open your browser and navigate to: **`http://<your-server-ip>:4090/`** (bound to `0.0.0.0`).
2. Input a starting website (e.g. `https://example.com`), adjust crawl depth/pages, and click **Spawn Crawl Task**.
3. View real-time console progress.
4. When the task is complete, an interactive node chart will appear. Click any node to preview its Markdown page content.
5. Click **Download Vault ZIP** to grab the vault package and view it inside your local Obsidian desktop client using Obsidian's native **Graph View** (press `Ctrl + G` or `Cmd + G` in Obsidian).
