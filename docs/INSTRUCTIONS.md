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

The 16 tests cover process grouping (helpers, and Claude Code inside Terminal), every protection rule, the habit log, the rule-of-thumb score, Create ML training (including apps it has never seen and the "regret" relabel), the notification policy (thresholds and cooldowns), loading preferences, and a live smoke test of the samplers on this Mac.

## Using it

**Menu bar.** The chip icon shows how much memory is in use. Click it to see memory, the apps that look like deadweight (or the biggest apps when nothing does), a **Quit** button for each, and links to the window and Settings.

**Overview window.** Shows memory, CPU and disk use, and every Dock app with its memory, its CPU (averaged over the last few checks) and RamClean's verdict:

- **Deadweight NN%** (orange). RamClean thinks you could quit it.
- **Keep · NN%** (green). Not idle enough or used often enough to suggest.
- **Lock + reason** (gray). Protected and never suggested: you're using it, it's playing audio, it's running a command in a terminal (like `claude`), it's a busy work tool, it's on your always-keep list, it's part of macOS, or RamClean is still learning about it.

**Quit** asks the app to quit politely. If it's still running after 8 seconds (you can change this), RamClean offers **Force Quit**. The 👍 button means "keep this". Both buttons are answers the model learns from.

Rows stay in place while the pointer is over the list, and re-sort by memory at most once a minute or when you click **Refresh**, so a click never lands on the wrong app.

Menu bar apps, command-line tools and background processes are listed in a collapsed section. They're shown, but never suggested.

**Notifications.** A notification is sent when memory is at least 80% used (or memory pressure is elevated) and an app of 400 MB or more scores at least 70%. An app idling at 60%+ CPU also triggers one. Buttons: **Quit**, **Keep running**, **Always keep**. RamClean sends at most one notification every 10 minutes and asks about the same app at most every 4 hours. If free disk space drops below 10%, you get one warning a day. RamClean never deletes files.

**Habits.** Shows how long each app is in front while you're at the Mac (time only counts when there's been input in the last 2 minutes), averaged over 14 days, plus your Kept / Quit / Reopened counts.

**Activity Log.** A diary of launches, quits, suggestions and your answers.

**Model.** Shows the model's training state, how many answers it has, its accuracy on held-out answers, how much of the score it controls, and your recent answers. Buttons: **Retrain now** and **Reset model…**.

**Settings (⌘,)**
- **General:** notifications on/off, test notification, check interval, Force Quit delay.
- **Thresholds:** memory trigger, minimum app size, CPU hog level, deadweight score, cooldowns, disk warning.
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
| `feedback.jsonl` | Feedback you've written |

Preferences live in `UserDefaults` (domain `com.amalmehta.RamClean`).
