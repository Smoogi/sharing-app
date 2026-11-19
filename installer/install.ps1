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
$s = $ws.CreateShortcut($lnk); $s.TargetPath = $exe; $s.WorkingDirectory = $app; $s.IconLocation = "$exe,0"; $s.Save()

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SmoogiShare'
New-Item -Force -Path $key | Out-Null
Set-ItemProperty $key DisplayName 'Smoogi Share'
Set-ItemProperty $key InstallLocation $app
Set-ItemProperty $key DisplayIcon $exe
Set-ItemProperty $key UninstallString "powershell -NoProfile -ExecutionPolicy Bypass -File `"$app\uninstall.ps1`""
Set-ItemProperty $key NoModify 1
Set-ItemProperty $key NoRepair 1

# Windows caches icons; make Explorer, Start and the taskbar pick up the new one.
try {
  Add-Type -Namespace Win32 -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, int f, IntPtr a, IntPtr b);'
  [Win32.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
  Start-Process (Join-Path $env:SystemRoot 'System32\ie4uinit.exe') -ArgumentList '-show' -WindowStyle Hidden -Wait
} catch {}

Start-Process $exe
