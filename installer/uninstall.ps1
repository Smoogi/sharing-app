$ErrorActionPreference = 'SilentlyContinue'
$app = Join-Path $env:LOCALAPPDATA 'Programs\Smoogi Share'
Get-Process smoogi_share | Stop-Process -Force
Start-Sleep -Milliseconds 500
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Smoogi Share.lnk') -Force
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SmoogiShare' -Recurse -Force
# Your messages and identity live in %APPDATA%\com.smoogi and are kept on purpose.
Start-Process powershell -ArgumentList '-NoProfile','-Command',"Start-Sleep 2; Remove-Item -LiteralPath '$app' -Recurse -Force" -WindowStyle Hidden
