# RamClean — Setup, Run and Use

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later (built and tested with Xcode 26.5 on macOS 26.6)
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```bash
./scripts/build.sh
```

```bash
open build/RamClean.app
```

The script generates `RamClean.xcodeproj` from `project.yml`, builds a Release copy and puts it at `build/RamClean.app`. Drag it into `/Applications` if you want to keep it there.

To work on it in Xcode instead, run `xcodegen generate` and open `RamClean.xcodeproj`.

The first time it runs, macOS asks whether RamClean may send notifications. Click **Allow**, or suggestions can only appear in the window and the menu bar. You can change this later in System Settings → Notifications → RamClean.

## Run the tests

```bash
cd RamCleanCore && swift test
```

To time a real disk scan of your home folder, step by step:

```bash
cd RamCleanCore && RAMCLEAN_BENCH=1 swift test --filter ScanBenchmark
```

The 22 tests cover process grouping (helpers, and Claude Code inside Terminal), every protection rule, the habit log, the rule-of-thumb score, Create ML training (including apps it has never seen and the "regret" relabel), the notification policy (thresholds and cooldowns), loading preferences, the disk scanner on a fake home folder (including stale projects, unused apps and old downloads, and never active work), threshold alerts (sustain, repeat, recovery, snooze) and their recommendation text, the "why" text for each app, and a live smoke test of the samplers on this Mac.

## Using it

**Menu bar.** The chip icon shows how much memory is in use. Click it to see memory, the apps that look like deadweight (or the biggest apps when nothing does), a **Quit** button for each, and links to the window and Settings.

**Threshold alerts.** RamClean notifies you when:
- memory is at least **85%** used (or pressure is critical)
- CPU stays at **97%** or more for **2 minutes**
- the disk is **99%** full

Each alert names what to do: the idle apps to quit (with how much they'd free), the busiest app if nothing is idle, or what to clear on disk. Disk advice covers rebuildable caches, build files in projects you've stopped working on, apps you haven't opened in months, and old big files to move to an external drive.

Alert buttons:
- **The top fix:** "Quit Spotify", or "Trash uv" for the biggest rebuildable cache. It's always recoverable; a quit is polite first, then Force Quit is offered.
- **Show recommendations:** opens RamClean on that bar's list.
- **Snooze 1 hour.**

While a resource stays over its line, you're reminded at most once an hour. After it drops back below, the next crossing alerts right away. All of these limits are under Settings → Thresholds → Alerts.

**Click a bar for recommendations.** The three bars at the top of the Overview are buttons:

- **Memory → What to quit:** your Dock apps ranked by memory. Each shows RamClean's call (Quit, Keep or Protected), the reasons ("Idle 3 h · Rarely used (1 of 14 days) · You quit it 2× before"), and Quit / Keep buttons. The header names the apps it recommends quitting and how much memory that frees.
- **CPU → What's busy:** the same list ranked by CPU.
- **Disk → What to clear:** opens instantly with the last scan's results. If they're more than 30 minutes old, a fresh scan runs in the background and replaces them when done (about a minute and a half on a full 1 TB disk). On the very first scan, results appear as each part finishes. It covers:
  - **Rebuildable caches:** app caches in `~/Library/Caches` and `~/.cache`, Xcode build data, archives and device support, simulator caches, and npm, Gradle and Cargo caches.
  - **Build files in projects you've stopped working on:** `node_modules`, `.venv`, `target`, `.build`, `build`, `dist` and similar, in code projects with no changes for 30 days. Each says how to get it back (e.g. `npm install`).
  - **Apps you don't use anymore:** apps in `/Applications` you haven't opened in 90 days, by Spotlight's record. Apple apps, running apps, your always-keep apps and work tools are never listed.
  - **Old downloads:** things in `~/Downloads` over 50 MB you haven't opened in 90 days.
  - **Large files:** files of 1 GB or more in your home folder (outside `~/Library`). Ones not opened in 90 days are tagged **Move off this Mac**.
  - **Trash:** how much space it holds.

  **Active work is never suggested.** Projects with changes in the last 30 days, build folders being written to (a build in progress), and files opened or changed in the last 30 days are skipped. Both day counts are in Settings → Thresholds → What counts as unused.

  Buttons:
  - **Move to Trash** (or **Uninstall** for an app) asks you first; anything moved can be put back from the Trash until you empty it.
  - **Move to…** (large files and downloads) lists any connected external drives with their free space, plus **Choose a folder…**. RamClean checks there's room, copies the file, and removes it from the Mac only once the copy succeeded.
  - **Show in Finder.**

  RamClean never empties the Trash or deletes anything permanently. Items to double-check (like Xcode archives, or an app's leftover settings) carry an orange note. Simulator devices and the Trash are advice only. The first scan may make macOS ask for access to Desktop, Documents, Downloads or an external drive; RamClean only reads sizes there.

**Overview window.** Shows memory, CPU and disk use, and every Dock app with its memory, its CPU (averaged over the last few checks) and RamClean's verdict:

- **Deadweight NN%** (orange). RamClean thinks you could quit it.
- **Keep · NN%** (green). Not idle enough or used often enough to suggest.
- **Lock + reason** (gray). Protected and never suggested: you're using it, it's playing audio, it's running a command in a terminal (like `claude`), it's a busy work tool, it's on your always-keep list, it's part of macOS, or RamClean is still learning about it.

**Quit** asks the app to quit politely. If it's still running after 8 seconds (you can change this), RamClean offers **Force Quit**. The 👍 button means "keep this". Both buttons are answers the model learns from.

Rows stay in place while the pointer is over the list, and re-sort by memory at most once a minute or when you click **Refresh**, so a click never lands on the wrong app.

Menu bar apps, command-line tools and background processes are listed in a collapsed section. They're shown, but never suggested.

**Notifications.** A notification is sent when memory is at least 80% used (or memory pressure is elevated) and an app of 400 MB or more scores at least 70%. An app idling at 60%+ CPU also triggers one. Buttons: **Quit**, **Keep running**, **Always keep**. RamClean sends at most one notification every 10 minutes and asks about the same app at most every 4 hours. Threshold alerts (above) cover a full disk, and other resources crossing their lines.

**Habits.** Shows how long each app is in front while you're at the Mac (time only counts when there's been input in the last 2 minutes), averaged over 14 days, plus your Kept / Quit / Reopened counts.

**Activity Log.** A diary of launches, quits, suggestions and your answers.

**Model.** Shows the model's training state, how many answers it has, its accuracy on held-out answers, how much of the score it controls, and your recent answers. Buttons: **Retrain now** and **Reset model…**.

**Settings (⌘,)**
- **General:** notifications on/off, test notification, check interval, Force Quit delay.
- **Thresholds:** when to suggest apps (memory trigger, minimum app size, CPU hog level, deadweight score, cooldowns), threshold alerts (memory, CPU and how long, disk, reminder interval), and what counts as unused (not opened for N days) versus active work (touched within N days).
- **Protection:** recent-use window, busy work tools and their CPU level, menu bar utilities, always-keep list, and the editable list of work tools (bundle IDs; `com.jetbrains.*` matches a prefix).
- **Data:** where data lives, Show in Finder, clear habit history, reset preferences.

**Feedback.** Use the small **Feedback** link at the bottom of the sidebar. Entries are saved to `feedback.jsonl` in the data folder.

## Where your data lives

Everything stays in `~/Library/Application Support/RamClean/`; nothing is sent anywhere.

| File | What it holds |
|---|---|
| `habits.json` | Seconds in front per app per day, launches, last active, your answer counts (60 days kept) |
| `events.jsonl` | Activity log, one JSON event per line (trimmed past 5 MB) |
| `training.jsonl` | Your answers: each app's features at that moment and Quit / Keep |
| `meta.json` | When RamClean started watching |
| `disk-report.json` | The last disk scan, so "What to clear" opens instantly |
| `feedback.jsonl` | Feedback you've written |

Preferences live in `UserDefaults` (domain `com.amalmehta.RamClean`).
