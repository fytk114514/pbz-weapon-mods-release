' CarianSound launcher (2.2): starts CarianSound.ps1 with Windows' own PowerShell and no window.
' audio.lua opens this file through the shell (LaunchURL), which cannot pass arguments to a
' program; the shell runs a .vbs with wscript, which has no console, and Run(..., 0) starts
' PowerShell hidden, so nothing appears on screen and the game keeps the focus.
Option Explicit
Dim shell, fso, here, ps
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
shell.Run """" & ps & """ -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & fso.BuildPath(here, "CarianSound.ps1") & """", 0, False
