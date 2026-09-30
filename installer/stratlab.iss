; Stratlab installer (Inno Setup 6). Build with tools\build_installer.ps1, which passes the version in.
; Per-user install into %LocalAppData%\Stratlab: no admin rights, and the app's data lives next to it.
; Nothing to bundle: the app runs on the PowerShell 5.1 and Edge that ship with Windows 10 / 11.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "Stratlab"

[Setup]
AppId={{7E1D3C52-6A0B-4B7E-9C39-5A1F2D8E4B61}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Stratlab
DefaultDirName={localappdata}\Stratlab
DefaultGroupName=Stratlab
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Stratlab-Setup-{#AppVersion}
SetupIconFile=..\assets\app.ico
UninstallDisplayIcon={app}\assets\app.ico
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
CloseApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start the Stratlab server at login, so the app opens instantly"; GroupDescription: "Startup:"; Flags: checkedonce

[Files]
; the app
Source: "..\editor.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\overlay.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\launch.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\launch-bg.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\overlay.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\import.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Start Overlay.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\version.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\web\*"; DestDir: "{app}\web"; Flags: ignoreversion recursesubdirs
Source: "..\tools\stop.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "..\tools\get_official_art.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
; official art (icons, map banners, role art), never the user's own pictures
Source: "..\assets\app.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\assets\app-icon.png"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\assets\icons\*"; DestDir: "{app}\assets\icons"; Flags: ignoreversion recursesubdirs
Source: "..\assets\maps\*"; DestDir: "{app}\assets\maps"; Flags: ignoreversion recursesubdirs
Source: "..\assets\roles\*"; DestDir: "{app}\assets\roles"; Flags: ignoreversion recursesubdirs
; game data (maps, agents, pool): always updated
Source: "..\data\game.json"; DestDir: "{app}\data"; Flags: ignoreversion
; the user's library, packs and settings: created empty on a first install, never touched on an upgrade
Source: "lineups.empty.json"; DestDir: "{app}\data"; DestName: "lineups.json"; Flags: onlyifdoesntexist
Source: "packs.empty.json"; DestDir: "{app}\data"; DestName: "packs.json"; Flags: onlyifdoesntexist
Source: "config.default.json"; DestDir: "{app}"; DestName: "config.json"; Flags: onlyifdoesntexist

[Icons]
Name: "{group}\Stratlab"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"; Comment: "Stratlab: Valorant strats, editor and in-game overlay"
Name: "{group}\Start the overlay"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\overlay.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"
Name: "{group}\Uninstall Stratlab"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Stratlab"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"; Tasks: desktopicon
Name: "{userstartup}\Stratlab (background)"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch-bg.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"; Tasks: startup

[Registry]
; double-clicking a .stratlab pack opens it in the app (per-user, removed on uninstall)
Root: HKCU; Subkey: "Software\Classes\.stratlab"; ValueType: string; ValueName: ""; ValueData: "Stratlab.Pack"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\Stratlab.Pack"; ValueType: string; ValueName: ""; ValueData: "Stratlab pack"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Stratlab.Pack\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\assets\app.ico,0"
Root: HKCU; Subkey: "Software\Classes\Stratlab.Pack\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{sys}\wscript.exe"" ""{app}\import.vbs"" ""%1"""

[Run]
; always start the server (a silent in-app update stopped the old one; the open window reconnects to this one)
Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch-bg.vbs"""; WorkingDir: "{app}"; Flags: nowait runhidden
Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; WorkingDir: "{app}"; Description: "Open Stratlab"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\tools\stop.ps1"""; Flags: runhidden; RunOnceId: "StopStratlab"

[Code]
// an upgrade over a running copy: stop the server and overlay first, so files can be replaced
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  R: Integer;
  Stop: String;
begin
  Result := '';
  Stop := ExpandConstant('{app}\tools\stop.ps1');
  if FileExists(Stop) then
    Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + Stop + '"', '', SW_HIDE, ewWaitUntilTerminated, R);
end;
