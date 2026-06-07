' =============================================================================
'  LaunchSmartAwake.vbs
'  Silent launcher - starts SmartAwakeTray.ps1 without a visible console.
'  Place a shortcut to THIS file in shell:startup for auto-run on login.
' =============================================================================

Dim oShell, oFso, scriptDir, sCmd

Set oShell = CreateObject("WScript.Shell")
Set oFso   = CreateObject("Scripting.FileSystemObject")

' Resolve the directory this .vbs file lives in at runtime
scriptDir = oFso.GetParentFolderName(WScript.ScriptFullName)

sCmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass" & _
       " -File """ & scriptDir & "\SmartAwakeTray.ps1"""

' WindowStyle 0 = Hidden, bWaitOnReturn = False (fire-and-forget)
oShell.Run sCmd, 0, False

Set oFso   = Nothing
Set oShell = Nothing
