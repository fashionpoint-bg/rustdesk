# FashionPoint: builds the Windows x64 installer of one FPRemote edition on this machine, step for step as the
# x86_64-pc-windows-msvc job of .github/workflows/flutter-build.yml does it for fp-release.yml, with the toolchain
# setup-windows.ps1 installed under -Root. Inputs: the commit (checked out clean into <Root>\src), the edition's
# client config (-Config, the JSON of fp-remote's docs/client.md) and the bridge files of that commit (-Bridge, from
# bridge.sh). -Sign signs the files and the installer with Azure Artifact Signing, as the workflow does for tags;
# the credentials come from AZURE_TENANT_ID, AZURE_CLIENT_ID and AZURE_CLIENT_SECRET in the environment.
# Where the workflow skips a failed download (the printer driver) or a missing Runner.res, this script stops:
# a release must not lose a part silently.
# Result: <Out>\FPRemote-<Clinic|Staff>-<version>-x86_64.exe and <Out>\build-info.txt.
param(
    [Parameter(Mandatory)] [ValidateSet('clinic', 'staff')] [string] $Edition,
    [Parameter(Mandatory)] [string] $Commit,
    [Parameter(Mandatory)] [string] $Config,
    [Parameter(Mandatory)] [string] $Bridge,
    [Parameter(Mandatory)] [string] $Out,
    [string] $Root = 'C:\fpb',
    [switch] $Sign
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date

function Invoke-Checked([string] $what, [scriptblock] $run) {
    & $run
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}
function Get-Fresh([string] $url, [string] $out) {
    Remove-Item -Force -ErrorAction SilentlyContinue $out
    Invoke-Checked "download $url" { curl.exe -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o $out $url }
}
function Step([string] $name) { Write-Host "=== $name ($([int]((Get-Date) - $started).TotalMinutes) min)" }

$src = Join-Path $Root 'src'
$dl = Join-Path $Root 'dl'
$python = Join-Path $Root 'venv\Scripts\python.exe'

Step "Checkout $Commit"
Invoke-Checked 'fetch' { git -C $src fetch -q origin }
Invoke-Checked 'checkout' { git -C $src checkout -q --force $Commit }
Invoke-Checked 'submodules' { git -C $src submodule update -q --init --recursive --force }
# target\ stays: cargo rebuilds what changed (the client config is part of what it tracks).
Invoke-Checked 'clean' { git -C $src clean -q -ffdx -e target }
Invoke-Checked 'clean submodules' { git -C $src submodule foreach -q --recursive git clean -q -ffdx }
$head = git -C $src rev-parse HEAD

function Pin([string] $name) {
    $m = Select-String -Path "$src\.github\workflows\flutter-build.yml" -Pattern "^\s+${name}:\s*`"([^`"]+)`"" | Select-Object -First 1
    if (-not $m) { throw "flutter-build.yml has no $name" }
    return $m.Matches[0].Groups[1].Value
}
$version = Pin 'VERSION'
$flutter = Join-Path $Root "flutter-$(Pin 'FLUTTER_VERSION')"
$llvm = Join-Path $Root "llvm-$(Pin 'LLVM_VERSION')"
$rustVersion = Pin 'SCITER_RUST_VERSION'
foreach ($p in "$flutter\bin\flutter.bat", "$llvm\bin\libclang.dll", "$Root\vcpkg\vcpkg.exe", $python, "$Root\cargo\bin\cargo.exe") {
    if (-not (Test-Path $p)) { throw "$p is missing: run setup-windows.ps1 for this commit" }
}

$env:RUSTUP_HOME = Join-Path $Root 'rustup'
$env:CARGO_HOME = Join-Path $Root 'cargo'
$env:RUSTUP_TOOLCHAIN = $rustVersion
$env:PATH = "$env:CARGO_HOME\bin;$flutter\bin;$llvm\bin;$env:PATH"
$env:LLVM_PATH = $llvm
$env:LIBCLANG_PATH = "$llvm\bin"
$env:VCPKG_ROOT = Join-Path $Root 'vcpkg'
$env:VCPKG_BINARY_SOURCES = "clear;files,$Root\vcpkg-cache,readwrite"
# The Dart packages go to a cache of the build's own, not the user's. Some git packages (uni_links) carry their
# LICENSE as a symlink: git makes real links (Developer Mode allows them without an administrator), as on GitHub's
# runner, so the licenses page of the app shows the license and not the text "../LICENSE".
$env:PUB_CACHE = Join-Path $Root 'pub-cache'
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'core.symlinks'
$env:GIT_CONFIG_VALUE_0 = 'true'
New-Item -ItemType Directory -Force -Path "$Root\vcpkg-cache", $env:PUB_CACHE, $Out | Out-Null
$env:FP_CLIENT_CONFIG = (Get-Content -Raw $Config).Trim()
$appName = (ConvertFrom-Json $env:FP_CLIENT_CONFIG).'app-name'
if (-not $appName) { throw "$Config has no app-name" }
$exeName = "$appName.exe"
$title = (Get-Culture).TextInfo.ToTitleCase($Edition)

Push-Location $src
try {
    Step 'Restore bridge files'
    foreach ($f in 'src\bridge_generated.rs', 'src\bridge_generated.io.rs', 'flutter\lib\generated_bridge.dart',
        'flutter\lib\generated_bridge.freezed.dart', 'flutter\macos\Runner\bridge_generated.h', 'flutter\ios\Runner\bridge_generated.h') {
        Copy-Item -Force (Join-Path $Bridge $f) (Join-Path $src $f)
    }

    Step 'Install vcpkg dependencies'
    $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
    & "$env:VCPKG_ROOT\vcpkg.exe" install --triplet x64-windows-static --x-install-root="$env:VCPKG_ROOT\installed"
    if ($LASTEXITCODE -ne 0) {
        Get-ChildItem "$env:VCPKG_ROOT\buildtrees" -Recurse -Filter *.log | ForEach-Object {
            Write-Host "$($_.FullName):`n======"; Get-Content $_.FullName -Tail 60; Write-Host '======'
        }
        throw 'vcpkg install failed'
    }

    Step 'Build rustdesk'
    # The build script of the rustdesk crate writes src\version.rs, which the clean above removes; with target\ kept,
    # cargo would not run that script again. GitHub's rust-cache drops the workspace crates' artifacts the same way.
    Invoke-Checked 'cargo clean -p rustdesk' { cargo clean --release -p rustdesk }
    Invoke-Checked 'build.py' { & $python .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram }
    Move-Item .\flutter\build\windows\x64\runner\Release .\rustdesk

    $usbZip = Join-Path $dl 'usbmmidd_v2.zip'
    Get-Fresh 'https://github.com/rustdesk-org/rdev/releases/download/usbmmidd_v2/usbmmidd_v2.zip' $usbZip
    Expand-Archive $usbZip -DestinationPath .
    Remove-Item -Path usbmmidd_v2\Win32 -Recurse
    Remove-Item -Path 'usbmmidd_v2\deviceinstaller64.exe', 'usbmmidd_v2\deviceinstaller.exe', 'usbmmidd_v2\usbmmidd.bat'
    Move-Item -Force .\usbmmidd_v2 .\rustdesk

    # The installer registers the service, shortcuts and firewall rules for <app-name>.exe and the portable
    # launcher extracts into %LOCALAPPDATA%\<exe name>, so the exe carries the app name.
    Rename-Item .\rustdesk\rustdesk.exe $exeName

    $driverZip = Join-Path $dl 'rustdesk_printer_driver_v4-1.4.zip'
    $adapterZip = Join-Path $dl 'printer_driver_adapter.zip'
    $sums = Join-Path $dl 'printer-driver-sha256sums'
    Get-Fresh 'https://github.com/rustdesk/hbb_common/releases/download/driver/rustdesk_printer_driver_v4-1.4.zip' $driverZip
    Get-Fresh 'https://github.com/rustdesk/hbb_common/releases/download/driver/printer_driver_adapter.zip' $adapterZip
    Get-Fresh 'https://github.com/rustdesk/hbb_common/releases/download/driver/sha256sums' $sums
    $wantDriver = (Select-String -Path $sums -Pattern '^([a-fA-F0-9]{64}) \*rustdesk_printer_driver_v4-1.4\.zip$').Matches.Groups[1].Value
    $wantAdapter = (Select-String -Path $sums -Pattern '^([a-fA-F0-9]{64}) \*printer_driver_adapter\.zip$').Matches.Groups[1].Value
    if (-not $wantDriver -or $wantDriver -ne (Get-FileHash -Algorithm SHA256 $driverZip).Hash) { throw 'printer driver checksum mismatch' }
    if (-not $wantAdapter -or $wantAdapter -ne (Get-FileHash -Algorithm SHA256 $adapterZip).Hash) { throw 'printer driver adapter checksum mismatch' }
    Expand-Archive $driverZip -DestinationPath .
    New-Item -ItemType Directory -Path .\rustdesk\drivers | Out-Null
    Move-Item -Force .\rustdesk_printer_driver_v4-1.4 .\rustdesk\drivers\RustDeskPrinterDriver
    Expand-Archive $adapterZip -DestinationPath .
    Move-Item -Force .\printer_driver_adapter.dll .\rustdesk

    Step 'Runner.res and RustDeskTempTopMostWindow'
    # Runner.rc has no real version; the compiled Runner.res has, and the portable launcher embeds it.
    $runnerRes = @(Get-ChildItem -Path .\flutter\build -Recurse -Filter Runner.res -File)
    if ($runnerRes.Count -ne 1) { throw "expected one Runner.res under flutter\build, found $($runnerRes.Count)" }
    Copy-Item $runnerRes[0].FullName .\libs\portable\Runner.res
    Copy-Item (Join-Path $Root 'RustDeskTempTopMostWindow\WindowInjection\x64\Release\WindowInjection.dll') .\rustdesk\

    if ($Sign) {
        Step 'Sign rustdesk files'
        & (Join-Path $PSScriptRoot 'sign-windows.ps1') -Root $Root -Folder .\rustdesk -Filter 'exe,dll' -Recurse
    }

    Step 'Build self-extracted executable'
    # sed -i '/dpiAware/d' res/manifest.xml, byte for byte.
    $manifest = Join-Path $src 'res\manifest.xml'
    $text = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($manifest))
    [IO.File]::WriteAllBytes($manifest, [Text.Encoding]::Latin1.GetBytes([regex]::Replace($text, '(?m)^[^\n]*dpiAware[^\n]*\n', '')))
    Push-Location .\libs\portable
    try {
        Invoke-Checked 'pip install' { & $python -m pip install -q -r requirements.txt }
        Invoke-Checked 'generate.py' { & $python .\generate.py -f ..\..\rustdesk\ -o . -e "..\..\rustdesk\$exeName" }
    } finally { Pop-Location }
    $installer = Join-Path $Out "FPRemote-$title-$version-x86_64.exe"
    Move-Item -Force .\target\release\rustdesk-portable-packer.exe $installer

    if ($Sign) {
        Step 'Sign the self-extracted executable'
        & (Join-Path $PSScriptRoot 'sign-windows.ps1') -Root $Root -Files $installer
    }
} finally { Pop-Location }

$hash = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLower()
@(
    "file: $(Split-Path -Leaf $installer)"
    "sha256: $hash"
    "edition: $Edition"
    "commit: $head"
    "signed: $([bool] $Sign)"
    "rust: $(rustc -V)"
    "flutter: $((flutter --version --machine | ConvertFrom-Json).frameworkVersion)"
    "llvm: $llvm"
    "vcpkg: $(git -C $env:VCPKG_ROOT rev-parse HEAD)"
    "rustdesk engine zip sha256: $(Get-Content (Join-Path $flutter 'bin\cache\artifacts\engine\windows-x64-release\.fashionpoint-engine'))"
    "usbmmidd_v2.zip sha256: $((Get-FileHash -Algorithm SHA256 $usbZip).Hash.ToLower())"
    "built: $(Get-Date -Format o) on $env:COMPUTERNAME in $([int]((Get-Date) - $started).TotalMinutes) min"
) | Set-Content -Path (Join-Path $Out 'build-info.txt')
Write-Host "Built $installer ($hash)"
