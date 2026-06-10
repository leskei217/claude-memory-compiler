#Requires -Version 7
<#
.SYNOPSIS
    SessionStart hook — injects project-filtered knowledge base context into a new
    session. Reads cwd from the hook stdin, then injects only global articles plus
    articles whose source_project matches the current project. No API calls.
#>

# Cyrillic in additionalContext must reach Claude Code as UTF-8, not OEM mojibake.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$REPO_DIR = Split-Path $PSScriptRoot -Parent
. (Join-Path $REPO_DIR "scripts\_config.ps1")   # paths + Get-ProjectKey

$MAX_CONTEXT_CHARS = 20000
$MAX_LOG_LINES     = 30

# --- Current project from hook stdin (cwd) ---
$projKey = ""
try {
    $hookInput = Read-HookStdin
    if ($hookInput -and $hookInput.cwd) { $projKey = Get-ProjectKey $hookInput.cwd }
} catch { $projKey = "" }

function Get-RecentLog {
    for ($offset = 0; $offset -le 1; $offset++) {
        $date    = (Get-Date).AddDays(-$offset).ToString("yyyy-MM-dd")
        $logPath = Join-Path $DAILY_DIR "$date.md"
        if (Test-Path $logPath) {
            $lines  = Get-Content $logPath -Encoding UTF8
            $recent = if ($lines.Count -gt $MAX_LOG_LINES) { $lines | Select-Object -Last $MAX_LOG_LINES } else { $lines }
            return $recent -join "`n"
        }
    }
    return "(no recent daily log)"
}

# Keep only rows where Scope == global (or blank legacy) OR Project == current project.
# Rules (type == rule) are surfaced first. Uses the shared parser/predicate in _config
# so the injected set always matches what /brain reports.
function Get-FilteredIndex([string]$ProjKey, [string[]]$ProjDomains) {
    $rows = Get-IndexRows
    if ($rows.Count -eq 0) { return "(empty — no articles compiled yet)" }
    # Real header+separator from the index file → never drifts from reindex columns.
    $header = Get-IndexHeader
    $kept   = @($rows | Where-Object { Test-RowInjected $_ $ProjKey $ProjDomains })
    $rules  = @($kept | Where-Object { $_.type -eq 'rule' })
    $others = @($kept | Where-Object { $_.type -ne 'rule' })
    return "$header`n" + ((@($rules) + @($others) | ForEach-Object { $_.raw }) -join "`n")
}

$parts = [System.Collections.Generic.List[string]]::new()
$parts.Add("## Today`n$((Get-Date).ToString('dddd, MMMM dd, yyyy'))")

# Project domain profile (drives the global-scope domain filter + the header line).
$projDomains = @()
if ($projKey) {
    $reg = Load-Registry
    if ($reg.ContainsKey($projKey)) { $projDomains = @($reg[$projKey]['domains']) }
}

$indexBlock = if (-not (Test-Path $INDEX_FILE)) {
    "(empty — no articles compiled yet)"
} elseif ($projKey) {
    Get-FilteredIndex $projKey $projDomains       # filter by project + domains
} else {
    Get-Content $INDEX_FILE -Raw -Encoding UTF8   # no cwd → inject everything (no regression)
}
$projNote = if ($projKey) { " (проект: $projKey)" } else { "" }
$domLine = ""
if ($projKey) {
    $domLine = if ($projDomains.Count) { "_Домены проекта:_ " + ($projDomains -join ', ') + "`n`n" } else { "_Домены проекта: не заданы_`n`n" }
}
$parts.Add("## Knowledge Base Index$projNote`n`n$domLine$indexBlock")

$parts.Add("## Recent Daily Log`n`n$(Get-RecentLog)")

$context = $parts -join "`n`n---`n`n"
if ($context.Length -gt $MAX_CONTEXT_CHARS) {
    $context = $context.Substring(0, $MAX_CONTEXT_CHARS) + "`n`n...(truncated)"
}

Write-Output (@{
    hookSpecificOutput = @{
        hookEventName     = "SessionStart"
        additionalContext = $context
    }
} | ConvertTo-Json -Depth 5 -Compress)
