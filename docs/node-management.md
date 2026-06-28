# Managing Your NeuSlice Node

## Starting and stopping

```bash
# Start all containers
docker compose up -d

# Stop all containers (does not delete data)
docker compose down

# Restart just the agent
docker compose restart neuslice-agent
```

## Viewing logs

```bash
# Follow agent logs live
docker compose logs -f neuslice-agent

# Show last 100 lines of all services
docker compose logs --tail=100
```

## Pausing job acceptance

You can pause your node from the NeuSlice dashboard without stopping the containers — useful if you're about to run your own prints and don't want incoming jobs. The agent will still stay connected; it just won't accept new assignments.

## Updating your Agent Token

If you need to replace your Agent Token (e.g. you revoked and regenerated it in the dashboard):

```bash
# Edit your .env
nano ~/.neuslice/.env   # update AGENT_TOKEN=

# Restart just the agent (no need to restart Bambuddy or Watchtower)
docker compose restart neuslice-agent
```

## Changing your printer settings

Nozzle diameter, build plate type, and printer model are set in the NeuSlice dashboard under **Your Printers → Edit**. You don't need to touch the containers to update these.

## Uninstalling

```bash
# Stop and remove all containers and volumes
docker compose down -v

# Remove the install directory
rm -rf ~/.neuslice
```

This will not affect your Bambu printer or any prints already completed.
