# SmartAwake

SmartAwake is a lightweight, zero-CPU background utility for Windows that automatically toggles the system's "Always On" (sleep-preventing) state when a specific USB device—such as a docking station—is connected or disconnected.

**Author note**: I vibe-coded this (including the readme) with Antigravity CLI running Claude Sonnet 4.6 and Gemini 3.1 Pro (High). I couldn't find a utility that would keep my laptop on when docked and revert to normal power behavior when undocked, so I created it myself.

I have no experience with PowerShell scripts, and the only dock I've tested this with is my [Anker 778](https://www.anker.com/nz/products/a83a9?variant=45193924313259). If you see a glaring issue or would like to contribute, please feel free.

## Features
- **Automatic Dock Detection:** Wakes the PC when your dock is connected, and restores normal sleep behavior when it's unplugged.
- **Manual Toggle:** Double-click the system tray icon or use the right-click menu to manually override the awake state.
- **Zero-CPU Overhead:** Uses pure Windows API event-driven architecture instead of CPU-heavy polling loops.
- **Silent & Invisible:** Runs completely in the background via a VBScript launcher with no console window.

## Screenshots

| State | Image |
| --- | --- |
| Disabled | <img width="276" height="115" alt="Screenshot 2026-06-06 174846" src="https://github.com/user-attachments/assets/cebd284d-440b-44bd-9a16-fad6dd8d4a55" /> |
| Enabled | <img width="278" height="85" alt="Screenshot 2026-06-06 174903" src="https://github.com/user-attachments/assets/1298fcbb-2671-4f4c-8f4f-a2efb7f576e3" /> |
| Context menu | <img width="323" height="148" alt="Screenshot 2026-06-06 174937" src="https://github.com/user-attachments/assets/9eb049db-c6a5-45bd-91df-c39a2598e03e" /> |
| Windows notification | <img width="645" height="213" alt="Screenshot 2026-06-06 175049" src="https://github.com/user-attachments/assets/0ea1bb3e-914f-46e6-bff9-c90ab7db91ad" /> |

## Installation & Usage
1. Open PowerShell and run `Get-CimInstance Win32_USBHub` (or `Get-CimInstance Win32_PnPEntity`) while your dock is connected to find its `DeviceID`.
2. Open `SmartAwakeTray.ps1` and set `$script:TargetDeviceId` to the `VID_...&PID_...` string that matches your dock.
3. (Optional) Toggle balloon notifications on or off by setting `$script:ShowNotifications`.
4. Double-click `LaunchSmartAwake.vbs` to start the utility in the background. 
5. (Optional) Place a shortcut to `LaunchSmartAwake.vbs` in your `shell:startup` folder to automatically run it when you log in to Windows.

## The Journey of Dock Detection (Technical Notes)
Reliably detecting the connection and disconnection of a complex USB4/Thunderbolt dock in the background using native PowerShell and WinForms turned out to be an intricate process involving several low-level Windows quirks:

1. **The Event Storm:** Complex docks aren't single devices; they are massive trees of nested hubs, NICs, and audio cards. Plugging one in causes an instantaneous "storm" of dozens of hardware events. Querying WMI synchronously for each one would lock up the UI thread, necessitating a debounce timer.
2. **The Missing API Broadcasts:** By default, the standard `WM_DEVICECHANGE` broadcast in Windows is only sent to applications when a storage volume (like a flash drive) is mounted. Generic USB hubs are ignored. We had to use C# Interop to call `RegisterDeviceNotification` to explicitly ask the OS for all USB interface events.
3. **The USB4/Thunderbolt Quirk:** Even with device notifications, the unplugs were being missed. High-speed USB4 routers (like Intel's) are treated by Windows as internal PCIe bridges rather than standard USB endpoints. We had to hook into the universal `DBT_DEVNODES_CHANGED` (0x0007) event, which fires for any structural change to the system's hardware tree.
4. **The "Invisible Form" Handle Gotcha:** Because our background listener was an explicitly invisible WinForms `Form`, the framework silently skipped generating its underlying native Window Handle to save memory. Without a native handle, the low-level `RegisterDeviceNotification` API was never actually executed. We had to force immediate handle creation via `$null = $script:watcherForm.Handle`.
5. **The Delayed WMI Unload:** The Windows WMI database is asynchronous to the kernel. When a massive USB4 tree is physically unplugged, it can take up to 7 seconds for the OS to fully teardown and remove the entries from WMI. If we checked immediately, WMI would report the dock was still connected. Our debounce timer now intentionally checks at 2s, 5s, and 8s intervals to guarantee it catches the delayed unload.
