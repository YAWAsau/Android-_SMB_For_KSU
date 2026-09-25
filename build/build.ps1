param(
    [string]$DeviceSerial,
    [switch]$Clean,
    [ValidateSet('standard','size')][string]$BuildProfile = 'size',
    [ValidateSet('all','client')][string]$BuildScope = 'all'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 otherwise decodes MSYS2 UTF-8 output as the OEM codepage.
$Utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8
$env:PYTHONUTF8 = '1'
$env:LC_ALL = 'C.UTF-8'
$Repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cache = Join-Path $env:USERPROFILE 'SambaAndroidBuild'
$Work = Join-Path $Cache 'work-r29-api28'
$Tool = Join-Path $Cache 'toolchain'
$NdkZip = Join-Path $Cache 'android-ndk-r29-windows.zip'
$Ndk = Join-Path $Tool 'android-ndk-r29'
$SourceRoot = Join-Path $Work 'src'
$DepsRoot = Join-Path $Cache 'deps'
$DepsSource = Join-Path $DepsRoot 'src-r29-api28'
$PerlDependencyArchive = Join-Path $DepsRoot 'Parse-Yapp-1.21.tar.gz'
$PerlDependencyRoot = Join-Path $DepsRoot 'perl'
$PerlYappLib = Join-Path $PerlDependencyRoot 'Parse-Yapp-1.21\lib'
$Prefix = Join-Path $Cache 'android-prefix-r29-api28'
$OutDir = Join-Path $Repo 'dist\android-arm64'
if ($BuildProfile -eq 'size') {
    $Work = Join-Path $Cache 'work-r29-api28-size'
    $SourceRoot = Join-Path $Work 'src'
    $OutDir = Join-Path $Repo 'dist\android-arm64-size'
}
$Adb = 'C:\platform-tools\adb.exe'
$MsysBash = 'C:\msys64\usr\bin\bash.exe'
$Gpg = 'C:\Program Files\Git\usr\bin\gpg.exe'
$ExpectedNdkSha1 = 'ab3bb30fbb9e6903666d60c55d11e78b04e07472'
$SambaSigningFingerprint = '81F5E2832BD2545A1897B713AA99442FB680B620'

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Exe $($Arguments -join ' ')" }
}

function ConvertTo-MsysPath([string]$WindowsPath) {
    # Convert in .NET without a native stdout encoding round-trip through cygpath.
    $FullPath = [System.IO.Path]::GetFullPath($WindowsPath).Replace('\','/')
    if ($FullPath -notmatch '^([A-Za-z]):/(.*)$') {
        throw "Expected an absolute Windows drive path: $WindowsPath"
    }
    return '/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2]
}

if (-not (Test-Path $MsysBash)) { throw "MSYS2 not found at $MsysBash. Install MSYS2 first." }
if (-not (Test-Path $Gpg)) { throw "Git for Windows GPG not found at $Gpg." }
if (-not (Test-Path $Adb)) { throw "adb not found at $Adb. Install Android platform-tools." }
New-Item -ItemType Directory -Force -Path $Cache,$Work,$Tool,$SourceRoot,$DepsRoot,$DepsSource,$OutDir | Out-Null
if ($Clean) { Remove-Item -Recurse -Force -LiteralPath $Work; New-Item -ItemType Directory -Force -Path $Work,$SourceRoot | Out-Null }

# Install the host compiler through the existing MSYS2 package manager.
$HostGcc = Join-Path $Tool 'ucrt64\bin\x86_64-w64-mingw32-gcc.exe'
if (-not (Test-Path $HostGcc)) {
    Write-Host '[1/6] Installing the MSYS2 UCRT64 host compiler...'
    $Ucrt = Join-Path $Repo '.build\msys-root\ucrt64'
    if (-not (Test-Path $Ucrt)) { $Ucrt = 'C:\msys64\ucrt64' }
    if (-not (Test-Path $Ucrt)) {
        Invoke-Checked $MsysBash @('-lc','pacman -Sy --needed --noconfirm mingw-w64-ucrt-x86_64-gcc')
        $Ucrt = 'C:\msys64\ucrt64'
    }
    if (-not (Test-Path $Ucrt)) { throw 'MSYS2 did not install C:\msys64\ucrt64.' }
    Copy-Item -Recurse -Force $Ucrt (Join-Path $Tool 'ucrt64')
}
$HostGeneratorsReady = & $MsysBash -lc 'command -v flex >/dev/null 2>&1 && command -v bison >/dev/null 2>&1'
if ($LASTEXITCODE -ne 0) {
    Write-Host '[1/6] Installing the MSYS2 Flex/Bison host generators...'
    Invoke-Checked $MsysBash @('-lc','pacman -S --needed --noconfirm flex bison')
}
$MsysGccReady = & $MsysBash -lc 'command -v gcc >/dev/null 2>&1'
if ($LASTEXITCODE -ne 0) {
    Write-Host '[1/6] Installing the native MSYS2 GCC host compiler...'
    Invoke-Checked $MsysBash @('-lc','pacman -S --needed --noconfirm gcc')
}

if (-not (Test-Path $Ndk)) {
    Write-Host '[2/6] Downloading Android NDK r29 (first run only)...'
    if (-not (Test-Path $NdkZip)) {
        $Seed = Join-Path $Repo '.build\android-ndk-r29-windows.zip'
        if (Test-Path $Seed) { Copy-Item -LiteralPath $Seed -Destination $NdkZip }
        else { Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/android/repository/android-ndk-r29-windows.zip' -OutFile $NdkZip }
    }
    $NdkSha1 = (Get-FileHash -Algorithm SHA1 -LiteralPath $NdkZip).Hash.ToLowerInvariant()
    if ($NdkSha1 -ne $ExpectedNdkSha1) { throw "NDK SHA1 mismatch: $NdkSha1" }
    Expand-Archive -LiteralPath $NdkZip -DestinationPath $Tool -Force
}
$Clang = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe'
if (-not (Test-Path $Clang)) { throw "NDK compiler not found: $Clang" }
$NdkProperties = Get-Content -Raw -LiteralPath (Join-Path $Ndk 'source.properties')
if ($NdkProperties -notmatch 'Pkg.Revision\s*=\s*29\.0\.14206865') {
    throw 'The selected NDK is not the pinned r29 release (29.0.14206865).'
}

Write-Host '[3/6] Discovering the newest official Samba stable release...'
try {
    $Page = (Invoke-WebRequest -UseBasicParsing 'https://www.samba.org/samba/download/' -TimeoutSec 12).Content
    $Match = [regex]::Match($Page,'Samba\s+([0-9]+\.[0-9]+\.[0-9]+)\s*\(gzipped\)')
    if (-not $Match.Success) { throw 'Release page did not contain a stable version.' }
    $Version = $Match.Groups[1].Value
} catch {
    Write-Warning "Could not reach Samba release page; using the newest cached source: $($_.Exception.Message)"
    $CachedVersions = @(
        Get-ChildItem -LiteralPath $Cache -File -Filter 'samba-*.tar.gz' -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath (Join-Path $Repo '.build') -File -Filter 'samba-*.tar.gz' -ErrorAction SilentlyContinue
    ) | ForEach-Object { if ($_.Name -match '^samba-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz$') { [version]$Matches[1] } }
    if (-not $CachedVersions) { throw 'No Samba stable version found online or in cache.' }
    $Version = ($CachedVersions | Sort-Object -Descending | Select-Object -First 1).ToString()
}
$TarGz = Join-Path $Cache "samba-$Version.tar.gz"
$Tar = Join-Path $Cache "samba-$Version.tar"
$Sig = "$Tar.asc"
$Key = Join-Path $Cache 'samba-pubkey.asc'
$Source = Join-Path $SourceRoot "samba-$Version"
if (-not (Test-Path $TarGz)) {
    $Seed = Join-Path $Repo ".build\samba-$Version.tar.gz"
    if (Test-Path $Seed) { Copy-Item -LiteralPath $Seed -Destination $TarGz }
    else { Invoke-WebRequest -UseBasicParsing "https://download.samba.org/pub/samba/stable/samba-$Version.tar.gz" -OutFile $TarGz }
}
if (-not (Test-Path $Sig)) {
    $Seed = Join-Path $Repo ".build\samba-$Version.tar.asc"
    if (Test-Path $Seed) { Copy-Item -LiteralPath $Seed -Destination $Sig }
    else { Invoke-WebRequest -UseBasicParsing "https://download.samba.org/pub/samba/stable/samba-$Version.tar.asc" -OutFile $Sig }
}
if (-not (Test-Path $Key)) {
    $Seed = Join-Path $Repo '.build\samba-pubkey.asc'
    if (Test-Path $Seed) { Copy-Item -LiteralPath $Seed -Destination $Key }
    else { Invoke-WebRequest -UseBasicParsing 'https://download.samba.org/pub/samba/samba-pubkey.asc' -OutFile $Key }
}
$GpgHome = Join-Path $Cache 'gnupg'
New-Item -ItemType Directory -Force -Path $GpgHome | Out-Null
$GpgHomePosix = (ConvertTo-MsysPath $GpgHome)
$KeyPosix = (ConvertTo-MsysPath $Key)
$TarPosix = (ConvertTo-MsysPath $Tar)
$SigPosix = (ConvertTo-MsysPath $Sig)
$TarGzPosix = (ConvertTo-MsysPath $TarGz)
Invoke-Checked $Gpg @('--batch','--homedir',$GpgHomePosix,'--import',$KeyPosix)
$Fingerprint = (& $Gpg --batch --homedir $GpgHomePosix --with-colons --fingerprint 2>$null | Where-Object { $_ -like 'fpr:*' } | ForEach-Object { ($_ -split ':')[9] } | Select-Object -First 1)
if ($Fingerprint -ne $SambaSigningFingerprint) { throw "Unexpected Samba signing key fingerprint: $Fingerprint" }
if (-not (Test-Path $Tar)) {
    Write-Host '[4/6] Decompressing the signed Samba archive...'
    Invoke-Checked $MsysBash @('-lc',"gzip -dc '$TarGzPosix' > '$TarPosix'")
}
Invoke-Checked $Gpg @('--batch','--homedir',$GpgHomePosix,'--verify',$SigPosix,$TarPosix)
if (-not (Test-Path (Join-Path $Source '.extracted-ok'))) {
    Write-Host '[4/6] Extracting signed Samba source...'
    $SourceRootPosix = (ConvertTo-MsysPath $SourceRoot)
    $Extractor = (ConvertTo-MsysPath (Join-Path $Repo 'tools\samba_android\extract-source.py'))
    if (Test-Path $Source) { Remove-Item -Recurse -Force -LiteralPath $Source }
    Invoke-Checked $MsysBash @('-lc',"python3 '$Extractor' '$TarPosix' '$SourceRootPosix'")
}

# Build the crypto stack locally as static Android libraries. Source archives
# and detached signatures are pinned to upstream release versions and checked
# against explicitly trusted upstream primary fingerprints.
$DependencyKeyHome = Join-Path $Cache 'dependency-gnupg'
New-Item -ItemType Directory -Force -Path $DependencyKeyHome | Out-Null
$DependencyKeyHomePosix = (ConvertTo-MsysPath $DependencyKeyHome)
$DependencyKeyFile = Join-Path $Repo 'tools\samba_android\upstream-crypto-keys.asc'
$DependencyKeyFilePosix = (ConvertTo-MsysPath $DependencyKeyFile)
$DependencyFingerprints = @('343C2FF0FBEE5EC2EDBEF399F3599FF828C67298','5D46CB0F763405A7053556F47A75A648B3F9220C','E987AB7F7E89667776D05B3BB0E9DD20B29F1432')
$ImportedFingerprints = (& $Gpg --batch --homedir $DependencyKeyHomePosix --with-colons --fingerprint --list-keys 2>$null | Where-Object { $_ -like 'fpr:*' } | ForEach-Object { ($_ -split ':')[9] })
if (-not ($DependencyFingerprints | Where-Object { $ImportedFingerprints -contains $_ })) {
    Invoke-Checked $Gpg @('--batch','--homedir',$DependencyKeyHomePosix,'--import',$DependencyKeyFilePosix)
}
$ImportedFingerprints = (& $Gpg --batch --homedir $DependencyKeyHomePosix --with-colons --fingerprint --list-keys 2>$null | Where-Object { $_ -like 'fpr:*' } | ForEach-Object { ($_ -split ':')[9] })
foreach ($ExpectedFingerprint in $DependencyFingerprints) {
    if ($ImportedFingerprints -notcontains $ExpectedFingerprint) { throw "Bundled upstream key fingerprint missing: $ExpectedFingerprint" }
}
$Dependencies = @(
    @{ Name='gmp-6.3.0'; Archive='gmp-6.3.0.tar.xz'; Url='https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz'; SigUrl='https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz.sig'; Fingerprints=@('343C2FF0FBEE5EC2EDBEF399F3599FF828C67298'); Key='343C2FF0FBEE5EC2EDBEF399F3599FF828C67298' },
    @{ Name='nettle-3.10.2'; Archive='nettle-3.10.2.tar.gz'; Url='https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz'; SigUrl='https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz.sig'; Fingerprints=@('343C2FF0FBEE5EC2EDBEF399F3599FF828C67298'); Key='343C2FF0FBEE5EC2EDBEF399F3599FF828C67298' },
    @{ Name='gnutls-3.8.13'; Archive='gnutls-3.8.13.tar.xz'; Url='https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz'; SigUrl='https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz.sig'; Fingerprints=@('5D46CB0F763405A7053556F47A75A648B3F9220C','E987AB7F7E89667776D05B3BB0E9DD20B29F1432'); Key='5D46CB0F763405A7053556F47A75A648B3F9220C' }
)
foreach ($Dependency in $Dependencies) {
    $ArchivePath = Join-Path $DepsRoot $Dependency.Archive
    $SignaturePath = "$ArchivePath.sig"
    if (-not (Test-Path $ArchivePath)) { Invoke-WebRequest -UseBasicParsing $Dependency.Url -OutFile $ArchivePath }
    if (-not (Test-Path $SignaturePath)) { Invoke-WebRequest -UseBasicParsing $Dependency.SigUrl -OutFile $SignaturePath }
    $ArchivePosix = (ConvertTo-MsysPath $ArchivePath)
    $SignaturePosix = (ConvertTo-MsysPath $SignaturePath)
    # GPG writes successful verification diagnostics to stderr. Windows
    # PowerShell 5.1 wraps redirected stderr in NativeCommandError records.
    # Capture those locally, then enforce the exit code AND signing fingerprint.
    $SavedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $VerifyStatus = @(& $Gpg --batch --homedir $DependencyKeyHomePosix --status-fd 1 --verify $SignaturePosix $ArchivePosix 2>&1 | ForEach-Object { $_.ToString() })
        $VerifyExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $SavedErrorPreference
    }
    $AllowedSignature = $false
    foreach ($StatusLine in $VerifyStatus) {
        if ($StatusLine -match '^\[GNUPG:\] VALIDSIG\s+') {
            $StatusFields = ($StatusLine -replace '^\[GNUPG:\] VALIDSIG\s+','') -split '\s+'
            if ($Dependency.Fingerprints -contains $StatusFields[0] -or $Dependency.Fingerprints -contains $StatusFields[-1]) { $AllowedSignature = $true }
        }
    }
    if ($VerifyExitCode -ne 0 -or -not $AllowedSignature) { throw "Upstream signature verification failed or used an unexpected key for $($Dependency.Archive): $($VerifyStatus -join ' ')" }
    $DependencySource = Join-Path $DepsSource $Dependency.Name
    if (-not (Test-Path (Join-Path $DependencySource '.extracted-ok'))) {
        if (Test-Path $DependencySource) { Remove-Item -Recurse -Force -LiteralPath $DependencySource }
        $DepsSourcePosix = (ConvertTo-MsysPath $DepsSource)
        $Extractor = (ConvertTo-MsysPath (Join-Path $Repo 'tools\samba_android\extract-source.py'))
        Invoke-Checked $MsysBash @('-lc',"python3 '$Extractor' '$ArchivePosix' '$DepsSourcePosix'")
    }
}

# Samba's Waf configuration needs Parse::Yapp::Driver from this pure-Perl
# CPAN distribution. Keep it private to the build cache and pin the archive.
if (-not (Test-Path $PerlDependencyArchive)) {
    Invoke-WebRequest -UseBasicParsing 'https://cpan.metacpan.org/authors/id/W/WB/WBRASWELL/Parse-Yapp-1.21.tar.gz' -OutFile $PerlDependencyArchive
}
$PerlDependencySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PerlDependencyArchive).Hash.ToUpperInvariant()
if ($PerlDependencySha256 -ne '3810E998308FBA2E0F4F26043035032B027CE51CE5C8A52A8B8E340CA65F13E5') {
    throw "Parse-Yapp source SHA256 mismatch: $PerlDependencySha256"
}
if (-not (Test-Path (Join-Path $PerlYappLib 'Parse\Yapp\Driver.pm'))) {
    if (Test-Path $PerlDependencyRoot) { Remove-Item -Recurse -Force -LiteralPath $PerlDependencyRoot }
    New-Item -ItemType Directory -Force -Path $PerlDependencyRoot | Out-Null
    $PerlArchivePosix = (ConvertTo-MsysPath $PerlDependencyArchive)
    $PerlRootPosix = (ConvertTo-MsysPath $PerlDependencyRoot)
    $Extractor = (ConvertTo-MsysPath (Join-Path $Repo 'tools\samba_android\extract-source.py'))
    Invoke-Checked $MsysBash @('-lc',"python3 '$Extractor' '$PerlArchivePosix' '$PerlRootPosix'")
}

Write-Host '[5/6] Checking Android target device...'
$DeviceLines = & $Adb devices
if (-not $DeviceSerial) {
    $Online = @($DeviceLines | Select-String '\tdevice$')
    if ($Online.Count -ne 1) { throw 'Connect exactly one adb device or pass -DeviceSerial.' }
    $DeviceSerial = ($Online[0].Line -split '\s+')[0]
}
Invoke-Checked $Adb @('-s',$DeviceSerial,'shell','getprop','ro.product.cpu.abi')

Write-Host "[6/6] Configuring and building Samba $Version for Android arm64 (profile: $BuildProfile)..."
$RepoPosix = (ConvertTo-MsysPath $Repo)
$CachePosix = (ConvertTo-MsysPath $Cache)
$ShellScript = Join-Path $Repo 'tools\samba_android\build-samba.sh'
$Runner = Join-Path $Repo 'tools\samba_android\adb-runner.sh'
$AnswerFile = Join-Path $Cache "cross-answers-$Version-r29-api28.txt"
# Bionic/Linux provides POSIX fcntl record locks. Samba's configure source
# probe hits a Waf gccdeps path-index issue on Windows when including ../tests.
$FcntlLockAnswer = 'Checking whether fcntl locking is available: OK'
$CurrentAnswers = @(Get-Content -LiteralPath $AnswerFile -ErrorAction SilentlyContinue)
if ($CurrentAnswers -notcontains $FcntlLockAnswer) {
    Add-Content -LiteralPath $AnswerFile -Value $FcntlLockAnswer -Encoding Ascii
}
$CryptoScript = Join-Path $Repo 'tools\samba_android\build-crypto.sh'
$BashEnv = @{
    SAMBA_BUILD_ROOT = (ConvertTo-MsysPath $Source)
    SAMBA_CACHE = $CachePosix
    SAMBA_DEPS_SOURCE = (ConvertTo-MsysPath $DepsSource)
    SAMBA_PREFIX = (ConvertTo-MsysPath $Prefix)
    SAMBA_REPO = $RepoPosix
    SAMBA_NDK = (ConvertTo-MsysPath $Ndk)
    SAMBA_HOST_TOOL = (ConvertTo-MsysPath (Join-Path $Tool 'ucrt64'))
    SAMBA_ADB = (ConvertTo-MsysPath $Adb)
    SAMBA_DEVICE = $DeviceSerial
    SAMBA_ANSWERS = (ConvertTo-MsysPath $AnswerFile)
    SAMBA_OUT = (ConvertTo-MsysPath $OutDir)
    SAMBA_VERSION = $Version
    SAMBA_BUILD_PROFILE = $BuildProfile
    SAMBA_BUILD_SCOPE = $BuildScope
    SAMBA_PERL5LIB = (ConvertTo-MsysPath $PerlYappLib)
    SAMBA_YAPP_BIN = (ConvertTo-MsysPath (Join-Path $PerlDependencyRoot 'Parse-Yapp-1.21'))
}
$EnvPrefix = ($BashEnv.GetEnumerator() | ForEach-Object { "export $($_.Key)='$($_.Value.Replace("'", "'\''"))'" }) -join '; '
$CryptoPosix = (ConvertTo-MsysPath $CryptoScript)
$ShellScriptPosix = (ConvertTo-MsysPath $ShellScript)
$Command = "set -e; $EnvPrefix; bash '$CryptoPosix'; bash '$ShellScriptPosix'"
Invoke-Checked $MsysBash @('-lc',$Command)
$BuildMetadata = @{ ndk = 'r29'; ndk_revision = '29.0.14206865'; android_api = 28; target = 'aarch64-linux-android28'; samba_version = $Version; build_profile = $BuildProfile; build_scope = $BuildScope }
if ($BuildProfile -eq 'size') {
    $BuildMetadata.samba_cflags = '-Os -fPIE -ffunction-sections -fdata-sections -flto=thin'
    $BuildMetadata.crypto_cflags = '-O2 -fPIC'
}
[System.IO.File]::WriteAllText((Join-Path $OutDir 'build-metadata.json'), ($BuildMetadata | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
$BuiltHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $OutDir 'smbclient')).Hash.ToLowerInvariant()
$BinaryNames = @('smbclient','smbd','samba-dcerpcd','rpcd_classic','rpcd_lsad','rpcd_winreg')
if ($BuildScope -eq 'client') { $BinaryNames = @('smbclient') }
$HashLines = foreach ($BinaryName in $BinaryNames) {
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $OutDir $BinaryName)).Hash.ToLowerInvariant()
    "$Hash  $BinaryName"
}
[System.IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS.txt'), ($HashLines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
$TestReport = Join-Path $OutDir 'functional-test-report.json'
if (Test-Path -LiteralPath $TestReport) {
    $PreviousTest = Get-Content -Raw -LiteralPath $TestReport | ConvertFrom-Json
    if ($PreviousTest.binary_sha256 -ne $BuiltHash) { Remove-Item -LiteralPath $TestReport }
}
$ServerReport = Join-Path $OutDir 'server-functional-test-report.json'
if ($BuildScope -eq 'all' -and (Test-Path -LiteralPath $ServerReport)) {
    $PreviousServerTest = Get-Content -Raw -LiteralPath $ServerReport | ConvertFrom-Json
    foreach ($Name in @('smbd','samba-dcerpcd','rpcd_classic','rpcd_lsad','rpcd_winreg')) {
        $CurrentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $OutDir $Name)).Hash.ToLowerInvariant()
        if ($PreviousServerTest.binary_sha256.$Name -ne $CurrentHash) {
            Remove-Item -LiteralPath $ServerReport
            break
        }
    }
}
Write-Host "Build complete: $OutDir (profile: $BuildProfile; binaries: $($BinaryNames -join ', '))"
