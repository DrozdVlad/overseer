# Удаление «Сторожа OBS»: останавливает сторожа и окно, убирает ярлыки и задачу Планировщика.
# Файлы в этой папке (в том числе журнал incidents.log) не удаляются.
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1

& schtasks.exe /Delete /TN 'OBS-Watchdog-Revive' /F 2>$null | Out-Null

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*obs-watchdog*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($folder in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Desktop')) {
    Remove-Item (Join-Path $folder 'Сторож OBS.lnk') -ErrorAction SilentlyContinue
}

Write-Host 'Сторож OBS удалён: остановлен, ярлыки и задача Планировщика убраны.' -ForegroundColor Green
