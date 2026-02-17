[Setup]
AppName=FileShare
AppVersion={#AppVersion}
AppPublisher=FileShare
AppPublisherURL=https://example.com
DefaultDirName={autopf}\FileShare
DefaultGroupName=FileShare
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=FileShare-Setup-{#AppVersion}
SetupIconFile={#SourcePath}\..\windows\runner\resources\app_icon.ico
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "VC_redist.x64.exe"
Source: "{#BuildDir}\VC_redist.x64.exe"; DestDir: "{tmp}"; DestName: "VC_redist.x64.exe"; Flags: deleteafterinstall

[Icons]
Name: "{group}\FileShare"; Filename: "{app}\fileshare.exe"
Name: "{commondesktop}\FileShare"; Filename: "{app}\fileshare.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:";

[Run]
Filename: "{tmp}\VC_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing Microsoft Visual C++ Runtime..."; Flags: waituntilterminated
Filename: "{app}\fileshare.exe"; Description: "Launch FileShare"; Flags: nowait postinstall skipifsilent
