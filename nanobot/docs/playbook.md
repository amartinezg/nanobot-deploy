# Nanobot PoC playbook — Hetzner VPS (Docker Compose edition)

> **Historical document.** These are the original bring-up notes from migrating one profile
> off a heavier agent stack ("OpenClaw") onto Nanobot. That stack is not part of this
> repository, so references to `openclaw-*` containers are context, not instructions. The
> resource numbers and host specs are from that machine in mid-2026 and are stale. Kept because
> the step-by-step Docker/MCP/Playwright bring-up is still an accurate walkthrough.

Target VPS: `root@<your-vps>` (Ubuntu 24.04, 2 vCPU, 3.7 GB RAM, ~16 GB free disk, Docker 29.1.3 already installed).
Goal: prove Nanobot can replace `openclaw-personal` for the listed requirements at much lower resource cost, with web search, Google Calendar, and browser tasks all working.
Coexistence: leave `openclaw-boost` running, stop `openclaw-personal`, run everything new as containers on a private compose network.

**Architecture this playbook builds:**

```
                Telegram ─────┐
                              │
           ┌──────────────────┴────────────────┐
           │           nanobot                  │      ◄── docker compose service
           │   (gateway, OpenRouter LLM,        │
           │    spawns stdio MCP children)      │
           └──┬───────┬────────────┬────────────┘
              │       │            │
   stdio  ┌───┘  stdio│        HTTP/SSE
   ▼      ▼           ▼            ▼
 ┌────────────┐ ┌────────────┐ ┌──────────────────┐
 │ mcp-remote │ │ mcp-remote │ │ playwright       │  ◄── docker compose service
 │ → Tavily   │ │ → Google   │ │ (Chromium MCP)   │
 │  (hosted)  │ │  Calendar  │ │                  │
 └────────────┘ │  (hosted)  │ └──────────────────┘
                └────────────┘
```

Memory budget after stopping `openclaw-personal`: ~2.1 GB free. Expected use: Nanobot ~100 MB, Playwright (Chromium idle) ~250–400 MB, mcp-remote children negligible. Plenty of room.

Disk budget: Playwright image is ~1.5 GB, Nanobot build ~200 MB. Of your 16 GB free, you'll spend ~1.7 GB. Watch the bar but you're fine.

---

## Phase 0 — Pre-reqs you collect off the VPS

No commands on the VPS yet. Get these in hand first:

1. **OpenRouter API key** — https://openrouter.ai/ → top up a few dollars → create key. Format `sk-or-v1-...`. Pick a default model: `anthropic/claude-haiku-4-5` is the cost-efficient default; bigger questions can spend `anthropic/claude-sonnet-4-6`.

2. **Telegram bot token** — DM `@BotFather` → `/newbot` → name + username → token (`1234567890:ABCdef...`).

3. **Your numeric Telegram user ID** — DM `@userinfobot` → it replies with your ID.

4. **Tavily API key** — https://tavily.com → sign up → dashboard → API key. Free tier is 1,000 searches/month, fine for a PoC. (If you'd rather use Brave Search, swap the MCP config block in Phase 4 — note at end of file.)

5. **Google Cloud setup for the hosted Calendar MCP** (source: https://developers.google.com/workspace/calendar/api/guides/configure-mcp-server):
   - Pick or create a project at https://console.cloud.google.com.
   - Enable the two APIs:
     ```bash
     gcloud services enable calendar-json.googleapis.com --project=YOUR_PROJECT_ID
     gcloud services enable calendarmcp.googleapis.com  --project=YOUR_PROJECT_ID
     ```
     (or click Enable in the Console.)
   - OAuth consent screen → External → add yourself as Test user → name "Calendar MCP Server" → add scopes:
     - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
     - `https://www.googleapis.com/auth/calendar.events.freebusy`
     - `https://www.googleapis.com/auth/calendar.events.readonly`
     - `https://www.googleapis.com/auth/calendar.events` *(add this one only if you want write access in the spike)*
   - Credentials → Create OAuth client → **Desktop app** → save the **Client ID** and **Client Secret**.

---

## Phase 1 — Make room and prepare the host

```bash
# 1.1 — free RAM and port 18790 by stopping openclaw-personal
docker stop openclaw-personal
free -h
df -hT /

# 1.2 — create a working directory for the PoC
mkdir -p /opt/nanobot-poc && cd /opt/nanobot-poc
mkdir -p nanobot-data

# 1.3 — clone Nanobot so we can docker build (no prebuilt image is published)
git clone https://github.com/HKUDS/nanobot.git
```

If `git` isn't installed: `apt update && apt install -y git`.

---

## Phase 2 — Boot Nanobot, smoke-test Telegram

### 2.1 — Drop the compose file

Create `/opt/nanobot-poc/docker-compose.yml`:

```yaml
services:
  nanobot:
    build: ./nanobot
    image: nanobot:local
    container_name: nanobot
    restart: unless-stopped
    env_file: ./secrets.env
    volumes:
      - ./nanobot-data:/home/nanobot/.nanobot
    ports:
      - "127.0.0.1:18790:18790"
    command: gateway
    networks:
      - agent-net
    mem_limit: 512m
    cpus: 1.0

  playwright:
    # Phase 5 fills this in; commented out for Phase 2 smoke test
    # uncomment + restart compose once we get to browser tasks
    image: mcr.microsoft.com/playwright:v1.50.0-noble
    container_name: playwright-mcp
    restart: unless-stopped
    command: sh -c "npx -y @playwright/mcp@latest --port 8931 --host 0.0.0.0 --headless --no-sandbox"
    expose:
      - "8931"
    networks:
      - agent-net
    mem_limit: 768m
    profiles: ["browser"]   # only starts when we add --profile browser

networks:
  agent-net:
    driver: bridge
```

### 2.2 — Drop the secrets file

Create `/opt/nanobot-poc/secrets.env`:

```bash
OPENROUTER_API_KEY=sk-or-v1-REPLACE_ME
TELEGRAM_TOKEN=1234567890:ABC_REPLACE_ME
TAVILY_API_KEY=tvly-REPLACE_ME
GOOGLE_OAUTH_CLIENT_ID=REPLACE_ME.apps.googleusercontent.com
GOOGLE_OAUTH_CLIENT_SECRET=GOCSPX-REPLACE_ME
```

Lock it down: `chmod 600 secrets.env`.

### 2.3 — Build the Nanobot image and run onboard

```bash
cd /opt/nanobot-poc
docker compose build nanobot
# fix ownership of the mounted data dir to UID 1000 (the nanobot user inside the container)
sudo chown -R 1000:1000 ./nanobot-data
# one-time interactive setup; writes nanobot-data/config.json
docker compose run --rm nanobot onboard
```

### 2.4 — Write the initial config

Edit `/opt/nanobot-poc/nanobot-data/config.json`. Start with this minimal version — we add MCPs in Phases 3, 4, 5:

```json
{
  "providers": {
    "openrouter": { "apiKey": "${OPENROUTER_API_KEY}" }
  },
  "agents": {
    "defaults": {
      "provider": "openrouter",
      "model": "anthropic/claude-haiku-4-5"
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "token": "${TELEGRAM_TOKEN}",
      "allowFrom": ["YOUR_NUMERIC_TELEGRAM_ID"]
    }
  },
  "gateway": {
    "port": 18790,
    "bind": "0.0.0.0"
  },
  "tools": {
    "mcpServers": {}
  }
}
```

Re-fix ownership after editing: `sudo chown -R 1000:1000 ./nanobot-data`.

### 2.5 — Start the gateway

```bash
docker compose up -d nanobot
docker compose logs -f nanobot
```

**Smoke test:** open Telegram, find your bot, send `hi`. You should get an LLM reply within ~5 seconds. If not:
- Check the logs for auth errors (wrong OpenRouter key) or `allowFrom` rejections (wrong Telegram ID).
- Confirm `allowFrom` is the **numeric** ID, not your `@username`.

Ctrl-C exits the `logs -f`; the container stays running.

---

## Phase 3 — Add Google Calendar (hosted MCP)

We bridge Google's hosted MCP into Nanobot using `mcp-remote`, a small npm package that runs as a stdio child and proxies to remote MCP over HTTP+OAuth, handling the OAuth flow and refresh token persistence for us.

Why the bridge rather than direct HTTP MCP? My research only verified Nanobot's HTTP MCP support with static `Authorization` headers — `mcp-remote` removes that uncertainty by presenting Google's MCP to Nanobot as a stdio server, which Nanobot definitely supports.

### 3.1 — Add the Calendar block to `mcpServers`

Edit `nanobot-data/config.json` → replace the `mcpServers` block with:

```json
"mcpServers": {
  "calendar": {
    "command": "npx",
    "args": [
      "-y", "mcp-remote",
      "https://calendarmcp.googleapis.com/mcp/v1",
      "--oauth-client-id", "${GOOGLE_OAUTH_CLIENT_ID}",
      "--oauth-client-secret", "${GOOGLE_OAUTH_CLIENT_SECRET}"
    ]
  }
}
```

`sudo chown -R 1000:1000 ./nanobot-data` after saving.

### 3.2 — First-run OAuth (headless via SSH tunnel)

`mcp-remote` opens a local HTTP server on port 6274 for the OAuth redirect. On a headless box we tunnel that port to your laptop so the browser redirect lands on something your browser can reach.

```bash
# from your LAPTOP, in a separate terminal — keep this open during the auth dance
ssh -L 6274:localhost:6274 root@<your-vps>
```

```bash
# back on the VPS, restart nanobot so it spawns the new MCP
cd /opt/nanobot-poc
docker compose restart nanobot
docker compose logs -f nanobot
```

When the log prints a Google authorization URL, paste it into your **laptop** browser. Sign in → approve scopes → Google redirects to `http://localhost:6274/...` → SSH tunnel forwards it to the VPS → `mcp-remote` writes a refresh token under `nanobot-data/.mcp-auth/`. You do this dance once; afterwards tokens self-refresh.

### 3.3 — Test from Telegram

- *"What's on my calendar tomorrow?"* → should call `list_events`.
- *"Create an event 'PoC calendar test' tomorrow at 10am for 30 minutes."* → should call `create_event` (requires the `calendar.events` write scope from Phase 0).

If the bot answers but doesn't have the tool, the MCP didn't load — `docker compose logs nanobot | grep -i calendar` will show why (typical causes: stale config not mounted, wrong client ID, expired test-user grant).

---

## Phase 4 — Add Tavily web search

Tavily hosts its own MCP at `https://mcp.tavily.com/mcp/`. Same bridge pattern as Calendar.

### 4.1 — Extend `mcpServers`

```json
"mcpServers": {
  "calendar": { "...": "as above" },
  "web-search": {
    "command": "npx",
    "args": [
      "-y", "mcp-remote",
      "https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"
    ]
  }
}
```

`sudo chown -R 1000:1000 ./nanobot-data` and `docker compose restart nanobot`.

### 4.2 — Test from Telegram

- *"What's on the F1 2026 calendar for the next Grand Prix? Give me the session times in my local timezone."* → should call Tavily, return event + session table with citations.
- *"Summarize the most recent stage of the Giro d'Italia 2026 — who won, key moments."* → should return a paragraph + cited source URLs.

If results feel thin, the model might be summarising stale knowledge instead of calling the tool — open `docker compose logs nanobot` while running the query and look for an MCP invocation. If absent, prompt more directly: *"Use web search to find..."*.

---

## Phase 5 — Add Playwright browser MCP

This is the resource-heaviest piece. Chromium idle is ~250 MB, peaks higher during page loads. We isolate it in its own container with a 768 MB cap.

### 5.1 — Bring up the playwright service

The `playwright` service in your compose file is gated behind `profiles: ["browser"]` so it only starts on demand:

```bash
cd /opt/nanobot-poc
docker compose --profile browser up -d playwright
docker compose logs -f playwright
```

Wait for the log line indicating the MCP is listening on `:8931`. Note the actual endpoint path it prints (typically `/sse` or `/mcp`).

### 5.2 — Extend `mcpServers` with the browser

Add to `nanobot-data/config.json`:

```json
"browser": {
  "url": "http://playwright:8931/sse"
}
```

(If the playwright log printed a different path, match it here.)

`sudo chown -R 1000:1000 ./nanobot-data` and `docker compose --profile browser restart nanobot playwright`.

### 5.3 — Test from Telegram

- *"Open https://www.futbolenvivocolombia.com and list the soccer games scheduled for today with kickoff times."* → expects the agent to call a browser tool (`browser_navigate` + `browser_snapshot` or similar), extract today's matches, return a tidy list.

If the agent answers from memory instead of navigating, prompt more directly: *"Use the browser tool to visit ..."*. If it tries but the page is JS-heavy and doesn't render fully, add: *"... after waiting for the page to fully load and clicking any 'today' filter."*

---

## Phase 6 — Verification

The three scenarios you asked for, plus the baseline checks:

| Check | How to trigger from Telegram | Pass criteria |
|---|---|---|
| Telegram DM round-trip | `hi` | Reply in <10s |
| Group chat | Add bot to a group, mention it: `@yourbot hi` | Replies |
| General knowledge | "Capital of Peru?" | Correct |
| Reminder | "Remind me in 2 minutes to test" | Fires after 2 min |
| **F1 next GP agenda** | "Tell me the agenda with the times for the next F1 GP." | Returns FP1/FP2/Sprint/Quali/Race session times + dates, with at least one cited source URL |
| **Soccer schedule (browser)** | "Open https://www.futbolenvivocolombia.com and list the soccer games scheduled for today." | Lists today's matches with kickoff times; logs show a `browser_navigate` call |
| **Giro previous stage** | "Give me a summary of the previous stage in the Giro d'Italia." | Names the stage number, winner, key moments; cites sources |
| Calendar read | "What's on my calendar tomorrow?" | Real events from your Google Calendar |
| Calendar write | "Create event 'PoC verified' tomorrow at 14:00 for 15 minutes." | Event appears in your Google Calendar |
| Coexistence | `docker ps` | `openclaw-boost` and `nanobot` (and `playwright`) all up |
| **Resource use, idle** | `docker stats --no-stream` | nanobot MEM < 200 MB, playwright MEM < 400 MB |
| **Resource use, under load** | Run the soccer test, then `docker stats --no-stream` | Combined < 1 GB |

Write down the numbers from the last two rows. The headline PoC question is: *do Nanobot + Playwright + the MCPs deliver OpenClaw's functionality at under half its RAM?* (OpenClaw personal baseline was 707 MB.)

---

## Rollback

Everything is in `/opt/nanobot-poc/` and Docker. Rollback is fully clean:

```bash
cd /opt/nanobot-poc
docker compose --profile browser down
docker start openclaw-personal
# optionally: rm -rf /opt/nanobot-poc to fully remove
```

---

## Known gaps after this spike

| Requirement | Covered? |
|---|---|
| General questions, reminders | Yes |
| Google Calendar (read + write) | Yes — Google's hosted MCP |
| Web search | Yes — Tavily |
| Browser tasks | Yes — Playwright MCP |
| Gmail read | **No** — round 2; configure https://gmailmcp.googleapis.com/mcp/v1 the same way as Calendar |
| Drive / Sheets | **No** — round 2; configure https://drivemcp.googleapis.com/mcp/v1, plus Sheets API |
| WhatsApp | **No** — round 2; Nanobot has a bridge, needs separate auth (`docker compose run --rm nanobot channels login whatsapp`) |
| Telegram (DM + groups) | Yes |
| Multiple skills | Partially — Nanobot supports skills, none wired in spike |
| Other agents/tools | Yes — adding more MCPs is a config edit + restart |

---

## Swapping Tavily for Brave Search

If you'd rather use Brave (free 2,000 queries/month, more privacy-aligned), replace the `web-search` block in `mcpServers`:

```json
"web-search": {
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-brave-search"],
  "env": { "BRAVE_API_KEY": "${BRAVE_API_KEY}" }
}
```

Add `BRAVE_API_KEY=...` to `secrets.env`. Restart Nanobot.

---

## What to ping me with when you start

For Phase 1: just confirm `docker stop openclaw-personal` succeeded and the directory + clone are in place.
For Phase 2: paste the output of `docker compose build nanobot` (especially the last lines) plus the Telegram smoke-test result.
For each subsequent phase: tell me which test passed/failed and paste the relevant `docker compose logs` slice if something didn't.
