# Builds dist\smoogi-share-setup.exe from build\windows\x64\runner\Release using IExpress (built into Windows).
param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$rel = Join-Path $Root 'build\windows\x64\runner\Release'
$dist = Join-Path $Root 'dist'
$stage = Join-Path $env:TEMP 'smoogi_setup_stage'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage, $dist | Out-Null
Compress-Archive -Path "$rel\*" -DestinationPath "$stage\payload.zip" -Force
Copy-Item "$PSScriptRoot\install.ps1","$PSScriptRoot\uninstall.ps1" $stage
$final = Join-Path $dist 'smoogi-share-setup.exe'
$out = Join-Path $env:TEMP ('smoogi-setup-' + [guid]::NewGuid().ToString('N') + '.exe')
$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=Smoogi Share installed. It starts now; find it later in the Start Menu.
TargetName=$out
FriendlyName=Smoogi Share Setup
AppLaunched=powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[SourceFiles]
SourceFiles0=$stage\
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
[Strings]
FILE0="payload.zip"
FILE1="install.ps1"
FILE2="uninstall.ps1"
"@
$sedPath = Join-Path $stage 'setup.sed'
Set-Content $sedPath $sed -Encoding ASCII
Start-Process iexpress.exe -ArgumentList '/N','/Q',$sedPath -Wait
for ($i = 0; $i -lt 60 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 500 }
if (-not (Test-Path $out)) { throw 'IExpress did not produce the installer' }
Start-Sleep -Seconds 1
Copy-Item $out $final -Force
Remove-Item $out -Force -ErrorAction SilentlyContinue
Get-Item $final | Select Name, Length, LastWriteTime
