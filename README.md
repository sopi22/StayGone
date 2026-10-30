# StayGone

**Keeps removed Windows bloatware gone.**

You uninstall Xbox, Clipchamp or Solitaire, and after the next Windows update
they're back. That happens because uninstalling only removes an app for *your*
account: Windows keeps a hidden "provisioned" copy and reinstalls it, often
during updates.

StayGone removes the apps on your blocklist **for all users, including the
hidden copy**, and can install a small **watcher** that checks again right
after every successful Windows update and at sign-in. If something came back,
it removes it again and tells you with a notification.

- Plain PowerShell 5.1, built into every Windows 10/11 PC. Nothing to install.
- No network access, no telemetry.
- Core Windows parts (Store, App Installer, Windows Security, Photos,
  Calculator, Notepad, Terminal, ...) are **protected in code** and are never
  removed, even if you list them.

## Tech stack

- Windows PowerShell 5.1 (Appx, DISM provisioning and Task Scheduler cmdlets)
- Windows notifications through the built-in WinRT API (no extra modules)
- [Pester](https://pester.dev) 5+ for tests, run on Windows by GitHub Actions
- No Docker: it manages Windows itself, so a container would add nothing.

## Inspiration and credit

StayGone is an independent project written from scratch. Two open-source
projects influenced its design:

- [Win11Debloat](https://github.com/Raphire/Win11Debloat) (MIT): removing apps
  for all users *and* deprovisioning them, so they don't return for new
  accounts. Great for a one-time cleanup; StayGone adds the "keep it clean"
  part.
- [Update Arbiter](https://github.com/Arcusfoundry/update-arbiter) (MIT): the
  idea of a scheduled task that re-applies settings right after Windows Update
  finishes installing.

No code was copied from either project.

## Setup and run

1. Download: click **Code -> Download ZIP** on this page and extract it, or:

   ```powershell
   git clone https://github.com/sopi22/StayGone.git
   cd StayGone
   ```

2. Open PowerShell in that folder. Safe, read-only first look:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\StayGone.ps1 check
   ```

3. For the commands that change the system, open PowerShell with
   **Run as administrator**, go to the folder, then:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\StayGone.ps1 remove -WhatIf   # preview, changes nothing
   powershell -ExecutionPolicy Bypass -File .\StayGone.ps1 remove           # remove now
   powershell -ExecutionPolicy Bypass -File .\StayGone.ps1 watch-on         # keep them gone automatically
   ```

`-ExecutionPolicy Bypass` applies only to that one run; it doesn't change your
system's settings.

**Before removing anything, create a restore point:** Start -> type
"Create a restore point" -> System Protection tab -> **Create...**

## Commands

| Command | What it does | Admin? |
|---|---|---|
| `check` | Shows which blocklisted apps are installed (read-only) | no* |
| `remove [-WhatIf]` | Removes them now for all users, including hidden copies | yes |
| `watch-on` | Installs the watcher (runs after updates and at sign-in) | yes |
| `watch-off` | Removes the watcher | yes |
| `status` | Is the watcher on? When did it last run? | no |
| `restore <App>` | Takes an app off the blocklist and opens its Store page | no |
| `list` / `edit` | Shows / edits your blocklist | no |
| `log [-Tail N]` | Shows what StayGone did | no |
| `about` | Version and author | no |

\* Without admin rights, `check` can only see your own apps, not other users'
or the hidden copies. It says so when that happens.

## Features

- **Blocklist** you control: one package name per line, `*` wildcards,
  `#` comments. Starts from a conservative default (Xbox apps, Clipchamp,
  Solitaire, Office Hub, Teams personal, News, Tips, Feedback Hub, ...).
- **Removal that sticks:** uninstalls for all users *and* removes the
  provisioned copy.
- **Watcher:** a scheduled task that runs 2 minutes after sign-in and 1 minute
  after each successful Windows update (System event 19 from Windows Update).
  It runs a copy of StayGone kept in `C:\ProgramData\StayGone\app`, so it keeps
  working even if you move or delete the downloaded folder.
- **Notifications:** "StayGone removed 1 app after a Windows update - GamingApp
  came back and was removed again."
- **Preview mode:** `remove -WhatIf` shows exactly what would happen.
- **Undo:** `restore <App>` stops StayGone from removing it and opens the
  app's Microsoft Store page so you can reinstall it.
- **Log** of every removal: `C:\ProgramData\StayGone\staygone.log`.

## Where StayGone keeps its files

Everything lives in `C:\ProgramData\StayGone\`:

| File | Purpose |
|---|---|
| `blocklist.txt` | Your blocklist (created from `config\blocklist.default.txt` on first run) |
| `staygone.log` | What happened and when |
| `removed.json` | Record of removed apps, used by `restore` |
| `app\` | The copy of StayGone the watcher runs |

To remove StayGone completely: run `watch-off` as administrator, then delete
that folder.

## Running the tests

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5 -SkipPublisherCheck
Invoke-Pester .\tests
```

The tests use fake package data only. They never read or change your real
apps.

## Author

Developed by **Jhoana Sophia C. Munar** ([@sopi22](https://github.com/sopi22)).

## License

[MIT](LICENSE) - Copyright (c) 2026 Jhoana Sophia C. Munar.
