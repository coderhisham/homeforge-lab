# Services explained (for beginners)

New to self-hosting? This page explains **what each tool is and why you'd want
it**, in plain language — no jargon assumed. For the technical setup of any
service (how to verify it, common problems, backups), see its own page in
[docs/](.).

tuninforge groups services into **layers**. You don't need all of them — pick
what solves a problem you actually have.

---

## Access layer — getting to your server safely

### Tailscale
**What it is:** a "mesh VPN" — it creates a small, private network that only
your own devices can join.
**Why you want it:** normally, reaching a home server from your laptop means
opening ports on your router and exposing them to the whole internet (risky).
Tailscale skips all that: your laptop, phone, and server act like they're on the
same private LAN, wherever they are. Nothing is exposed publicly.
**Analogy:** a private hallway that only your devices have a key to, instead of
putting your server's front door on a public street.

### SSH hardening
**What it is:** locks down how you remotely log into the server's command line
(SSH), so only your cryptographic key works — no password guessing.
**Why you want it:** an internet-facing server gets thousands of automated
password-guess attempts a day. Key-only login makes those pointless. tuninforge
does this *carefully* so you can't accidentally lock yourself out.

---

## Core layer — the plumbing everything else uses

### Docker + Compose
**What it is:** the technology that runs each service in its own isolated
"container." Compose describes a service in a simple file.
**Why you want it:** instead of installing software directly on your server (and
fighting version conflicts), each service runs in a clean, self-contained box.
Install, update, or remove one without disturbing the others. tuninforge installs
this for you.
**Analogy:** shipping containers — each app packed in its own standard box that
runs the same anywhere.

### Caddy
**What it is:** a reverse proxy with automatic HTTPS.
**Why you want it:** you have several web services, but you don't want to
remember port numbers or deal with certificate warnings. Caddy sits in front,
gives each a clean `https://name.your-tailnet.ts.net` address, and gets valid
TLS certificates automatically.
**Analogy:** a receptionist who routes visitors to the right office and checks
everyone's ID at the door.

### Portainer
**What it is:** a web dashboard for Docker.
**Why you want it:** see all your running containers, their logs, and resource
use in a browser instead of typing commands. Great for beginners who'd rather
click than memorize `docker` commands.

### Watchtower
**What it is:** an automatic updater for your containers.
**Why you want it:** it watches for new versions of the apps you've opted in and
updates them for you. tuninforge scopes it carefully — it **never** auto-updates
your databases (those you update deliberately, after a backup).

---

## Data layer — where your information lives

### PostgreSQL
**What it is:** a powerful, reliable relational database (tables, rows, SQL).
**Why you want it:** many apps (including n8n here) need somewhere to store
structured data. Postgres is the trusted default. You rarely use it directly —
other services store their data in it.
**Analogy:** a meticulous filing cabinet other apps keep their records in.

### Redis
**What it is:** an in-memory data store — extremely fast, used for caching and
queues.
**Why you want it:** apps use it to remember temporary things quickly (sessions,
job queues, cached results) instead of hitting the slower database every time.
**Analogy:** a sticky-note board for things you need instantly but not forever.

### MinIO
**What it is:** S3-compatible object storage — like running your own Amazon S3.
**Why you want it:** somewhere to store files/blobs (backups, uploads, images,
datasets) via the standard S3 API, on your own hardware. Apps that "upload to
S3" can point at MinIO instead.
> Note: the free MinIO edition is winding down — see [minio.md](minio.md) for
> alternatives before relying on it long-term.

### Qdrant
**What it is:** a vector database — stores data as "embeddings" for
similarity/semantic search.
**Why you want it:** it powers AI features like "find things *similar in
meaning*" (semantic search, recommendations, RAG for chatbots). If you're
building anything with AI + your own documents, this is where the searchable
"memory" lives.
**Analogy:** a librarian who finds books by *what they're about*, not just their
exact title.

---

## AI layer — running models yourself

### Ollama
**What it is:** runs large language models (LLMs) locally on your own machine.
**Why you want it:** chat with AI models privately, with no API bills and no data
leaving your server. Download a model and it just runs.
> Note: models are big (4–40 GB each) and run faster with a GPU — see
> [ollama.md](ollama.md).

### LiteLLM
**What it is:** a universal gateway that speaks the OpenAI API in front of many
model providers.
**Why you want it:** your apps talk to *one* endpoint with *one* API key, and
LiteLLM routes to your local Ollama models **or** cloud providers (OpenAI,
Gemini, etc.). Swap the backend without changing your app.
**Analogy:** a universal remote for AI models.

---

## Automation layer

### n8n
**What it is:** a visual workflow-automation tool (think "if this, then that,"
but far more powerful).
**Why you want it:** connect apps and APIs with drag-and-drop nodes — automate
notifications, data syncs, scheduled jobs, AI pipelines — without writing a
full program. It stores its workflows in Postgres and uses Redis for queues
(which is why picking n8n auto-adds both).

---

## Observability layer — knowing what your stack is doing

### Prometheus (+ node-exporter + cAdvisor)
**What it is:** collects and stores **metrics** — numeric measurements over time
(CPU, memory, disk, per-container usage). node-exporter reports host stats;
cAdvisor reports per-container stats.
**Why you want it:** answer "is my server running out of memory?" or "which
container is eating the CPU?" with real data, and power graphs/alerts.
**Analogy:** the dashboard gauges in a car — speed, fuel, engine temp.

### Loki
**What it is:** a log database — stores the text logs your containers produce.
**Why you want it:** instead of SSHing around running `docker logs` on each
container, all logs land in one searchable place.
**Analogy:** a single searchable inbox for every app's diary entries.

### Alloy
**What it is:** the agent that collects logs from every container and ships them
to Loki, automatically.
**Why you want it:** zero setup — it discovers all your containers and forwards
their logs, so new services show up in your logs with no extra config. (It's the
maintained successor to the older "Promtail.")

### Grafana
**What it is:** the dashboards front-end — turns Prometheus metrics and Loki logs
into graphs and views.
**Why you want it:** this is where you *look* at everything: CPU graphs, memory
trends, live logs, all in one browser tab. tuninforge pre-wires it with a
starter dashboard.
**Analogy:** the cockpit display that shows all the gauges and warning lights
together.

---

## Backup layer

### Restic
**What it is:** an encrypted, deduplicated backup tool.
**Why you want it:** your databases and files are valuable — Restic backs them up
safely (encrypted, so even the backup storage can't read them) and can send
copies off-site (S3, Backblaze, another server). **A backup you've never
restored isn't a backup** — see [backup.md](backup.md) for how to test yours.
**Analogy:** a fireproof safe with an off-site copy of the key documents.

---

## Which should a beginner start with?

You don't need the whole stack. A sensible first run:

- **Just the essentials:** Tailscale (safe access) + Caddy + Portainer (the
  QuickStart default). Now you can reach a dashboard privately.
- **Add a real app:** n8n (it brings Postgres + Redis automatically) to start
  automating things.
- **Add visibility later:** Prometheus + Grafana + Loki + Alloy when you want to
  *see* how it's all doing.

Add anything anytime with `./tuninforge.sh add <service>` — nothing is permanent.
