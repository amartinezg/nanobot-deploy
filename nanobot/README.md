# nanobot

Deployable [Nanobot](https://github.com/HKUDS/nanobot) agent — each profile runs as its own
pair of containers (`nanobot` + `playwright`) on a shared VPS.

This directory is the **source of truth** for every profile. The live state on the VPS is a
managed copy — never edit it by hand for anything that belongs here.

## Layout

```
nanobot/
├── instances/
│   ├── personal/                   # general-purpose assistant
│   └── boost/                      # clinic operations bot
│       ├── docker-compose.yml      # deployed verbatim to $NANOBOT_DIR/docker-compose.yml
│       ├── config.json.template    # envsubst-hydrated on the VPS from secrets.env
│       ├── .env.example            # documentation only; live secrets stay on the VPS
│       ├── required-keys.txt       # deploy pre-flight: these must be non-empty
│       └── workspace/              # NOT PUBLISHED — agent persona, skills, user memory
├── scripts/
│   ├── setup-host.sh               # one-time per-profile VPS bootstrap
│   ├── deploy.sh                   # repeat-safe push from local → VPS
│   └── sync-skills.sh              # the agent-skill safety net (pull/diff/check)
└── docs/playbook.md                # walkthrough from the original bring-up
```

**`workspace/` is intentionally absent.** In the private repo it holds `SOUL.md` (agent
persona), `USER.md` (accumulated user memory) and `skills/*/SKILL.md`. That content is
business- and patient-specific; the deploy machinery here works with any workspace you supply.

## Paths on the VPS

`deploy.sh` derives the install path from the profile: `personal` → `/opt/nanobot/`, anything
else → `/opt/nanobot-<profile>/`. Under each:

- `secrets.env` — chmod 600, edited via ssh, never pushed
- `nanobot-data/` — mounted as `/home/nanobot/.nanobot`; holds the hydrated `config.json`,
  `workspace/`, `media/telegram/` (downloaded attachments), sessions, memory, cron
- `gog`, `client_secret.json`, `gogcli-config/` — Google CLI binary + OAuth keyring
- `playwright-cache/` — `/ms-playwright` bind-mount, ~700 MB of chrome-for-testing
- `nanobot/` — cloned upstream source, fetched by `setup-host.sh`

## Operations

```bash
export NANOBOT_VPS=root@your.vps.ip

# One-time host bootstrap (run on the VPS, as root)
./nanobot/scripts/setup-host.sh <profile>

# Deploy after editing config or workspace (run locally)
./nanobot/scripts/deploy.sh <profile>
./nanobot/scripts/deploy.sh <profile> --force-recreate   # after env_file or compose changes

# Review what the agent created on the VPS
./nanobot/scripts/sync-skills.sh <profile> pull
./nanobot/scripts/sync-skills.sh <profile> diff
./nanobot/scripts/sync-skills.sh <profile> check         # deploy.sh runs this automatically
```

`deploy.sh` rsyncs **without** `--delete` and honours an optional `.deployignore`
(rsync syntax) to hold back files the agent owns on the VPS — typically `USER.md`, which the
agent rewrites as it learns. Without a `.deployignore`, a deploy overwrites the VPS copy, so
`pull` and diff before deploying.

## The agent-skill safety net

Nanobot agents can author new `SKILL.md` files in the live workspace. `deploy.sh` refuses to
run when the VPS has skills the repo doesn't, forcing you to promote or delete them first.

Two limits worth knowing: it compares **directory names only**, so an edit to a skill that
exists in both places is invisible and gets overwritten; and it does not validate frontmatter,
so a malformed `SKILL.md` deploys cleanly and fails at runtime.

## Adding a skill

Create `nanobot/instances/<profile>/workspace/skills/<name>/SKILL.md`, then deploy. Nanobot
auto-discovers it from `~/.nanobot/workspace/skills/`. Frontmatter convention:

```yaml
---
name: <kebab-case, matches the directory>
description: '<what it does; when to use it; key guardrail>'
metadata:
  nanobot:
    emoji: 📅
    requires:
      bins: [curl, python3]
      env: [SOME_API_KEY]
---
```

`requires.env` names must also appear in `tools.exec.allowedEnvKeys` in
`config.json.template`, or the agent's `exec` tool will not see them at runtime. Keep detail in
sibling `references/*.md` files and load them on demand — it keeps the system prompt small.

## Model tiering

`config.json.template` defines `modelPresets`; `agents.defaults.modelPreset` picks the default
and `fallbackModels` the fallback chain. Operators can switch mid-session from Telegram with
`/model <preset>`. The two profiles here default to different tiers — a cheap fast model for
general chat, a stronger one for the profile that does data reconciliation.
