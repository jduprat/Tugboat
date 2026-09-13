# Security Policy

Tugboat is maintained by a single developer. Security fixes are applied only to the latest release.

## Scope and Privileges

Tugboat requires **macOS Accessibility permission** (`AXUIElement`) to move and resize windows.

* **Local only.** Tugboat runs entirely on your Mac. It never collects, logs, or transmits window layouts, keystrokes, or personal data. Remembered window arrangements are stored in a local file under `~/Library/Application Support/Tugboat/`.
* **Network access.** None, unless a Sparkle update feed is configured in a release build, in which case the app only fetches the appcast and update packages.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security bugs.** Use GitHub's private vulnerability reporting on the Tugboat repository (Security tab, "Report a vulnerability").

Please include a short description of the issue and its impact, steps or a proof of concept to reproduce it, and your Tugboat and macOS versions.
