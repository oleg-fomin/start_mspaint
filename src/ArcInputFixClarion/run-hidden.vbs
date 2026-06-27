' run-hidden.vbs - launch launch-paint-hidden.ps1 with NO visible window.
'
' Why this exists:
'   powershell.exe is a CONSOLE application. When a scheduled task runs it
'   directly, Windows creates the console host (conhost.exe) window BEFORE
'   PowerShell parses its arguments, so "-WindowStyle Hidden" / "-NonInteractive"
'   cannot prevent a brief blue flash at logon. The Task Scheduler "Hidden"
'   checkbox does not help either (it only hides the task's own window).
'
'   WScript.Shell.Run(command, 0, False) starts the process with window style 0
'   (SW_HIDE) from its very first instruction, so the console host is created
'   hidden - no flash. wscript.exe itself has no console window. This is the same
'   net effect as ArcInputFix.exe launching the helper with CREATE_NO_WINDOW.
'
' Scheduled-task action (Run only when user is logged on, so the fix lands in the
' interactive session):
'   Program/script : wscript.exe
'   Arguments      : "C:\Path\To\run-hidden.vbs"

Option Explicit
Dim shell, here, ps, cmd
Set shell = CreateObject("WScript.Shell")

' Folder this script lives in (helper .ps1 sits next to it).
here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))

' Native PowerShell. A scheduled task runs 64-bit, so System32 is the real 64-bit
' PowerShell (no Sysnative needed here, unlike the 32-bit ArcInputFix.exe).
ps = shell.ExpandEnvironmentStrings("%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe")

cmd = """" & ps & """ -NoProfile -ExecutionPolicy Bypass -NonInteractive" & _
      " -File """ & here & "launch-paint-hidden.ps1"""

' 0 = hidden window, False = do not wait for it to finish.
shell.Run cmd, 0, False
