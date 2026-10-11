param([Parameter(Mandatory=$true)][string]$Ndk)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Toolchain = Join-Path $Ndk 'toolchains/llvm/prebuilt/windows-x86_64/bin'
if (-not (Test-Path (Join-Path $Toolchain 'clang.exe'))) { throw 'NDK LLVM toolchain not found' }
$Props = Get-Content (Join-Path $Ndk 'source.properties') -Raw
if ($Props -notmatch 'Pkg.Revision\s*=\s*30\.') { throw 'Use NDK r30' }
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = Join-Path $Toolchain 'clang.exe'
$env:RUSTFLAGS = '-C link-arg=--target=aarch64-linux-android28 -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384'
Push-Location (Join-Path $PSScriptRoot 'smbctl')
try {
    cargo build --offline --locked --release --target aarch64-linux-android
    if ($LASTEXITCODE -ne 0) { throw 'Rust build failed' }
} finally { Pop-Location }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'smbctl/target/aarch64-linux-android/release/smbctl') -Destination (Join-Path $Root 'bin/smbctl')
# Deliberately leaves smbd, RPC helpers and notification Dex unchanged.
