# Claude CLI utilities — dot-source this file: . "$PSScriptRoot\_api.ps1"
# Requires: claude CLI installed and authenticated (claude auth login)

# Calls claude -p with the given prompt via stdin. Returns response text.
function Invoke-ClaudeCLI {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        [int]$MaxRetries = 4,
        [string]$Model
    )

    $useModel = if ($Model) { $Model } else { $DEFAULT_MODEL }
    $cliArgs = @("-p", "--output-format", "text")
    if ($useModel) {
        $cliArgs += "--model"
        $cliArgs += $useModel
    }

    for ($attempt = 1; ; $attempt++) {
        $prevEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $output = $Prompt | & claude @cliArgs 2>$null
        $exit   = $LASTEXITCODE
        [Console]::OutputEncoding = $prevEncoding

        if ($exit -eq 0) {
            return ($output -is [array]) ? ($output -join "`n") : [string]$output
        }
        if ($attempt -ge $MaxRetries) {
            throw "claude CLI exited with code $exit after $attempt attempt(s). Verify that 'claude' is in PATH and authenticated (run: claude auth login)."
        }
        # Backoff for transient / rate-limit failures, then retry.
        Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
    }
}

# Parses structured file-operation blocks from compile/query output.
# Format used in prompts:
#   <<<WRITE:path/to/file.md>>>
#   [content]
#   <<<END>>>
#
#   <<<APPEND:path/to/file.md>>>
#   [content]
#   <<<END>>>
function Invoke-ParseFileOps {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [Parameter(Mandatory)]
        [string]$RootDir,
        [string]$AllowedSubdir = ""
    )

    $pattern = [regex]::new(
        '<<<(WRITE|APPEND):([^>]+)>>>(.*?)<<<END>>>',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $ops = $pattern.Matches($Text)
    if ($ops.Count -eq 0) { return 0 }

    $count = 0
    foreach ($m in $ops) {
        $action  = $m.Groups[1].Value
        $relPath = $m.Groups[2].Value.Trim()
        $content = $m.Groups[3].Value -replace '^\r?\n', ''   # strip leading newline

        $result = Invoke-FileTool -ToolName ($action.ToLower() + "_file") `
            -ToolInput @{ path = $relPath; content = $content } `
            -RootDir $RootDir -AllowedSubdir $AllowedSubdir
        Write-Host "    $result"
        $count++
    }
    return $count
}

# Security-checked file write/append — only writes inside RootDir.
function Invoke-FileTool {
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,    # "write_file" or "append_file"
        [Parameter(Mandatory)]
        $ToolInput,
        [Parameter(Mandatory)]
        [string]$RootDir,
        [string]$AllowedSubdir = ""
    )

    $path = $ToolInput.path
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        # A ':' in a relative path means a drive-relative path (C:foo) or an NTFS alternate
        # data stream (a.md:hidden) — neither is a legitimate knowledge-base file op.
        if ($path.Contains(':')) { return "Error: suspicious ':' in relative path '$path'." }
        $path = Join-Path $RootDir $path
    }
    $realPath = [System.IO.Path]::GetFullPath($path)
    $realRoot = [System.IO.Path]::GetFullPath($RootDir)

    $sep = [System.IO.Path]::DirectorySeparatorChar
    if (-not $realPath.StartsWith($realRoot + $sep) -and $realPath -ne $realRoot) {
        return "Error: '$realPath' is outside project directory."
    }
    # Optional allowlist: confine writes to one subdirectory (compile/query pass 'knowledge'),
    # so a prompt-injected <<<WRITE>>> can't reach domains.md / projects.json / state.json,
    # which live in $CLAUDE_DIR but outside knowledge/.
    if ($AllowedSubdir) {
        $realAllowed = [System.IO.Path]::GetFullPath((Join-Path $realRoot $AllowedSubdir))
        if (-not $realPath.StartsWith($realAllowed + $sep) -and $realPath -ne $realAllowed) {
            return "Error: '$realPath' is outside allowed subdir '$AllowedSubdir'."
        }
    }

    $dir = [System.IO.Path]::GetDirectoryName($realPath)
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    switch ($ToolName) {
        "write_file" {
            [System.IO.File]::WriteAllText($realPath, $ToolInput.content, [System.Text.Encoding]::UTF8)
            return "Written: $realPath"
        }
        "append_file" {
            [System.IO.File]::AppendAllText($realPath, $ToolInput.content, [System.Text.Encoding]::UTF8)
            return "Appended: $realPath"
        }
        default { return "Unknown tool: $ToolName" }
    }
}

# Summarize a conversation context into the structured daily-log entry. ONE prompt
# shared by the live flush (flush.ps1) and retrocompile's Quality mode, so the
# daily-log shape and the FLUSH_OK sentinel never drift between the two writers.
# Returns the raw LLM text ("FLUSH_OK" when nothing is worth saving).
function Get-FlushSummary {
    param([Parameter(Mandatory)][string]$Context)

    $prompt = @"
Проанализируй контекст разговора ниже и ответь кратким резюме важных моментов для сохранения в дневном логе.
Не используй никакие инструменты — только обычный текст.
ВАЖНО: Отвечай ТОЛЬКО на русском языке.

Оформи ответ как структурированную запись дневного лога с разделами:

**Контекст:** [Одна строка о том, чем занимался пользователь]

**Ключевые обмены:**
- [Важные вопросы и ответы, обсуждения]

**Принятые решения:**
- [Любые решения с обоснованием]

**Выводы:**
- [Подводные камни, паттерны, инсайты]

**Задачи:**
- [Упомянутые последующие шаги или TODO]

Пропускай рутинные вызовы инструментов, тривиальные чтения файлов и очевидный back-and-forth.
Включай только разделы с реальным содержимым.
Если ничего не стоит сохранять, ответь ровно: FLUSH_OK

## Контекст разговора

$Context
"@
    return Invoke-ClaudeCLI -Prompt $prompt
}

# Classify an article body into knowledge DOMAINS, picking ONLY from the controlled
# vocabulary (domains.md). Returns a (possibly empty) array of vocab keys. The vocab
# filter is deterministic — anything the LLM returns outside the vocabulary is dropped.
# Shared by compile/tag-domains (live tagging) and suggest-domains (offline batch) so
# the classifier prompt never drifts between them.
function Get-DomainsForArticle {
    param(
        [Parameter(Mandatory)] [string]$Body,
        [Parameter(Mandatory)] [string[]]$Vocab
    )
    if (-not $Vocab -or $Vocab.Count -eq 0) { return @() }

    $prompt = @"
Ты классификатор доменов знаний. Ниже статья. Выбери ВСЕ подходящие домены ТОЛЬКО из этого списка:
$($Vocab -join ', ')

Домен подходит, если знание статьи относится к этой области. Выбери 1–3 самых релевантных.
Если ни один не подходит — ответь ровно: -
Ответь ОДНОЙ строкой: ключи доменов через запятую, без пояснений и без markdown.

## Статья
$Body
"@
    $resp = Invoke-ClaudeCLI -Prompt $prompt   # throws on persistent CLI failure — caller logs it

    $picked = @()
    foreach ($tok in ($resp -split '[,;\r\n]+')) {
        $t = $tok.Trim().Trim('`', '"', "'", ' ').ToLower()
        if ($t -and ($t -in $Vocab) -and ($t -notin $picked)) { $picked += $t }
    }
    return @($picked)
}

# Classify a USER PROMPT for the UserPromptSubmit accrual hook. ONE cheap light-model
# call returns BOTH: in-vocabulary domains (for accrual) AND a suspected out-of-vocabulary
# domain candidate (for the gap log). Best-effort: 1 attempt, no retries — must never
# block or fail the prompt. Returns @{ Domains = @(...); Gap = '<text or empty>' }.
function Get-DomainsForPrompt {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string[]]$Vocab,
        [string]$Model
    )
    $result = @{ Domains = @(); Gap = '' }
    if (-not $Vocab -or $Vocab.Count -eq 0) { return $result }
    if (-not $Prompt -or $Prompt.Trim().Length -lt 15) { return $result }

    $useModel = if ($Model) { $Model } elseif ($DOMAINIZE_MODEL) { $DOMAINIZE_MODEL } else { $DEFAULT_MODEL }

    $classify = @"
Ты классификатор доменов знаний. Ниже запрос пользователя и ЗАКРЫТЫЙ список доменов:
$($Vocab -join ', ')

Ответь РОВНО двумя строками, без markdown и без пояснений:
DOMAINS: ключи ИЗ СПИСКА через запятую, к которым по существу относится запрос (0–3, не натягивай); если ни один — поставь -
GAP: если запрос явно про значимую область, которой НЕТ в списке — короткое имя-кандидат (1–3 слова, латиницей-через-дефис) и 3–6 слов почему; иначе поставь -

## Запрос
$Prompt
"@
    try { $resp = Invoke-ClaudeCLI -Prompt $classify -MaxRetries 1 -Model $useModel }
    catch { return $result }

    foreach ($line in ($resp -split '\r?\n')) {
        $l = $line.Trim()
        if ($l -match '^DOMAINS:\s*(.*)$') {
            foreach ($tok in ($matches[1] -split '[,;]+')) {
                $t = $tok.Trim().Trim('`', '"', "'", ' ').ToLower()
                if ($t -and ($t -in $Vocab) -and ($t -notin $result.Domains)) { $result.Domains += $t }
            }
        }
        elseif ($l -match '^GAP:\s*(.*)$') {
            $g = $matches[1].Trim()
            if ($g -and $g -ne '-') { $result.Gap = $g }
        }
    }
    return $result
}
