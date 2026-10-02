' Run at login by the "Stratlab (background)" shortcut in the Startup folder: starts Stratlab's server in the
' background (tray icon, no window). "Start with Windows" off in the tray menu or the app's settings makes the
' server exit straight away instead (the shortcut stays, so an update cannot bring the setting back).
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = root
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\editor.ps1"" -Background -AtLogin", 0, False
