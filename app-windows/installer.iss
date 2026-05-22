; Summer 2008 — An American Girl Archive · Windows installer (Inno Setup 6)
;
; Driven by build.ps1, which:
;   1. Publishes a single-file .NET 8 EXE
;   2. Stages it + Resources\ + projector\ into build\stage\
;   3. Calls: ISCC.exe installer.iss /DStageDir=...\build\stage
;
; The installer:
;   • Installs to Program Files\Summer 2008\
;   • Creates Start Menu + optional desktop shortcuts
;   • Registers an uninstaller
;   • Detects + bootstraps WebView2 runtime if missing
;   • Prompts to launch on finish

#define MyAppName       "Summer 2008 — An American Girl Archive"
#define MyAppShortName  "Summer 2008"
#define MyAppVersion    "1.0.0"
#define MyAppPublisher  "Summer 2008 Archive"
#define MyAppExeName    "Summer2008.exe"
#define MyAppURL        "https://github.com/ganten7/summer-2008"
#define MyAppSupportURL "https://github.com/ganten7/summer-2008/issues"

#ifndef StageDir
  #define StageDir "build\stage"
#endif

[Setup]
AppId={{C0C0C0C0-2008-4AA1-A6B8-AC3CFCDA8AA1}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppShortName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppSupportURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\Summer 2008
DefaultGroupName={#MyAppShortName}
DisableProgramGroupPage=auto
DisableWelcomePage=no
LicenseFile=
OutputDir=build
OutputBaseFilename=Summer-2008-Setup-v{#MyAppVersion}
SetupIconFile=icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
WizardImageAlphaFormat=defined
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
MinVersion=10.0
WizardSmallImageFile=

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Everything under build\stage\ — the EXE plus Resources\ + projector\.
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppShortName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppShortName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppShortName}}"; Flags: nowait postinstall skipifsilent

[Code]
{ -----------------------------------------------------------------
  WebView2 runtime check.

  Every Win10/11 since mid-2021 ships with the Edge WebView2 runtime
  pre-installed. But on older Win10 builds (or stripped LTSC images)
  it may be missing — the .exe will refuse to start. Bootstrap by
  downloading the evergreen installer from Microsoft on first run.

  Reference: https://docs.microsoft.com/microsoft-edge/webview2/
            concepts/distribution#online-only-deployment
  ---------------------------------------------------------------- }

function IsWebView2Installed(): Boolean;
var
  PV: String;
begin
  Result := False;
  if RegQueryStringValue(HKEY_LOCAL_MACHINE,
       'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
       'pv', PV) then
    Result := (PV <> '') and (PV <> '0.0.0.0');
  if not Result then
    if RegQueryStringValue(HKEY_LOCAL_MACHINE,
         'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
         'pv', PV) then
      Result := (PV <> '') and (PV <> '0.0.0.0');
  if not Result then
    if RegQueryStringValue(HKEY_CURRENT_USER,
         'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
         'pv', PV) then
      Result := (PV <> '') and (PV <> '0.0.0.0');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  TmpFile: String;
begin
  if (CurStep = ssPostInstall) and (not IsWebView2Installed()) then
  begin
    if MsgBox(
      'Microsoft Edge WebView2 isn''t installed on this system. ' +
      'Summer 2008 needs it to render the archive. Download and install it now? ' +
      '(about 1.5 MB, online installer.)',
      mbConfirmation, MB_YESNO) = IDYES then
    begin
      TmpFile := ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe');
      DownloadTemporaryFile(
        'https://go.microsoft.com/fwlink/p/?LinkId=2124703',
        'MicrosoftEdgeWebview2Setup.exe', '', nil);
      Exec(TmpFile, '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;
  end;
end;
