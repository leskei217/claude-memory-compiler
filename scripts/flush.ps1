#Requires -Version 7
<#
.SYNOPSIS
    Memory flush — extracts important knowledge from a conversation context file.
    Spawned by session-end.ps1 / pre-compact.ps1 as a background process.
    Calls Anthropic API, appends result to today's daily log.

.PARAMETER ContextFile
    Path to the temp .md file containing extracted conversation turns.

.PARAMETER SessionId
    Claude Code session identifier (used for deduplication).
#>

param(
    [Parameter(Mandatory)][string]$ContextFile,
    [Parameter(Mandatory)][string]$SessionId,
    [string]$SourceProject = "",
    [string]$Cwd = ""
)

# Recursion guard: prevent hooks from re-firing if this process somehow
# ends up back in Claude Code's hook chain.
$env:CLAUDE_INVOKED_BY = "memory_flush"

. "$PSScriptRoot\_config.ps1"
. "$PSScriptRoot\_api.ps1"

# Flush dedup state — separate from compile state.json
$LAST_FLUSH_FILE = Join-Path $CLAUDE_DIR "last-flush.json"

function Write-FlushLog([string]$Level, [string]$Msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts $Level [flush] $Msg" | Add-Content -Path $FLUSH_LOG -Encoding UTF8
}

function Append-DailyLog([string]$Content, [string]$Section = "Session") {
    $today   = (Get-Date).ToString("yyyy-MM-dd")
    $logPath = Join-Path $DAILY_DIR "$today.md"

    if (-not (Test-Path $logPath)) {
        New-Item -ItemType Directory -Path $DAILY_DIR -Force | Out-Null
        $header = "# Daily Log: $today`n`n## Sessions`n`n## Memory Maintenance`n`n"
        [System.IO.File]::WriteAllText($logPath, $header, [System.Text.Encoding]::UTF8)
    }

    $timeStr = (Get-Date).ToString("HH:mm")
    # Provenance line: which project this session came from (for scope routing).
    # ${SourceProject}/${Cwd} are brace-delimited so a trailing "_" isn't parsed into the name.
    $prov = ""
    if ($SourceProject) {
        $prov = if ($Cwd) { "_Проект: ${SourceProject} — ${Cwd}_`n`n" } else { "_Проект: ${SourceProject}_`n`n" }
    }
    $entry   = "### $Section ($timeStr)`n`n$prov$Content`n`n"
    [System.IO.File]::AppendAllText($logPath, $entry, [System.Text.Encoding]::UTF8)
}

function Load-FlushState {
    if (Test-Path $LAST_FLUSH_FILE) {
        try { return (Get-Content $LAST_FLUSH_FILE -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable) }
        catch {}
    }
    return @{}
}

function Save-FlushState([hashtable]$State) {
    $State | ConvertTo-Json | Set-Content -Path $LAST_FLUSH_FILE -Encoding UTF8
}

# --- Main ---
Write-FlushLog "INFO" "Started for session $SessionId, context: $ContextFile"

if (-not (Test-Path $ContextFile)) {
    Write-FlushLog "ERROR" "Context file not found: $ContextFile"
    exit 1
}

# Deduplication: skip if same session was flushed within 60 seconds
$flushState = Load-FlushState
$lastTs     = $flushState['timestamp']
if ($flushState['session_id'] -eq $SessionId -and
    $lastTs -and (([DateTimeOffset]::Now - [DateTimeOffset]::FromUnixTimeSeconds($lastTs)).TotalSeconds -lt 60)) {
    Write-FlushLog "INFO" "Skipping duplicate flush for session $SessionId"
    Remove-Item $ContextFile -Force -ErrorAction SilentlyContinue
    exit 0
}

$context = [System.IO.File]::ReadAllText($ContextFile, [System.Text.Encoding]::UTF8).Trim()
if (-not $context) {
    Write-FlushLog "INFO" "Context file is empty, skipping"
    Remove-Item $ContextFile -Force -ErrorAction SilentlyContinue
    exit 0
}

Write-FlushLog "INFO" "Flushing session ${SessionId}: $($context.Length) chars"

try {
    # Shared flush prompt (Get-FlushSummary in _api.ps1) — same as retrocompile Quality mode.
    $result = Get-FlushSummary -Context $context

    if ($result -match "FLUSH_OK") {
        Write-FlushLog "INFO" "Result: FLUSH_OK"
        Append-DailyLog "FLUSH_OK — Nothing worth saving from this session." "Memory Flush"
    }
    elseif ($result -match "FLUSH_ERROR") {
        Write-FlushLog "ERROR" "Result: $result"
        Append-DailyLog $result "Memory Flush"
    }
    else {
        Write-FlushLog "INFO" "Result: saved $($result.Length) chars to daily log"
        Append-DailyLog $result "Session"
    }
}
catch {
    Write-FlushLog "ERROR" "API call failed: $_"
    Append-DailyLog "FLUSH_ERROR: $_" "Memory Flush"
}

Save-FlushState @{ session_id = $SessionId; timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
Remove-Item $ContextFile -Force -ErrorAction SilentlyContinue

# Register this session in retro-processed.json so retrocompile skips it
# (shared Load/Save-RetroState from _config.ps1 — same schema as retrocompile).
try {
    $retroState = Load-RetroState
    if (-not $retroState.ContainsKey('processed')) { $retroState['processed'] = @{} }
    $retroState['processed'][$SessionId] = @{
        project      = "hook"
        processed_at = (Get-NowIso)
        mode         = "flush"
    }
    Save-RetroState $retroState
} catch {
    Write-FlushLog "WARN" "Could not update retro-processed.json: $_"
}

# End-of-day auto-compile: if past $COMPILE_AFTER_HOUR and today's log has changed
$hour = (Get-Date).Hour
if ($hour -ge $COMPILE_AFTER_HOUR) {
    $today    = (Get-Date).ToString("yyyy-MM-dd")
    $logPath  = Join-Path $DAILY_DIR "$today.md"
    $compilePs = Join-Path $SCRIPTS_DIR "compile.ps1"   # SCRIPTS_DIR = repo/scripts

    if ((Test-Path $logPath) -and (Test-Path $compilePs)) {
        $state   = Load-State
        $ingested = $state['ingested']
        $key     = "$today.md"
        $hash    = Get-FileHash256 $logPath

        $alreadyCompiled = $ingested -and $ingested.ContainsKey($key) -and $ingested[$key]['hash'] -eq $hash

        if (-not $alreadyCompiled) {
            Write-FlushLog "INFO" "Triggering end-of-day compilation (after ${COMPILE_AFTER_HOUR}:00)"
            try {
                # Per-process log names ($PID) so two near-simultaneous spawns don't contend
                # for one compile.log; capture stderr too; -NoProfile to match the other spawns.
                $tag    = "$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$PID"
                $outLog = Join-Path $CLAUDE_DIR "compile-$tag.out.log"
                $errLog = Join-Path $CLAUDE_DIR "compile-$tag.err.log"
                Start-Process -FilePath "pwsh" `
                    -ArgumentList @("-NoProfile", "-NonInteractive", "-File", "`"$compilePs`"", "-Log", "`"$logPath`"") `
                    -WindowStyle Hidden `
                    -RedirectStandardOutput $outLog `
                    -RedirectStandardError $errLog
            }
            catch {
                Write-FlushLog "ERROR" "Failed to spawn compile.ps1: $_"
            }
        }
    }
}

Write-FlushLog "INFO" "Flush complete for session $SessionId"
