# Установка «Сторожа OBS» на этом компьютере. Запускать из папки, куда скачан репозиторий:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# Что делает:
#  - снимает с файлов пометку «скачано из интернета» (иначе Windows может их блокировать);
#  - кладёт ярлык «Сторож OBS» в автозагрузку (сторож запускается при входе в Windows);
#  - кладёт ярлык «Сторож OBS» на рабочий стол (окно с настройками и журналом);
#  - регистрирует задачу «OBS-Watchdog-Revive» (раз в минуту поднимает сторожа, если его закрыли);
#  - запускает сторожа.
# Повторный запуск безопасен: всё пересоздаётся. Удаление — uninstall.ps1.

$ErrorActionPreference = 'Stop'
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$sh  = New-Object -ComObject WScript.Shell

Get-ChildItem $Dir -File | Unblock-File

# Ярлык через временное латинское имя: WScript.Shell не сохраняет ярлык с кириллицей в пути
function New-Shortcut([string]$folder, [string]$name, [string]$target, [string]$arguments, [string]$icon, [string]$desc) {
    $tmp = Join-Path $folder 'obs-watchdog-tmp.lnk'
    $l = $sh.CreateShortcut($tmp)
    $l.TargetPath = $target
    $l.Arguments = $arguments
    $l.WorkingDirectory = $Dir
    $l.WindowStyle = 7
    $l.Description = $desc
    if ($icon) { $l.IconLocation = $icon }
    $l.Save()
    $final = Join-Path $folder $name
    Remove-Item $final -ErrorAction SilentlyContinue
    Rename-Item $tmp $name
    $final
}

$obsExe = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'
$icon = if (Test-Path $obsExe) { "$obsExe,0" } else { "$env:WINDIR\System32\shell32.dll,21" }

$startup = New-Shortcut ([Environment]::GetFolderPath('Startup')) 'Сторож OBS.lnk' $ps `
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\obs-watchdog.ps1`"" $null 'Сторож трансляции OBS'
$desktop = New-Shortcut ([Environment]::GetFolderPath('Desktop')) 'Сторож OBS.lnk' $ps `
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\obs-watchdog-gui.ps1`"" $icon 'Настройки и журнал сторожа трансляции OBS'

# Автозапуск сторожа: раз в минуту revive.vbs проверяет, работает ли он
& schtasks.exe /Create /TN 'OBS-Watchdog-Revive' /TR "wscript.exe `"$Dir\revive.vbs`"" /SC MINUTE /MO 1 /F | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать задачу OBS-Watchdog-Revive в Планировщике Windows' }

# Сторож включён (на случай, если до переустановки его выключили кнопкой)
$settingsFile = Join-Path $Dir 'settings.json'
if (Test-Path $settingsFile) {
    $s = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $s | Add-Member Enabled $true -Force
    $s | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8
}

Start-Process $ps -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$Dir\obs-watchdog.ps1`""

Write-Host ''
Write-Host 'Сторож OBS установлен и запущен.' -ForegroundColor Green
Write-Host "  Автозапуск:      $startup"
Write-Host "  Ярлык окна:      $desktop"
Write-Host '  Автоподъём:      задача Планировщика «OBS-Watchdog-Revive»'
Write-Host ''
Write-Host 'Осталось один раз в OBS: Инструменты -> Настройки сервера WebSocket -> «Включить сервер WebSocket».' -ForegroundColor Yellow
Write-Host 'Адрес камеры для проверки пингом меняется в окне «Сторож OBS» (по умолчанию 192.168.100.20).'
