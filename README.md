<p align="center">
  <img src="docs/tugboat-logo.png" width="720" alt="Tugboat">
</p>

Tugboat is a window manager for macOS that does two things:

1. **Places windows from the keyboard.** Halves, thirds, quarters, maximize, move between displays, snap areas when you drag a window to a screen edge. This half is [Rectangle](https://github.com/rxhanson/Rectangle), which Tugboat is forked from.
2. **Remembers where your windows go.** For every set of displays you use (laptop alone, laptop plus the office monitor, the two displays at home) Tugboat keeps track of where each window lives and puts it back when you dock, undock, wake the machine, or relaunch an app. *This half is under construction; see the roadmap.*

## Status

Early fork. The placement half is Rectangle 1.100 with a new name, icon, and bundle identifier. The arrangements half is being built in `Rectangle/Arrangements/`.

## System requirements

macOS 10.15 or later for window placement. Tugboat is built and tested on Apple silicon; Intel builds are expected to work.

## Installation

There are no packaged releases yet. Build it yourself:

```bash
git clone https://github.com/jduprat/Tugboat.git
cd Tugboat
xcodebuild -project Tugboat.xcodeproj -scheme Tugboat -configuration Release build
```

or open `Tugboat.xcodeproj` in Xcode and run the `Tugboat` scheme. Builds are ad-hoc signed by default. On first launch Tugboat asks for Accessibility permission; a rebuild that changes the code signature will ask again.

Tugboat uses its own bundle identifier (`io.github.jduprat.Tugboat`), so it can be installed next to Rectangle. Do not run both at the same time, or every shortcut fires twice.

## How to use it

The keyboard shortcuts are listed in the menu bar menu and in Settings. Snap areas work by dragging a window to a screen edge; when the cursor reaches the edge you see a footprint of where the window will land when you release it.

| Snap area                                              | Resulting action                       |
|--------------------------------------------------------|----------------------------------------|
| Left or right edge                                     | Left or right half                     |
| Top                                                    | Maximize                               |
| Corners                                                | Quarter in respective corner           |
| Left or right edge, just above or below a corner       | Top or bottom half                     |
| Bottom left, center, or right third                    | Respective third                       |
| Bottom left or right third, then drag to bottom center | First or last two thirds, respectively |

Hidden settings are changed from the terminal with `defaults write io.github.jduprat.Tugboat …`; see [TerminalCommands.md](TerminalCommands.md). Settings can be exported to and imported from JSON in Settings, and a file at `~/Library/Application Support/Tugboat/TugboatConfig.json` is offered for import at launch.

## Roadmap

| Phase | Scope |
|---|---|
| 1 | Display fingerprint, arrangement store, manual store and restore shortcuts, restore on display change |
| 2 | Automatic capture with debounce and a post-change freeze |
| 3 | Restore on app launch and window creation, with retries |
| 4 | Settings tab, stored-window editor, title regex matching |

Known limits shared with every tool of this kind: windows on other Spaces cannot be moved through public APIs, and Stage Manager reports misleading window frames.

## Relationship to Rectangle

Tugboat is a fork of [Rectangle](https://github.com/rxhanson/Rectangle) by Ryan Hanson, itself based on Spectacle by Eric Czarny, both MIT licensed. Upstream changes are merged regularly, and fixes to the shared placement engine are sent upstream where they fit. Rectangle Pro is a separate commercial product from the Rectangle author and is unrelated to Tugboat.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
