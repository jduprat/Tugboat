<p align="center">
  <img src="docs/tugboat-logo.png" width="720" alt="Tugboat">
</p>

Tugboat is a window manager for macOS that helps you place windows and keep layouts organized as your display setup changes.

1. **Place windows.** Use keyboard shortcuts or menu commands to move and resize windows into halves, thirds, quarters, and other layouts. Snap areas let you place windows by dragging them to a screen edge.
2. **Save and restore window positions.** Save a separate arrangement for each set of displays, then restore it manually or after a display change or wake. Row and column tiling can also keep groups of windows arranged as displays are connected and disconnected.

The placement features originated in [Rectangle](https://github.com/rxhanson/Rectangle). Saved arrangements are inspired by [Stay](https://cordlessdog.com/stay/) by Cordless Dog; Tugboat contains no Stay code.

## Status

Tugboat has regular releases, and we are responsive to bug reports.

## System requirements

macOS 14 or later. Tugboat is built and tested on Apple silicon; released builds also include an Intel binary. Runtime validation on Intel and macOS 14 is still required.

## Installation

Download the latest `Tugboat-x.y.z.dmg` from the [Releases page](https://github.com/jduprat/Tugboat/releases), open it, and drag Tugboat to Applications.

Released builds use ad hoc signing and are not notarized. On first launch, macOS may require you to right-click Tugboat and choose **Open**, or approve it under **System Settings → Privacy & Security**. Tugboat also needs Accessibility permission to move and resize windows; follow its authorization prompt when it opens.

Released builds check for newer releases and offer to install them through the app. You can turn automatic checks off in **Settings → General**.

Tugboat can be installed alongside Rectangle. Quit Rectangle before running Tugboat to avoid conflicts between their shortcuts and snapping behavior.

## Building from source

Building from source requires Xcode 27 and a full Git checkout:

```bash
git clone https://github.com/jduprat/Tugboat.git
cd Tugboat
xcodebuild -project Tugboat.xcodeproj -scheme Tugboat -configuration Release \
  -derivedDataPath ./build \
  build
```

The app is written to `build/Build/Products/Release/Tugboat.app`. Alternatively, open `Tugboat.xcodeproj` in Xcode and run the `Tugboat` scheme.

Source builds use ad hoc signing by default and do not require an Apple Developer account. macOS may ask for Accessibility permission again after rebuilding an app signed this way. To give successive builds a stable identity, configure Xcode to use a code-signing identity available in your keychain.

Each build uses the number of commits reachable from its Git commit as its build number, so rebuilding the same commit keeps the same number. The About panel shows the full commit ID and whether the checkout had uncommitted changes. It also identifies non-`main` branches and builds made from a detached commit or tag.

## How to use it

Tugboat runs in the menu bar. Open **Window Actions** for placement and tiling commands, or **Settings → Shortcuts** to learn and customize their keyboard bindings. The defaults combine Rectangle's recommended shortcuts, mostly ⌃⌥ plus an arrow or a letter, with Tugboat's tiling and saved-position shortcuts.

### Set up shortcuts

**Settings → Shortcuts** shows assigned shortcuts in a searchable list. Select one to change its keys or action, or use **＋** to add another. The action catalog groups commands into Place, Arrange, Move, Resize, Restore, Record, Sidebar, and Access, with fractional placements grouped by size.

Choose **Save Shortcut** to apply key and action changes together. **Cancel** discards edits to the selected shortcut. If a key combination is already used, you can replace the existing binding or share it as a cycle for supported single-window actions.

**Shared settings** take effect immediately and can affect other shortcuts and snap actions that use the same window behavior. The action catalog's **Access → Toggle stacked window badge** entry includes **Show stacked window list on hover**. **Show additional sizes in menu** appears below the shortcut list.

Presets include **Rectangle + Tugboat**, **Compact**, and **App Tiling**. After confirmation, a preset replaces shortcut bindings and discards shortcut drafts while preserving window behavior and snap area settings.

### Snap windows to screen edges

Drag a window to a screen edge. When the pointer reaches an active snap area, Tugboat shows a preview of where the window will land. Release the window to apply it. Configure these areas in **Settings → Snap Areas**.

These are the default snap areas on landscape displays:

| Snap area | Resulting action |
|---|---|
| Left or right edge, away from corners | Left or right half |
| Top edge | Maximize |
| Corners | Corresponding quarter |
| Left or right edge near a top or bottom corner | Top or bottom half |
| Left, center, or right third of the bottom edge | Corresponding third |
| Start in the left or right third of the bottom edge, then drag into the center third | First or last two thirds, respectively |

Portrait displays have separate defaults, using thirds along the side edges and halves along the bottom edge.

### Tile windows in rows, columns or a grid

| Shortcut | Action |
|---|---|
| ⌃⌥H | Tile windows on the active display in rows |
| ⌃⌥V | Tile windows on the active display in columns |
| ⌃⌥⇧H | Tile the focused app's windows in rows |
| ⌃⌥⇧V | Tile the focused app's windows in columns |
| ⌃⌥⇧G | Tile the focused app's windows in a grid |

These are the default bindings. By default, the app tiling actions target whichever app has focus. For row and column tiling, the active display is the one containing the focused window, or the display under the pointer when no ordinary window has focus.

All five commands appear in **Window Actions → Tiling** when **Show additional sizes in menu** is enabled. Change their shortcuts using the **Arrange** action group in **Settings → Shortcuts**.

### Save and restore window positions

| Shortcut | Action |
|---|---|
| ⌃⌥⇧S | Save Window Positions: record the current window positions |
| ⌃⌥⇧R | Restore Window Positions: restore saved positions for matching open windows |

Both commands are also in the menu bar menu. Change their shortcuts in **Settings → Shortcuts**, using the **Record** and **Restore** action groups.

Saving and restoring apply to windows on the current Space. Tugboat skips hidden, minimized, and full-screen windows; sheets and dialogs; ignored apps; its own windows; and the reserved sidebar window. Each display setup has separate saved positions. Each save updates the windows it captures and keeps previously saved records for other windows. **Restore Window Positions** is disabled when nothing has been saved for the connected displays.

Saved positions are stored in one JSON file per display setup under `~/Library/Application Support/Tugboat/Arrangements/`. The file format is described in [docs/arrangements-design.md](docs/arrangements-design.md).

### Adaptive row and column layouts

The **Keep row and column layouts when displays change** checkbox in a tiling shortcut's shared settings enables this behavior for all row and column groups. Tugboat remembers each group's window order, relative sizes, and preferred display. After a display change or wake, it rearranges the group's available windows to fit. If the preferred display is disconnected, recovery on another display is temporary; reconnecting the original display moves the group back there.

For **Tile app windows in rows/columns**, select **Application → Terminal** in the shortcut's shared settings to target Terminal even while another app has focus. The app must already be running. Tugboat brings its eligible windows on the current Space to the active display. Grid and cascade layouts are applied once and do not adapt to later display changes.

Moving a grouped window with a next/previous-display shortcut moves the group's visible windows together. A single-window placement, resize, or restore command removes that window from its group. Grid, cascade, reverse, and manual position restore commands also remove affected windows from their groups.

New windows join when you run the tiling command again, after the existing group members. Dragging windows manually changes their current positions but leaves the saved group order and relative sizes in place; run the tiling command again to replace the saved layout.

Saved groups survive app and Tugboat restarts and are considered during the next display-change or wake recovery. Tugboat resumes the members it can identify unambiguously. If repeated titles prevent matching, reapply the tiling shortcut to establish the group again.

After display changes, Tugboat also tries to bring inaccessible title bars of current-Space windows back within reach, respecting the same exclusions and app size constraints. If a group cannot fit within the apps' minimum window sizes, windows may overlap. Detailed behavior and remaining work are in [docs/adaptive-layouts.md](docs/adaptive-layouts.md).

### Import, export, and advanced settings

Settings can be exported to and imported from JSON in **Settings**. Tugboat also offers to import `~/Library/Application Support/Tugboat/TugboatConfig.json` at launch when that file exists. Removed shortcuts stay removed through export and import. Saved window positions and adaptive row and column groups are stored separately and are not included in the settings export.

Advanced settings can be changed from the terminal with `defaults write io.github.jduprat.Tugboat …`; see [TerminalCommands.md](TerminalCommands.md).

## Roadmap

Planned work for saved arrangements includes:

- Automatic saving of window positions, with a pause during display changes so temporary layouts are not recorded.
- Restoring positions when apps launch or open windows, with retries while those windows become ready.
- Arrangements settings and a stored-window editor, including title-pattern editing.

## Limitations

Tugboat manages windows on the current Space. Stage Manager can report inaccurate window frames, so layouts may not behave as expected when it is enabled.

## Relationship to Rectangle

Tugboat is a hard fork of [Rectangle](https://github.com/rxhanson/Rectangle) by Ryan Hanson, itself based on Spectacle by Eric Czarny, both MIT licensed. It is developed independently around the maintainer's usage patterns, with no plans to merge further updates from Rectangle. Rectangle Pro is a separate commercial product from the Rectangle author and is unrelated to Tugboat.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
