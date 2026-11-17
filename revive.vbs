' Автовосстановление сторожа OBS. Запускается Планировщиком Windows раз в минуту.
' Если сторож не работает (его закрыли или он упал) — запускает его скрыто.
' Ничего не делает, если в окне «Сторож OBS» выключено автовосстановление
' или сторож выключен кнопкой «Выключить сторожа».

Option Explicit
Dim fso, dir, txt, re, procs

Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)

txt = ""
If fso.FileExists(dir & "\settings.json") Then
    txt = fso.OpenTextFile(dir & "\settings.json", 1).ReadAll
End If

Set re = New RegExp
re.IgnoreCase = True
re.Pattern = """AutoRevive""\s*:\s*false"
If re.Test(txt) Then WScript.Quit
re.Pattern = """Enabled""\s*:\s*false"
If re.Test(txt) Then WScript.Quit

Set procs = GetObject("winmgmts:\\.\root\cimv2").ExecQuery( _
    "SELECT ProcessId FROM Win32_Process WHERE Name='powershell.exe' AND CommandLine LIKE '%obs-watchdog.ps1%'")
If procs.Count > 0 Then WScript.Quit

CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & _
    dir & "\obs-watchdog.ps1"" -Revived", 0, False
