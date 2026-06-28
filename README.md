# NeuSlice — Printer Node Setup

NeuSlice is an on-demand 3D printing marketplace. Printer owners earn money by sharing their idle printers. Customers upload a model, get an instant quote, pay, and a nearby printer starts the job automatically.

This repository contains everything a printer owner needs to get their node online.

---

## Requirements

- A Bambu Lab printer (P1S, P1P, A1, X1C) connected to your local network
- A Windows, Mac, or Linux machine that stays on when you want to accept jobs
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running

---

## Quick Start

### Windows

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.ps1 | iex
```

### Mac / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.sh | bash
```

The installer will:
1. Confirm Docker is running
2. Ask for your **Agent Token** (one-time, from the NeuSlice dashboard)
3. Pull all containers and start your node

Your printer will appear online in the dashboard within about 30 seconds.

---

## Agent Token

Your Agent Token is generated when you register a printer in the NeuSlice dashboard:

**Dashboard → Your Printers → Add Printer → Copy Agent Token**

Keep this token private — it's how the NeuSlice backend authenticates your node.

---

## Automatic Updates

Once installed, your node updates itself automatically whenever NeuSlice releases a new version. You don't need to reinstall, run `docker pull`, or open any firewall ports. Updates happen silently in the background, and any active print job will finish before the update applies.

---

## Manual Setup

If you prefer to set up manually instead of using the installer:

```bash
# 1. Create a directory for NeuSlice
mkdir -p ~/.neuslice && cd ~/.neuslice

# 2. Download the compose file
curl -fsSL https://raw.githubusercontent.com/neubauet/neuslice-public/main/docker-compose.yml -o docker-compose.yml

# 3. Create your .env file
cat > .env <<EOF
AGENT_TOKEN=your_token_here
TZ=America/New_York
EOF

# 4. Start the stack
docker compose up -d
```

---

## Useful Commands

All commands should be run from your NeuSlice install directory (`~/.neuslice` by default).

| Action | Command |
|---|---|
| View agent logs | `docker compose logs -f neuslice-agent` |
| View all logs | `docker compose logs -f` |
| Stop the node | `docker compose down` |
| Restart the node | `docker compose restart` |
| Check status | `docker compose ps` |

---

## Troubleshooting

**My printer isn't showing up in the dashboard**
- Make sure your Agent Token in `.env` matches exactly what the dashboard shows
- Check agent logs: `docker compose logs neuslice-agent`
- Confirm Docker Desktop is running and the containers are up: `docker compose ps`

**Bambuddy can't connect to my printer**
- Open [http://localhost:8000](http://localhost:8000) and add your printer there first
- Make sure your printer is on the same network as the machine running the node

**I need to update my token**
- Edit `~/.neuslice/.env`, update `AGENT_TOKEN`, then run `docker compose restart neuslice-agent`

---

## Support

- **Dashboard**: [neuslice.com](https://neuslice.com)
- **Email**: support@neuslice.com

---

## What's in this repo

| File | Purpose |
|---|---|
| `docker-compose.yml` | The full container stack (agent + Bambuddy + Watchtower) |
| `install.sh` | One-line installer for Mac / Linux |
| `install.ps1` | One-line installer for Windows |
| `docs/` | Additional documentation |
