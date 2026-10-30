; Devinorium Windows installer, compiled by Inno Setup in CI.
; scripts/build-windows-installer.sh drives ISCC with these defines:
;   /DMyAppVersion=<version> /DSourceDir=<flutter Release dir>
;   /DArch=x86_64|arm64 /DIconFile=<app_icon.ico> /DLicenseFile=<LICENSE>
; /O<dir> and /F<name> control where the setup exe lands.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "app"
#endif
#ifndef Arch
  #define Arch "x86_64"
#endif
#ifndef IconFile
  #define IconFile "app_icon.ico"
#endif
#ifndef LicenseFile
  #define LicenseFile "LICENSE.txt"
#endif

#define MyAppName "Devinorium"
#define MyAppPublisher "Devinorium"
#define MyAppURL "https://gitlab.com/HttpAnimations/devinorium"
#define MyAppExeName "devinorium_frontend.exe"

[Setup]
AppId={{90F77D65-DFC3-48A9-B4BD-A6BB988EAE24}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\Devinorium
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename=devinorium-setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
MinVersion=10.0
LicenseFile={#LicenseFile}
AppMutex=devinorium_single_instance_mutex
CloseApplications=yes
VersionInfoVersion={#MyAppVersion}
VersionInfoProductName={#MyAppName}
VersionInfoDescription={#MyAppName} Setup
#if Arch == "arm64"
  #define ArchAllowed "arm64"
#elif Ver >= EncodeVer(6,3,0)
  #define ArchAllowed "x64compatible"
#else
  #define ArchAllowed "x64"
#endif
ArchitecturesAllowed={#ArchAllowed}
ArchitecturesInstallIn64BitMode={#ArchAllowed}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
