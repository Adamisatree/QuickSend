#ifndef AppVersion
  #define AppVersion "2.1.0"
#endif
#ifndef TargetArch
  #define TargetArch "x64"
#endif
#ifndef BundleDir
  #define BundleDir "..\\build\\windows\\x64\\runner\\Release"
#endif

#define AppName "QuickSend"

[Setup]
AppId={{96A4C7F4-46CE-4CC7-A514-3A2E7F98A4B1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=QuickSend
DefaultDirName={autopf}\QuickSend
DefaultGroupName=QuickSend
DisableProgramGroupPage=yes
OutputDir=..\release-assets
OutputBaseFilename=QuickSend-v{#AppVersion}-windows-{#TargetArch}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible arm64
ArchitecturesInstallIn64BitMode=x64compatible arm64
UninstallDisplayIcon={app}\quicksend_native.exe

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\QuickSend"; Filename: "{app}\quicksend_native.exe"
Name: "{autodesktop}\QuickSend"; Filename: "{app}\quicksend_native.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\quicksend_native.exe"; Description: "启动 QuickSend"; Flags: postinstall nowait skipifsilent
