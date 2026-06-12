# CaptionPro

**Subtitle → Animated Fusion Text+** for DaVinci Resolve Studio 21

> ⚠️ **Alpha v0.1** — This is an early build shared for testing. Expect rough edges
> and occasional crashes. If something breaks, see [Reporting Bugs](#reporting-bugs).

---

## What it does

CaptionPro reads your existing subtitle track and converts every clip into a
**Fusion Text+** composition clip on a video track — with optional:

- **Highlight detection** (on-machine, no internet) — automatically scores lines
  using TF-IDF and linguistic heuristics (all-caps words, exclamations, short
  punchy phrases, statistics) and flags the top N% as "highlights"
- **Animation macros** — applies your own `.setting` Fusion macros to highlighted
  vs. normal lines so each clip gets the right animation style

---

## Requirements

| Requirement | Details |
|---|---|
| **DaVinci Resolve Studio** | Version 18 or later (free version does not support Lua scripting) |
| **Operating System** | Windows 10 / 11 (64-bit) |
| **Lua** | Built into Resolve — no separate install needed |
| **Timeline** | Must have at least one subtitle track with content |

---

## Installation

### Option A — Interactive installer (recommended)

1. Download or clone this repository
2. Right-click `install.ps1` → **Run with PowerShell**  
   *(or open PowerShell in this folder and run `.\install.ps1`)*
3. Follow the on-screen prompts — the installer will:
   - Detect your DaVinci Resolve installation (including non-default paths)
   - Find or create the correct Scripts folder
   - Copy all plugin files and macros
   - Verify every file was placed correctly
   - Print a success summary with the next steps

> If Windows blocks the script, run this first in PowerShell:
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
> ```

### Option B — Manual install

Copy the following to your Resolve `Scripts` folder  
*(usually `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts`)*:

| Source | Destination (relative to Scripts/) |
|---|---|
| `src/main.lua` | `Comp/CaptionPro.lua` |
| `src/resolve/*.lua` | `CaptionPro_src/resolve/` |
| `src/core/*.lua` | `CaptionPro_src/core/` |
| `src/ui/*.lua` | `CaptionPro_src/ui/` |
| `macros/*.setting` | `CaptionPro_macros/` |

---

## How to use

1. Open DaVinci Resolve Studio with a project that has a **subtitle track**
2. Make sure the Edit page is open and the target video track is **selected** (highlighted blue)
3. Go to **Workspace → Scripts → Comp → CaptionPro**
4. In the panel:
   - Set **Subtitle Track** — the subtitle track number to read from (default 1)
   - Set **Target Video Track** — which video track to place Fusion clips on
   - Toggle **Highlight Detection** and pick the percentage of lines to flag
   - Toggle **Animation Macros** and browse to your `.setting` files  
     *(optional — plain text is used if no macros are selected)*
   - Click **Convert Subtitles → Animated Text+**
5. Watch the progress bar. When it reaches 100%, all clips are on the timeline

### Using the included macros

After installation, the two bundled macros are at:
```
%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\CaptionPro_macros\
  highlight.setting   ← bold yellow text, bottom-centre
  normal.setting      ← regular white text, bottom-centre
```
Paste those paths into the Browse fields, or use your own Fusion macros.

### Creating your own macros

1. Open a Fusion comp, build a TextPlus node with the styling you want
2. Select the TextPlus node → **File → Save As** → save as a `.setting` file
3. Point CaptionPro to that file via the Browse button

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Script doesn't appear in Workspace → Scripts | Restart Resolve after installation |
| "No subtitle track found" | Check the subtitle track number — Resolve starts at 1 |
| "InsertFusionCompositionIntoTimeline returned nil" | Make sure a video track is selected (highlighted blue) in the Edit page before clicking Convert |
| Wrong number of clips created | This is a known INSERT-mode quirk — the plugin handles it automatically. If it still happens, send the log |
| Macro does nothing / plain text appears | The `.setting` file may not contain a TextPlus node. Re-export from Fusion |
| Panel crashes on open | Send `build.log` from the log folder (see below) |

---

## Reporting Bugs

If anything goes wrong, the plugin writes log files to:

```
%USERPROFILE%\CaptionPro Logs\
  startup.log   ← script load and initialisation (overwritten each launch)
  build.log     ← conversion steps, frame numbers, errors
  install.log   ← installer steps and errors
```

*(Paste `%USERPROFILE%\CaptionPro Logs` into Explorer's address bar to open the folder.)*

**To report a bug:**

1. Open `build.log` (or `startup.log` if the panel never opened)
2. Copy the contents
3. Email to: **aniket.bhattacharjee@gmail.com** with:
   - The log file attached
   - What you were doing when it broke
   - Your Resolve version (**Help → About DaVinci Resolve**)

---

## Project layout

```
CaptionPro_Lua/
├── install.ps1                    ← Interactive Windows installer
├── README.md
├── macros/
│   ├── highlight.setting          ← Bold yellow macro (bundled)
│   └── normal.setting             ← Regular white macro (bundled)
└── src/
    ├── main.lua                   ← Entry point (copied to Comp/CaptionPro.lua)
    ├── core/
    │   ├── highlight_analyzer.lua ← TF-IDF + heuristic scoring
    │   └── workflow.lua           ← Pipeline orchestrator
    ├── resolve/
    │   ├── subtitle_reader.lua    ← Reads subtitle track
    │   └── fusion_builder.lua     ← 3-phase Fusion clip insertion
    └── ui/
        └── panel.lua              ← UIManager panel
```

---

## Known limitations (Alpha)

- Windows only (macOS support planned)
- Requires Resolve **Studio** — free version does not expose the Lua scripting API
- Clip duration is fixed at 5 seconds (120 frames at 24 fps); per-clip trimming
  via `COMPN_GlobalEnd` matches the subtitle length inside the comp
- The plugin inserts clips using Resolve's **INSERT/SPLICE** mode — any content
  on the target video track beyond the last subtitle will be shifted right

---

*Created by Rishi — Alpha v0.1*
