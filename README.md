# SmartAwake

SmartAwake is a lightweight, zero-CPU background utility for Windows that automatically toggles the system's "Always On" (sleep-preventing) state when a specific USB device—such as a docking station—is connected or disconnected.

## Features
- **Automatic Dock Detection:** Wakes the PC when your dock is connected, and restores normal sleep behavior when it's unplugged.
- **Manual Toggle:** Double-click the system tray icon or use the right-click menu to manually override the awake state.
- **Zero-CPU Overhead:** Uses pure Windows API event-driven architecture instead of CPU-heavy polling loops.
- **Silent & Invisible:** Runs completely in the background via a VBScript launcher with no console window.

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
