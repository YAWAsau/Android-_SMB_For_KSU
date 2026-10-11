param([string]$Sdk = "$env:LOCALAPPDATA/Android/Sdk")
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Out = Join-Path $Here 'target'
New-Item -ItemType Directory -Force "$Out/classes", "$Out/dex", "$Out/tests" | Out-Null
$Android = Join-Path $Sdk 'platforms/android-36/android.jar'
$D8 = Join-Path $Sdk 'build-tools/36.0.0/d8.bat'
& javac --release 8 -encoding UTF-8 -classpath $Android -d "$Out/classes" "$Here/SmbNotifyUtil.java"
if ($LASTEXITCODE) { throw 'javac failed' }
Get-ChildItem -LiteralPath "$Out/classes/com/yawasau/smbnotify" -Filter "NotifyTest*.class" | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
& jar cf "$Out/notify.jar" -C "$Out/classes" .
& $D8 --min-api 28 --lib $Android --output "$Out/dex" "$Out/notify.jar"
if ($LASTEXITCODE) { throw 'd8 failed' }
Copy-Item -LiteralPath "$Out/dex/classes.dex" -Destination "$Here/../../bin/smbnotify.dex"
& javac --release 8 -encoding UTF-8 -classpath "$Android;$Out/classes" -d "$Out/classes" "$Here/NotifyTest.java"
if ($LASTEXITCODE) { throw 'test javac failed' }
& jar cf "$Out/tests.jar" -C "$Out/classes" .
& $D8 --min-api 28 --lib $Android --output "$Out/tests" "$Out/tests.jar"
if ($LASTEXITCODE) { throw 'test d8 failed' }
