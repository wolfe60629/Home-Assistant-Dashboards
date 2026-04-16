# Workflow: production, dev preview, git, and back to production

For setup, prerequisites, and command tables, start with the repo **[README.md](../README.md)**.

This repo is the **single source of truth** for what you ship to Home Assistant. The Docker folder **`dev/ha-config/`** is a **disposable full clone** of production (gitignored): use it to preview and click-test, not as the thing you merge.

---

## Golden rules

1. **`master` is deployable** — merge only when you are willing to push the same tree to production (or when the diff is intentionally not yet deployed and you document that).
2. **Never commit** `ha-sync.config.json`, `secrets.yaml`, or **`dev/ha-config/`**.
3. **Branch for every change** — `git checkout -b feature/short-description` from up-to-date `master`.
4. **Pull before you push (both meanings)** — `git pull` on `master` before starting work; consider **`scripts\Pull-HaConfig.cmd`** before editing if someone else may have changed prod.
5. **Prod receives commits, not experiments** — ship only what is in the PR diff; dev-UI-only edits must be copied into tracked files before commit (see step 4).

---

### Repository layout

| Path | Purpose |
|------|---------|
| **`docs/`** | Process documentation (this file). |
| **`scripts/`** | Windows `.cmd` launchers that call `Sync-HaConfig.ps1` from the repo root. |
| **`dev/`** | `docker-compose.yml`, `Run-Nonprod.cmd`, `Prepare-DevConfig.ps1`, `Apply-NonprodDashboard.ps1`, **runtime** `dev/ha-config/` (ignored). |
| **Repo root** | `Sync-HaConfig.ps1`, `ha-sync.config.example.json`, YAML and other files you commit. |

---

## What lives where

| Location | Role | In git? |
|----------|------|--------|
| Repo root YAML (`configuration.yaml`, `automations.yaml`, …) | What you intend to run in prod | Yes |
| Repo `.storage/lovelace*` (and other HA files you track) | Dashboards / resources | Yes (if tracked) |
| **`dev/ha-config/`** | Full `/config` mirror (DB, secrets, HACS, all `.storage`) | **No** |
| **`ha-sync.config.json`** | SSH + Docker targets | **No** (use `ha-sync.config.example.json` as template) |
| **`.ha-assistant-context/`** | Optional registry snapshots for AI/tools | **No** (default in `.gitignore`) |
| **`Sync-HaConfig.ps1`** | Automation entry point | Yes |

---

## 1. Pull production into the dev environment

**Goal:** Local Home Assistant in Docker matches prod closely enough to validate dashboards and automations.

### Full mirror (recommended)

1. Stop the dev stack (avoids locked files on Windows when unpacking):
   ```bat
   cd dev
   docker compose down
   ```
2. From the **repo root**:
   ```bat
   scripts\Pull-ProdToDev.cmd
   ```
   Or: `powershell -NoProfile -File .\Sync-HaConfig.ps1 PullDev`  
   Faster/smaller archive (skips SQLite DB): `.\Sync-HaConfig.ps1 PullDev -ExcludeDatabase`
3. Start dev:
   ```bat
   cd dev
   docker compose up -d
   ```
4. Open **http://localhost:8123** — use the **same credentials** as production for this clone.

### Light preview (git only, no SSH)

`dev\Prepare-DevConfig.ps1` copies repo YAML + repo `.storage/lovelace*` into `dev/ha-config`. Custom Lovelace cards may still error without `custom_components` / `www` in that folder.

### Non-Prod dashboard (Docker, no full clone)

Run **`dev\Run-Nonprod.cmd`** (same as **`Start-DashboardDev.cmd`**): `docker compose down`, prepare from repo, **`Apply-NonprodDashboard.ps1`** (adds sidebar **Non-Prod** with built-in cards only), then **`docker compose up -d`**. Open **http://localhost:8123** and use **Non-Prod** when the main UI shows custom-card errors.

---

## 2. Make changes

Choose **one primary workflow** so you always know what to commit.

| Mode | Where you edit | To ship to prod |
|------|------------------|-----------------|
| **Repo-first** (recommended) | Cursor / IDE on tracked files | Commit those files; refresh dev with `Prepare-DevConfig.ps1` or `PullDev` as needed. |
| **UI-first (dev)** | Home Assistant UI against Docker dev | Copy or export changed pieces from `dev/ha-config/` into repo paths, then commit (see step 4). |

**Tip:** For small Lovelace tweaks, **repo-first** keeps history and review simple.

---

## 3. Review and approve (before opening a PR)

- [ ] Behavior verified in **dev** (or you accept repo-only change risk).
- [ ] `git status` shows **only** intended files (no `ha-sync.config.json`, no paths under `dev/ha-config/`).
- [ ] `git diff` read once for typos, wrong `entity_id`, and accidental secrets.
- [ ] If you changed **`configuration.yaml`**, confirm related files (`secrets.yaml` on prod, packages, etc.) remain consistent.

---

## 4. Open a pull request into `master`

1. `git fetch` and branch from current `master`.
2. Commit **tracked** files only; push branch; open PR.
3. Get review (self-review counts for solo work—use the checklist above).

### Merging dev-UI edits into the repo

**Default path:** run **`Promote-DevToRepo.ps1`** (or **`scripts\Promote-DevToRepo.cmd`**) from the repo root.

```powershell
.\Promote-DevToRepo.ps1 -DryRun   # preview
.\Promote-DevToRepo.ps1           # copies YAML + .storage/lovelace* from dev/ha-config into the repo
```

Promote **skips** dev-only **`lovelace.nonprod`** and removes the **Non-Prod** dashboard row from **`lovelace_dashboards`** in the repo so production never references Docker-only dashboards.

Optional: **`-IncludeThemes`** if you keep themes under `dev/ha-config/themes`. Then **`git diff`**, branch, commit.

**Manual path** (anything the script does not cover—packages, `blueprints/`, nonstandard paths):

| You changed in dev UI | Copy into repo (examples) |
|------------------------|---------------------------|
| Split includes / packages | Copy the same relative paths you use in prod. |
| Blueprints | `dev/ha-config/blueprints/` → repo if you version them. |

---

## 5. After merge: deploy to production

### Pre-deploy

- [ ] `git checkout master && git pull` — you are deploying **exactly** what is on remote `master`.
- [ ] Optional but safe: `scripts\Pull-HaConfig.cmd` once to confirm prod has not drifted with hotfixes you forgot to capture.

### Deploy

```bat
scripts\Push-HaConfig.cmd
```

Or: `powershell -NoProfile -File .\Sync-HaConfig.ps1 Push`

### Post-deploy

- [ ] In prod Home Assistant: **Developer tools → YAML** — reload automations / template entities / manual sections as needed.
- [ ] If you pushed **Lovelace `.storage`**, restart HA or follow the on-screen note if the UI does not refresh.
- [ ] Smoke-test the one or two things you changed (device, view, automation trace).

---

## Keeping GitHub in sync with “what prod actually has”

If you (or family) changed something **only** in the production UI:

```bat
scripts\Pull-HaConfig.cmd
```

Review the diff, commit on a branch, PR to `master` so the repo stops lying.

---

## Script quick reference (from repo root)

| Step | Script / command |
|------|------------------|
| Prod → git (config + YAML + Lovelace + context per config) | `scripts\Pull-HaConfig.cmd`, `scripts\Pull-HaContext.cmd` |
| Prod → **`dev/ha-config`** (full mirror) | `scripts\Pull-ProdToDev.cmd` (root **`Pull-ProdToDev.cmd`** is a shim) |
| Git → prod | `scripts\Push-HaConfig.cmd` (or root shim) |
| **Dev mirror → repo** (YAML + Lovelace storage) | **`Promote-DevToRepo.ps1`** or `scripts\Promote-DevToRepo.cmd` |
| Git slices → `dev/ha-config` only | `dev\Prepare-DevConfig.ps1` then `docker compose up` in `dev/` |

Sync launchers call **`Sync-HaConfig.ps1`**; see its header comment for flags.

---

## Optional improvements (later)

- **Post-merge automation:** trusted runner that `git pull` + `scripts\Push-HaConfig.cmd` (only if you accept unattended prod writes).
- **Extend `Promote-DevToRepo.ps1`** with more allowlisted paths (e.g. `blueprints/`) if you want one-click promotion for those too.
