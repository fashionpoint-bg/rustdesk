<#
.SYNOPSIS
Installs FPRemote (clinic edition) on this computer and registers it for unattended support.

.DESCRIPTION
Run once per clinic computer, as administrator, from the folder that holds the installer:

    powershell -ExecutionPolicy Bypass -File .\FPRemote-Clinic-Install.ps1 -Clinic "Fase Clinic"

1. Checks that the installer is signed by Fashion Point International Ltd.
2. Installs FPRemote silently, without the remote printer, and waits for its service.
3. Gives the computer its own random permanent password. Nobody sees it; the server keeps it.
4. Deploys the computer on the FashionPoint server and adds it, with that password, to the shared
   address book (default: the clinics book) as "<clinic> - <computer name>".

Staff and agents then connect from the address book, and nobody at the clinic has to accept.
The console API token for step 4 is asked for at the prompt (or taken from FPREMOTE_TOKEN) and is
not stored. The script can be run again on the same computer: it skips the installation and gives
the computer a new password.

.PARAMETER Clinic
The clinic's name as staff know it. Becomes the tag and the start of the alias in the address book.

.PARAMETER Installer
The clinic edition installer (FPRemote-Clinic-<version>-x86_64.exe). Default: the newest one next to
this script, then in the Downloads folder.

.PARAMETER DeviceGroup
A device group that already exists in the console, if the computer should join one.

.PARAMETER SkipSignatureCheck
Only for unsigned test builds.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Clinic,
    [string]$Installer,
    [string]$AddressBook = [string]::new([char[]]@(0x41A, 0x43B, 0x438, 0x43D, 0x438, 0x43A, 0x438)),
    [string]$DeviceGroup,
    [switch]$SkipSignatureCheck
)

$ErrorActionPreference = 'Stop'
$AppName = 'FPRemote'
$Signer = 'CN=Fashion Point International Ltd.'
$Exe = Join-Path $env:ProgramFiles "$AppName\$AppName.exe"

function Invoke-App([string[]]$Arguments, [int]$TimeoutSeconds = 120) {
    # The app is a GUI program, which `&` would not wait for, and it prints to the inherited
    # standard handles, so the output goes through files.
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $line = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
        $p = Start-Process -FilePath $Exe -ArgumentList $line -PassThru -NoNewWindow `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle # keeps the exit code readable after the process ends
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $p.Kill()
            throw "$AppName $($Arguments[0]) did not finish within $TimeoutSeconds seconds."
        }
        [pscustomobject]@{
            ExitCode = $p.ExitCode
            Output   = ("$(Get-Content $out -Raw) $(Get-Content $err -Raw)").Trim()
        }
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
}

function New-Password([int]$Length = 24) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] $Length
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as administrator (right-click PowerShell, Run as administrator).'
}
if ($Clinic -match '["\r\n]' -or -not $Clinic.Trim()) {
    throw 'The clinic name must not be empty or contain quotes or line breaks.'
}
$Clinic = $Clinic.Trim()

$token = $env:FPREMOTE_TOKEN
if (-not $token) {
    $secure = Read-Host 'FPRemote console API token' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
$token = "$token".Trim()
if (-not $token) { throw 'No API token given.' }

if (Get-Service -Name $AppName -ErrorAction SilentlyContinue) {
    Write-Host "$AppName is already installed; skipping the installation."
} else {
    if (-not $Installer) {
        $folders = @($PSScriptRoot, (Join-Path $env:USERPROFILE 'Downloads')) | Where-Object { $_ }
        $Installer = Get-ChildItem -Path $folders -Filter "$AppName-Clinic-*.exe" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        if (-not $Installer) { throw "No $AppName-Clinic-*.exe next to this script or in Downloads; pass -Installer." }
    }
    $Installer = (Resolve-Path $Installer).Path
    $signature = Get-AuthenticodeSignature -LiteralPath $Installer
    $signedBy = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
    if ($signature.Status -ne 'Valid' -or -not $signedBy.StartsWith($Signer)) {
        if (-not $SkipSignatureCheck) {
            throw "Not installing ${Installer}: signature $($signature.Status), signer '$signedBy'. Download it again from FashionPoint."
        }
        Write-Warning "Unsigned installer accepted (-SkipSignatureCheck): $Installer"
    }
    if ($Installer -notmatch '-Clinic-') { throw "$Installer is not the clinic edition." }

    Write-Host "Installing $AppName from $Installer ..."
    # Not -Wait: it would also wait for the tray the installation leaves running.
    Start-Process -FilePath $Installer -ArgumentList '--silent-install printer=0' | Out-Null
    $deadline = (Get-Date).AddMinutes(3)
    do {
        if ((Get-Date) -gt $deadline) { throw "The $AppName installation did not finish within 3 minutes." }
        Start-Sleep -Seconds 2
        $running = (Get-Service -Name $AppName -ErrorAction SilentlyContinue).Status -eq 'Running'
        $installing = @(Get-CimInstance Win32_Process -Filter "Name LIKE '$AppName%'" |
            Where-Object { $_.CommandLine -match '--silent-install' }).Count
    } until ($running -and -not $installing -and (Test-Path $Exe))
}
if (-not (Test-Path $Exe)) { throw "$Exe is missing: the installation did not complete." }

$id = ''
$deadline = (Get-Date).AddMinutes(2)
while ($id -notmatch '^\d{6,}$') {
    if ((Get-Date) -gt $deadline) { throw "$AppName has no ID yet ($id)." }
    $id = (Invoke-App @('--get-id')).Output
    if ($id -notmatch '^\d{6,}$') { Start-Sleep -Seconds 2 }
}
Write-Host "$AppName ID: $id"

$password = New-Password
$result = Invoke-App @('--password', $password)
if ($result.Output -notmatch 'Done') { throw "Setting the permanent password failed: $($result.Output)" }

$result = Invoke-App @('--deploy', '--token', $token)
switch ($result.ExitCode) {
    0 { Write-Host 'Deployed on the server.' }
    3 { Write-Host 'The server does not require deployment.' }
    default { throw "Deployment failed (exit $($result.ExitCode)): $($result.Output)" }
}

$alias = "$Clinic - $env:COMPUTERNAME"
$assign = @('--assign', '--token', $token,
    '--address_book_name', $AddressBook, '--address_book_tag', $Clinic,
    '--address_book_alias', $alias, '--address_book_password', $password,
    '--address_book_note', "Installed $(Get-Date -Format 'yyyy-MM-dd') by $env:USERNAME",
    '--note', $Clinic)
if ($DeviceGroup) { $assign += @('--device_group_name', $DeviceGroup) }
# The device may still be registering after the deployment; retry for a minute.
for ($try = 1; ; $try++) {
    $result = Invoke-App $assign
    if ($result.Output -match '^Done') { break }
    if ($try -ge 12) { throw "Adding the computer to the address book failed: $($result.Output)" }
    Start-Sleep -Seconds 5
}
$password = $null
$token = $null

Write-Host ''
Write-Host "Done. $AppName ID $id is in the address book '$AddressBook' as '$alias'."
Write-Host 'Staff and agents can now connect without anyone at this computer accepting.'
