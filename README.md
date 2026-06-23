# Novopay Branch Updater

Syncs configured `ddp-*` / `dsa-*` branches across all git repos under your novopay workspace.

## Quick start

1. Copy `config.local.json.example` to `config.local.json` if your novopay root is not `Desktop\novopay`.
2. Double-click `run.cmd` **or** use the IntelliJ external tool (below).
3. Optional: double-click `register-schedule.cmd` for weekday 9 AM / 9 PM idle-only runs.

## Configure

Edit `config.json` (team defaults) or `config.local.json` (your machine only).

| Setting | Purpose |
|---------|---------|
| `novopayRoot` | Path to novopay folder. Empty = auto (`tools/../..`) |
| `novopayRootEnv` | Env var override (default `NOVOPAY_ROOT`) |
| `reportDirectory` | Where HTML report is written. Empty = `.reports/` in this folder |
| `frontend.repos` / `frontend.branches` | Webapp repos use `dsa-*` branches |
| `backend.branches` | All other repos use these `ddp-*` branches |
| `allLocalBranchesRepos` | Repos where every **local** branch is updated |
| `excludedRepos` | Folder names to skip entirely |
| `preferredRepoOrder` | Process order; others run A-Z after |
| `scheduler` | Idle minutes, weekday times for Task Scheduler |

`bob-the-builder` is updated like any other backend repo (same `ddp-*` branches).

## IntelliJ / WebStorm

**Option A - Import external tool (recommended)**

1. Open the **novopay** root project (or `novopay.code-workspace`).
2. Copy `intellij/externalTools.xml` to `.idea/externalTools.xml` in the novopay root.
3. Restart IDE or reload project.
4. **Settings - Tools - External Tools - Novopay Branch Updater** - assign a shortcut (e.g. `Ctrl+Alt+U`).
5. Run from **Tools - External Tools** or the shortcut.

**Option B - Manual external tool**

| Field | Value |
|-------|-------|
| Program | `cmd.exe` |
| Arguments | `/c "$ProjectFileDir$\tools\novopay-branch-updater\run.cmd"` |
| Working directory | `$ProjectFileDir$` |

If you open only a single service repo (not novopay root), set `NOVOPAY_ROOT` in your environment or use `config.local.json`.

## Behaviour

- Auto-stashes uncommitted work before fetch; restores on your original branch after.
- Merge conflicts: abort and continue; listed in HTML report.
- Report opens in browser; file deleted when you close that tab.
- No log files stored.

## Files

```
novopay-branch-updater/
  config.json              Team defaults (commit this)
  config.local.json        Your overrides (gitignored)
  run.cmd                  Manual run
  register-schedule.cmd    One-time Task Scheduler setup
  scripts/                 PowerShell implementation
  intellij/                IDE external tool template
  .reports/                Generated report (gitignored)
```

## Share with team

Commit `tools/novopay-branch-updater/` to the novopay repo. Each developer copies `config.local.json.example` to `config.local.json` only if paths differ.
