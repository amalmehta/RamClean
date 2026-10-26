# <img src="docs/images/icon.png" width="64" align="center" alt=""> RamClean

A Mac menu bar app that spots apps eating memory you aren't using, asks before quitting them, and learns your habits so it stops asking about the ones you need.

**Free.** [Download the latest release](https://github.com/amalmehta/RamClean/releases/latest/download/RamClean.zip) (macOS 14 or later, Apple silicon and Intel), unzip it and drag RamClean to Applications. It isn't notarized yet, so the first time, right-click it and choose **Open**.

![RamClean overview](docs/images/overview.png)

```mermaid
flowchart LR
    A[Every 15 s: sample processes, memory, CPU, disk, audio] --> B[Group helpers under their app]
    B --> C{Protected?<br/>in front · playing audio ·<br/>terminal running claude ·<br/>busy work tool · always keep}
    C -- yes --> K[Leave it alone]
    C -- no --> D[Deadweight score<br/>rules of thumb + Create ML model]
    D -- memory tight and score ≥ 70% --> N[Notification: Quit? Keep? Always keep?]
    N -- your answer --> L[(Habit log + training answers)]
    A --> T{Memory ≥ 85% · CPU ≥ 97% for 2 min · Disk ≥ 99%}
    T -- crossed --> R[Alert with what to quit, clear or move<br/>+ one-tap fix]
    L --> D
```

| Learns from your answers | Everything in one Settings window (⌘,) |
|---|---|
| ![Model page](docs/images/model.png) | ![Settings](docs/images/settings.png) |

## Links

- [Setup, run and use](docs/INSTRUCTIONS.md)
- [System design](docs/SYSTEM-DESIGN.md)
- [What's where](docs/FILE-STRUCTURE.md)
- [Go-live checklist](docs/GO-LIVE.md): for a paid Pro version later (Developer ID, notarization, Lemon Squeezy and Sparkle); RamClean itself is free (`ProductConfig.isFree`)
- [Product website](site/index.html)
- [Project brief](RamClean.md)
