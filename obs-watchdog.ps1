# Сторож трансляции OBS (работает скрыто, запускается при входе в Windows, всегда в одном экземпляре).
#
# Что делает:
#  1. Трансляция. Периодически спрашивает у OBS (obs-websocket) её состояние. Если трансляция
#     включена, но слишком долго висит в переподключении или не отправляет данные — перезапускает её.
#     Ручную остановку не трогает.
#  2. Провайдер. Отдельный поток раз в секунду пингует Google; при обрыве сразу проверяет роутер,
#     чтобы отличить проблему провайдера от локальной сети. Так же пингует камеру.
#  3. Железо и система. Раз в минуту читает журнал Windows: ошибки оборудования, сбросы драйвера
#     видеокарты, ошибки диска и сетевой карты, нехватка портов и памяти, падения OBS.
#     Следит за температурой видеокарты.
#
# Каждое событие пишется в incidents.log отдельным блоком с датой и подробностями.
# К записи о прерывании трансляции добавляется вывод: виноват интернет, компьютер или YouTube.
# Записи старше срока хранения удаляются. Настройки — settings.json (окно «Сторож OBS»).

param([switch]$Revived)   # -Revived: запущен автовосстановлением (revive.vbs)

$ErrorActionPreference = 'Stop'

$Dir          = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile      = Join-Path $Dir 'incidents.log'
$SettingsFile = Join-Path $Dir 'settings.json'
$PidFile      = Join-Path $Dir 'watchdog.pid'
$WsConfig     = "$env:APPDATA\obs-studio\plugin_config\obs-websocket\config.json"
$ObsLogDir    = "$env:APPDATA\obs-studio\logs"
$DateFmt      = 'dd.MM.yyyy HH:mm:ss'

# Не запускать вторую копию
$mutex = New-Object Threading.Mutex($false, 'Global\OBS-Watchdog')
if (-not $mutex.WaitOne(0)) { exit }

# Выключен кнопкой «Выключить сторожа» — не работать (в т.ч. при автозапуске с Windows)
try { if ((Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json).Enabled -eq $false) { exit } } catch {}

Set-Content -Path $PidFile -Value $PID

function Get-Settings {
    $s = @{ CheckSec = 30; StuckSec = 90; KeepDays = 30; AlwaysOn = $false; ReportMin = 10; SkipPct = 2 }
    try {
        $j = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.SkipPct -gt 0) { $s.SkipPct = [double]$j.SkipPct }
        if ($j.ReportMin -ge 1) { $s.ReportMin = [int]$j.ReportMin }
        if ($null -ne $j.AlwaysOn) { $s.AlwaysOn = [bool]$j.AlwaysOn }
        if ($j.CheckSec -ge 5)  { $s.CheckSec = [int]$j.CheckSec }
        if ($j.StuckSec -ge 30) { $s.StuckSec = [int]$j.StuckSec }
        if ($j.KeepDays -ge 1)  { $s.KeepDays = [int]$j.KeepDays }
    } catch {}
    $s
}

# Запись в журнал (из двух потоков, поэтому через общий замок)
function Write-Log([string[]]$lines) {
    $m = New-Object Threading.Mutex($false, 'OBS-Watchdog-Log')
    try { [void]$m.WaitOne(5000) } catch [Threading.AbandonedMutexException] {}
    try { Add-Content -Path $LogFile -Encoding UTF8 -Value $lines }
    finally { $m.ReleaseMutex(); $m.Dispose() }
}

function Start-Incident([string]$title, [string[]]$details, [datetime]$at = (Get-Date)) {
    [void]$shared.Events.Add("$($at.ToString('HH:mm:ss'))  $title")
    Write-Log (@('', "==== $($at.ToString($DateFmt)) ====  $title") + ($details | ForEach-Object { "  $_" }))
}

function Get-Duration([datetime]$since) {
    $t = (Get-Date) - $since
    if ($t.TotalMinutes -lt 1) { return "$([int]$t.TotalSeconds) с" }
    if ($t.TotalHours -lt 1)   { return "$([int][math]::Floor($t.TotalMinutes)) мин $($t.Seconds) с" }
    "$([int][math]::Floor($t.TotalHours)) ч $($t.Minutes) мин"
}

# Удалить блоки старше срока хранения
function Remove-OldIncidents([int]$days) {
    if (-not (Test-Path $LogFile)) { return }
    $limit = (Get-Date).AddDays(-$days)
    $keep = New-Object Collections.Generic.List[string]
    $take = $false
    foreach ($line in (Get-Content $LogFile -Encoding UTF8)) {
        if ($line -match '^==== (\d\d\.\d\d\.\d{4} \d\d:\d\d:\d\d) ====') {
            $take = [datetime]::ParseExact($Matches[1], $DateFmt, $null) -ge $limit
            if ($take) { $keep.Add('') }
        }
        if ($take -and $line -ne '') { $keep.Add($line) }
    }
    $m = New-Object Threading.Mutex($false, 'OBS-Watchdog-Log')
    try { [void]$m.WaitOne(5000) } catch [Threading.AbandonedMutexException] {}
    try { Set-Content -Path $LogFile -Encoding UTF8 -Value $keep }
    finally { $m.ReleaseMutex(); $m.Dispose() }
}

# ======================= 1. Журнал OBS: причина обрыва =======================

function Read-ObsLog {
    $f = Get-ChildItem $ObsLogDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
    $sr = New-Object IO.StreamReader($fs)
    $lines = $sr.ReadToEnd() -split "`r?`n"
    $sr.Close()
    , $lines
}

function Get-DisconnectCount {
    try { @((Read-ObsLog) | Where-Object { $_ -match 'Disconnected from' }).Count } catch { -1 }
}

# Возвращает @{ Lines = строки для журнала; Code = код ошибки; Hints = известные факторы риска }
function Get-DropDetails {
    $res = @{ Lines = @(); Code = ''; Hints = @() }
    try {
        $lines = Read-ObsLog

        # Настройки кодировщика из последнего запуска трансляции
        $fps = 0; $keyint = 0
        foreach ($l in $lines) {
            if ($l -match 'fps:\s+(\d+)/(\d+)') { $fps = [double]$Matches[1] / [double]$Matches[2] }
            if ($l -match 'keyint:\s+(\d+)')    { $keyint = [int]$Matches[1] }
        }
        if ($fps -gt 0 -and $keyint -gt 0 -and ($keyint / $fps) -gt 4) {
            $res.Hints += "ключевой кадр раз в $([math]::Round($keyint / $fps, 1)) с, а YouTube требует не реже 4 с (рекомендует 2 с)"
        }

        $idx = -1
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match 'Disconnected from') { $idx = $i; break } }
        if ($idx -lt 0) {
            $res.Lines = @('Ошибка: данные перестали уходить, OBS ошибку не сообщил')
            return $res
        }

        $from = [math]::Max(0, $idx - 6)
        $to   = [math]::Min($lines.Count - 1, $idx + 8)
        $raw  = $lines[$from..$to] | Where-Object { $_ -match 'error|GetSockError|Disconnected|dropped|lagged|Total frames' }

        $text = $raw -join "`n"
        $m = [regex]::Matches($text, '(?:GetSockError\(\): |send error )(\d+)')
        if ($m.Count -gt 0) { $res.Code = $m[0].Groups[1].Value }
        $what = switch ($res.Code) {
            '10054' { 'сервер YouTube разорвал соединение' }
            '10053' { 'соединение прервалось по пути (сеть, роутер, провайдер)' }
            '10060' { 'сервер не отвечает, таймаут' }
            '10065' { 'нет маршрута в интернет' }
            '10051' { 'сеть недоступна' }
            ''      { 'неизвестна' }
            default { 'сетевая ошибка' }
        }
        $codeText = if ($res.Code) { " (код $($res.Code))" } else { '' }

        if ($text -match 'dropped frames due to insufficient bandwidth[^(]*\((\d+(?:\.\d+)?)%\)' -and [double]$Matches[1] -ge 1) {
            $res.Hints += "OBS терял кадры из-за нехватки канала: $($Matches[1])%"
        }
        if ($text -match 'lagged frames due to rendering lag[^(]*\((\d+(?:\.\d+)?)%\)' -and [double]$Matches[1] -ge 5) {
            $res.Hints += "компьютер не успевал отрисовывать кадры: $($Matches[1])%"
        }

        $res.Lines = @("Ошибка: $what$codeText", 'Из журнала OBS:') + ($raw | ForEach-Object { "  $($_.Trim())" })
    } catch {
        $res.Lines = @('Ошибка: не удалось прочитать журнал OBS')
    }
    $res
}

# ======================= 2. Сеть: отдельный поток пингов =======================

$PingLoop = {
    param($shared, $LogFile, $SettingsFile, $DateFmt)

    function Write-Log([string[]]$lines) {
        $m = New-Object Threading.Mutex($false, 'OBS-Watchdog-Log')
        try { [void]$m.WaitOne(5000) } catch [Threading.AbandonedMutexException] {}
        try { Add-Content -Path $LogFile -Encoding UTF8 -Value $lines }
        finally { $m.ReleaseMutex(); $m.Dispose() }
    }
    function Get-Duration([datetime]$since) {
        $t = (Get-Date) - $since
        if ($t.TotalMinutes -lt 1) { return "$([int]$t.TotalSeconds) с" }
        if ($t.TotalHours -lt 1)   { return "$([int][math]::Floor($t.TotalMinutes)) мин $($t.Seconds) с" }
        "$([int][math]::Floor($t.TotalHours)) ч $($t.Minutes) мин"
    }
    function Test-Router {
        try {
            $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1).NextHop
        } catch { return 'Роутер: адрес не определён — у компьютера нет сетевого подключения (кабель, сетевая карта)' }
        $p = New-Object Net.NetworkInformation.Ping
        foreach ($i in 1..3) {
            try { if ($p.Send($gw, 500).Status -eq 'Success') {
                return "Роутер ($gw) отвечает — значит, обрыв у ПРОВАЙДЕРА или дальше" } } catch {}
        }
        "Роутер ($gw) НЕ отвечает — проблема в роутере, кабеле или сетевой карте компьютера"
    }

    # Состояние каждой цели: сколько подряд не ответила, с какого момента нет связи
    $targets = @{
        Net = @{ Host = '8.8.8.8';        On = $true; Fails = 0; Lost = 0; Down = $null }
        Cam = @{ Host = '192.168.100.20'; On = $true; Fails = 0; Lost = 0; Down = $null }
    }
    $need = 3
    $cfgAt = [datetime]::MinValue

    while ($true) {
        $tick = Get-Date
        if (($tick - $cfgAt).TotalSeconds -ge 10) {
            try {
                $j = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $j.PingEnabled) { $targets.Net.On = [bool]$j.PingEnabled }
                if ($j.PingHost)              { $targets.Net.Host = [string]$j.PingHost }
                if ($null -ne $j.CameraPing)  { $targets.Cam.On = [bool]$j.CameraPing }
                if ($j.CameraHost)            { $targets.Cam.Host = [string]$j.CameraHost }
                if ($j.PingFails -ge 2)       { $need = [int]$j.PingFails }
            } catch {}
            $cfgAt = $tick
        }

        # Пингуем все включённые цели одновременно
        $tasks = @{}
        foreach ($k in $targets.Keys) {
            $t = $targets[$k]
            if ($t.On) {
                try { $tasks[$k] = (New-Object Net.NetworkInformation.Ping).SendPingAsync($t.Host, 1000) } catch {}
            } else {
                $shared["${k}Ok"] = $null
                if ($t.Down) {
                    Write-Log "  Итог: проверку выключили в $(Get-Date -Format $DateFmt), связи не было $(Get-Duration $t.Down)"
                    $t.Down = $null; $t.Fails = 0
                }
            }
        }
        foreach ($k in @($tasks.Keys)) { try { [void]$tasks[$k].Wait(1500) } catch {} }

        foreach ($k in $targets.Keys) {
            $t = $targets[$k]
            if (-not $t.On) { continue }
            $ok = $false; $ms = -1
            try {
                $r = $tasks[$k].Result
                if ($r.Status -eq 'Success') { $ok = $true; $ms = [int]$r.RoundtripTime }
            } catch {}

            if ($k -eq 'Net') {
                $shared.Recent.Enqueue(@($ok, $ms))
                while ($shared.Recent.Count -gt 120) { [void]$shared.Recent.Dequeue() }
            }
            $shared["${k}Ok"] = $ok
            $shared["${k}Ms"] = $ms

            if ($ok) {
                if ($t.Down) {
                    $what = if ($k -eq 'Net') { 'интернет вернулся' } else { 'камера снова отвечает' }
                    Write-Log "  Итог: $what в $(Get-Date -Format $DateFmt), не было связи $(Get-Duration $t.Down), потеряно пингов: $($t.Lost)"
                    $t.Down = $null
                    if ($k -eq 'Net') { $shared.NetDownSince = $null } else { $shared.CamDownSince = $null }
                }
                $t.Fails = 0
            } else {
                $t.Fails++
                if ($t.Down) { $t.Lost++ }
                elseif ($t.Fails -ge $need) {
                    $t.Down = $tick.AddSeconds(-($t.Fails - 1))
                    $t.Lost = $t.Fails
                    if ($k -eq 'Net') {
                        $shared.NetDownSince = $t.Down
                        [void]$shared.Events.Add("$($t.Down.ToString('HH:mm:ss'))  ПРОВАЙДЕР / СЕТЬ: ПРОПАЛ ИНТЕРНЕТ")
                        Write-Log @('', "==== $($t.Down.ToString($DateFmt)) ====  ПРОВАЙДЕР / СЕТЬ: ПРОПАЛ ИНТЕРНЕТ",
                            "  Пинг до Google ($($t.Host)) не проходит $($t.Fails) с подряд",
                            "  $(Test-Router)")
                    } else {
                        $shared.CamDownSince = $t.Down
                        [void]$shared.Events.Add("$($t.Down.ToString('HH:mm:ss'))  ЖЕЛЕЗО: КАМЕРА НЕ ОТВЕЧАЕТ")
                        Write-Log @('', "==== $($t.Down.ToString($DateFmt)) ====  ЖЕЛЕЗО: КАМЕРА НЕ ОТВЕЧАЕТ",
                            "  Камера ($($t.Host)) не отвечает на пинг $($t.Fails) с подряд",
                            "  Проверьте питание камеры, кабель и коммутатор (PoE)")
                    }
                }
            }
        }

        $wait = 1000 - ((Get-Date) - $tick).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
    }
}

$shared = [hashtable]::Synchronized(@{
    Recent       = [Collections.Queue]::Synchronized((New-Object Collections.Queue))
    NetDownSince = $null
    CamDownSince = $null
    Events       = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))   # сбои с последнего отчёта
})
$pingThread = $null
$pingHandle = $null
function Start-PingThread {
    if ($script:pingThread) { try { $script:pingThread.Dispose() } catch {} }
    $script:pingThread = [PowerShell]::Create()
    [void]$script:pingThread.AddScript($PingLoop).AddArgument($shared).AddArgument($LogFile).AddArgument($SettingsFile).AddArgument($DateFmt)
    $script:pingHandle = $script:pingThread.BeginInvoke()
}

# Сеть за последние 2 минуты: @{ Text; Bad }
function Get-NetSummary {
    $a = $shared.Recent.ToArray()
    if ($a.Count -eq 0) { return @{ Text = 'Сеть: проверка пингом выключена'; Bad = $false } }
    $lost = @($a | Where-Object { -not $_[0] }).Count
    $max  = ($a | Where-Object { $_[0] } | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum
    $now  = if ($shared.NetDownSince) { "интернета НЕТ с $($shared.NetDownSince.ToString('HH:mm:ss'))" } else { 'интернет есть' }
    @{
        Text = "Сеть (пинг Google) за последние $($a.Count) с: потеряно $lost, макс. задержка $([int]$max) мс; сейчас $now"
        Bad  = ($lost -ge 3 -or $shared.NetDownSince)
    }
}

# ======================= 3. Железо и система: журнал Windows =======================

$HwFilters = @(
    @{ Log = 'System'; Provider = 'Microsoft-Windows-WHEA-Logger';                  What = 'аппаратная ошибка (процессор, память, PCIe)' }
    @{ Log = 'System'; Provider = 'nvlddmkm';                                       What = 'сбой драйвера видеокарты NVIDIA' }
    @{ Log = 'System'; Provider = 'Display';                                        What = 'драйвер видеокарты перестал отвечать и был перезапущен' }
    @{ Log = 'System'; Provider = 'Microsoft-Windows-Kernel-Power'; Id = 41;        What = 'компьютер перезагрузился аварийно (питание, зависание, синий экран)' }
    @{ Log = 'System'; Provider = 'disk';                                           What = 'ошибка диска' }
    @{ Log = 'System'; Provider = 'Ntfs';                                           What = 'ошибка файловой системы' }
    @{ Log = 'System'; Provider = 'stornvme';                                       What = 'ошибка NVMe-диска' }
    @{ Log = 'System'; Provider = 'storahci';                                       What = 'ошибка SATA-диска' }
    @{ Log = 'System'; Provider = 'rtcx21';                                         What = 'сетевая карта Realtek: ошибка или пропадание связи по кабелю' }
    @{ Log = 'System'; Provider = 'Microsoft-Windows-NDIS';                         What = 'сбой сетевого адаптера' }
    @{ Log = 'System'; Provider = 'Tcpip'; Id = 4231, 4266;                         What = 'в Windows закончились сетевые порты — новые соединения (в т.ч. к YouTube) не открываются' }
    @{ Log = 'System'; Provider = 'Microsoft-Windows-Resource-Exhaustion-Detector'; What = 'не хватает оперативной памяти' }
    @{ Log = 'Application'; Provider = 'Application Error'; Match = 'obs64';        What = 'OBS аварийно завершился' }
    @{ Log = 'Application'; Provider = 'Application Hang';  Match = 'obs64';        What = 'OBS завис' }
)

$hwRecent = New-Object Collections.Generic.List[object]   # события за последние 15 минут: @{ Time; What }
$hwLastCheck = Get-Date
$gpuHot = $false

function Test-Hardware {
    $since = $script:hwLastCheck
    $script:hwLastCheck = Get-Date
    $found = @()
    foreach ($f in $HwFilters) {
        $q = @{ LogName = $f.Log; ProviderName = $f.Provider; StartTime = $since }
        if ($f.Id) { $q.Id = $f.Id } elseif ($f.Log -eq 'System') { $q.Level = 1, 2, 3 }
        $ev = @(Get-WinEvent -FilterHashtable $q -ErrorAction SilentlyContinue)
        if ($f.Match) { $ev = @($ev | Where-Object { $_.Message -match $f.Match }) }
        foreach ($e in $ev) {
            $msg = ''
            try { $msg = (($e.Message -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1).Trim() } catch {}
            if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) + '…' }
            $found += @{ Time = $e.TimeCreated; What = $f.What; Detail = "$($f.Provider), событие $($e.Id)$(if ($msg) { ": $msg" })" }
        }
    }

    # Температура видеокарты
    try {
        $t = [int](& nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        $script:gpuTemp = $t
        if ($t -ge 83 -and -not $script:gpuHot) {
            $script:gpuHot = $true
            $found += @{ Time = Get-Date; What = 'видеокарта перегревается'; Detail = "температура $t °C" }
        } elseif ($t -gt 0 -and $t -lt 75 -and $script:gpuHot) {
            $script:gpuHot = $false
            Write-Log "  $(Get-Date -Format $DateFmt)  Видеокарта остыла: $t °C"
        }
    } catch {}

    foreach ($x in ($found | Sort-Object { $_.Time })) {
        Start-Incident "ЖЕЛЕЗО / СИСТЕМА: $($x.What)" @($x.Detail) $x.Time
        $script:hwRecent.Add($x)
    }
    $limit = (Get-Date).AddMinutes(-15)
    $old = @($script:hwRecent | Where-Object { $_.Time -lt $limit })
    foreach ($x in $old) { [void]$script:hwRecent.Remove($x) }
}

# ======================= Вывод: кто виноват =======================

function Get-Verdict($drop, $net) {
    $lines = @()
    $hw = @($script:hwRecent | Where-Object { $_.Time -ge (Get-Date).AddMinutes(-10) })
    if ($net.Bad) {
        $lines += 'ВЫВОД: обрыв из-за интернета — см. запись «ПРОВАЙДЕР / СЕТЬ» рядом (там видно, роутер или провайдер)'
    } elseif ($hw.Count -gt 0) {
        $lines += "ВЫВОД: интернет в порядке, но за 10 минут до обрыва был сбой компьютера: $(($hw | ForEach-Object { $_.What } | Select-Object -Unique) -join '; ')"
    } elseif ($drop.Code -eq '10054') {
        $lines += 'ВЫВОД: интернет и компьютер в порядке — соединение закрыл сам YouTube'
        $lines += 'Точную причину YouTube показывает в YouTube Studio → Трансляция → «Состояние потока»'
    } elseif ($drop.Code -eq '10053') {
        $lines += 'ВЫВОД: Google пингуется, но соединение оборвалось по пути — вероятно, кратковременный сбой у провайдера или роутера'
    } else {
        $lines += 'ВЫВОД: явной причины не найдено — интернет и компьютер в порядке'
    }
    foreach ($h in $drop.Hints) { $lines += "Фактор риска: $h" }
    $lines
}

# ======================= OBS WebSocket =======================

function Send-Json($ws, $obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))
    [void]$ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Receive-Json($ws) {
    $buf = New-Object byte[] 65536
    $ms  = New-Object IO.MemoryStream
    $cts = New-Object Threading.CancellationTokenSource 10000
    do {
        $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).GetAwaiter().GetResult()
        if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
            throw 'OBS закрыл соединение со сторожем (проверьте пароль WebSocket)'
        }
        $ms.Write($buf, 0, $r.Count)
    } while (-not $r.EndOfMessage)
    [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}

function Connect-Obs {
    $cfg = Get-Content $WsConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.server_enabled) { throw 'в OBS выключен сервер WebSocket' }
    $ws = New-Object Net.WebSockets.ClientWebSocket
    [void]$ws.ConnectAsync([Uri]"ws://127.0.0.1:$($cfg.server_port)",
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $hello = Receive-Json $ws
    $identify = @{ op = 1; d = @{ rpcVersion = 1; eventSubscriptions = 0 } }
    if ($hello.d.authentication) {
        $sha    = [Security.Cryptography.SHA256]::Create()
        $utf8   = [Text.Encoding]::UTF8
        $secret = [Convert]::ToBase64String($sha.ComputeHash($utf8.GetBytes($cfg.server_password + $hello.d.authentication.salt)))
        $identify.d.authentication = [Convert]::ToBase64String($sha.ComputeHash($utf8.GetBytes($secret + $hello.d.authentication.challenge)))
    }
    Send-Json $ws $identify
    if ((Receive-Json $ws).op -ne 2) { throw 'OBS не принял подключение сторожа' }
    $ws
}

$script:ReqId = 0
function Invoke-Obs($ws, [string]$type) {
    $script:ReqId++
    $id = [string]$script:ReqId
    Send-Json $ws @{ op = 6; d = @{ requestType = $type; requestId = $id } }
    while ($true) {
        $m = Receive-Json $ws
        if ($m.op -eq 7 -and $m.d.requestId -eq $id) {
            if (-not $m.d.requestStatus.result) { throw "$type не выполнен: $($m.d.requestStatus.comment)" }
            return $m.d.responseData
        }
    }
}

function Restart-Stream($ws) {
    Invoke-Obs $ws 'StopStream' | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep 1
        if (-not (Invoke-Obs $ws 'GetStreamStatus').outputActive) { break }
    }
    Start-Sleep 3
    Invoke-Obs $ws 'StartStream' | Out-Null
}

# ======================= Живое состояние для окна (status.json, в журнал не пишется) =======================

$StatusFile = Join-Path $Dir 'status.json'
$gpuTemp = 0
$rateBytes = -1
$rateAt = $null

function Save-Status([string]$stream) {
    $st = @{
        Time   = (Get-Date).ToString('o')
        Stream = $stream
        NetOk  = $shared.NetOk;  NetMs = $shared.NetMs
        CamOk  = $shared.CamOk;  CamMs = $shared.CamMs
        Gpu    = $script:gpuTemp
    }
    $tmp = "$StatusFile.tmp"
    $st | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding UTF8
    Move-Item $tmp $StatusFile -Force
}

function Get-StreamText($s) {
    if (-not $s.outputActive) { $script:rateBytes = -1; return 'выключена' }
    $dur = [TimeSpan]::FromMilliseconds([double]$s.outputDuration)
    $txt = "идёт {0}:{1:mm}:{1:ss}" -f [int][math]::Floor($dur.TotalHours), $dur
    $now = Get-Date
    if ($script:rateBytes -ge 0 -and $s.outputBytes -ge $script:rateBytes) {
        $sec = ($now - $script:rateAt).TotalSeconds
        if ($sec -gt 0) { $txt += ', {0:N1} Мбит/с' -f (($s.outputBytes - $script:rateBytes) * 8 / $sec / 1e6) }
    }
    $script:rateBytes = $s.outputBytes
    $script:rateAt = $now
    if ($s.outputReconnecting) { $txt = 'ПЕРЕПОДКЛЮЧАЕТСЯ' }
    $txt
}

# ---------- Пропуск кадров: счётчики OBS между отчётами ----------
# Render — видеокарта не успела отрисовать кадр, Encode — кодировщик не успел,
# Net — кадр не ушёл в сеть. Любой пропуск = YouTube получает меньше 25 кадров/с.
$frmBase = $null
$frmLast = $null

function Get-FrameSnapshot($ws, $s) {
    $g = Invoke-Obs $ws 'GetStats'
    @{
        RS = [double]$g.renderSkippedFrames; RT = [double]$g.renderTotalFrames
        ES = [double]$g.outputSkippedFrames; ET = [double]$g.outputTotalFrames
        NS = [double]$s.outputSkippedFrames; NT = [double]$s.outputTotalFrames
        Cpu = [double]$g.cpuUsage
    }
}

function Get-FrameStats($a, $b) {
    if (-not $a -or -not $b) { return $null }
    $rt = $b.RT - $a.RT; $et = $b.ET - $a.ET; $nt = $b.NT - $a.NT
    if ($rt -le 0 -or $et -lt 0) { return $null }
    if ($nt -lt 0) { $nt = $b.NT; $ns = $b.NS } else { $ns = $b.NS - $a.NS }   # стрим перезапускался — счётчик сети обнулился
    @{
        Render = 100 * ($b.RS - $a.RS) / $rt
        Encode = if ($et -gt 0) { 100 * ($b.ES - $a.ES) / $et } else { 0 }
        Net    = if ($nt -gt 0) { 100 * $ns / $nt } else { 0 }
        Cpu    = $b.Cpu
    }
}

function Format-FrameStats($f) {
    if (-not $f) { return 'кадры: нет данных' }
    'кадры пропущены: отрисовка {0:N1}% · кодирование {1:N1}% · сеть {2:N1}%' -f $f.Render, $f.Encode, $f.Net
}

# Если пропусков больше порога — отдельная запись о проблеме (до отчёта, чтобы попала в его список)
function Test-FrameSkips($f, [double]$limit, [int]$minutes) {
    if (-not $f) { return }
    $worst = [math]::Max($f.Render, [math]::Max($f.Encode, $f.Net))
    if ($worst -lt $limit) { return }
    $gpu = ''
    try { $gpu = (& nvidia-smi --query-gpu=utilization.gpu,utilization.encoder,temperature.gpu --format=csv,noheader 2>$null | Select-Object -First 1) } catch {}
    if ($f.Net -ge $worst) {
        $type = 'ПРОВАЙДЕР / СЕТЬ'
        $verdict = 'ВЫВОД: кадры не успевают уходить в интернет — не хватает исходящего канала или сбоит провайдер'
    } else {
        $type = 'ЖЕЛЕЗО / СИСТЕМА'
        $verdict = 'ВЫВОД: компьютер не успевает ' + $(if ($f.Render -ge $f.Encode) { 'отрисовывать кадры (перегружена видеокарта: сцена, браузерный источник, разрешение)' } else { 'кодировать кадры (перегружен кодировщик: пресет, разрешение)' })
    }
    Start-Incident ("{0}: ПРОПУСК КАДРОВ {1:N1}% ЗА {2} МИН" -f $type, $worst, $minutes) @(
        $verdict,
        (Format-FrameStats $f),
        ('Загрузка процессора OBS: {0:N0}%' -f $f.Cpu),
        "Видеокарта (загрузка, кодировщик, температура): $gpu",
        'YouTube в это время показывает «видео поступает недостаточно быстро» и буферизует у зрителей'
    )
}

# Периодический отчёт: «всё хорошо» или список сбоев за период
function Write-Report([int]$minutes, [string]$stream) {
    $events = @($shared.Events.ToArray())
    $shared.Events.Clear()
    $net = if ($null -eq $shared.NetOk) { 'не проверяется' } elseif ($shared.NetOk) { "есть ($($shared.NetMs) мс)" } else { 'НЕТ' }
    $cam = if ($null -eq $shared.CamOk) { 'не проверяется' } elseif ($shared.CamOk) { "отвечает ($($shared.CamMs) мс)" } else { 'НЕ ОТВЕЧАЕТ' }
    $now = "Сейчас: трансляция $stream · интернет $net · камера $cam$(if ($script:gpuTemp -gt 0) { " · видеокарта $($script:gpuTemp) °C" })"
    if ($script:reportFrames) { $now += " · $(Format-FrameStats $script:reportFrames)" }
    $title = if ($events.Count -eq 0) { "ОК: за $minutes мин сбоев не было" } else { "ОТЧЁТ: за $minutes мин сбоев — $($events.Count) (подробности в записях выше)" }
    Write-Log (@('', "==== $(Get-Date -Format $DateFmt) ====  $title") + ($events | ForEach-Object { "  $_" }) + "  $now")
}

# ======================= Главный цикл =======================

Start-PingThread
if ($Revived) {
    $details = @('Сторож закрыли не кнопкой в окне (Диспетчер задач, завершение процесса) или он упал')
    try {
        $last = [datetime]((Get-Content $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json).Time)
        $details += "Последний раз работал: $($last.ToString($DateFmt)), не работал около $(Get-Duration $last)"
    } catch {}
    $details += 'Автозапуск сторожа: Планировщик Windows запустил его снова'
    Start-Incident 'СТОРОЖ: БЫЛ ЗАКРЫТ — ЗАПУЩЕН СНОВА' $details
}

$ws = $null
$incident = $null      # время начала текущего прерывания
$stuckSince = $null    # с какого момента трансляция стоит после последней попытки
$restarts = 0
$lastBytes = -1
$knownDrops = -1
$wasStreaming = $false
$lastErr = ''
$errSince = $null
$lastCleanup = [datetime]::MinValue
$lastHw = [datetime]::MinValue
$startErr = ''
$lastReport = Get-Date

while ($true) {
    $cfg = Get-Settings
    try {
        if (((Get-Date) - $lastCleanup).TotalHours -ge 24) { Remove-OldIncidents $cfg.KeepDays; $lastCleanup = Get-Date }
        if ($pingHandle.IsCompleted) { Start-PingThread }
        if (((Get-Date) - $lastHw).TotalSeconds -ge 60) { Test-Hardware; $lastHw = Get-Date }
    } catch {}

    try {
        if (-not $ws -or $ws.State -ne [Net.WebSockets.WebSocketState]::Open) {
            if (-not (Get-Process obs64 -ErrorAction SilentlyContinue)) {
                if ($wasStreaming) { throw 'OBS закрылся во время трансляции' }
                throw 'OBS не запущен'
            }
            $ws = Connect-Obs
            $lastBytes = -1
        }

        $s = Invoke-Obs $ws 'GetStreamStatus'
        if ($lastErr) {
            Write-Log "  Итог: $(Get-Date -Format $DateFmt) сторож снова видит OBS (недоступен был $(Get-Duration $errSince))"
            $lastErr = ''
        }
        $wasStreaming = [bool]$s.outputActive
        $streamText = Get-StreamText $s
        try {
            $frmLast = Get-FrameSnapshot $ws $s
            if (-not $frmBase) { $frmBase = $frmLast }
        } catch {}

        if (-not $s.outputActive) {
            if ($incident) {
                Write-Log "  Итог: трансляцию остановили вручную в $(Get-Date -Format $DateFmt), простой $(Get-Duration $incident)"
                $incident = $null
            }
            $lastBytes = -1
            $knownDrops = -1

            # Режим «Всегда в эфире»: запускаем трансляцию, даже если её выключили вручную
            if ($cfg.AlwaysOn) {
                try {
                    Invoke-Obs $ws 'StartStream' | Out-Null
                    Start-Incident 'YOUTUBE: ТРАНСЛЯЦИЯ БЫЛА ВЫКЛЮЧЕНА' @('Режим «Всегда в эфире»: сторож запустил трансляцию')
                    $startErr = ''
                    $streamText = 'запускается'
                } catch {
                    $e = $_.Exception.Message
                    if ($e -ne $startErr) {
                        Start-Incident 'YOUTUBE: СТОРОЖ НЕ СМОГ ЗАПУСТИТЬ ТРАНСЛЯЦИЮ' @("Причина: $e")
                        $startErr = $e
                    }
                }
            }
        } else {
            $drops = Get-DisconnectCount
            $newDrop = ($knownDrops -ge 0 -and $drops -gt $knownDrops)
            $knownDrops = $drops
            $bad = $s.outputReconnecting -or ($s.outputBytes -eq $lastBytes)
            $lastBytes = $s.outputBytes

            if (($bad -or $newDrop) -and -not $incident) {
                $incident = Get-Date
                $stuckSince = $incident
                $restarts = 0
                try { Test-Hardware; $lastHw = Get-Date } catch {}
                $drop = Get-DropDetails
                $net  = Get-NetSummary
                $frames = "Перед обрывом (с последнего отчёта): $(Format-FrameStats (Get-FrameStats $frmBase $frmLast))"
                Start-Incident 'YOUTUBE: ПРЕРЫВАНИЕ ТРАНСЛЯЦИИ' (@(Get-Verdict $drop $net) + $drop.Lines + $net.Text + $frames)
            }

            if ($incident -and $bad) {
                if (((Get-Date) - $stuckSince).TotalSeconds -ge $cfg.StuckSec) {
                    $restarts++
                    Write-Log "  $(Get-Date -Format $DateFmt)  OBS не переподключился за $(Get-Duration $stuckSince) — сторож перезапускает трансляцию (попытка $restarts)"
                    try { Restart-Stream $ws }
                    catch { Write-Log "  $(Get-Date -Format $DateFmt)  Перезапуск не удался: $($_.Exception.Message)" }
                    $stuckSince = Get-Date
                    $lastBytes = -1
                }
            } elseif ($incident) {
                $how = if ($restarts -gt 0) { "после перезапуска сторожем ($restarts)" } else { 'OBS переподключился сам' }
                Write-Log "  Итог: трансляция снова идёт в $(Get-Date -Format $DateFmt), $how, простой $(Get-Duration $incident)"
                $incident = $null
            }
        }
    } catch {
        $err = $_.Exception.Message
        if ($err -ne $lastErr) {
            if (-not $lastErr) { $errSince = Get-Date }
            $title = if ($err -eq 'OBS закрылся во время трансляции') { 'OBS: ЗАКРЫЛСЯ ВО ВРЕМЯ ТРАНСЛЯЦИИ' } else { 'OBS: СТОРОЖ НЕ МОЖЕТ ПРОВЕРИТЬ OBS' }
            Start-Incident $title @("Причина: $err")
            $lastErr = $err
        }
        if ($ws) { try { $ws.Dispose() } catch {} }
        $ws = $null
        $streamText = "нет данных — $err"
        $rateBytes = -1
    }
    try { Save-Status $streamText } catch {}
    if (((Get-Date) - $lastReport).TotalMinutes -ge $cfg.ReportMin) {
        $mins = [int][math]::Round(((Get-Date) - $lastReport).TotalMinutes)
        $reportFrames = $null
        if ($wasStreaming) {
            $reportFrames = Get-FrameStats $frmBase $frmLast
            try { Test-FrameSkips $reportFrames $cfg.SkipPct $mins } catch {}
        }
        try { Write-Report $mins $streamText } catch {}
        $frmBase = $frmLast
        $lastReport = Get-Date
    }
    Start-Sleep $cfg.CheckSec
}
