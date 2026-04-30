Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

strScriptPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
strCommand = "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strScriptPath & "\proxy-switch.ps1"""

objShell.Run strCommand, 0, False
