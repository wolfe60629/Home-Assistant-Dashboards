# Home Assistant sync

Small repo: **`Sync-HaConfig.ps1`** + **`ha-sync.config.json`** (copy from **`ha-sync.config.example.json`**) + your tracked HA files (YAML, **`.storage/`**, etc.).

**Flow:** On production Home Assistant you keep a **Nonprod** dashboard (storage id **`nonprod`**). Edit there, run **`scripts\Pull-Nonprod.cmd`**, commit, merge what you want into **`.storage/lovelace`** on **`master`**, then **`scripts\Push.cmd`** (or **`Push -Scope Lovelace`**) to ship the main dashboard.

---

## Windows shortcuts (`scripts\`)

| Script | What it runs |
|--------|----------------|
| **`Pull.cmd`** | Full pull: `configuration.yaml`, YAML artifacts, all `lovelace*` in `.storage/` |
| **`Push.cmd`** | Full push (same set) |
| **`Pull-Nonprod.cmd`** | Only the Nonprod slice: `lovelace.nonprod`, `lovelace_dashboards`, `lovelace_resources` |
| **`Push-Nonprod.cmd`** | Push that slice back |

From repo root in PowerShell you can always run:

`.\Sync-HaConfig.ps1 Pull` · `.\Sync-HaConfig.ps1 Push` · `-Scope Lovelace` · `-Scope LovelaceNonprod` · `-Scope Artifacts` · `-Scope Config`

---

## Do not commit

`ha-sync.config.json`, `secrets.yaml`

---

## Troubleshooting

SSH errors: keys, `authorized_keys`, or add **`-AllowPasswordPrompt`** to the script line in the `.cmd` file.

If **Pull-Nonprod** skips **`lovelace.nonprod`**, create the dashboard in HA (Settings → Dashboards) with URL path **`nonprod`**.
