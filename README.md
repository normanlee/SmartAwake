# SmartAwake

A lightweight Windows system-tray utility written in PowerShell that prevents your PC from sleeping on demand — and reminds you to turn it off when you unplug your laptop.

**Author note**: I vibe-coded this (including the readme) with Antigravity CLI running Claude Sonnet 4.6. I couldn't find a utility that would keep my laptop on when docked and revert to normal power behavior when undocked, so I settled for this, which needs to be manually enabled but will at least prompt you to disable it when unplugging while it's active.

I have no experience with PowerShell scripts. If you see a glaring issue or would like to contribute, please feel free.

---

## Features

- **System tray toggle** — left-click the tray icon to switch between *Normal Sleep* (default Windows behavior) and *Always On* (display + system sleep fully suppressed)
- **Distinct visual states** — amber sun icon for Always On, blue crescent moon for Normal Sleep, with matching tooltip and right-click menu labels
- **Power-disconnect prompt** — if you unplug your laptop while Always On is active, a dialog appears within ~3 seconds asking if you want to revert to Normal Sleep to conserve battery
- **Clean exit** — right-click → *Exit SmartAwake* fully restores default sleep behavior and removes the tray icon with no lingering processes
- **No installation required** — pure PowerShell + WinForms, no dependencies, no installer
- **Auto-start support** — an optional VBScript launcher runs the script silently (no console window) and can be added to your startup folder

---

## Files

| File                   | Purpose                                                    |
| ---------------------- | ---------------------------------------------------------- |
| `SmartAwakeTray.ps1`   | The application — all logic, icons, and UI                 |
| `LaunchSmartAwake.vbs` | Silent launcher — runs the script without a console window |

Both files must be kept in the **same directory**.

---

## Screenshots

| State | Image |
| --- | --- |
| Disabled | <img width="351" height="133" alt="Screenshot 2026-06-06 150330" src="https://github.com/user-attachments/assets/d92ac664-bc3b-4094-9613-8ac4ed99e883" /> |
| Enabled | <img width="348" height="133" alt="Screenshot 2026-06-06 150346" src="https://github.com/user-attachments/assets/29dc4240-5074-4c4b-a623-ef13fcf47e2e" /> |
| Context menu | <img width="467" height="126" alt="Screenshot 2026-06-06 150402" src="https://github.com/user-attachments/assets/1a5c92a3-f0b8-4432-87f7-e37105dbace4" /> |
| Disconnect prompt | <img width="740" height="411" alt="Screenshot 2026-06-06 150432" src="https://github.com/user-attachments/assets/7b2ece43-56f8-4b2a-800f-cb3c2cced9c8" /> |

---

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built into Windows — no download needed)

---

## Usage

### Run manually

Double-click `LaunchSmartAwake.vbs`. The tray icon will appear in the system tray (bottom-right). You may need to expand the hidden icons arrow `^` to see it.

### Run directly (with a console window)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SmartAwakeTray.ps1"
```

### Tray icon controls

| Action      | Result                                                       |
| ----------- | ------------------------------------------------------------ |
| Left-click  | Toggle between Normal Sleep and Always On                    |
| Right-click | Open context menu (shows current state, toggle option, Exit) |

---

## Auto-start on login (optional)

To have SmartAwake launch silently every time you log in:

1. Press **Win + R**, type `shell:startup`, press Enter
2. Create a shortcut inside that folder pointing to `LaunchSmartAwake.vbs`

To remove auto-start, delete the shortcut from that folder.

---

## How it works

**Always On** calls the Win32 API `SetThreadExecutionState` with the flags:

```
ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
```

This tells Windows not to sleep or turn off the display while the process is running. **Normal Sleep** clears these flags by calling `SetThreadExecutionState(ES_CONTINUOUS)` alone, fully restoring default power behavior.

The power monitor runs on a 3-second timer using `SystemInformation.PowerStatus` to detect the moment AC power is disconnected. It only fires a prompt on the `Online → Offline` transition, so it won't nag repeatedly.

Icons are generated at runtime using GDI+ — no image files are needed.

---

## Notes

- The console-less launch requires `LaunchSmartAwake.vbs` (or any other wrapper that passes `-WindowStyle Hidden` to `powershell.exe`). A plain `.ps1` shortcut will always show a console window — this is a Windows limitation, not a bug in the script.
- `SetThreadExecutionState` affects only the thread that calls it, which in this case is the WinForms UI/message-pump thread — the correct thread to call it from.
- Closing the terminal or PowerShell window that launched the script (if run directly) will also kill the tray app. Use the `.vbs` launcher or the *Exit* menu item for a clean shutdown.

---

## License

[MIT](LICENSE)
