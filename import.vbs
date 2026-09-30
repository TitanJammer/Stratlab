' Opens a .stratlab pack in Stratlab (the installer registers this for double-clicking a pack file).
' The app shows the import preview; nothing is added until Import is pressed there.
If WScript.Arguments.Count < 1 Then WScript.Quit
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = root
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\editor.ps1"" -Import """ & WScript.Arguments(0) & """", 0, False
