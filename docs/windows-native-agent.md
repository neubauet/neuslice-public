# Windows agent (native, no Docker) — managing & troubleshooting

The native Windows agent runs as a **Windows service** named `neuslice-agent` — no Docker.
Everything lives under `%USERPROFILE%\.neuslice\`:

| What | Path |
|------|------|
| Config (`.env`) | `%USERPROFILE%\.neuslice\agent\.env` |
| Agent log (**the important one**) | `%USERPROFILE%\.neuslice\neuslice-agent.err.log` |
| Service-wrapper log | `%USERPROFILE%\.neuslice\neuslice-agent.wrapper.log` |

Service commands need an **elevated** PowerShell (Run as administrator).

## Managing the service

```powershell
Get-Service neuslice-agent            # status
Restart-Service neuslice-agent        # apply any .env change
Stop-Service  neuslice-agent          # graceful — drains an in-flight print
Start-Service neuslice-agent
```

## Viewing logs

The agent writes to **`.err.log`** (not `.out.log`):

```powershell
Get-Content "$env:USERPROFILE\.neuslice\neuslice-agent.err.log" -Tail 40 -Wait
```

> **Tip:** `-Tail` prints the last lines *first*, so right after a restart you may be
> looking at **old** lines from a previous run. Check the timestamps / whether the file
> is still growing before assuming it's still failing.

## The service keeps restarting (status flips to `Stopped`)

It's crashing on startup. The reason is at the **bottom** of `.err.log`. Fix the cause
(usually a value in `.env`), then `Restart-Service neuslice-agent`.

## My node won't come online

The agent connects to your **printer (through Bambuddy) before** it connects to NeuSlice,
so the node stays **offline until Bambuddy has a printer**. Add your printer in Bambuddy,
then:

```powershell
Restart-Service neuslice-agent
```

## Point the agent at an existing Bambuddy (same PC or another machine)

Native Windows agents have full host networking, so they can use a Bambuddy running on a
**different machine** directly. First find the printer id:

```powershell
# add  -Headers @{'X-API-Key'='<key>'}  if your Bambuddy has auth enabled
Invoke-RestMethod "http://<host>:8000/api/v1/printers/" | Select-Object id,name,model
```
`<host>` = `127.0.0.1` if Bambuddy is on this PC, or the other machine's IP (e.g. `192.168.1.50`).

Then edit `%USERPROFILE%\.neuslice\agent\.env`:

```
BAMBUDDY_BASE_URL=http://<host>:8000
BAMBU_PRINTER_ID=<id from the command above>
# only if your Bambuddy has auth enabled:
# BAMBU_API_KEY=<key>
# BAMBU_USERNAME=<Bambuddy web-UI username>
# BAMBU_PASSWORD=<Bambuddy web-UI password>
```

Then `Restart-Service neuslice-agent`.

If Bambuddy is on another machine, make sure it listens on `0.0.0.0` and its firewall
allows inbound TCP 8000.

## Editing configuration

All connection settings live in `%USERPROFILE%\.neuslice\agent\.env`. After **any** edit,
apply it with `Restart-Service neuslice-agent`. (Nozzle diameter, plate type, and printer
model are set in the NeuSlice dashboard under **Your Printers → Edit** — no file editing
needed for those.)

## Uninstalling

```powershell
& "$env:USERPROFILE\.neuslice\neuslice-agent.exe" stop
& "$env:USERPROFILE\.neuslice\neuslice-agent.exe" uninstall
Remove-Item "$env:USERPROFILE\.neuslice" -Recurse -Force
```

This does not affect your printer or any completed prints.
