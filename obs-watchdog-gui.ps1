# Окно «Сторож OBS»: состояние сторожа, настройки, журнал прерываний.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$Dir          = Split-Path -Parent $MyInvocation.MyCommand.Path
$Watchdog     = Join-Path $Dir 'obs-watchdog.ps1'
$SettingsFile = Join-Path $Dir 'settings.json'
$LogFile      = Join-Path $Dir 'incidents.log'
$StatusFile   = Join-Path $Dir 'status.json'
$PidFile      = Join-Path $Dir 'watchdog.pid'
$WsConfig     = "$env:APPDATA\obs-studio\plugin_config\obs-websocket\config.json"

function Get-Settings {
    $s = @{ CheckSec = 30; StuckSec = 90; KeepDays = 30; PingEnabled = $true; PingHost = '8.8.8.8'
            CameraPing = $true; CameraHost = '192.168.100.20'; PingFails = 3; AlwaysOn = $false; ReportMin = 10; Enabled = $true; AutoRevive = $true; SkipPct = 2 }
    try {
        $j = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.SkipPct -gt 0)         { $s.SkipPct = [double]$j.SkipPct }
        if ($null -ne $j.Enabled)     { $s.Enabled = [bool]$j.Enabled }
        if ($null -ne $j.AutoRevive)  { $s.AutoRevive = [bool]$j.AutoRevive }
        if ($j.ReportMin -ge 1)       { $s.ReportMin = [int]$j.ReportMin }
        if ($null -ne $j.AlwaysOn)    { $s.AlwaysOn = [bool]$j.AlwaysOn }
        if ($j.CheckSec -ge 5)  { $s.CheckSec = [int]$j.CheckSec }
        if ($j.StuckSec -ge 30) { $s.StuckSec = [int]$j.StuckSec }
        if ($j.KeepDays -ge 1)  { $s.KeepDays = [int]$j.KeepDays }
        if ($null -ne $j.PingEnabled) { $s.PingEnabled = [bool]$j.PingEnabled }
        if ($j.PingHost)              { $s.PingHost = [string]$j.PingHost }
        if ($null -ne $j.CameraPing)  { $s.CameraPing = [bool]$j.CameraPing }
        if ($j.CameraHost)            { $s.CameraHost = [string]$j.CameraHost }
        if ($j.PingFails -ge 2)       { $s.PingFails = [int]$j.PingFails }
    } catch {}
    $s
}

function Get-WatchdogProcess {
    try {
        $id = [int](Get-Content $PidFile -ErrorAction Stop)
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
        if ($p -and $p.CommandLine -like '*obs-watchdog.ps1*') { return $p }
    } catch {}
    $null
}

function Start-Watchdog {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$Watchdog`"")
}

function New-Label($text, $x, $y, $w = 260) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, 22)
    $l
}

function New-Number($min, $max, $value, $x, $y) {
    $n = New-Object Windows.Forms.NumericUpDown
    $n.Minimum = $min; $n.Maximum = $max; $n.Value = $value
    $n.Location = New-Object Drawing.Point($x, $y); $n.Width = 80
    $n
}

$cfg = Get-Settings

$form = New-Object Windows.Forms.Form
$form.Text = 'Сторож OBS'
$form.Size = New-Object Drawing.Size(760, 845)
$form.MinimumSize = New-Object Drawing.Size(640, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

# Состояние
$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(15, 12); $status.Size = New-Object Drawing.Size(330, 50)
$status.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$form.Controls.Add($status)

$toggle = New-Object Windows.Forms.Button
$toggle.Location = New-Object Drawing.Point(530, 14); $toggle.Size = New-Object Drawing.Size(160, 32)
$toggle.Anchor = 'Top, Right'
$form.Controls.Add($toggle)

# Режим «Всегда в эфире»
$always = New-Object Windows.Forms.Button
$always.Location = New-Object Drawing.Point(350, 14); $always.Size = New-Object Drawing.Size(170, 32)
$always.Anchor = 'Top, Right'
$always.FlatStyle = 'Flat'
$form.Controls.Add($always)
$tip = New-Object Windows.Forms.ToolTip
$tip.SetToolTip($always, 'ВКЛ: при открытом OBS сторож сам запускает трансляцию, даже если её выключили вручную.' + "`n" + 'ВЫКЛ: перезапускаются только зависшие трансляции, ручная остановка уважается.')

# Автовосстановление сторожа (revive.vbs через Планировщик Windows)
$revive = New-Object Windows.Forms.Button
$revive.Location = New-Object Drawing.Point(510, 52); $revive.Size = New-Object Drawing.Size(180, 30)
$revive.Anchor = 'Top, Right'
$revive.FlatStyle = 'Flat'
$revive.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.Controls.Add($revive)
$tip.SetToolTip($revive, 'ВКЛ: если сторожа закрыли (не кнопкой) или он упал, он запустится снова в течение минуты.' + "`n" + 'ВЫКЛ: закрытый сторож остаётся закрытым до следующего входа в Windows.')

function Save-Settings($s) {
    $s | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
}

# Запись действия из окна в журнал (через тот же замок, что и сторож)
function Write-LogBlock([string]$title, [string[]]$details) {
    $lines = @('', "==== $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') ====  $title") + ($details | ForEach-Object { "  $_" })
    $m = New-Object Threading.Mutex($false, 'OBS-Watchdog-Log')
    try { [void]$m.WaitOne(5000) } catch [Threading.AbandonedMutexException] {}
    try { Add-Content -Path $LogFile -Encoding UTF8 -Value $lines }
    finally { $m.ReleaseMutex(); $m.Dispose() }
}

function Update-AlwaysButton {
    if ((Get-Settings).AutoRevive) {
        $revive.Text = 'Автозапуск сторожа: ВКЛ'
        $revive.BackColor = [Drawing.Color]::ForestGreen; $revive.ForeColor = [Drawing.Color]::White
    } else {
        $revive.Text = 'Автозапуск сторожа: ВЫКЛ'
        $revive.BackColor = [Drawing.Color]::Gainsboro; $revive.ForeColor = [Drawing.Color]::Black
    }
    if ((Get-Settings).AlwaysOn) {
        $always.Text = 'Всегда в эфире: ВКЛ'
        $always.BackColor = [Drawing.Color]::ForestGreen; $always.ForeColor = [Drawing.Color]::White
    } else {
        $always.Text = 'Всегда в эфире: ВЫКЛ'
        $always.BackColor = [Drawing.Color]::Gainsboro; $always.ForeColor = [Drawing.Color]::Black
    }
}

# Живое состояние (из status.json, обновляется после каждой проверки)
$live = New-Object Windows.Forms.Label
$live.Location = New-Object Drawing.Point(15, 58); $live.Size = New-Object Drawing.Size(490, 50)
$live.Font = New-Object Drawing.Font('Segoe UI', 9)
$live.Anchor = 'Top, Left, Right'
$form.Controls.Add($live)

# Настройки
$box = New-Object Windows.Forms.GroupBox
$box.Text = 'Настройки (применяются сразу)'
$box.Location = New-Object Drawing.Point(15, 113); $box.Size = New-Object Drawing.Size(715, 250)
$box.Anchor = 'Top, Left, Right'
$form.Controls.Add($box)

$box.Controls.Add((New-Label 'Проверять трансляцию каждые, сек:' 15 30 300))
$numCheck = New-Number 5 600 $cfg.CheckSec 320 28
$box.Controls.Add($numCheck)
$box.Controls.Add((New-Label 'Перезапускать, если зависла дольше, сек:' 15 62 300))
$numStuck = New-Number 30 1800 $cfg.StuckSec 320 60
$box.Controls.Add($numStuck)
$box.Controls.Add((New-Label 'Хранить журнал прерываний, дней:' 15 94 300))
$numKeep = New-Number 1 365 $cfg.KeepDays 320 92
$box.Controls.Add($numKeep)
$box.Controls.Add((New-Label 'Отчёт «всё ОК» каждые, мин:' 420 30 210))
$numReport = New-Number 1 240 $cfg.ReportMin 630 28
$numReport.Width = 70
$box.Controls.Add($numReport)
$box.Controls.Add((New-Label 'Тревога: пропуск кадров от, %:' 420 94 210))
$numSkip = New-Number 1 50 ([int][math]::Round($cfg.SkipPct)) 630 92
$numSkip.Width = 70
$box.Controls.Add($numSkip)

$save = New-Object Windows.Forms.Button
$save.Text = 'Сохранить'
$save.Location = New-Object Drawing.Point(420, 58); $save.Size = New-Object Drawing.Size(120, 32)
$box.Controls.Add($save)

$chkPing = New-Object Windows.Forms.CheckBox
$chkPing.Text = "Пинговать Google ($($cfg.PingHost)) каждую секунду — обрывы у провайдера"
$chkPing.Checked = $cfg.PingEnabled
$chkPing.Location = New-Object Drawing.Point(15, 126); $chkPing.Size = New-Object Drawing.Size(680, 24)
$box.Controls.Add($chkPing)

$chkCam = New-Object Windows.Forms.CheckBox
$chkCam.Text = 'Пинговать камеру каждую секунду, адрес:'
$chkCam.Checked = $cfg.CameraPing
$chkCam.Location = New-Object Drawing.Point(15, 156); $chkCam.Size = New-Object Drawing.Size(330, 24)
$box.Controls.Add($chkCam)
$txtCam = New-Object Windows.Forms.TextBox
$txtCam.Text = $cfg.CameraHost
$txtCam.Location = New-Object Drawing.Point(350, 155); $txtCam.Width = 150
$box.Controls.Add($txtCam)

$box.Controls.Add((New-Label 'Считать обрывом, если подряд не прошло пингов:' 15 188 400))
$numFails = New-Number 2 60 $cfg.PingFails 420 186
$box.Controls.Add($numFails)

$hint = New-Object Windows.Forms.Label
$hint.Text = 'Проверки почти не нагружают компьютер и не влияют на трансляцию. Железо проверяется раз в минуту.'
$hint.Location = New-Object Drawing.Point(15, 220); $hint.Size = New-Object Drawing.Size(690, 22)
$hint.ForeColor = [Drawing.Color]::Gray
$box.Controls.Add($hint)

# ---------- Журнал: таблица № / Дата / Тип / Событие / Подробности ----------
$form.Controls.Add((New-Label 'Журнал событий:' 15 371 140))

$filter = New-Object Windows.Forms.ComboBox
$filter.DropDownStyle = 'DropDownList'
[void]$filter.Items.AddRange(@('Все записи', 'Только сбои', 'Только отчёты «ОК»', 'Сторож и режимы'))
$filter.SelectedIndex = 0
$filter.Location = New-Object Drawing.Point(160, 368); $filter.Width = 200
$form.Controls.Add($filter)

$export = New-Object Windows.Forms.Button
$export.Text = 'Экспорт в Excel'
$export.Location = New-Object Drawing.Point(570, 366); $export.Size = New-Object Drawing.Size(160, 28)
$export.Anchor = 'Top, Right'
$form.Controls.Add($export)

$grid = New-Object Windows.Forms.ListView
$grid.View = 'Details'; $grid.FullRowSelect = $true; $grid.GridLines = $true
$grid.MultiSelect = $false; $grid.HideSelection = $false
$grid.Font = New-Object Drawing.Font('Segoe UI', 9)
$grid.Location = New-Object Drawing.Point(15, 400); $grid.Size = New-Object Drawing.Size(715, 230)
$grid.Anchor = 'Top, Bottom, Left, Right'
[void]$grid.Columns.Add('№', 50)
[void]$grid.Columns.Add('Дата и время', 130)
[void]$grid.Columns.Add('Тип', 130)
[void]$grid.Columns.Add('Событие', 230)
[void]$grid.Columns.Add('Подробности', 520)
$form.Controls.Add($grid)

$detail = New-Object Windows.Forms.TextBox
$detail.Multiline = $true; $detail.ReadOnly = $true; $detail.ScrollBars = 'Vertical'; $detail.WordWrap = $true
$detail.Font = New-Object Drawing.Font('Consolas', 9)
$detail.BackColor = [Drawing.Color]::White
$detail.Location = New-Object Drawing.Point(15, 638); $detail.Size = New-Object Drawing.Size(715, 115)
$detail.Anchor = 'Bottom, Left, Right'
$detail.Text = 'Выберите строку — здесь появится полная информация по записи.'
$form.Controls.Add($detail)

$openLog = New-Object Windows.Forms.Button
$openLog.Text = 'Открыть файл журнала'
$openLog.Location = New-Object Drawing.Point(15, 761); $openLog.Size = New-Object Drawing.Size(200, 30)
$openLog.Anchor = 'Bottom, Left'
$form.Controls.Add($openLog)

# Разбор incidents.log на записи: № (по порядку, с 1), дата, заголовок, строки подробностей
function Read-Journal {
    $items = New-Object Collections.Generic.List[object]
    if (-not (Test-Path $LogFile)) { return , $items }
    $cur = $null
    foreach ($line in (Get-Content $LogFile -Encoding UTF8)) {
        if ($line -match '^==== (\S+ \S+) ====\s+(.*)$') {
            $cur = [pscustomobject]@{ No = 0; Time = $Matches[1]; Title = $Matches[2].Trim(); Lines = New-Object Collections.Generic.List[string] }
            $items.Add($cur)
        } elseif ($cur -and $line.Trim()) {
            $cur.Lines.Add($line.Trim())
        }
    }
    for ($i = 0; $i -lt $items.Count; $i++) { $items[$i].No = $i + 1 }
    , $items
}

# 'YOUTUBE: ПРЕРЫВАНИЕ ТРАНСЛЯЦИИ' -> тип 'YOUTUBE', событие 'ПРЕРЫВАНИЕ ТРАНСЛЯЦИИ'
function Split-Title([string]$t) {
    if ($t -match '^([^:]+):\s*(.*)$') { return @($Matches[1].Trim(), $Matches[2].Trim()) }
    @('OBS', $t)
}

function Get-Kind([string]$type) {
    if ($type -eq 'ОК') { return 'ok' }
    if ($type -eq 'СТОРОЖ' -or $type -eq 'РЕЖИМ') { return 'service' }
    'fail'
}

# Кратко для колонки «Подробности»: вывод или причина + итог
function Get-Summary($it, [string]$type) {
    if ($type -eq 'ОТЧЁТ') {
        return (@($it.Lines | Where-Object { $_ -match '^\d\d:\d\d:\d\d' }) -join ';  ')
    }
    $main = $it.Lines | Where-Object { $_ -match '^(ВЫВОД|Причина|Ошибка|Сейчас)' } | Select-Object -First 1
    if (-not $main) { $main = $it.Lines | Select-Object -First 1 }
    $s = ([string]$main) -replace '^(ВЫВОД|Сейчас):\s*', ''
    $res = $it.Lines | Where-Object { $_ -match '^Итог' } | Select-Object -Last 1
    if ($res) { $s += '   →   ' + ($res -replace '^Итог:\s*', '') }
    $s
}

$journal = @()
$logStamp = ''
function Update-Journal([switch]$Force) {
    $stamp = ''
    if (Test-Path $LogFile) { $f = Get-Item $LogFile; $stamp = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)" }
    if (-not $Force -and $stamp -eq $script:logStamp) { return }
    $script:logStamp = $stamp
    $script:journal = Read-Journal

    $selNo = if ($grid.SelectedItems.Count) { $grid.SelectedItems[0].Tag.No } else { 0 }
    $grid.BeginUpdate()
    $grid.Items.Clear()
    for ($i = $script:journal.Count - 1; $i -ge 0; $i--) {     # новые сверху
        $it = $script:journal[$i]
        $type, $evt = Split-Title $it.Title
        $kind = Get-Kind $type
        $want = @('', 'fail', 'ok', 'service')[$filter.SelectedIndex]
        if ($want -and $kind -ne $want) { continue }
        $row = New-Object Windows.Forms.ListViewItem([string]$it.No)
        [void]$row.SubItems.Add($it.Time)
        [void]$row.SubItems.Add($type)
        [void]$row.SubItems.Add($evt)
        [void]$row.SubItems.Add((Get-Summary $it $type))
        $row.BackColor = switch ($kind) {
            'ok'    { [Drawing.Color]::Honeydew }
            'fail'  { [Drawing.Color]::MistyRose }
            default { [Drawing.Color]::WhiteSmoke }
        }
        $row.Tag = $it
        [void]$grid.Items.Add($row)
        if ($it.No -eq $selNo) { $row.Selected = $true }
    }
    $grid.EndUpdate()
    if ($grid.Items.Count -eq 0) { $detail.Text = 'Записей нет.' }
}

$grid.Add_SelectedIndexChanged({
    if ($grid.SelectedItems.Count -eq 0) { return }
    $it = $grid.SelectedItems[0].Tag
    $detail.Text = (@("№ $($it.No)   ·   $($it.Time)   ·   $($it.Title)", '') + @($it.Lines)) -join "`r`n"
})

$filter.Add_SelectedIndexChanged({ Update-Journal -Force })

$export.Add_Click({
    $csv = Join-Path $Dir 'incidents.csv'
    try {
        $rows = foreach ($it in (Read-Journal)) {
            $type, $evt = Split-Title $it.Title
            [pscustomobject]@{
                '№'            = $it.No
                'Дата и время' = $it.Time
                'Тип'          = $type
                'Событие'      = $evt
                'Кратко'       = Get-Summary $it $type
                'Подробности'  = ($it.Lines -join '  |  ')
            }
        }
        $rows | Export-Csv -Path $csv -NoTypeInformation -Delimiter ';' -Encoding UTF8
        Start-Process $csv
    } catch {
        [Windows.Forms.MessageBox]::Show("Не удалось сохранить таблицу (возможно, она уже открыта в Excel):`n$($_.Exception.Message)", 'Сторож OBS') | Out-Null
    }
})

function Update-View {
    $p = Get-WatchdogProcess
    $ws = $null
    try { $ws = Get-Content $WsConfig -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if (-not $p) {
        $status.Text = 'Сторож выключен'; $status.ForeColor = [Drawing.Color]::Firebrick
        $toggle.Text = 'Включить сторожа'
    } elseif ($ws -and -not $ws.server_enabled) {
        $status.Text = "Сторож работает, но в OBS выключен WebSocket`n(OBS: Инструменты → Настройки сервера WebSocket)"
        $status.ForeColor = [Drawing.Color]::DarkOrange
        $toggle.Text = 'Выключить сторожа'
    } else {
        $status.Text = 'Сторож работает'; $status.ForeColor = [Drawing.Color]::ForestGreen
        $toggle.Text = 'Выключить сторожа'
    }

    # Строка живого состояния
    $live.ForeColor = [Drawing.Color]::Black
    try {
        if (-not $p) { throw 'off' }
        $st = Get-Content $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $at = [datetime]$st.Time
        $age = ((Get-Date) - $at).TotalSeconds
        $net = if ($null -eq $st.NetOk) { 'не проверяется' } elseif ($st.NetOk) { "есть ($($st.NetMs) мс)" } else { 'НЕТ' }
        $cam = if ($null -eq $st.CamOk) { 'не проверяется' } elseif ($st.CamOk) { "отвечает ($($st.CamMs) мс)" } else { 'НЕ ОТВЕЧАЕТ' }
        $gpu = if ($st.Gpu -gt 0) { " · Видеокарта: $($st.Gpu) °C" } else { '' }
        $live.Text = "Проверено $($at.ToString('HH:mm:ss')) · Трансляция: $($st.Stream)`r`nИнтернет: $net · Камера: $cam$gpu"
        if ($age -gt ((Get-Settings).CheckSec * 2 + 15)) {
            $live.Text = "Нет свежих данных от сторожа (последние в $($at.ToString('HH:mm:ss')))"
            $live.ForeColor = [Drawing.Color]::DarkOrange
        } elseif ($st.Stream -match 'ПЕРЕПОДКЛ|нет данных' -or $st.NetOk -eq $false -or $st.CamOk -eq $false) {
            $live.ForeColor = [Drawing.Color]::Firebrick
        }
    } catch {
        $live.Text = if ($p) { 'Ждём первую проверку…' } else { '' }
    }

    Update-Journal
}

$save.Add_Click({
    # Берём текущие настройки и меняем только поля из этого блока (кнопки-режимы не трогаем)
    $s = Get-Settings
    $s.CheckSec = [int]$numCheck.Value; $s.StuckSec = [int]$numStuck.Value; $s.KeepDays = [int]$numKeep.Value
    $s.ReportMin = [int]$numReport.Value; $s.SkipPct = [int]$numSkip.Value; $s.PingEnabled = $chkPing.Checked
    $s.CameraPing = $chkCam.Checked; $s.CameraHost = $txtCam.Text.Trim(); $s.PingFails = [int]$numFails.Value
    Save-Settings $s
    [Windows.Forms.MessageBox]::Show('Настройки сохранены.', 'Сторож OBS') | Out-Null
})

$always.Add_Click({
    $s = Get-Settings
    $s.AlwaysOn = -not $s.AlwaysOn
    Save-Settings $s
    if ($s.AlwaysOn) { Write-LogBlock 'РЕЖИМ: «ВСЕГДА В ЭФИРЕ» ВКЛЮЧЁН' @('Сторож будет запускать трансляцию, даже если её выключили вручную') }
    else             { Write-LogBlock 'РЕЖИМ: «ВСЕГДА В ЭФИРЕ» ВЫКЛЮЧЕН' @('Ручная остановка трансляции уважается') }
    Update-AlwaysButton
})

$revive.Add_Click({
    $s = Get-Settings
    $s.AutoRevive = -not $s.AutoRevive
    Save-Settings $s
    if ($s.AutoRevive) { Write-LogBlock 'РЕЖИМ: АВТОЗАПУСК СТОРОЖА ВКЛЮЧЁН' @('Закрытый или упавший сторож поднимется сам в течение минуты') }
    else               { Write-LogBlock 'РЕЖИМ: АВТОЗАПУСК СТОРОЖА ВЫКЛЮЧЕН' @('Закрытый сторож останется закрытым до следующего входа в Windows') }
    Update-AlwaysButton
})

$toggle.Add_Click({
    $p = Get-WatchdogProcess
    $s = Get-Settings
    if ($p) {
        # Выключение кнопкой — настоящее: автовосстановление и автозапуск с Windows его уважают
        $s.Enabled = $false; Save-Settings $s
        Stop-Process -Id $p.ProcessId -Force
        Write-LogBlock 'СТОРОЖ: ВЫКЛЮЧЕН ВРУЧНУЮ' @('Кнопкой «Выключить сторожа» в окне. Трансляция, сеть и железо не проверяются, автозапуск сторожа не сработает')
    } else {
        $s.Enabled = $true; Save-Settings $s
        Start-Watchdog
        Write-LogBlock 'СТОРОЖ: ВКЛЮЧЕН ВРУЧНУЮ' @('Кнопкой «Включить сторожа» в окне')
    }
    Start-Sleep -Milliseconds 1500
    Update-View
})

$openLog.Add_Click({
    if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile | Out-Null }
    Start-Process notepad.exe -ArgumentList "`"$LogFile`""
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-View })
$timer.Start()

Update-AlwaysButton
Update-View
[void]$form.ShowDialog()
