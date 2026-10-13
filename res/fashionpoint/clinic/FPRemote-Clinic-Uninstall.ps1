<#
.SYNOPSIS
Removes FPRemote (clinic edition) from this computer, with its settings and password.

.DESCRIPTION
Run as administrator:

    powershell -ExecutionPolicy Bypass -File .\FPRemote-Clinic-Uninstall.ps1

Uninstalls FPRemote, removes its configuration (ID, password) from the service profile and from
every user profile, and lists anything left. The computer stays in the console and in the address
book until support removes it there; the script prints its ID for that.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$AppName = 'FPRemote'
$InstallDir = Join-Path $env:ProgramFiles $AppName
$Exe = Join-Path $InstallDir "$AppName.exe"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as administrator (right-click PowerShell, Run as administrator).'
}

$id = ''
if (Test-Path $Exe) {
    $out = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList '--get-id' -PassThru -NoNewWindow -RedirectStandardOutput $out
        if ($p.WaitForExit(60000)) { $id = "$(Get-Content $out -Raw)".Trim() }
    } finally { Remove-Item $out -Force -ErrorAction SilentlyContinue }
    Write-Host "Uninstalling $AppName (ID $id) ..."
    $p = Start-Process -FilePath $Exe -ArgumentList '--uninstall' -PassThru
    $null = $p.WaitForExit(120000)
}

$deadline = (Get-Date).AddMinutes(2)
while ((Get-Service -Name $AppName -ErrorAction SilentlyContinue) -or (Test-Path $Exe)) {
    if ((Get-Date) -gt $deadline) { throw "$AppName is still installed after 2 minutes." }
    Start-Sleep -Seconds 2
}

$leftovers = @(
    $InstallDir,
    (Join-Path $env:windir "ServiceProfiles\LocalService\AppData\Roaming\$AppName"),
    (Join-Path $env:ProgramData $AppName)
)
foreach ($user in Get-ChildItem (Split-Path $env:PUBLIC) -Directory -ErrorAction SilentlyContinue) {
    $leftovers += Join-Path $user.FullName "AppData\Roaming\$AppName"
    $leftovers += Join-Path $user.FullName "AppData\Local\$($AppName.ToLower())"
}
foreach ($path in $leftovers) {
    if (Test-Path $path) { Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue }
}
$left = @($leftovers | Where-Object { Test-Path $_ })
$left += @(Get-Service -Name $AppName -ErrorAction SilentlyContinue | ForEach-Object { "service $($_.Name)" })

if ($left.Count) {
    Write-Warning "Left on this computer: $($left -join ', ')"
} else {
    Write-Host "$AppName is removed from this computer."
}
if ($id) {
    Write-Host "Remove ID $id from the console and from the address book as well."
}
