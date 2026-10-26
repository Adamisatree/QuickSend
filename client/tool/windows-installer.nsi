Unicode true
!include "MUI2.nsh"

!ifndef APP_VERSION
  !define APP_VERSION "2.1.0"
!endif
!ifndef APP_ARCH
  !define APP_ARCH "x64"
!endif
!ifndef BUNDLE_DIR
  !define BUNDLE_DIR "build\windows\x64\runner\Release"
!endif
!ifndef OUTPUT_FILE
  !define OUTPUT_FILE "release-assets\QuickSend-v${APP_VERSION}-windows-${APP_ARCH}-setup.exe"
!endif

Name "QuickSend ${APP_VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\QuickSend"
InstallDirRegKey HKCU "Software\QuickSend" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\quicksend_native.exe"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "QuickSend" SEC_MAIN
  SectionIn RO
  SetOutPath "$INSTDIR"
  File /r "${BUNDLE_DIR}\*.*"
  WriteRegStr HKCU "Software\QuickSend" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\QuickSend" "DisplayName" "QuickSend"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\QuickSend" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\QuickSend" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\QuickSend"
  CreateShortcut "$SMPROGRAMS\QuickSend\QuickSend.lnk" "$INSTDIR\quicksend_native.exe"
  CreateShortcut "$DESKTOP\QuickSend.lnk" "$INSTDIR\quicksend_native.exe"
SectionEnd

Section "Uninstall"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\QuickSend"
  DeleteRegKey HKCU "Software\QuickSend"
  Delete "$SMPROGRAMS\QuickSend\QuickSend.lnk"
  RMDir "$SMPROGRAMS\QuickSend"
  Delete "$DESKTOP\QuickSend.lnk"
  RMDir /r "$INSTDIR"
SectionEnd
