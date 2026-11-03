; Inno Setup script: builds HomeGuard-Setup-<version>.exe from the Flutter
; Windows release bundle. Run from the repo root:
;   iscc /DAppVersion=1.0.0 installer\HomeGuard.iss
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6B0D6E2A-3F4C-4C8E-9A57-2D1E8C0B7A11}
AppName=HomeGuard
AppVersion={#AppVersion}
AppPublisher=MAH78
DefaultDirName={autopf}\HomeGuard
DefaultGroupName=HomeGuard
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=HomeGuard-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\HomeGuard.exe
SetupIconFile=..\windows\runner\resources\app_icon.ico
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\HomeGuard"; Filename: "{app}\HomeGuard.exe"
Name: "{autodesktop}\HomeGuard"; Filename: "{app}\HomeGuard.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\HomeGuard.exe"; Description: "{cm:LaunchProgram,HomeGuard}"; Flags: nowait postinstall skipifsilent
