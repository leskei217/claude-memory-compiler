#Requires -Version 7
<#
.SYNOPSIS
    Ретроспективная компиляция исторических сессий Claude Code в базу знаний.
    Сканирует JSONL-транскрипты из ~/.claude/projects/ и добавляет их в daily-логи,
    затем компилирует изменённые логи в статьи knowledge base.

.PARAMETER Mode
    Fast    — скрипт сам пишет реплики в daily-лог; compile делает 1 API-вызов на день.
    Quality — Claude суммаризирует каждую сессию (как flush); потом compile. ~1 вызов на сессию.
    По умолчанию: Fast

.PARAMETER Projects
    Фильтр по имени папки проекта (подстрока). Несколько значений — через запятую.
    Пусто = все проекты.

.PARAMETER MinTurns
    Минимальное число реплик (user+assistant) для включения сессии. По умолчанию: 3.

.PARAMETER Since
    Обрабатывать только сессии начиная с этой даты (YYYY-MM-DD). По умолчанию: всё время.
    Дата сессии берётся по времени последней записи транскрипта (LastWriteTime), а не по
    внутренним таймстампам реплик — этим же временем датируется и daily-лог.

.PARAMETER Limit
    Максимальное число сессий за один запуск (защита от долгого выполнения).
    0 = без ограничений. По умолчанию: 0.

.PARAMETER BatchSize
    Размер батча: после каждых N сессий выводится краткий отчёт о прогрессе.
    По умолчанию: 5. Игнорируется при -NoBatch.

.PARAMETER NoBatch
    Отключить батч-режим: обработать все сессии без промежуточных отчётов.

.PARAMETER DryRun
    Показать что будет обработано — без записи файлов и API-вызовов.

.PARAMETER Force
    Повторно обработать сессии, уже отмеченные в retro-processed.json.

.PARAMETER NoCompile
    Только заполнить daily-логи, без финального шага compile.ps1.

.EXAMPLE
    # Пробный запуск — посмотреть что будет
    pwsh -File scripts\retrocompile.ps1 -DryRun

    # Быстрый режим, все проекты (батч по 5)
    pwsh -File scripts\retrocompile.ps1

    # Батч по 10 сессий
    pwsh -File scripts\retrocompile.ps1 -BatchSize 10

    # Без батч-режима (обработать всё без промежуточных отчётов)
    pwsh -File scripts\retrocompile.ps1 -NoBatch

    # Качественный режим, ограничен 20 сессиями за раз
    pwsh -File scripts\retrocompile.ps1 -Mode Quality -Limit 20

    # Только два проекта, начиная с даты
    pwsh -File scripts\retrocompile.ps1 -Projects "villacarte","evoschool" -Since 2026-01-01

    # Повторная обработка конкретного проекта
    pwsh -File scripts\retrocompile.ps1 -Projects "claude-memory-compiler" -Force
#>

param(
    [ValidateSet("Fast", "Quality")]
    [string]$Mode = "Fast",

    [string[]]$Projects = @(),

    [int]$MinTurns = 3,

    [string]$Since = "",

    [int]$Limit = 0,

    [int]$BatchSize = 5,

    [switch]$NoBatch,

    [switch]$DryRun,

    [switch]$Force,

    [switch]$NoCompile
)

. "$PSScriptRoot\_config.ps1"
. "$PSScriptRoot\_api.ps1"

$env:CLAUDE_INVOKED_BY = "retro_compile"

# $RETRO_STATE_FILE + Load/Save-RetroState live in _config.ps1 (shared with flush.ps1).
$TRANSCRIPTS_ROOT = Join-Path $env:USERPROFILE ".claude\projects"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-RetroLog([string]$Level, [string]$Msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts $Level [retrocompile] $Msg" | Add-Content -Path $FLUSH_LOG -Encoding UTF8
}

# Get-ProjectLabel and the transcript parser moved to _config.ps1 (shared with hooks):
# retro reads the same JSONL via Get-TranscriptTurns with Russian labels, 800-char
# per-turn truncation and hook-injection skipping.

function Ensure-DailyLog([string]$Date) {
    $logPath = Join-Path $DAILY_DIR "$Date.md"
    if (-not (Test-Path $logPath)) {
        New-Item -ItemType Directory -Path $DAILY_DIR -Force | Out-Null
        $header = "# Daily Log: $Date`n`n## Sessions`n`n## Memory Maintenance`n`n"
        [System.IO.File]::WriteAllText($logPath, $header, [System.Text.Encoding]::UTF8)
    }
    return $logPath
}

function Append-RetroEntry([string]$LogPath, [string]$Content, [string]$TimeStr, [string]$Label) {
    $entry = "### Ретро: $Label ($TimeStr)`n`n$Content`n`n"
    [System.IO.File]::AppendAllText($LogPath, $entry, [System.Text.Encoding]::UTF8)
}

# Get-QualitySummary replaced by the shared Get-FlushSummary in _api.ps1 (same prompt
# as the live flush, so the daily-log entry shape never drifts).

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "claude-memory-compiler / retrocompile" -ForegroundColor Cyan
Write-Host ("=" * 50)
Write-Host "  Режим:     $Mode"
Write-Host "  Проекты:   $(if ($Projects) { $Projects -join ', ' } else { 'все' })"
Write-Host "  MinTurns:  $MinTurns"
Write-Host "  Since:     $(if ($Since) { $Since } else { 'всё время' })"
Write-Host "  Limit:     $(if ($Limit -gt 0) { $Limit } else { 'без ограничений' })"
Write-Host "  Батч:      $(if ($NoBatch) { 'отключён (-NoBatch)' } else { "$BatchSize сессий" })"
if ($DryRun)    { Write-Host "  *** ПРОБНЫЙ ЗАПУСК — ничего не записывается ***" -ForegroundColor Yellow }
if ($NoCompile) { Write-Host "  Финальная компиляция: отключена" -ForegroundColor Yellow }
Write-Host ""

if (-not (Test-Path $TRANSCRIPTS_ROOT)) {
    Write-Error "Папка транскриптов не найдена: $TRANSCRIPTS_ROOT"
    exit 1
}

$retroState = Load-RetroState
$sinceDate  = if ($Since) {
    try { [datetime]::ParseExact($Since, "yyyy-MM-dd", $null) }
    catch { Write-Error "Неверный формат Since: '$Since'. Ожидается YYYY-MM-DD."; exit 1 }
} else { $null }

# --- Discover JSONL files ---
$allFiles = Get-ChildItem -Path $TRANSCRIPTS_ROOT -Recurse -Filter "*.jsonl" | Where-Object {
    # Project filter
    if ($Projects) {
        $folderName = $_.Directory.Name
        $match = $false
        foreach ($p in $Projects) {
            if ($folderName -like "*$p*") { $match = $true; break }
        }
        if (-not $match) { return $false }
    }
    # Date filter
    if ($sinceDate -and $_.LastWriteTime -lt $sinceDate) { return $false }
    $true
} | Sort-Object LastWriteTime

Write-Host "Найдено транскриптов: $($allFiles.Count)"
if ($Limit -gt 0) { Write-Host "Ограничение: первые $Limit (по дате)" }
Write-Host ""

$skippedDedup  = 0
$skippedShort  = 0
$processed     = 0
$errors        = 0
$flushedOk     = 0
$limitReached  = $false

$batchNum       = 0
$batchCount     = 0   # сессии в текущем батче (не считая dedup-пропуски)
$batchProcessed = 0
$batchSkipped   = 0
$batchErrors    = 0

$modifiedDates = [System.Collections.Generic.HashSet[string]]::new()

# Restore dates pending compilation from a previous interrupted run
if ($retroState.ContainsKey('pending_compile') -and $retroState['pending_compile']) {
    $restored = @($retroState['pending_compile'])
    foreach ($d in $restored) { $modifiedDates.Add([string]$d) | Out-Null }
    if ($restored.Count -gt 0 -and -not $DryRun) {
        Write-Host "  Восстановлено $($restored.Count) дат из прерванного запуска: $($restored -join ', ')" -ForegroundColor Yellow
        Write-Host ""
    }
}

foreach ($file in $allFiles) {
    if ($Limit -gt 0 -and $processed -ge $Limit) {
        $limitReached = $true
        break
    }

    $sessionId    = $file.BaseName
    $date         = $file.LastWriteTime.ToString("yyyy-MM-dd")
    $timeStr      = $file.LastWriteTime.ToString("HH:mm")
    $projectLabel = Get-ProjectLabel $file.Directory.Name

    # Dedup — не считается в батч
    if (-not $Force -and $retroState['processed'].ContainsKey($sessionId)) {
        $skippedDedup++
        continue
    }

    # Эта сессия входит в текущий батч
    $batchCount++

    # Extract turns
    $turns = Get-TranscriptTurns -Path $file.FullName -UserLabel 'Пользователь' -AssistantLabel 'Клод' -MaxTurnChars 800 -SkipInjected

    if ($turns.Count -lt $MinTurns) {
        Write-Host "  SKIP  [$date $timeStr] $projectLabel — $($turns.Count) реплик" -ForegroundColor DarkGray
        $skippedShort++
        $batchSkipped++
        if (-not $DryRun) {
            $retroState['processed'][$sessionId] = @{
                date    = $date
                turns   = $turns.Count
                skipped = $true
            }
            Save-RetroState $retroState
        }
    }
    else {
        Write-Host "  OK    [$date $timeStr] $projectLabel — $($turns.Count) реплик" -ForegroundColor Cyan

        if ($DryRun) {
            $processed++
            $batchProcessed++
        }
        else {
            # Build context (last $MAX_TURNS turns, max $MAX_CONTEXT_CHARS chars — _config)
            $recent  = if ($turns.Count -gt $MAX_TURNS) { $turns | Select-Object -Last $MAX_TURNS } else { $turns }
            $context = $recent -join "`n`n"
            if ($context.Length -gt $MAX_CONTEXT_CHARS) {
                $context  = $context.Substring($context.Length - $MAX_CONTEXT_CHARS)
                $boundary = $context.IndexOf("`n`n**")
                if ($boundary -gt 0) { $context = $context.Substring($boundary + 2) }
            }

            $logPath = Ensure-DailyLog -Date $date

            try {
                if ($Mode -eq "Quality") {
                    $summary = Get-FlushSummary -Context $context
                    if ($summary -match "^\s*FLUSH_OK\s*$") {
                        Write-Host "         → ничего ценного (FLUSH_OK)" -ForegroundColor DarkGray
                        $flushedOk++
                    }
                    else {
                        Append-RetroEntry -LogPath $logPath -Content $summary -TimeStr $timeStr -Label $projectLabel
                        Write-Host "         → суммаризовано и записано" -ForegroundColor Green
                    }
                }
                else {
                    # Fast mode: write raw formatted transcript
                    $rawContent = "**Проект:** ``$projectLabel```n`n$context"
                    Append-RetroEntry -LogPath $logPath -Content $rawContent -TimeStr $timeStr -Label $projectLabel
                    Write-Host "         → записано как есть" -ForegroundColor Green
                }

                $modifiedDates.Add($date) | Out-Null
                $retroState['processed'][$sessionId] = @{
                    date         = $date
                    turns        = $turns.Count
                    mode         = $Mode
                    project      = $projectLabel
                    processed_at = (Get-NowIso)
                }
                $retroState['pending_compile'] = @($modifiedDates)   # persist so resume knows what to compile
                Save-RetroState $retroState
                $processed++
                $batchProcessed++
            }
            catch {
                Write-Host "         ERROR: $_" -ForegroundColor Red
                Write-RetroLog "ERROR" "session=$sessionId project=$projectLabel error=$_"
                $errors++
                $batchErrors++
            }
        }
    }

    # Батч-отчёт после каждых $BatchSize сессий
    if (-not $NoBatch -and $batchCount -ge $BatchSize) {
        $batchNum++
        $totalSoFar = $processed + $skippedShort + $errors
        Write-Host ""
        Write-Host ("  " + ("-" * 46)) -ForegroundColor DarkYellow
        Write-Host ("  Батч $batchNum завершён  |  обработано: $batchProcessed  пропущено: $batchSkipped  ошибок: $batchErrors  |  итого: $totalSoFar") -ForegroundColor Yellow
        Write-Host ("  " + ("-" * 46)) -ForegroundColor DarkYellow
        Write-Host ""
        $batchCount = 0; $batchProcessed = 0; $batchSkipped = 0; $batchErrors = 0
    }
}

# --- Summary ---
Write-Host ""
Write-Host ("=" * 50)
Write-Host "Обработано:  $processed"
Write-Host "Пропущено:   $skippedShort (мало реплик) + $skippedDedup (уже обработаны)"
if ($flushedOk -gt 0) { Write-Host "FLUSH_OK:    $flushedOk (без ценного контента)" }
if ($errors    -gt 0) { Write-Host "Ошибок:      $errors" -ForegroundColor Red }
if ($limitReached)    { Write-Host "Лимит $Limit достигнут — запусти снова для продолжения" -ForegroundColor Yellow }

if ($DryRun) {
    Write-Host "`nПробный запуск завершён. Файлы не изменялись."
    exit 0
}

# Compile whenever there are pending dates — even if $processed is 0 this run, which
# happens on a resume where every session was already deduped but pending_compile still
# holds dates from an interrupted compile step. Only "no dates at all" means nothing to do.
if ($modifiedDates.Count -eq 0) {
    Write-Host "`nНечего компилировать."
    exit 0
}

if ($NoCompile) {
    Write-Host "`nКомпиляция пропущена (-NoCompile). Daily-логи обновлены:"
    foreach ($d in ($modifiedDates | Sort-Object)) { Write-Host "  daily\$d.md" }
    exit 0
}

# --- Compile modified daily logs ---
Write-Host ""
Write-Host "Компилирую $($modifiedDates.Count) дневных лог(а) в knowledge base..." -ForegroundColor Cyan
$compilePs = Join-Path $SCRIPTS_DIR "compile.ps1"

$compileErrors = 0
foreach ($date in ($modifiedDates | Sort-Object)) {
    $logPath = Join-Path $DAILY_DIR "$date.md"
    Write-Host "`n  $date.md"

    # Force recompile by clearing the cached hash — atomic, because the compile spawned
    # below writes ingested between iterations and a stale in-memory snapshot would clobber it.
    Update-State { param($s) if ($s.ContainsKey('ingested')) { $s['ingested'].Remove("$date.md") } } | Out-Null

    try {
        & pwsh -NonInteractive -File $compilePs -Log $logPath
        if ($LASTEXITCODE -ne 0) {
            $compileErrors++
            Write-Host "  ⚠ compile вернул код $LASTEXITCODE для $date" -ForegroundColor Yellow
            Write-RetroLog "ERROR" "compile date=$date exit=$LASTEXITCODE"
        }
    }
    catch {
        $compileErrors++
        Write-Host "  ERROR при компиляции $date`: $_" -ForegroundColor Red
        Write-RetroLog "ERROR" "compile date=$date error=$_"
    }
}

if ($compileErrors -eq 0) {
    $retroState['pending_compile'] = @()   # all dates compiled — clear checkpoint
    Save-RetroState $retroState
}
else {
    Write-Host "  ⚠ $compileErrors дн(ей) не скомпилировались — checkpoint pending_compile сохранён для повтора." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Ретроспективная компиляция завершена." -ForegroundColor Green
Write-RetroLog "INFO" "Done. processed=$processed errors=$errors dates=$($modifiedDates.Count)"
