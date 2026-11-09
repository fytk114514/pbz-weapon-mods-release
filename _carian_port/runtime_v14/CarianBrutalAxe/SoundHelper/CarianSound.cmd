@echo off
rem CarianSound launcher, fallback (2.2): used by audio.lua only when CarianSound.vbs did not
rem start the player (for example when Windows Script Host is switched off). A console window
rem shows for a moment; PowerShell itself starts minimised and hides its window.
start "" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CarianSound.ps1"
