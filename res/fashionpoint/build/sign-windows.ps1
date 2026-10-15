# FashionPoint: signs files with Azure Artifact Signing the way azure/artifact-signing-action v2.0.0 does in
# .github/workflows/flutter-build.yml: the action's ArtifactSigning PowerShell module at the version it pins, its
# default digests, timestamp server and credential chain. The signing identity comes from the environment, under the
# names of the fork's GitHub variables and secret: AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET,
# AZURE_SIGNING_ENDPOINT, AZURE_SIGNING_ACCOUNT, AZURE_CERT_PROFILE.
# Azure's signing and timestamp services fail now and then, so a failed call gets two more tries a minute apart.
# Afterwards every file must carry a valid signature of Fashion Point International with a timestamp.
# Usage: sign-windows.ps1 -Folder <dir> -Filter exe,dll [-Recurse]   or   sign-windows.ps1 -Files <path>[,<path>...]
param(
    [string] $Folder,
    [string] $Filter = 'exe,dll',
    [switch] $Recurse,
    [string[]] $Files,
    [string] $Root = 'C:\fpb'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
foreach ($v in 'AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_SIGNING_ENDPOINT', 'AZURE_SIGNING_ACCOUNT', 'AZURE_CERT_PROFILE') {
    if (-not [Environment]::GetEnvironmentVariable($v)) { throw "$v is not set" }
}
if ([bool] $Folder -eq [bool] $Files) { throw 'give either -Folder or -Files' }

$moduleVersion = '0.1.8'  # ARTIFACT_SIGNING_MODULE_VERSION of azure/artifact-signing-action v2.0.0
$modules = Join-Path $Root 'psmodules'
if (-not (Test-Path (Join-Path $modules "ArtifactSigning\$moduleVersion"))) {
    New-Item -ItemType Directory -Force -Path $modules | Out-Null
    Save-PSResource -Name ArtifactSigning -Version $moduleVersion -Repository PSGallery -Path $modules -TrustRepository -Quiet
}
Import-Module (Join-Path $modules "ArtifactSigning\$moduleVersion\ArtifactSigning.psd1") -Force

$params = @{
    Endpoint                            = $env:AZURE_SIGNING_ENDPOINT
    CodeSigningAccountName              = $env:AZURE_SIGNING_ACCOUNT
    CertificateProfileName              = $env:AZURE_CERT_PROFILE
    FileDigest                          = 'SHA256'
    TimestampRfc3161                    = 'http://timestamp.acs.microsoft.com'
    TimestampDigest                     = 'SHA256'
    ExcludeEnvironmentCredential        = $false
    ExcludeWorkloadIdentityCredential   = $true
    ExcludeManagedIdentityCredential    = $true
    ExcludeSharedTokenCacheCredential   = $true
    ExcludeVisualStudioCredential       = $true
    ExcludeVisualStudioCodeCredential   = $true
    ExcludeAzureCliCredential           = $false
    ExcludeAzurePowerShellCredential    = $true
    ExcludeAzureDeveloperCliCredential  = $true
    ExcludeInteractiveBrowserCredential = $true
}
if ($Folder) {
    $params.FilesFolder = (Resolve-Path $Folder).Path
    $params.FilesFolderFilter = $Filter
    $params.FilesFolderRecurse = [bool] $Recurse
    $extensions = $Filter.Split(',') | ForEach-Object { ".$($_.Trim())" }
    $targets = @(Get-ChildItem -Path $params.FilesFolder -File -Recurse:$Recurse | Where-Object { $extensions -contains $_.Extension.ToLower() } | ForEach-Object FullName)
} else {
    $targets = @($Files | ForEach-Object { (Resolve-Path $_).Path })
    $params.Files = $targets -join ','
}
if ($targets.Count -eq 0) { throw 'nothing to sign' }
Write-Host "Signing $($targets.Count) file(s)"
# A file that already carries a valid signature may keep it: the signing tool leaves the printer driver's DLL with
# Microsoft's hardware program signature (as in the GitHub build) and re-signs others (usbmmIdd.dll). Afterwards such
# a file must carry either that signature or ours.
$presigned = @{}
foreach ($f in $targets) {
    $s = Get-AuthenticodeSignature -FilePath $f
    if ($s.Status -eq 'Valid') { $presigned[$f] = $s.SignerCertificate.Thumbprint }
}

# The module downloads signtool, the signing client and (with `dotnet tool install`, the SDK setup-windows.ps1 put in
# the build folder) the sign CLI into $env:LOCALAPPDATA\ArtifactSigning: all of it stays in the build folder, not in
# the user's profile.
$saved = @{}
foreach ($v in 'LOCALAPPDATA', 'PATH', 'DOTNET_ROOT', 'DOTNET_CLI_HOME', 'NUGET_PACKAGES') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
$env:LOCALAPPDATA = Join-Path $Root 'localappdata'
$env:DOTNET_ROOT = Join-Path $Root 'dotnet'
$env:DOTNET_CLI_HOME = Join-Path $Root 'dotnet-home'
$env:NUGET_PACKAGES = Join-Path $Root 'nuget-packages'
$env:PATH = "$env:DOTNET_ROOT;$env:PATH"
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
if (-not (Test-Path "$env:DOTNET_ROOT\dotnet.exe")) { throw "$env:DOTNET_ROOT\dotnet.exe is missing: run setup-windows.ps1" }
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, $env:DOTNET_CLI_HOME, $env:NUGET_PACKAGES | Out-Null
try {
    for ($try = 1; ; $try++) {
        try {
            Invoke-ArtifactSigning @params
            break
        } catch {
            if ($try -ge 3) { throw }
            Write-Warning "Artifact Signing failed (try $try of 3): $($_.Exception.Message); trying again in 60 s"
            Start-Sleep -Seconds 60
        }
    }
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
}

$bad = foreach ($f in $targets) {
    $s = Get-AuthenticodeSignature -FilePath $f
    $ours = $s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'Fashion Point International' -and $s.TimeStamperCertificate
    if ($presigned.ContainsKey($f)) {
        if (-not $ours -and ($s.Status -ne 'Valid' -or $s.SignerCertificate.Thumbprint -ne $presigned[$f])) {
            "$f : was signed by someone else before, now $($s.Status) $($s.SignerCertificate.Subject)"
        }
    } elseif (-not $ours) {
        "$f : $($s.Status) $($s.SignerCertificate.Subject) timestamp=$([bool] $s.TimeStamperCertificate)"
    }
}
if ($bad) { throw "not signed as expected:`n$($bad -join "`n")" }
$kept = @($presigned.Keys | Where-Object { (Get-AuthenticodeSignature -FilePath $_).SignerCertificate.Thumbprint -eq $presigned[$_] })
Write-Host "Verified $($targets.Count) file(s): $($targets.Count - $kept.Count) signed by Fashion Point International, $($kept.Count) kept the signature they had ($((($kept | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')))"
