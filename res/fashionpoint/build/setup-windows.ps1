# FashionPoint: prepares a Windows x64 machine to build FPRemote with build-windows.ps1. Installs the toolchain
# of the x86_64-pc-windows-msvc job of .github/workflows/flutter-build.yml, with the versions pinned there, into
# one folder (-Root), so nothing else on the machine changes and the folder can simply be deleted.
# Visual Studio 2022 with the C++ workload and the v142 tools (RustDeskTempTopMostWindow's x64 configuration
# uses v142, which the windows-2022 runner has) has to be there already; the script only checks it, because
# installing it needs an administrator.
# Safe to run again: every step skips what is already in place. Runs in PowerShell 7 (pwsh), the shell of the
# workflow's Windows steps.
# Usage: pwsh -ExecutionPolicy Bypass -File setup-windows.ps1 -Repo <checkout of the commit to build>
param(
    [Parameter(Mandatory)] [string] $Repo,
    [string] $Root = 'C:\fpb'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Pin([string] $file, [string] $pattern) {
    $m = Select-String -Path (Join-Path $Repo $file) -Pattern $pattern | Select-Object -First 1
    if (-not $m) { throw "$file has no match for $pattern" }
    return $m.Matches[0].Groups[1].Value
}
function Invoke-Checked([string] $what, [scriptblock] $run) {
    & $run
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}
function Test-Native([scriptblock] $run) {
    & $run *> $null
    return $LASTEXITCODE -eq 0
}
function Get-File([string] $url, [string] $out) {
    if (Test-Path $out) { return }
    Invoke-Checked "download $url" { curl.exe -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o "$out.part" $url }
    Move-Item -Force "$out.part" $out
}

$workflow = '.github\workflows\flutter-build.yml'
$flutterVersion = Pin $workflow '^\s+FLUTTER_VERSION:\s*"([^"]+)"'
$rustVersion = Pin $workflow '^\s+SCITER_RUST_VERSION:\s*"([^"]+)"'
$llvmVersion = Pin $workflow '^\s+LLVM_VERSION:\s*"([^"]+)"'
$vcpkgCommit = Pin $workflow '^\s+VCPKG_COMMIT_ID:\s*"([0-9a-f]{40})"'
$topmostCommit = Pin '.github\workflows\third-party-RustDeskTempTopMostWindow.yml' 'git checkout ([0-9a-f]{40})'
Write-Host "Pins: Flutter $flutterVersion, Rust $rustVersion, LLVM $llvmVersion, vcpkg $vcpkgCommit, TopMostWindow $topmostCommit"

$dl = Join-Path $Root 'dl'
New-Item -ItemType Directory -Force -Path $dl | Out-Null

# build-windows.ps1 lets git make symlinks (some Dart packages carry their LICENSE as one); without an administrator
# Windows allows that only in Developer Mode.
$devMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
if ($devMode -ne 1) { throw 'Turn on Developer Mode (Settings > System > For developers): the build creates symlinks.' }

# LLVM and Clang (KyleMayes/install-llvm-action unpacks the same installer with 7-Zip).
$llvm = Join-Path $Root "llvm-$llvmVersion"
if (-not (Test-Path "$llvm\bin\libclang.dll")) {
    $exe = Join-Path $dl "LLVM-$llvmVersion-win64.exe"
    Get-File "https://github.com/llvm/llvm-project/releases/download/llvmorg-$llvmVersion/LLVM-$llvmVersion-win64.exe" $exe
    Invoke-Checked 'unpack LLVM' { & "$env:ProgramFiles\7-Zip\7z.exe" x -y "-o$llvm" $exe | Out-Null }
    if (-not (Test-Path "$llvm\bin\libclang.dll")) { throw "LLVM unpacked without bin\libclang.dll" }
}
Write-Host "LLVM: $llvm"

# Flutter, patched as the workflow does, with RustDesk's Windows engine.
$flutter = Join-Path $Root "flutter-$flutterVersion"
if (-not (Test-Path "$flutter\bin\flutter.bat")) {
    $zip = Join-Path $dl "flutter_windows_$flutterVersion-stable.zip"
    Get-File "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$flutterVersion-stable.zip" $zip
    $tmp = Join-Path $Root 'flutter-unpack'
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Invoke-Checked 'unpack Flutter' { tar.exe -xf $zip -C $tmp }
    Move-Item (Join-Path $tmp 'flutter') $flutter
    Remove-Item -Recurse -Force $tmp
}
$env:PATH = "$flutter\bin;$env:PATH"
Invoke-Checked 'flutter config' { flutter config --no-analytics | Out-Null }
$patch = Join-Path $Repo '.github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff'
if ($flutterVersion -eq '3.24.5' -and -not (Test-Native { git -C $flutter apply --reverse --check $patch })) {
    Invoke-Checked 'patch Flutter' { git -C $flutter apply $patch }
}
Invoke-Checked 'flutter precache' { flutter precache --windows }
$engineZip = Join-Path $dl 'rustdesk-engine-windows-x64-release.zip'
$engineStamp = Join-Path $flutter 'bin\cache\artifacts\engine\windows-x64-release\.fashionpoint-engine'
if (-not (Test-Path $engineStamp)) {
    Get-File 'https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip' $engineZip
    $tmp = Join-Path $Root 'engine-unpack'
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Path $engineZip -DestinationPath $tmp
    Move-Item -Force "$tmp\*" "$flutter\bin\cache\artifacts\engine\windows-x64-release\"
    Remove-Item -Recurse -Force $tmp
    (Get-FileHash -Algorithm SHA256 $engineZip).Hash | Set-Content -NoNewline $engineStamp
}
Write-Host "Flutter: $flutter (RustDesk engine zip sha256 $(Get-Content $engineStamp))"

# vcpkg at the pinned commit.
$vcpkg = Join-Path $Root 'vcpkg'
if (-not (Test-Path "$vcpkg\.git")) { Invoke-Checked 'clone vcpkg' { git clone -q https://github.com/microsoft/vcpkg $vcpkg } }
if ((git -C $vcpkg rev-parse HEAD) -ne $vcpkgCommit) {
    if (-not (Test-Native { git -C $vcpkg cat-file -e "$vcpkgCommit^{commit}" })) { Invoke-Checked 'fetch vcpkg' { git -C $vcpkg fetch -q origin } }
    Invoke-Checked 'checkout vcpkg' { git -C $vcpkg checkout -q --force $vcpkgCommit }
    Remove-Item -Force -ErrorAction SilentlyContinue "$vcpkg\vcpkg.exe"
}
if (-not (Test-Path "$vcpkg\vcpkg.exe")) { Invoke-Checked 'bootstrap vcpkg' { & "$vcpkg\bootstrap-vcpkg.bat" -disableMetrics } }
Write-Host "vcpkg: $vcpkg at $vcpkgCommit"

# .NET SDK 8 for sign-windows.ps1: the ArtifactSigning module installs its sign CLI with `dotnet tool install`, which
# needs an SDK (GitHub's runner has one; a machine with only .NET runtimes has none).
$dotnet = Join-Path $Root 'dotnet'
if (-not (Get-ChildItem "$dotnet\sdk" -Directory -Filter '8.*' -ErrorAction SilentlyContinue)) {
    $installer = Join-Path $dl 'dotnet-install.ps1'
    Get-File 'https://dot.net/v1/dotnet-install.ps1' $installer
    & $installer -Channel 8.0 -InstallDir $dotnet -NoPath
}
Write-Host ".NET SDK: $(& "$dotnet\dotnet.exe" --version) in $dotnet"

# Python packages of libs\portable\generate.py, in a venv of their own.
$venv = Join-Path $Root 'venv'
if (-not (Test-Path "$venv\Scripts\python.exe")) { Invoke-Checked 'create venv' { python -m venv $venv } }
Invoke-Checked 'pip install' { & "$venv\Scripts\python.exe" -m pip install -q -r (Join-Path $Repo 'libs\portable\requirements.txt') }

# Everything below needs Visual Studio's C++ tools.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsAdd = '--add Microsoft.VisualStudio.Workload.NativeDesktop --add Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64 --includeRecommended'
function Assert-VS([string[]] $components) {
    $found = & $vswhere -latest -products * -requires $components -property installationPath
    if (-not $found) {
        throw ("Visual Studio 2022 lacks $($components -join ', '). As administrator: " +
            "`"${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe`" modify --installPath `"<Visual Studio folder>`" " +
            "$vsAdd --passive --norestart")
    }
    return $found
}
Write-Host "Visual Studio: $(Assert-VS 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.VC.CMake.Project')"

# Rust, in the build folder (RUSTUP_HOME and CARGO_HOME), not in the user's profile.
$env:RUSTUP_HOME = Join-Path $Root 'rustup'
$env:CARGO_HOME = Join-Path $Root 'cargo'
$rustup = Join-Path $env:CARGO_HOME 'bin\rustup.exe'
if (-not (Test-Path $rustup)) {
    $init = Join-Path $dl 'rustup-init.exe'
    Get-File 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' $init
    Invoke-Checked 'rustup-init' { & $init -y -q --no-modify-path --default-host x86_64-pc-windows-msvc --default-toolchain none --profile minimal }
}
Invoke-Checked 'rust toolchain' { & $rustup toolchain install $rustVersion --profile minimal --component rustfmt --target x86_64-pc-windows-msvc }
Invoke-Checked 'rustup default' { & $rustup default $rustVersion }
Write-Host "Rust: $(& "$env:CARGO_HOME\bin\rustc.exe" -V)"

# RustDeskTempTopMostWindow, built as third-party-RustDeskTempTopMostWindow.yml does (the x86 MSBuild of setup-msbuild).
$topmost = Join-Path $Root 'RustDeskTempTopMostWindow'
$topmostDll = Join-Path $topmost 'WindowInjection\x64\Release\WindowInjection.dll'
if (-not (Test-Path "$topmost\.git")) { Invoke-Checked 'clone RustDeskTempTopMostWindow' { git clone -q https://github.com/rustdesk-org/RustDeskTempTopMostWindow $topmost } }
if ((git -C $topmost rev-parse HEAD) -ne $topmostCommit -or -not (Test-Path $topmostDll)) {
    Assert-VS 'Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64' | Out-Null
    Invoke-Checked 'checkout RustDeskTempTopMostWindow' { git -C $topmost checkout -q --force $topmostCommit }
    $msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\Current\Bin\MSBuild.exe' | Select-Object -First 1
    Invoke-Checked 'build WindowInjection.dll' { & $msbuild "$topmost\WindowInjection\WindowInjection.vcxproj" -nologo -v:minimal -p:Configuration=Release -p:Platform=x64 /p:TargetVersion=Windows10 }
}
Write-Host "WindowInjection.dll: $topmostDll"
Write-Host 'Setup complete.'
