# Home Assistant sync

Git is the **source of truth** for YAML and Lovelace you merge to `master`. **`Sync-HaConfig.ps1`** pulls/pushes to your production host over **SSH + Docker**. **`dev/ha-config/`** is a **local-only** Home Assistant profile (gitignored).

---

## Quick start

1. Copy **`ha-sync.config.example.json`** → **`ha-sync.config.json`** and edit (never commit it).
2. Put your SSH key on the HA host user (or set `SshIdentityFile`).
3. Test: `powershell -File .\Sync-HaConfig.ps1 Pull -Scope Config`

**Non-production Home Assistant (Docker):** double-click **`dev\Run-Nonprod.cmd`**  
That copies the repo into `dev/ha-config`, adds a **Non-Prod** sidebar dashboard (built-in cards only), and runs `docker compose up -d`. Open **http://localhost:8123** and use **Non-Prod** in the sidebar. For a **full** copy of prod (HACS, DB, everything), stop the stack and run **`scripts\Pull-ProdToDev.cmd`**.

Full process (PRs, prod deploy, checklists): **[docs/WORKFLOW.md](docs/WORKFLOW.md)**

---

## Commands (repo root)

| Goal | Command |
|------|---------|
| Prod → git (config, YAML, Lovelace, …) | `scripts\Pull-HaConfig.cmd` or `Pull-HaConfig.cmd` |
| Prod → git (assistant registries only) | `scripts\Pull-HaContext.cmd` |
| Prod → **`dev/ha-config`** (entire `/config`) | `scripts\Pull-ProdToDev.cmd` (run `cd dev` + `docker compose down` first) |
| Git → prod | `scripts\Push-HaConfig.cmd` |
| Dev UI → git (YAML + `lovelace*`) | `.\Promote-DevToRepo.ps1` (`-DryRun` first; omits dev-only `lovelace.nonprod` and strips Non-Prod from `lovelace_dashboards`) |

PowerShell: `.\Sync-HaConfig.ps1 Pull | Push | PullDev` - see comment help at top of **`Sync-HaConfig.ps1`**.

---

## Layout

| Path | Role |
|------|------|
| **`Sync-HaConfig.ps1`** | Sync engine |
| **`scripts/*.cmd`**, root **`Pull*.cmd` / `Push*.cmd`** | Shortcuts into the script |
| **`dev/Run-Nonprod.cmd`**, **`Prepare-DevConfig.ps1`**, **`Apply-NonprodDashboard.ps1`** | Nonprod Docker workflow |
| **`Promote-DevToRepo.ps1`** | Copy from `dev/ha-config` back into the repo |
| **`docs/WORKFLOW.md`** | Branch / PR / deploy checklist |

---

## Safety

Do not commit **`ha-sync.config.json`**, **`secrets.yaml`**, or **`dev/ha-config/`**. **`PullDev`** copies real prod tokens into `dev/ha-config`. **`BackupOnPush`** in config helps on prod pushes.

---

## Troubleshooting

| Issue | Check |
|-------|--------|
| SSH / BatchMode | Keys, `authorized_keys`, or `-AllowPasswordPrompt` |
| `PullDev` unpack on Windows | Docker Desktop running (extract uses Linux `tar` in Docker) |
| Custom cards 404 in dev | Expected with repo-only prepare — use **Non-Prod** dashboard or full **`PullDev`** |
