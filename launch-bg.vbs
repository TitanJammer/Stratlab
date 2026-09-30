' Starts Stratlab's server in the background (no window), so the app opens instantly any time.
' Placed in the Windows Startup folder by tools\install_shortcut.ps1.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = root
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\editor.ps1"" -Background", 0, False
