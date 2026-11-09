# CarianSound, PowerShell host (2.2): plays the Carian sounds without a bundled program.
# Windows' own PowerShell compiles CarianSound.cs (next to this script) when it starts and runs
# it: the same mixer, named pipe and behaviour as CarianSound.exe (see the top of that file).
# audio.lua starts this script when CarianSound.exe is not in the package: CarianSound.vbs runs
# it with no window; CarianSound.cmd (a console window flashes) is the fallback.
# QA: any arguments are passed on, e.g.
#   powershell -NoProfile -ExecutionPolicy Bypass -File CarianSound.ps1 --render out.wav 4 script.txt
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
try {
    if (-not ('CarianSound' -as [type])) {
        $source = [System.IO.File]::ReadAllText((Join-Path $here 'CarianSound.cs'))
        Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies System.Core, System.Management
    }
    $argv = [string[]](@('--host-script', $PSCommandPath) + $args)
    exit [CarianSound]::Main($argv)
}
catch {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss ') + 'PowerShell host failed: ' + $_.Exception.Message + [Environment]::NewLine
    try { [System.IO.File]::AppendAllText((Join-Path $here 'CarianSound.log'), $line) } catch { }
    exit 1
}
