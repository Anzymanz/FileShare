[Setup]
AppName=FileShare
AppVersion={#AppVersion}
AppPublisher=FileShare
AppPublisherURL=https://example.com
DefaultDirName={pf}\FileShare
DefaultGroupName=FileShare
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=FileShare-Setup-{#AppVersion}
SetupIconFile={#SourcePath}\..\windows\runner\resources\app_icon.ico
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\FileShare"; Filename: "{app}\fileshare.exe"
Name: "{commondesktop}\FileShare"; Filename: "{app}\fileshare.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:";

[Run]
Filename: "{app}\fileshare.exe"; Description: "Launch FileShare"; Flags: nowait postinstall skipifsilent
