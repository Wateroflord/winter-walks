; Установщик Winter Walks для Windows (Inno Setup 6), ставится в профиль пользователя.
#define BuildNo GetEnv("BUILD_NO")
#if BuildNo == ""
  #define BuildNo "0"
#endif

[Setup]
AppId={{0B14C6B1-03AF-4512-A80F-DBB039E8FBBF}
AppName=Winter Walks
AppVersion=1.0.{#BuildNo}
AppPublisher=Winter Hub
DefaultDirName={localappdata}\Programs\Winter Walks
DefaultGroupName=Winter Walks
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Winter-Walks-Setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\winter_walks.exe
CloseApplications=force
RestartApplications=no
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Winter Walks"; Filename: "{app}\winter_walks.exe"
Name: "{group}\{cm:UninstallProgram,Winter Walks}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Winter Walks"; Filename: "{app}\winter_walks.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\winter_walks.exe"; Description: "{cm:LaunchProgram,Winter Walks}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\winter_walks.exe"; Flags: nowait; Check: WizardSilent
