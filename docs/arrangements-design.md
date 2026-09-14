# Arrangements: how Tugboat remembers where windows go

This is the design for the half of Tugboat that Rectangle does not have. It is
written before the code so that the data model is settled first; the module
lives in `Rectangle/Arrangements/` and touches the rest of the app in as few
places as possible.

## Vocabulary

- **Display set.** The displays connected right now, identified durably. A laptop
  alone is one display set; laptop plus the office monitor is another; the two
  displays at home are a third.
- **Fingerprint.** A stable string that names a display set. Same displays,
  same fingerprint, no matter when they are plugged in.
- **Window record.** One remembered window: how to recognise it again, which
  display it belongs on, and where on that display it goes.
- **Arrangement.** All the window records for one display set.

## Where the list lives

One file per display set, in a directory owned by Tugboat and outside the
settings export:

```
~/Library/Application Support/Tugboat/Arrangements/
    BuiltIn-37D8832A.json
    StudioDisplay-2072A734.json
    BuiltIn-37D8832A+StudioDisplay-2072A734.json
    Dell-U2723QE-9A4E1C2B+Dell-U2723QE-C41B77D0.json
```

One file is one arrangement. Forgetting a display set is deleting its file,
inspecting or hand-editing one is opening it, and a file can be copied to
another Mac that sees the same display UUIDs. Writes are atomic (write to a
temp file, rename over the old one) and debounced, so a burst of window moves
produces one write. Files are read on demand and cached in memory.

### File names

Each connected display contributes one token, `<Name>-<Short>`:

- `Name` is the display's product name from the IORegistry (`StudioDisplay`,
  `U2723QE`), reduced to letters and digits, with the vendor prefixed when the
  product name is generic. The built-in panel is always `BuiltIn`. If no name
  is available the token is `Display`.
- `Short` is the first eight hex digits of the display UUID that macOS derives
  from the panel's EDID (vendor, model, serial number and manufacture date).
  It is what System Settings itself uses to remember display arrangements.

Tokens are sorted and joined with `+`, so laptop plus monitor and monitor plus
laptop name the same file. Names are for people and for the direct lookup;
the identities that matter are inside the file.

### Identity, and why not the serial number alone

Serial numbers are obtainable: `CGDisplaySerialNumber` returns the numeric
serial from the EDID (the Studio Display on the development Mac reports
1654046352, vendor 1552, model 44602, year 2022 week 7), and the IORegistry
exposes the same values under `ProductAttributes`. Two caveats keep the serial
from being the key on its own:

- Many third-party panels report `0` or a placeholder such as `0x01010101`,
  and identical monitors from one batch can share it.
- The alphanumeric serial that System Information shows for Apple displays
  comes from the display's USB side, not the EDID, and most displays have no
  such thing.

So the key is the display UUID, which already folds vendor, model and serial
together and falls back sensibly when the serial is missing, and the full
identity is stored alongside it. `CGDisplayCreateUUIDFromDisplayID` is not in
the Swift SDK headers; it is declared in the bridging header the same way
Rectangle declares `_AXUIElementGetWindow`.

### Lookup

1. Compute the file name for the connected displays and open it.
2. If there is no such file, scan the directory for a set with the same
   number of displays and the same multiset of pixel sizes. This is Stay's
   rule and it covers docks and KVMs that hand out a fresh UUID on every
   reconnect. A fallback match is adopted: the file is rewritten with the new
   identities and renamed, so the next connection matches directly.
3. If nothing matches, a new file is created as soon as the first window is
   captured.

Origins and scale factor never take part in matching. Rearranging displays in
System Settings or changing "More Space" must not create a new arrangement;
origins are stored only so frames can be restored, and pixel sizes survive a
scale change.

Mirrored displays count as one, identified by the primary of the mirror set.

## Shape of a file

```json
{
  "version": 1,
  "name": "Laptop + Studio Display",
  "lastSeen": "2026-09-13T22:10:04Z",
  "displays": [
    { "uuid": "37D8832A-…", "name": "Built-in Retina Display", "builtIn": true,
      "vendor": 1552, "model": 41067, "serial": 0,
      "pixels": [3024, 1964], "points": [1512, 982], "origin": [0, 0], "main": true },
    { "uuid": "2072A734-E3C9-47B0-ADEB-47BF362404A8", "name": "Studio Display", "builtIn": false,
      "vendor": 1552, "model": 44602, "serial": 1654046352,
      "pixels": [5120, 2880], "points": [2560, 1440], "origin": [1512, -458], "main": false }
  ],
  "windows": [
    {
      "app": "com.apple.Safari",
      "title": "GitHub - jduprat/Tugboat",
      "titlePattern": null,
      "subrole": "AXStandardWindow",
      "ordinal": 0,
      "display": "2072A734-E3C9-47B0-ADEB-47BF362404A8",
      "frame": { "x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0 },
      "points": { "x": 1512, "y": -458, "w": 1280, "h": 1415 },
      "lastAction": "leftHalf",
      "lastSeen": "2026-09-13T22:10:04Z",
      "pinned": false
    }
  ]
}
```

`name` is generated from the display names and can be renamed from the menu.
`version` exists so files can be migrated later. Unknown keys are preserved on
rewrite so a newer Tugboat can read a file written by an older one and back.

Expected size: fifty windows is under 20 KB per file.

Later, if named layouts per display set are wanted (a "coding" and a
"meeting" layout on the same displays), a file becomes a folder of the same
name holding one file per layout, with `default.json` as the automatic one.

## Recognising a window again

A window record is matched to a live window in this order, all within the same
app bundle identifier:

1. `titlePattern`, a user-supplied ICU regular expression, when present. This
   is for apps whose titles carry changing content (browsers, editors,
   terminals).
2. Exact title.
3. Same accessibility subrole, then `ordinal`. The ordinal is the window's rank
   by x then y position among the app's windows that tie on the rules above,
   which disambiguates two Terminal windows both titled `bash`.

Live windows that match nothing are left alone. Records that match nothing
stay in the file until they expire (see housekeeping). Window ids are never
stored: they change on every launch and Rectangle already has to synthesise
them for some apps.

## Where a window goes

Each record stores its frame two ways:

- `frame`, relative to the display's **visible** frame (the area excluding menu
  bar and Dock), as fractions from 0 to 1. This is what is used when the
  display is the same model but a different unit, or when the Dock has changed
  size, or in the fallback match.
- `points`, the absolute frame in screen points, used when the same display
  with the same geometry is present. Exact restore, no rounding drift.

When the record came from a Rectangle shortcut, `lastAction` names the action
(`leftHalf`, `topRightQuarter`…). Restore then re-runs the action on the target
display instead of applying a raw frame, so gaps and edge alignment come out
exactly as the shortcut would produce them. Windows the user placed by hand
have no `lastAction` and get the frame.

## Capture: when the list is written

Capture is automatic. Each window's record is refreshed when:

- Tugboat itself moves it (the existing post-process step in `WindowManager`).
- The window is moved or resized by the user or the app, seen through an
  accessibility observer per running app (`kAXWindowMovedNotification`,
  `kAXWindowResizedNotification`), debounced so a drag produces one update.
- A window is created (`kAXWindowCreatedNotification`) and no record matched
  it; it is then recorded where it opened.

Capture is frozen for a few seconds after a display change and until any
pending restore has finished, so macOS's own shuffling of windows during
reconnect is never recorded as intent. A `pinned` record is never overwritten
by capture; only the user changes it.

There is also an explicit "Store arrangement" shortcut that records every
visible window immediately, for people who prefer Stay's manual model.

## Restore: when the list is read

- **Display change.** On the CoreGraphics reconfiguration callback, after the
  end-of-configuration flag and a short debounce, compute the fingerprint,
  load the arrangement, restore every matching window. Verify each frame
  afterwards and retry once; macOS sometimes moves a window back on its own.
- **App launch and window creation.** When an app launches or opens a window,
  match it against the current arrangement and place it. Retry a few times
  over several seconds, because titles settle late in many apps.
- **Wake from sleep.** Same as a display change.
- **Manual.** A "Restore arrangement" shortcut and a menu item.

Only windows on the current Space can be moved; that is a limit of the public
API shared with every tool of this kind.

## Housekeeping

- A record that has not been seen for 60 days is dropped, unless pinned.
- A display set file that has not been seen for a year is deleted, unless it
  has pinned records.
- The menu lists display sets by name with Rename, Restore and Forget; the
  settings tab later gets a table of records with the title pattern editor.

## What it deliberately does not do

- It does not store window ids, Space ids or full-screen state.
- It does not try to move windows on other Spaces.
- It does not record windows of apps on the ignore list, sheets, dialogs, or
  the Todo-mode sidebar app.
- It does not sync between machines; the file is per machine by design.

## Touch points in the existing code

| Need | Existing piece |
|---|---|
| Move a window | `AccessibilityElement.setFrame` |
| List every visible window | `AccessibilityElement.getAllWindowElements` |
| Visible frame of a display | `NSScreen.adjustedVisibleFrame` |
| Remap a frame between displays | `NextPrevDisplayCalculation.relativePositionedRect` |
| Bulk move precedent | `MultiWindowManager`, `TodoManager.moveAll` |
| Record after a shortcut | `WindowManager.postProcess` |
| Global shortcut outside `WindowAction` | `TodoManager` binding via `MASShortcutBinder` |
| Internal notification names | `NotificationExtension.swift` |
