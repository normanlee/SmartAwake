#Requires -Version 5.1
# =============================================================================
#  SmartAwakeTray.ps1
#  A standalone background utility that detects when a specific USB device 
#  (like a dock) is connected or disconnected, and toggles "Always Awake" mode.
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIGURATION
# Replace "VID_xxxx&PID_yyyy" with your dock's actual USB Device ID.
# (Run `Get-CimInstance Win32_USBHub` while connected to find it)
# ---------------------------------------------------------------------------
$script:TargetDeviceId = "VID_xxxx&PID_yyyy"
$script:ShowNotifications = $true


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Compile C# helper classes (DPI, Power API, and the hidden WM_DEVICECHANGE watcher)
# ---------------------------------------------------------------------------
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    public static void MakeAware() {
        try { SetProcessDpiAwarenessContext(new IntPtr(-2)); } catch {} // SYSTEM_AWARE
    }
}

public static class PowerHelper {
    [Flags]
    public enum EXECUTION_STATE : uint {
        ES_CONTINUOUS       = 0x80000000,
        ES_DISPLAY_REQUIRED = 0x00000002,
        ES_SYSTEM_REQUIRED  = 0x00000001
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern EXECUTION_STATE SetThreadExecutionState(EXECUTION_STATE esFlags);
    
    public static void EnableAwake() {
        SetThreadExecutionState(
            EXECUTION_STATE.ES_CONTINUOUS |
            EXECUTION_STATE.ES_SYSTEM_REQUIRED |
            EXECUTION_STATE.ES_DISPLAY_REQUIRED
        );
    }
    public static void DisableAwake() {
        SetThreadExecutionState(EXECUTION_STATE.ES_CONTINUOUS);
    }
}

public class DeviceWatcherForm : Form {
    private const int WM_DEVICECHANGE = 0x0219;
    private const int DBT_DEVICEARRIVAL = 0x8000;
    private const int DBT_DEVICEREMOVECOMPLETE = 0x8004;
    private const int DBT_DEVNODES_CHANGED = 0x0007;

    private const int DBT_DEVTYP_DEVICEINTERFACE = 5;
    private const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr RegisterDeviceNotification(IntPtr recipient, IntPtr notificationFilter, int flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct DEV_BROADCAST_DEVICEINTERFACE {
        public int dbcc_size;
        public int dbcc_devicetype;
        public int dbcc_reserved;
        public Guid dbcc_classguid;
        public short dbcc_name;
    }

    public delegate void DeviceChangedHandler();
    public event DeviceChangedHandler OnDeviceChanged;

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        
        DEV_BROADCAST_DEVICEINTERFACE dbi = new DEV_BROADCAST_DEVICEINTERFACE();
        dbi.dbcc_size = Marshal.SizeOf(dbi);
        dbi.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
        dbi.dbcc_reserved = 0;
        // Listen to all USB device arrivals (GUID_DEVINTERFACE_USB_DEVICE)
        dbi.dbcc_classguid = new Guid("A5DCBF10-6530-11D2-901F-00C04F8EE392");
        
        IntPtr buffer = Marshal.AllocHGlobal(dbi.dbcc_size);
        Marshal.StructureToPtr(dbi, buffer, true);
        RegisterDeviceNotification(this.Handle, buffer, DEVICE_NOTIFY_WINDOW_HANDLE);
        Marshal.FreeHGlobal(buffer);
    }

    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (m.Msg == WM_DEVICECHANGE) {
            int wParam = m.WParam.ToInt32();
            // Fallback: DBT_DEVNODES_CHANGED fires for ANY hardware tree change (like USB4 Bridges)
            if (wParam == DBT_DEVICEARRIVAL || wParam == DBT_DEVICEREMOVECOMPLETE || wParam == DBT_DEVNODES_CHANGED) {
                if (OnDeviceChanged != null) {
                    OnDeviceChanged();
                }
            }
        }
    }

    protected override void SetVisibleCore(bool value) {
        // Force the form to remain completely invisible while still receiving Windows messages
        base.SetVisibleCore(false);
    }
}
'@

[DpiHelper]::MakeAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:IsAwake = $false

# ---------------------------------------------------------------------------
# Simple GDI-drawn "D" icon factory
# ---------------------------------------------------------------------------
function New-DockIcon {
    param([bool]$IsConnected)
    $size   = 16
    $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g      = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    
    if ($IsConnected) {
        # [ALWAYS ON] bright amber sun
        # Outer glow ring
        $glowBrush  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(80, 255, 200, 0))
        $g.FillEllipse($glowBrush, 0, 0, 15, 15)
        $glowBrush.Dispose()

        # Main circle
        $mainBrush  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 255, 185, 0))
        $g.FillEllipse($mainBrush, 2, 2, 11, 11)
        $mainBrush.Dispose()

        # Inner bright core
        $coreBrush  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 255, 240, 100))
        $g.FillEllipse($coreBrush, 5, 5, 5, 5)
        $coreBrush.Dispose()

        # Thin border
        $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(200, 200, 120, 0), 1)
        $g.DrawEllipse($pen, 2, 2, 11, 11)
        $pen.Dispose()
    } else {
        # [NORMAL SLEEP] cool blue crescent moon
        # Background disc
        $discBrush  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 55, 110, 185))
        $g.FillEllipse($discBrush, 1, 1, 13, 13)
        $discBrush.Dispose()

        # Carve the crescent by painting an offset circle with the background colour
        $carveBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 28, 28, 38))
        $g.FillEllipse($carveBrush, 4, 0, 12, 12)
        $carveBrush.Dispose()

        # Bright edge highlight
        $edgePen    = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(180, 140, 180, 255), 1)
        $g.DrawEllipse($edgePen, 1, 1, 13, 13)
        $edgePen.Dispose()
    }
    
    $g.Dispose()

    $hIcon = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    return @{ Icon = $icon; Bitmap = $bitmap }
}

# Cache the icons so we aren't creating new handles constantly
$icons = @{
    Connected    = New-DockIcon -IsConnected $true
    Disconnected = New-DockIcon -IsConnected $false
}

# ---------------------------------------------------------------------------
# Tray Icon & Menu
# ---------------------------------------------------------------------------
$script:trayIcon = [System.Windows.Forms.NotifyIcon]::new()
$script:trayIcon.Icon = $icons.Disconnected.Icon
$script:trayIcon.Text = "SmartAwake - Disconnected"

$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$script:menuStatus = [System.Windows.Forms.ToolStripMenuItem]::new("Status: Disconnected")
$script:menuStatus.Enabled = $false
$script:menuStatus.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$menuToggle = [System.Windows.Forms.ToolStripMenuItem]::new('Toggle Awake')
$menuToggle.add_Click({ Toggle-Awake })

$menuExit = [System.Windows.Forms.ToolStripMenuItem]::new('Exit SmartAwake')
$menuExit.add_Click({
    [PowerHelper]::DisableAwake()
    $script:trayIcon.Visible = $false
    $script:trayIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$menu.Items.AddRange(@($script:menuStatus, [System.Windows.Forms.ToolStripSeparator]::new(), $menuToggle, $menuExit))
$script:trayIcon.ContextMenuStrip = $menu
$script:trayIcon.Visible = $true

$script:trayIcon.add_DoubleClick({ Toggle-Awake })

# ---------------------------------------------------------------------------
# Validation & State Logic
# ---------------------------------------------------------------------------
function Set-AwakeState {
    param([bool]$Enable)
    if ($Enable) {
        $script:IsAwake = $true
        [PowerHelper]::EnableAwake()
        $script:trayIcon.Icon = $icons.Connected.Icon
        $script:trayIcon.Text = "SmartAwake - CONNECTED (Always On)"
        $script:menuStatus.Text = "Status: Connected (Awake)"
        $script:menuStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 80, 0)
    } else {
        $script:IsAwake = $false
        [PowerHelper]::DisableAwake()
        $script:trayIcon.Icon = $icons.Disconnected.Icon
        $script:trayIcon.Text = "SmartAwake - Disconnected"
        $script:menuStatus.Text = "Status: Disconnected"
        $script:menuStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 140, 220)
    }
}

function Toggle-Awake {
    Set-AwakeState -Enable (-not $script:IsAwake)
}

function Check-DockStatus {
    # Skip checking if not configured
    if ([string]::IsNullOrWhiteSpace($script:TargetDeviceId) -or $script:TargetDeviceId -match "xxxx") {
        return
    }

    # Query WMI only when an event fires
    $found = Get-CimInstance Win32_PnPEntity -Filter "DeviceID LIKE '%$($script:TargetDeviceId)%'" -ErrorAction SilentlyContinue
    
    if ($found) {
        if (-not $script:IsAwake) {
            Set-AwakeState -Enable $true
            if ($script:ShowNotifications) {
                $script:trayIcon.ShowBalloonTip(3000, "SmartAwake", "Dock connected. Always On enabled.", [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    } else {
        if ($script:IsAwake) {
            Set-AwakeState -Enable $false
            if ($script:ShowNotifications) {
                $script:trayIcon.ShowBalloonTip(3000, "SmartAwake", "Dock disconnected. Restored normal sleep.", [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Hidden form to intercept WM_DEVICECHANGE
# ---------------------------------------------------------------------------
# Timer to check WMI multiple times after a hardware event.
# USB4 devices take several seconds to fully unload from WMI after unplugging.
$script:checkCount = 0
$script:debounceTimer = [System.Windows.Forms.Timer]::new()
$script:debounceTimer.add_Tick({
    Check-DockStatus
    $script:checkCount++
    if ($script:checkCount -ge 3) {
        $script:debounceTimer.Stop()
    } else {
        # Check again in 3 seconds to catch delayed WMI updates
        $script:debounceTimer.Interval = 3000
    }
})

$script:watcherForm = [DeviceWatcherForm]::new()

# Force the native window handle to be created immediately so OnHandleCreated runs
# and RegisterDeviceNotification is actually executed. (Hidden forms don't create handles by default)
$null = $script:watcherForm.Handle

$script:watcherForm.add_OnDeviceChanged({
    # Start checking at 2s, 5s, and 8s after the hardware event storm
    $script:checkCount = 0
    $script:debounceTimer.Stop()
    $script:debounceTimer.Interval = 2000
    $script:debounceTimer.Start()
})

# Run an initial check at startup
Check-DockStatus

# Block and process windows messages via our hidden watcher form
[System.Windows.Forms.Application]::Run($script:watcherForm)

# Cleanup
$icons.Connected.Icon.Dispose()
$icons.Connected.Bitmap.Dispose()
$icons.Disconnected.Icon.Dispose()
$icons.Disconnected.Bitmap.Dispose()
