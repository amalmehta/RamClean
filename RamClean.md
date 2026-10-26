PROJECT NAME: RamClean

META-INSTRUCTIONS:

<Read it all before acting. Ask about anything unclear, contradictory or
 underspecified — before starting and mid-build. Ask in the question widget
 (AskUserQuestion): related questions batched, concrete options, your
 recommendation first. Plain text only if the widget isn't available.>

<Don't expand scope. Anything not listed here is a proposal, including changes
 to this file — propose it, don't do it.>

<Prefer doing over describing: run the code, write the files, test it.>

<Always in scope, no proposal needed: when it goes on GitHub, a README that is
 easy to read at a glance — a line on what it is, then clear visuals
 (screenshots, a diagram or a chart), then links. Everything else goes in
 linked files: docs/INSTRUCTIONS.md (setup, run, use),
 docs/SYSTEM-DESIGN.md (see below) and docs/FILE-STRUCTURE.md (what's where). If what you're
 building is an application rather than a script, also a small unobtrusive feedback tab, and a settings
 button or tab (⌘, on the Mac) that gathers its preferences in one place.>

<If what you're building is an application, build it as a Mac app first; the
 website comes after, as its own step.>

<Name things the way a person would say them — "Goal Tracker", not
 goal_tracker — for the app, its windows, titles, files people open, repo
 descriptions and README headings. When you create the GitHub repo, name it
 with no "_" or "-": one word or joined words, e.g. GoalTracker.>

<Always in scope: a system design doc in the codebase, docs/SYSTEM-DESIGN.md,
 kept current as the build changes. Cover the architecture (with a Mermaid
 diagram), each component's job, the main flows, where data lives, the key
 design decisions and their trade-offs, how it's tested, and known limits.>

<Finish by listing every deliverable: path, what it is, how to check it works.>

<Git rules (no Claude attribution, never commit .claude/) are in
 ~/.claude/CLAUDE.md and apply on their own — nothing to repeat here.>

<Keep the changelog at the bottom current.>

CONTEXT:

figuire out what is eating memory / storage / capacity on the mac and send auto notifications if the person would like to kill that process. be smart about it (i.e. if a claude code is building somehting or sptoify is being used often dont rec to kill those). maintain a log of the person’s habits and train a model to figure out what is actually useful to kill (deadweight), vs things that are actually important to keep running

DELIVERABLES:

mac app

OPEN QUESTIONS / ASSUMPTIONS:

<Agent fills in: what it guessed, what it decided without asking.>

Asked and answered (2026-10-07):
- Ending a process: quit politely first, then offer Force Quit if it's still running.
- Scope: RAM + CPU per process; disk is a gauge and a low-space warning.
- (2026-10-08) Threshold alerts: memory 85%, CPU 97% for 2 min, disk 99% used. Each alert names what to quit, clear or move and has a one-tap fix (quit the top app or trash the top rebuildable item), plus Show recommendations and Snooze 1 hour. Repeats at most hourly while over.
- (2026-10-08) Suggest what has no use anymore: unused apps (90 days), old downloads, build folders in projects untouched for 30 days. Never active work: projects, builds and files touched in the last 30 days.
- (2026-10-08) Moving: large files not opened in 90 days are tagged "Move off this Mac". "Move to…" lists connected external drives (asking each time) or a folder you choose; caches still go to the Trash.
- (2026-10-08) Clicking a bar gives recommendations. Memory and CPU: a ranked quit list with reasons. Disk: rebuildable caches, large files in home, and the Trash, with Move to Trash (confirmed, recoverable) and Show in Finder. Nothing is ever deleted permanently.
- Model: Apple Create ML classifier (boosted trees), trained on this Mac.
- GitHub: local git only at first; (2026-10-08) pushed to a private repo, github.com/amalmehta/RamClean.

Decided without asking:
- Menu bar item + regular Dock app (so ⌘, and the window behave normally), macOS 14+.
- Only Dock apps are ever suggested. Menu bar apps, command-line tools and background
  processes are shown but never suggested; a terminal running a command (e.g. claude)
  is protected instead.
- "Being used" = in front recently (20 min), playing audio, hosting terminal work, or a
  work tool (Xcode, terminals, editors, Claude, Docker…) above 15% CPU. Editable in Settings.
- Notify only when memory ≥ 80% used or pressure is elevated (or an idle app burns ≥ 60%
  CPU); at most one notification per 10 min and per app every 4 h.
- The model learns from Quit/Keep answers, plus "regret" (reopened within 30 min → keep).
  Until 8 answers (3 of each) it uses rules of thumb, then blends, up to 85% model.
- All data local in ~/Library/Application Support/RamClean; feedback saved there too.
- Ad-hoc signed, not sandboxed or notarized; built with xcodegen.

Proposals (not built):
- Launch at login (SMAppService).
- Somewhere to send feedback (email or an issue tracker).
- Menu-bar-only mode (no Dock icon).
- Developer ID signing + notarization for sharing.
- The website (a separate step after the Mac app, per the meta-instructions).

CHANGELOG:

- 2026-10-07 — created
- 2026-09-15 — added meta-instruction: built-out applications include a small feedback tab
- 2026-09-15 — added meta-instruction: no "Claude" attribution in commits, PRs, or branches
- 2026-09-16 — added meta-instruction: always include a README when adding to GitHub
- 2026-09-16 — changed meta-instruction: ask clarifying questions in the question widget
- 2026-09-17 — added meta-instructions: Claude never a contributor; never commit .claude/
- 2026-09-26 — compressed the meta-instructions and every field prompt; git rules moved to the global instruction file
- 2026-09-27 — added meta-instruction: applications are built as a Mac app first, then a website
- 2026-09-28 — folded inputs, instructions, constraints, deliverables and done criteria into one free-form CONTEXT
- 2026-09-28 — changed meta-instruction: a README on GitHub always includes a visual
- 2026-09-28 — added meta-instruction: name things like a person would, never snake_case
- 2026-09-28 — changed meta-instruction: README leads with visuals; instructions live in a linked guide
- 2026-09-28 — changed meta-instruction: README is visuals and links; details in docs/INSTRUCTIONS.md and docs/FILE-STRUCTURE.md
- 2026-09-29 — changed meta-instruction: GitHub repo names have no "_" or "-"
- 2026-10-02 — added a DELIVERABLES field after CONTEXT
- 2026-10-02 — added meta-instruction: every project has a system design doc at docs/SYSTEM-DESIGN.md
- 2026-10-05 — added meta-instruction: applications include a settings button or tab
- 2026-10-25 — disk scan works without Spotlight: with indexing off it used to find no large files or projects; now one parallel walk finds them (7 s, was ~2.5 min); sizes on the same worker pool (1.6 s, was 2.1–2.8 s); the Disk card says how much you could clear; tick items, Select all per section or Select All Safe, and move them to the Trash with one confirmation
- 2026-10-09 — Disk popover opens fast and leads with "Where to win space" (totals per category and the 3 biggest single wins); lazy rows, cached per-type icons (row icons cost 1.7 s before), at most 4 redraws a second while scanning
- 2026-10-09 — remembered sizes survive relaunches (scan after relaunch 2.8 s, was ~11 s); caches appear as soon as each is measured; tried biggest-first ordering and dropped it (no measurable gain)
- 2026-10-09 — faster disk scans: steps run at the same time, sizes read with getattrlistbulk in parallel, unchanged folders' sizes reused on refresh (refresh 2.8 s, was 12.7 s; first scan ~15% faster)
- 2026-10-08 — "What to clear" is fast: opens instantly with the last results and refreshes in the background; large files and projects come from Spotlight, folder sizes use fts in parallel (full scan 87 s, was over 10 min)
- 2026-10-08 — threshold alerts for memory, CPU and disk with recommendations and a one-tap fix; stale-item suggestions (unused apps, old downloads, old project build folders) that never touch active work; Move to… an external drive or folder
- 2026-10-08 — pushed to GitHub as a private repo: https://github.com/amalmehta/RamClean
- 2026-10-08 — new custom icon: a friendly ram with curled golden horns and sparkles (picked from three concepts)
- 2026-10-08 — the Memory, CPU and Disk bars open recommendations: what to quit (with reasons) and what to clear (caches, large files, Trash) with Move to Trash
- 2026-10-08 — added an app icon (RAM stick with sparkles), drawn by scripts/make-icon.swift
- 2026-10-07 — built the Mac app: process sampling, habit log, protections, Create ML model, notifications, settings, feedback, docs, tests
