#Requires -Version 7
<#
.SYNOPSIS
    Compile daily conversation logs into structured knowledge articles.
    Uses claude CLI (claude -p) — no API key required.

.EXAMPLE
    pwsh -File compile.ps1                              # compile new/changed logs only
    pwsh -File compile.ps1 -All                         # force recompile everything
    pwsh -File compile.ps1 -Log daily\2026-05-26.md
    pwsh -File compile.ps1 -DryRun
#>

param(
    [switch]$All,
    [string]$Log,
    [switch]$DryRun
)

. "$PSScriptRoot\_config.ps1"
. "$PSScriptRoot\_api.ps1"

$env:CLAUDE_INVOKED_BY = "memory_compile"

# Get-AllWikiContent moved to _config.ps1 (shared with query.ps1).

function Invoke-CompileLog {
    param([string]$LogPath)

    $logContent  = Get-Content $LogPath -Raw -Encoding UTF8
    $schema      = if (Test-Path $AGENTS_FILE) { Get-Content $AGENTS_FILE -Raw -Encoding UTF8 } else { "(AGENTS.md not found)" }
    $wikiContent = Get-AllWikiContent -EmptyIndexText "# Knowledge Base Index`n`n| Article | Summary | Compiled From | Updated |`n|---------|---------|---------------|---------|"
    $timestamp   = Get-NowIso

    $prompt = @"
Ты компилятор знаний. Прочитай дневной лог разговоров и извлеки знания в структурированные wiki-статьи.
ВАЖНО: Пиши ВСЁ содержимое статей ТОЛЬКО на русском языке. Названия файлов — на английском (транслитерация или ключевые слова).

## Схема (AGENTS.md)
$schema

## Текущая база знаний
$wikiContent

## Дневной лог для компиляции
**Файл:** $(Split-Path $LogPath -Leaf)

$logContent

## Формат вывода

Отвечай ТОЛЬКО файловыми операциями в точном формате ниже. Без объяснений, без блоков кода.

Создать или перезаписать файл:
<<<WRITE:knowledge/concepts/filename.md>>>
[полное содержимое файла]
<<<END>>>

Дописать в существующий файл:
<<<APPEND:knowledge/log.md>>>
[содержимое для добавления]
<<<END>>>

## Правила
1. Извлеки 3-7 отдельных уроков как статьи в knowledge/concepts/.
2. У КАЖДОГО концепта во frontmatter обязательны (см. схему выше):
   - type: concept | rule — rule для императивного урока «делай / не-делай / подвох» (грабли, анти-паттерн); concept для энциклопедической статьи.
   - scope: global | project — global, если урок полезен в ЛЮБОМ проекте (инструмент/язык/OS); project только для явных локальных фактов (схемы, поля, ключи API, бизнес-логика). СМЕЩЕНИЕ В GLOBAL: при сомнении выбирай global.
   - source_project: имя проекта из строки "_Проект:_" сессии-источника; unknown, если не определимо; при нескольких источниках — через запятую.
   - summary: однострочное описание для индекса.
   - а также title, sources, created, updated.
3. Создай статьи связей в knowledge/connections/ для неочевидных взаимосвязей (по умолчанию scope: global).
4. НЕ трогай knowledge/index.md — его детерминированно пересоберёт reindex.ps1.
5. Добавь запись о сборке в knowledge/log.md:
   ## [$timestamp] compile | $(Split-Path $LogPath -Leaf)
6. Предпочитай обновлять существующие статьи, а не создавать почти-дубликаты.
7. Каждая статья должна иметь YAML frontmatter и [[wikilinks]].
8. Используй относительные пути от корня проекта (например, knowledge/concepts/topic.md).
9. Заголовки разделов в статьях — на русском (## Ключевые моменты, ## Детали, ## Связанные концепты, ## Источники).
"@

    Write-Host "  Calling claude CLI..."
    $response = Invoke-ClaudeCLI -Prompt $prompt
    $opsCount = Invoke-ParseFileOps -Text $response -RootDir $CLAUDE_DIR -AllowedSubdir 'knowledge'
    Write-Host "  Executed $opsCount file operation(s)"
}

# --- Determine which logs to compile ---
$state = Load-State

if ($Log) {
    $target = $Log
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path $CLAUDE_DIR $target
    }
    if (-not (Test-Path $target)) { Write-Error "File not found: $Log"; exit 1 }
    $toCompile = @($target)
}
else {
    $allLogs = if (Test-Path $DAILY_DIR) {
        Get-ChildItem $DAILY_DIR -Filter "*.md" | Sort-Object Name | Select-Object -ExpandProperty FullName
    } else { @() }

    $toCompile = if ($All) {
        $allLogs
    } else {
        $ingested = $state['ingested'] ?? @{}
        $allLogs | Where-Object {
            $key = Split-Path $_ -Leaf
            -not $ingested[$key] -or $ingested[$key]['hash'] -ne (Get-FileHash256 $_)
        }
    }
}

if (-not $toCompile) {
    Write-Host "Nothing to compile — all daily logs are up to date."
    exit 0
}

$prefix = if ($DryRun) { "[DRY RUN] " } else { "" }
Write-Host "${prefix}Files to compile ($(@($toCompile).Count)):"
foreach ($f in $toCompile) { Write-Host "  - $(Split-Path $f -Leaf)" }
if ($DryRun) { exit 0 }

foreach ($logPath in @($toCompile)) {
    $leafName = Split-Path $logPath -Leaf
    Write-Host "`nCompiling $leafName..."

    try {
        Invoke-CompileLog -LogPath $logPath

        $logHash    = Get-FileHash256 $logPath
        $compiledAt = Get-NowIso
        $state = Update-State {
            param($s)
            if (-not $s.ContainsKey('ingested')) { $s['ingested'] = @{} }
            $s['ingested'][$leafName] = @{ hash = $logHash; compiled_at = $compiledAt }
        }
        Write-Host "  Done."
    }
    catch {
        Write-Host "  ERROR: $_"
    }
}

# Tag domains on the freshly compiled articles — the live domain step (controlled
# vocabulary, written straight to frontmatter; no manual Excel pass). Only articles
# without domains yet are classified, so repeat runs are cheap.
$tagDomainsPs = Join-Path $SCRIPTS_DIR "tag-domains.ps1"
if (Test-Path $tagDomainsPs) {
    Write-Host "`nTagging domains..."
    try { & $tagDomainsPs } catch { Write-Host "  WARNING: tag-domains.ps1 failed: $_" }
}

# Rebuild the index deterministically from article frontmatter (session-start
# filtering depends on accurate Scope/Project columns).
$reindexPs = Join-Path $SCRIPTS_DIR "reindex.ps1"
if (Test-Path $reindexPs) {
    Write-Host "`nRebuilding index..."
    try { & $reindexPs } catch { Write-Host "  WARNING: reindex.ps1 failed — index may be stale: $_" }
}

$articles = @(Get-AllArticles -IncludeQa)
Write-Host "`nDone. Knowledge base: $($articles.Count) articles"
