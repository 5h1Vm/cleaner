# Cleaner

A one-file cleanup tool for Windows 10 and 11. Double-click `cleaner.bat` and it frees disk space from temp files, caches, logs, developer tool caches and virtual disks (WSL, Docker Desktop, Hyper-V).

It works on any machine. Nothing in it points at one computer: every location is worked out when it runs, from the tool itself, its environment variables, the registry, or the vendor's default folder inside the user's profile.

## Usage

1. Download `cleaner.bat`.
2. Double-click it and accept the admin prompt.
3. Windows SmartScreen may warn you because the file came from the internet. Click **More info**, then **Run anyway**.

![SmartScreen](https://github.com/5h1Vm/cleaner/assets/83861668/d1cf030f-bb68-4a11-a4e6-47736bac7234)

From a terminal:

```
cleaner.bat          clean everything
cleaner.bat /dry     show what would be cleaned, change nothing
cleaner.bat /?       help
```

Run `/dry` first if you want to see what it will touch on your machine.

## What it cleans

**Temporary files**
- User and Windows temp folders
- Prefetch

**Windows Update**
- Download cache and update logs (the update services are stopped and restarted around this)
- Delivery Optimization cache

**Browsers (every profile, not only Default)**
- Edge, Chrome, Brave, Vivaldi, Chromium, Yandex, Opera, Opera GX
- Firefox, Waterfox, LibreWolf, Floorp, Zen

**GPU**
- DirectX, NVIDIA, AMD and Intel shader caches

**Windows**
- Thumbnail and icon caches, font cache
- Error reports, crash dumps, memory dump
- Defender scan history
- Jump lists (recent items in taskbar menus)
- Windows AI and shell caches, search index logs, .NET usage logs

**Apps**
- Teams (classic and new), OneDrive logs
- VS Code, VS Code Insiders, VSCodium, Cursor, Windsurf
- Any other Electron app (Discord, Slack, Spotify and so on), found automatically. Only cache folders are removed, never settings or sign-ins.

**Developer tools** (each one only if it is installed or its cache folder exists)

| Tool | How |
|---|---|
| npm | `npm cache clean --force` |
| Yarn | `yarn cache clean` |
| pnpm | `pnpm store prune` (removes only packages no project uses) |
| Bun | `bun pm cache rm` |
| Deno | npm download cache |
| pip | cache folder reported by `pip cache dir` |
| uv | `uv cache clean` |
| Poetry, Pipenv | cache folders |
| Conda | `conda clean --all --yes` |
| NuGet | HTTP, temp and plugins caches (installed packages are kept) |
| Go | `go clean -cache` |
| Cargo | downloaded crate archives |
| Gradle | build cache |
| Composer | `composer clear-cache` |
| Scoop | `scoop cache rm *` |
| Chocolatey | failed and backup package folders |
| winget | logs (its installers download to Temp, cleaned above) |
| Electron, electron-builder, node-gyp | download caches |

**Docker**
- Asks whether to remove unused images and build cache. If nobody answers within 60 seconds, it skips. Containers and volumes are never touched.

**Virtual disk compaction**

WSL distros, Docker Desktop and Hyper-V store everything in `.vhdx` files. These files grow but never shrink on their own, even after you delete things inside them. The script:

1. Finds every disk: WSL distros from the registry, Docker Desktop's disks from its settings and default folder, and Hyper-V VMs that are switched off and have no checkpoints.
2. Runs `fstrim` inside each WSL distro so the free space can be returned.
3. Stops Docker Desktop and shuts down WSL.
4. Compacts each disk with `diskpart`, which is part of every Windows edition.

Docker Desktop is left stopped afterwards. Start it again when you need it.

**System**
- Empties the Recycle Bin
- Clears all event logs
- Flushes the DNS cache
- Triggers Storage Sense
- Runs `DISM /StartComponentCleanup`

## Things to know

- Close browsers and apps before running. Files that are in use are skipped.
- Clearing event logs and Defender history removes the record of past errors and detections. Skip this tool if you are troubleshooting a problem or checking for malware.
- Jump lists are cleared, including files pinned in taskbar right-click menus.
- The Recycle Bin is emptied without asking.
- If you sign in to the admin prompt with a different account, the script still cleans your profile, not the admin's. Developer tool commands only run for your own account; for another account it removes their cache folders instead.

## How it works

`cleaner.bat` is a batch file and a PowerShell script in one. The first few lines are batch: they ask for admin rights, then hand the rest of the file to PowerShell. PowerShell sees those batch lines as a comment and skips them. This keeps it to a single double-clickable file.

Requires Windows 10 or 11 with Windows PowerShell 5.1, which every Windows 10 and 11 install includes.
