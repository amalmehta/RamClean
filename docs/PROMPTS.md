# Prompt log

The prompts that shaped RamClean, word for word, per session. Earlier sessions weren't logged here.

## 2026-11-20 — Clean up deadweight automatically

1. "RamClean: update this existing project. It's already built, so change what's here rather than starting it again. What I want changed, in my words: auto clean the non-running/deadweight projects periodically. How to go about it: Read RamClean.md and follow its META-INSTRUCTIONS, then the README and docs, and work the way the project already does. Edit what's here in place. Before rewriting a file wholesale or deleting anything, show me what would change and wait for my yes. Keep the README and docs in step with what changes, and add a CHANGELOG line if the project keeps one."
   → Two rounds of questions. Answers: clean both old project build folders and idle deadweight apps; "clean every 6 hrs or so so things dont get built up"; "every 6-12 hours. if it notices an overload ahead of time, it should do it automatically"; off by default with one switch in Settings; one notice with Undo; apps need deadweight + 2 h idle + no unsaved work; early runs on a disk forecast within 3 days, memory at 80% and memory pressure; 6 hours default. Trade-off named: freed memory vs. lost place. Led to `AutoClean.swift`, the Settings switch, the notification with Undo/Review, tests and docs.
