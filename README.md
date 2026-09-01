# agents-deploy

Deployment scaffolding for running [Nanobot](https://github.com/HKUDS/nanobot) Telegram AI
agents on a single VPS — multiple independent profiles on one host, each with its own
container, network, config and secrets.

This is the **infrastructure half** of a working two-profile deployment: one general-purpose
personal assistant, one operations bot for a physiotherapy clinic. The agent content itself
(`workspace/`, `SKILL.md` files, per-user memory) is **not** published — it contains business
and patient data. What's here is the part that generalizes: host bootstrap, profile-aware
deploy, and a safety net for agent-authored skills.

```
.
├── shared/scripts/setup-vps.sh    # vendor-neutral host bootstrap (Docker, UFW, swap)
└── nanobot/
    ├── instances/{personal,boost}/
    │   ├── docker-compose.yml     # deployed verbatim to the VPS
    │   ├── config.json.template   # envsubst-hydrated on the VPS from secrets.env
    │   ├── .env.example           # documentation only; real secrets never leave the VPS
    │   └── required-keys.txt      # deploy pre-flight checks these are non-empty
    ├── scripts/                   # setup-host.sh, deploy.sh, sync-skills.sh
    └── docs/playbook.md           # walkthrough from the original bring-up
```

## Quick start

```bash
# 1. Bootstrap a fresh VPS (run on the VPS, as root)
shared/scripts/setup-vps.sh

# 2. One-time per-profile host setup (run on the VPS)
./nanobot/scripts/setup-host.sh personal

# 3. Fill in /opt/nanobot/secrets.env on the VPS, then deploy from your laptop
export NANOBOT_VPS=root@your.vps.ip
./nanobot/scripts/deploy.sh personal
```

`NANOBOT_VPS` is required — the scripts fail fast rather than defaulting to a host.

## How profiles work

`deploy.sh <profile>` derives everything from the profile name: `personal` lives at
`/opt/nanobot/`, anything else at `/opt/nanobot-<profile>/`. Each profile gets its own compose
project, network, containers and `secrets.env`, so profiles can run side by side on one host
without touching each other. Adding one is `cp -r nanobot/instances/personal
nanobot/instances/<new>` plus edits to the four files above.

## The agent-skill safety net

Nanobot agents can write their own `SKILL.md` files into the live workspace. A naive
`rsync --delete` would destroy them on the next deploy, so `deploy.sh` refuses to run when the
VPS has skills the repo doesn't:

```bash
./nanobot/scripts/sync-skills.sh <profile> pull    # copy VPS workspace down for review
./nanobot/scripts/sync-skills.sh <profile> diff    # which VPS skills aren't in this repo?
./nanobot/scripts/sync-skills.sh <profile> check   # nonzero exit if unreconciled (deploy runs this)
```

You then either promote them into the repo or delete them on the VPS. It compares directory
names only — it will not catch an edit to a skill that already exists in both places.

## Secrets

Secrets never live in this repo. The chain is: `secrets.env` on the VPS (chmod 600, created by
`setup-host.sh`) → `envsubst` hydrates `config.json.template` during deploy → compose passes it
via `env_file` → nanobot's `tools.exec.allowedEnvKeys` gates which variables the agent's `exec`
tool can actually see. `.env.example` documents the shape; `required-keys.txt` is what the
deploy pre-flight enforces.

## Notes

- `--force-recreate` is required after changing `env_file` or compose; a plain deploy only
  restarts the container, which is enough for config and workspace changes.
- The personal profile's compose references a private container image for an internal MCP
  server. Remove that service or substitute your own.
- `setup-host.sh` clones nanobot upstream unpinned. Pin a tag if you care about reproducibility.
