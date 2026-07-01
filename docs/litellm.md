# LiteLLM (AI layer)

## What it does

A unified, OpenAI-compatible gateway in front of your models. Your apps talk to
one endpoint (`http://litellm:4000`, or a `*.ts.net` name via Caddy) with one
API key, and LiteLLM routes to local Ollama models and/or external providers
(OpenAI, Gemini, Anthropic). Swap backends without changing app code.

## Auth & config

- **Master key** (`LITELLM_MASTER_KEY`) is auto-generated into git-ignored
  `.env`, shown once. Clients send it as their API key
  (`Authorization: Bearer <key>`).
- **Models** are declared in `modules/litellm/config.yaml`. By default it maps
  `llama3.2` and `qwen2.5` to in-stack Ollama. Uncomment the external provider
  blocks and set the matching key in `.env` to add cloud models.

Ollama is a **runtime** dependency, not a startup one — LiteLLM boots fine
without it and only a request to an ollama-backed model fails if Ollama is down
or the model isn't pulled.

## Using it

```bash
# List available models (from inside the tailnet / stack):
curl -s http://<host>.ts.net/v1/models -H "Authorization: Bearer <master-key>"

# Chat completion routed to a local Ollama model:
curl -s http://<host>.ts.net/v1/chat/completions \
  -H "Authorization: Bearer <master-key>" -H "Content-Type: application/json" \
  -d '{"model":"llama3.2","messages":[{"role":"user","content":"hi"}]}'
```

(Requires `ollama pull llama3.2` first — see [ollama.md](ollama.md).)

## How to verify

```bash
./modules/litellm/healthcheck.sh    # PASS = /health/liveliness returns 2xx
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| 401 Unauthorized | Missing/wrong master key. Use the value in `modules/litellm/.env`. |
| Model request errors, gateway healthy | The backend (Ollama model not pulled, or provider key unset) — not LiteLLM itself. Pull the model / set the key. |
| Startup fails on config | YAML error in `config.yaml`, or a referenced `os.environ/KEY` isn't set. Check `docker logs forge_litellm`. |

## Backup / restore

LiteLLM is stateless — its config is the mounted `config.yaml` (in git) and its
secrets are in `.env` (backed up with the stack). No data volume to restore.
