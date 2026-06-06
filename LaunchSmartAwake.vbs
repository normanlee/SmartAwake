' =============================================================================
'  LaunchSmartAwake.vbs
'  Silent launcher - starts SmartAwakeTray.ps1 without a visible console.
'  Place a shortcut to THIS file in shell:startup for auto-run on login.
'  The .ps1 file must live in the same directory as this .vbs file.
' =============================================================================

Dim oShell, oFso, scriptDir, sCmd

Set oShell = CreateObject("WScript.Shell")
Set oFso   = CreateObject("Scripting.FileSystemObject")

' Resolve the directory this .vbs file lives in at runtime,
' so the launcher works regardless of where the pair of files are placed.
scriptDir = oFso.GetParentFolderName(WScript.ScriptFullName)

sCmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass" & _
       " -File """ & scriptDir & "\SmartAwakeTray.ps1"""

' WindowStyle 0 = Hidden, bWaitOnReturn = False (fire-and-forget)
oShell.Run sCmd, 0, False

Set oFso   = Nothing
Set oShell = Nothing
