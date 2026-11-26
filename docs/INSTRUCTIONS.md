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

### Keep Accessibility access across rebuilds

By default each build is signed ad hoc, which gives it a new identity, so macOS forgets that you allowed RamClean Accessibility access and the Settings row goes back to "Allow Accessibility…". To stop that, make a signing certificate once. The build script uses it automatically when it's there.

1. Open Keychain Access and choose **Keychain Access › Certificate Assistant › Create a Certificate…**.
2. Name it exactly `RamClean Development`, set **Identity Type** to **Self Signed Root** and **Certificate Type** to **Code Signing**, then click **Create**.
3. Rebuild with `./scripts/build.sh`. It prints "Signing with RamClean Development".
4. Allow Accessibility for RamClean once more. From then on it stays allowed after rebuilds.

To rebuild and swap in the new copy in one step, use `./scripts/build.sh --run`. It quits any RamClean that's running (including an older copy opened at login) and opens the new build. If the build fails, the script stops and leaves `build/RamClean.app` as it was.

To work on it in Xcode instead, run `xcodegen generate` and open `RamClean.xcodeproj`.

The first build downloads [Sparkle](https://sparkle-project.org) (auto-updates) through Swift Package Manager, so it needs an internet connection once.

To build the signed, notarized DMG you sell, see `./scripts/release.sh` and [GO-LIVE.md](GO-LIVE.md).

The first time it runs, a short **Set up RamClean** sheet offers Open at login (RamClean only learns while it's running), shows whether notifications are on, and offers Accessibility access for spotting unsaved changes. All three are in Settings later. macOS also asks whether RamClean may send notifications. Click **Allow**, or suggestions can only appear in the window and the menu bar. You can change this later in System Settings → Notifications → RamClean.

## Run the tests

```bash
cd RamCleanCore && swift test
```

To time a real disk scan of your home folder, step by step:

```bash
cd RamCleanCore && RAMCLEAN_BENCH=1 swift test --filter ScanBenchmark
```

The 114 tests (3 opt-in benchmarks are skipped) cover automatic cleaning (when it runs, which apps and folders it may touch, its notification, and that its quits never count as your answers), licensing against a fake licence server (trial, activation, offline grace, refunds, deactivation), process grouping (helpers, and Claude Code inside Terminal), every protection rule, the habit log, the rule-of-thumb score, Create ML training (including apps it has never seen and the "regret" relabel), the notification policy (thresholds and cooldowns), loading preferences, the disk scanner on a fake home folder (including stale projects, unused apps and old downloads, and never active work), threshold alerts (sustain, repeat, recovery, snooze) and their recommendation text, the "why" text for each app, and a live smoke test of the samplers on this Mac.

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
- **Disk → What to clear:** the Disk card says how much the last scan found to clear ("Clear up to 124 GB") and, on its own line, when the disk will be full at the current rate. Click it and the list opens instantly with the last scan's results. At the top, **Where to win space** shows how much each kind of thing could free (a coloured bar plus totals: caches, old project builds, unused apps, old downloads, big files to move, Trash) and the **three biggest single wins**, each with its buttons, so you see where the space is without scrolling. If they're more than 30 minutes old, a fresh scan runs in the background and replaces them when done. Refreshes reuse sizes of folders that haven't changed (remembered across relaunches), so they take a few seconds; **Rescan** looks for new files and measures everything from scratch (around 10 s). On the very first scan, results appear as each part finishes. It covers:
  - **Rebuildable caches:** app caches in `~/Library/Caches` over 500 MB and in `~/.cache`, Xcode build data, archives and device support, simulator caches, simulators whose runtime is no longer installed, the Homebrew cache, and npm, Yarn, pnpm, Gradle and Cargo caches.
  - **Build files in projects you've stopped working on:** `node_modules`, `.venv`, `target`, `.build`, `build`, `dist` and similar, in code projects with no changes for 30 days. `node_modules` folders up to 8 folders deep in your home folder (outside `~/Library` and hidden folders) are found this way too, even without other project files. Each says how to get it back (e.g. `npm install`). One inside another git checkout that has no git of its own, like the `node_modules` Emscripten's SDK keeps in `~/emsdk/upstream/emscripten`, is part of a tool rather than a project, so it's listed with a caution and never ticked by Select All Safe or cleaned automatically.

  Every item shows its size and when it was last modified (or opened, for files).
  - **Apps you don't use anymore:** apps in `/Applications` you haven't opened in 90 days, by Spotlight's record. Apple apps, running apps, your always-keep apps and work tools are never listed.
  - **Old downloads:** things in `~/Downloads` over 50 MB you haven't opened in 90 days.
  - **Large files:** files of 1 GB or more in your home folder (outside `~/Library`). Ones not opened in 90 days are tagged **Move off this Mac**.
  - **Trash:** how much space it holds.

  **Active work is never suggested.** Projects with changes in the last 30 days, build folders being written to (a build in progress), and files opened or changed in the last 30 days are skipped. Both day counts are in Settings → Thresholds → What counts as unused.

  Buttons:
  - **Show one kind:** click a category under **Where to win space** (Caches, Old project builds…) to list only that kind; click it again or **Show All** for everything.
  - **Clear several at once:** click a row (or its box) to tick it, use **Select all** on a section, or **Select All Safe** at the top, which ticks every cache and old build folder that comes back on its own and has nothing to check first. A bar at the bottom shows how many are ticked and their total size; **Move to Trash** (⌘⌫) moves them all after one confirmation, which names anything with a warning. Afterwards a bar says what went, with **Undo** (⌘Z) to put it all back, until the next scan. The Trash row grows by what you moved.
  - **Move to Trash** (or **Uninstall** for an app) asks you first; anything moved can be put back from the Trash until you empty it.
  - **Clean Up** runs the tool's own command instead, where one exists: `xcrun simctl delete unavailable` for unavailable simulators, `brew cleanup --prune=all` for the Homebrew cache. It names the command and asks you first; this space doesn't go through the Trash. If Homebrew isn't installed, its cache gets Move to Trash instead.
  - **Move to…** (large files and downloads) lists any connected external drives with their free space, plus **Choose a folder…**. RamClean checks there's room, copies the file, and removes it from the Mac only once the copy succeeded.
  - **Show in Finder.**

  RamClean never empties the Trash, and deletes nothing permanently except through a Clean Up command you confirm. Every move and cleanup is written to the habit log. Items to double-check (like Xcode archives, or an app's leftover settings) carry an orange note. The Docker disk image and the Trash are advice only. The first scan may make macOS ask for access to Desktop, Documents, Downloads or an external drive; RamClean only reads sizes there.

**Clean up automatically (off until you turn it on).** Settings → General → **Clean up automatically**. Every 6 hours (8 or 12 if you prefer) RamClean, with nobody asked:
- **quits apps marked deadweight** (score at or above your threshold, 70%) that you haven't had in front for 2 hours, use at least 400 MB, and have no unsaved changes. Protected apps (in front, playing audio, building, running Claude, always keep, work tools that are busy) are never touched. Apps are asked to quit politely, as with Quit.
- **moves build folders of projects untouched for 30 days to the Trash**: the same ones **Select All Safe** ticks under "Build files in projects you've stopped working on". Each folder is checked again just before; one written to since is left alone. Caches, downloads, apps and large files are never cleaned automatically.

It runs sooner between those times when memory reaches the suggest line (80%) or macOS reports memory pressure (apps only, at most hourly), or when the disk is on course to fill within 3 days (build folders only, at most hourly). Afterwards one notification says what it did ("Freed 2.9 GB of memory and 1.4 GB of disk") with **Undo**, which reopens the apps and puts the folders back, and **Review**, which opens the Activity Log. The same **Undo** sits in a bar at the top of the Activity Log until you use it, click **Dismiss**, or the next clean runs, so it works even if macOS doesn't pass the notification's button press on to RamClean. A run that finds nothing stays quiet. Nothing runs while notifications are paused from the menu bar.

How it learns: an automatic quit isn't your answer, so it doesn't teach the model "deadweight" (otherwise the model would grow more sure of its own guesses). Reopening an app within 30 minutes of an automatic quit, or tapping Undo, counts as **keep**, so a wrong quit makes the next one less likely.

Good to know: without Accessibility access RamClean can't see unsaved changes; the app's own "Save changes?" prompt is then the backstop, and the app stays open. Projects in Desktop, Documents or Downloads are only searched once you've opened the Disk list yourself, since that may raise a macOS permission prompt. Undo works until RamClean restarts; after that, folders are still in the Trash (Put Back in Finder).

**Overview window.** Shows memory, CPU and disk use, and every Dock app with its memory, its CPU (averaged over the last few checks) and RamClean's verdict:

- **Deadweight NN%** (orange). RamClean thinks you could quit it.
- **Keep · NN%** (green). Not idle enough or used often enough to suggest.
- **Busy** (blue tag by the name, with the reason). Never suggested while it lasts: it's building (a compiler or bundler is working under it), Claude Code inside it is running tasks, it's playing audio, or it's keeping the Mac awake. It stays busy for 2 minutes after the last sign, and any "Quit?" notification about it is taken back.
- **Lock + reason** (gray). Protected and never suggested: you're using it, it's running a command in a terminal (like `claude`), it's a busy work tool, it's on your always-keep list, it's part of macOS, or RamClean is still learning about it.

**Quit** asks the app to quit politely. If it's still running after 8 seconds (you can change this), RamClean offers **Force Quit**. The 👍 button means "keep this". Both buttons are answers the model learns from.

Rows stay in place while the pointer is over the list, and re-sort by memory at most once a minute or when you click **Refresh**, so a click never lands on the wrong app.

Menu bar apps, command-line tools and background processes are listed in a collapsed section. They're shown, but never suggested.

**Notifications.** A notification is sent when memory is at least 80% used (or memory pressure is elevated) and an app of 400 MB or more scores at least 70%. An app idling at 60%+ CPU also triggers one. Buttons: **Quit**, **Keep running**, **Always keep**. RamClean sends at most one notification every 10 minutes and asks about the same app at most every 4 hours. Threshold alerts (above) cover a full disk, and other resources crossing their lines.

**Habits.** Shows how long each app is in front while you're at the Mac (time only counts when there's been input in the last 2 minutes), averaged over 14 days, plus your Kept / Quit / Reopened counts.

**Activity Log.** A diary of launches, quits, suggestions and your answers.

**Model.** Shows the model's training state, how many answers it has (and how many came from quitting apps yourself), how much of the score it controls, and your recent answers. Buttons: **Retrain now** and **Reset model…**.

**Settings (⌘,)**
- **General:** open at login, notifications on/off, test notification, **Clean up automatically** and how often, check interval, Force Quit delay.
- **Thresholds:** when to suggest apps (memory trigger, minimum app size, CPU hog level, deadweight score, cooldowns), threshold alerts (memory, CPU and how long, disk, reminder interval), and what counts as unused (not opened for N days) versus active work (touched within N days).
- **Protection:** recent-use window, busy work tools and their CPU level, menu bar utilities, always-keep list, and the editable list of work tools (bundle IDs; `com.jetbrains.*` matches a prefix).
- **Data:** where data lives, Show in Finder, clear habit history, reset preferences.
- **Licence:** trial days left, licensed, licensed offline, or expired; **Buy**; paste a licence key and **Activate**; **Check Now** and **Deactivate on This Mac…**. General also has **Check for Updates…** and automatic update checks (also in the RamClean menu).

**Trial and licence.** Every feature works for 14 days from the first launch. After that RamClean keeps watching memory, CPU and disk, shows its recommendations and sends alerts, but quitting and restarting apps, moving files to the Trash or off the Mac, and learning from your Keep and Quit answers need a licence ($5, once). Trying one of those shows **Buy** and **Enter Licence Key…**. The sidebar and the menu bar show the trial's days left. A licensed copy checks its key about once a day and keeps working offline for 14 days. Until the store is set up in `ProductConfig.swift` (see [GO-LIVE.md](GO-LIVE.md)), Settings → Licence says "Development copy" and nothing is locked.

**Feedback.** Use the small **Feedback** link at the bottom of the sidebar. Entries are saved to `feedback.jsonl` in the data folder.

## Where your data lives

Everything stays in `~/Library/Application Support/RamClean/`. The only things sent anywhere are the licence check (the key and this Mac's name, to Lemon Squeezy) and the update check.

| File | What it holds |
|---|---|
| `habits.json` | Seconds in front per app per day, launches, last active, your answer counts (60 days kept) |
| `events.jsonl` | Activity log, one JSON event per line (trimmed past 5 MB) |
| `training.jsonl` | Your answers: each app's features at that moment and Quit / Keep |
| `meta.json` | When RamClean started watching |
| `disk-report.json` | The last disk scan, so "What to clear" opens instantly |
| `scan-memory.json` | What the last walk of your home folder found (used when Spotlight isn't indexing it) and the last list of unavailable simulators, so refreshes don't redo them |
| `sizes.json` | Remembered folder sizes, so refreshes (even after a relaunch) only re-measure what changed |
| `feedback.jsonl` | Feedback you've written |

Preferences live in `UserDefaults` (domain `com.amalmehta.RamClean`). The trial start and licence are in the Keychain (service `com.amalmehta.RamClean.licence`), with a copy in the same `UserDefaults` domain. While RamClean is free (`ProductConfig.isFree`) only the `UserDefaults` copy is used and the Keychain isn't touched.
