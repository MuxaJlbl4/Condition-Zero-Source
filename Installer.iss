#define MyAppName "Condition Zero: Source"
#define MyAppVersion "1.0"
#define MyAppPublisher "Miishanya"
#define MyAppURL "https://github.com/MuxaJlbl4/Condition-Zero-Source"
#define MyUninstallName "Condition Zero: Source"

[Setup]
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
VersionInfoVersion={#MyAppVersion}
DefaultDirName={code:GetSteamPath}\steamapps\common\Counter-Strike Source\cstrike\
DirExistsWarning=no
DisableProgramGroupPage=yes
OutputBaseFilename=Condition-Zero-Source-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
Uninstallable=yes
UninstallDisplayName={#MyUninstallName}
UninstallDisplayIcon={app}\czero.ico
WizardStyle=modern
WizardImageFile=Images/insecure.bmp
ShowLanguageDialog=auto

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
Source: "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Source\cstrike\addons\*"; DestDir: "{app}\addons\"; Excludes: "*.sq3,*.log"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "Resources\*";  DestDir: "{app}\custom\Condition_Zero\"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "Plugins\bot2player\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "Plugins\condition-zero\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "Images\czero.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autodesktop}\Condition Zero Source"; Filename: "{code:GetSteamPath}\steamapps\common\Counter-Strike Source\cstrike_win64.exe"; Parameters: "-insecure"; IconFilename: "{app}\czero.ico"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Code]
function GetSteamPath(Param: String): String;
var
  SteamPath: String;
begin
  SteamPath := 'C:\Program Files (x86)\Steam';
  RegQueryStringValue(HKCU, 'Software\Valve\Steam', 'SteamPath', SteamPath);
  Result := SteamPath;
end;