#Requires -Version 5.1
# =============================================================================
#  SmartAwakeTray.ps1
#  A Windows Forms system-tray utility that toggles "Always Awake" mode and
#  monitors AC power, prompting the user to revert when unplugged.
# =============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# DPI awareness - must be set before any window is created.
# SYSTEM_AWARE (-2) renders at the primary monitor DPI consistently, which is
# the right choice for a tray app. Falls back silently on pre-Win10 1703.
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    public static void MakeAware() {
        // DPI_AWARENESS_CONTEXT_SYSTEM_AWARE = -2: renders at primary monitor
        // DPI consistently. Falls back silently on pre-Win10 1703.
        try { SetProcessDpiAwarenessContext(new IntPtr(-2)); } catch {}
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

public static class IconHelper {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@

[DpiHelper]::MakeAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# Holds the current backing bitmap so it stays alive as long as the icon is shown.
$script:CurrentIconBitmap = $null

# ---------------------------------------------------------------------------
# Icon factory - creates 16x16 icons purely via GDI+ (no files needed)
# The bitmap is kept alive in $script:CurrentIconBitmap; caller must pass the
# previous Icon so its HICON can be destroyed before replacement.
# ---------------------------------------------------------------------------
function New-TrayIcon {
    param(
        [ValidateSet('Awake','Sleep')]
        [string]$State,
        [System.Drawing.Icon]$OldIcon = $null
    )

    $size   = 16
    $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g      = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    if ($State -eq 'Awake') {
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

    # Destroy the old icon's HICON before we replace it
    if ($OldIcon -ne $null) {
        $oldHandle = $OldIcon.Handle
        $OldIcon.Dispose()
        [IconHelper]::DestroyIcon($oldHandle) | Out-Null
    }
    # Dispose the old backing bitmap
    if ($script:CurrentIconBitmap -ne $null) {
        $script:CurrentIconBitmap.Dispose()
    }

    # Keep the new bitmap alive; FromHandle does NOT take ownership
    $script:CurrentIconBitmap = $bitmap
    $hIcon = $bitmap.GetHicon()
    $icon  = [System.Drawing.Icon]::FromHandle($hIcon)
    return $icon
}

# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------
$script:IsAwake        = $false
$script:LastPowerState = $null   # tracks previous AC status to detect edge
$script:PromptActive   = $false  # guard: prevents stacked power-disconnect dialogs

# ---------------------------------------------------------------------------
# Build context-menu
# ---------------------------------------------------------------------------
function Build-ContextMenu {
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()

    # Status header (non-clickable label style)
    $script:menuStatus          = [System.Windows.Forms.ToolStripMenuItem]::new()
    $script:menuStatus.Enabled  = $false
    $script:menuStatus.Font     = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)

    # Toggle item
    $script:menuToggle          = [System.Windows.Forms.ToolStripMenuItem]::new()
    $script:menuToggle.Font     = [System.Drawing.Font]::new('Segoe UI', 9)
    $script:menuToggle.add_Click({ Toggle-State })

    $sep1 = [System.Windows.Forms.ToolStripSeparator]::new()

    # Exit item
    $menuExit       = [System.Windows.Forms.ToolStripMenuItem]::new('Exit SmartAwake')
    $menuExit.Font  = [System.Drawing.Font]::new('Segoe UI', 9)
    $menuExit.add_Click({
        $powerTimer.Stop()
        [PowerHelper]::DisableAwake()
        $script:trayIcon.Visible = $false
        $script:trayIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })

    $sep2 = [System.Windows.Forms.ToolStripSeparator]::new()
    $menu.Items.AddRange(@($script:menuStatus, $sep1, $script:menuToggle, $sep2, $menuExit))
    return $menu
}

# ---------------------------------------------------------------------------
# Update icon + menu labels to reflect current state
# ---------------------------------------------------------------------------
function Refresh-TrayAppearance {
    if ($script:IsAwake) {
        $icon = New-TrayIcon -State 'Awake' -OldIcon $script:trayIcon.Icon
        $script:trayIcon.Icon        = $icon
        $script:trayIcon.Text        = "SmartAwake - ALWAYS ON"
        $script:menuStatus.Text      = "[ON] ALWAYS ON"
        $script:menuStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 80, 0)
        $script:menuToggle.Text      = "Switch to Normal Sleep"
    } else {
        $icon = New-TrayIcon -State 'Sleep' -OldIcon $script:trayIcon.Icon
        $script:trayIcon.Icon        = $icon
        $script:trayIcon.Text        = "SmartAwake - Normal Sleep"
        $script:menuStatus.Text      = "[zzz] Normal Sleep"
        $script:menuStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 140, 220)
        $script:menuToggle.Text      = "Switch to ALWAYS ON"
    }
}

# ---------------------------------------------------------------------------
# Toggle between Awake / Sleep
# ---------------------------------------------------------------------------
function Toggle-State {
    $script:IsAwake = -not $script:IsAwake

    if ($script:IsAwake) {
        [PowerHelper]::EnableAwake()
    } else {
        [PowerHelper]::DisableAwake()
    }

    Refresh-TrayAppearance
}

# ---------------------------------------------------------------------------
# Prompt user when power is disconnected while ALWAYS ON
# ---------------------------------------------------------------------------
function Prompt-PowerDisconnected {
    # Guard: do not stack a second dialog if one is already open
    if ($script:PromptActive) { return }
    $script:PromptActive = $true

    $msg    = "Your laptop has been unplugged from AC power.`n`n" +
              "SmartAwake is currently set to ALWAYS ON, which will drain`n" +
              "your battery significantly faster.`n`n" +
              "Do you want to switch back to Normal Sleep to conserve battery?"
    # A hidden topmost Form as owner gives the dialog proper DPI context and
    # ensures it appears in front, without the legacy ServiceNotification path
    # which bypasses normal DPI rendering and causes blurry text.
    $ownerForm = [System.Windows.Forms.Form]::new()
    $ownerForm.TopMost        = $true
    $ownerForm.ShowInTaskbar  = $false
    $ownerForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $ownerForm.Size           = [System.Drawing.Size]::new(1, 1)
    $ownerForm.StartPosition  = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $ownerForm.Show()
    $ownerForm.Activate()

    $result = [System.Windows.Forms.MessageBox]::Show(
        $ownerForm,
        $msg,
        "SmartAwake - Power Disconnected",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1
    )

    $ownerForm.Dispose()
    $script:PromptActive = $false

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:IsAwake = $false
        [PowerHelper]::DisableAwake()
        Refresh-TrayAppearance

        $script:trayIcon.ShowBalloonTip(
            3000,
            "SmartAwake",
            "Switched to Normal Sleep to conserve battery.",
            [System.Windows.Forms.ToolTipIcon]::Info
        )
    }
}

# ---------------------------------------------------------------------------
# Power-monitor timer (fires every 3 seconds)
# ---------------------------------------------------------------------------
$powerTimer          = [System.Windows.Forms.Timer]::new()
$powerTimer.Interval = 3000
$powerTimer.add_Tick({
    $status = [System.Windows.Forms.SystemInformation]::PowerStatus
    $currentAC = $status.PowerLineStatus   # Online | Offline | Unknown

    # Detect the Offline edge only (transition from Online -> Offline)
    if ($script:IsAwake -and
        $script:LastPowerState -eq [System.Windows.Forms.PowerLineStatus]::Online -and
        $currentAC -eq [System.Windows.Forms.PowerLineStatus]::Offline) {

        Prompt-PowerDisconnected
    }

    $script:LastPowerState = $currentAC
})

# ---------------------------------------------------------------------------
# Initialise the NotifyIcon
# ---------------------------------------------------------------------------
$script:trayIcon                  = [System.Windows.Forms.NotifyIcon]::new()
$script:trayIcon.ContextMenuStrip = Build-ContextMenu

# Seed the last-known power state before the timer starts
$script:LastPowerState = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus

Refresh-TrayAppearance        # assigns .Icon first ...
$script:trayIcon.Visible = $true  # ... then make it visible

# Left-click -> toggle state
$script:trayIcon.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Toggle-State
    }
})

# Start power monitor
$powerTimer.Start()

# ---------------------------------------------------------------------------
# Run the message pump (blocking call - keeps the tray alive)
# ---------------------------------------------------------------------------
[System.Windows.Forms.Application]::Run()
