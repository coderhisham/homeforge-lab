# Ollama (AI layer)

## What it does

Runs large language models locally. Other services (LiteLLM, your apps) call it
at `http://ollama:11434`; you can also reach its API through Caddy at a
`*.ts.net` name. No data leaves your box.

> **⚠ Disk:** models are **4–40 GB each** and live in `tuninforge_ollama_data`. On a
> constrained SSD this is the single biggest consumer in the stack — it's
> unchecked by default in the menu for that reason. Pull models deliberately.

## CPU by default, GPU opt-in

This module runs **CPU-only by default** so the container starts on any box.
Adding GPU device reservations unconditionally would make it fail to start on a
machine without an NVIDIA runtime — so GPU is an explicit opt-in.

To enable an NVIDIA GPU (requires the host `nvidia-container-toolkit`), create a
`modules/ollama/docker-compose.override.yml`:

```yaml
services:
  ollama:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

Compose auto-merges `docker-compose.override.yml`. Verify with
`docker exec tuninforge_ollama nvidia-smi`.

## Pulling and using models

```bash
docker exec tuninforge_ollama ollama pull llama3.2      # ~2GB; downloads into the volume
docker exec tuninforge_ollama ollama list               # what's installed
docker exec -it tuninforge_ollama ollama run llama3.2   # quick chat test
```

## How to verify

```bash
./modules/ollama/healthcheck.sh        # PASS = 'ollama list' succeeds (server up)
```

`tuninforge.sh status` also reports it.

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| Container "unhealthy" right after start | First start can be slow; `start_period` is 30s. Check `docker logs tuninforge_ollama`. |
| Out of disk | Models are huge. `docker exec tuninforge_ollama ollama rm <model>`; monitor the volume. |
| Very slow responses | CPU-only inference is slow for big models. Use small models, or enable GPU (above). |
| GPU not used | Missing `nvidia-container-toolkit` on the host, or no override file. See GPU section. |

## Backup / restore

`tuninforge_ollama_data` holds downloaded models — large, and re-downloadable. It's
included in `scripts/backup.sh`, but you may prefer to **exclude** it to keep
backups small (models can just be re-pulled). See [backup.md](backup.md).
