# Smoogi Share per-user installer (no admin needed). Run by smoogi-share-setup.exe.
$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'Programs\Smoogi Share'
Get-Process smoogi_share -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
New-Item -ItemType Directory -Force $app | Out-Null
Expand-Archive -Force -Path (Join-Path $PSScriptRoot 'payload.zip') -DestinationPath $app
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1') $app -Force

$exe = Join-Path $app 'smoogi_share.exe'
$ws = New-Object -ComObject WScript.Shell
$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Smoogi Share.lnk'
$s = $ws.CreateShortcut($lnk); $s.TargetPath = $exe; $s.WorkingDirectory = $app; $s.Save()

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SmoogiShare'
New-Item -Force -Path $key | Out-Null
Set-ItemProperty $key DisplayName 'Smoogi Share'
Set-ItemProperty $key InstallLocation $app
Set-ItemProperty $key DisplayIcon $exe
Set-ItemProperty $key UninstallString "powershell -NoProfile -ExecutionPolicy Bypass -File `"$app\uninstall.ps1`""
Set-ItemProperty $key NoModify 1
Set-ItemProperty $key NoRepair 1

Start-Process $exe
