Option Explicit
Dim fso, shell, baseDir, psExe, launcher, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
launcher = fso.BuildPath(baseDir, "RF-Network-Tool-Launcher.ps1")
psExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
shell.CurrentDirectory = baseDir
cmd = Chr(34) & psExe & Chr(34) & " -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Chr(34) & launcher & Chr(34)
' RF Network Tool v1.4.2 Full QA / CI-E2E - ASCII/no-BOM launcher.
shell.Run cmd, 0, False