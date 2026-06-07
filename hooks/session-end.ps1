#Requires -Version 7
<#
.SYNOPSIS
    SessionEnd hook — captures conversation transcript for memory extraction.
    No API calls here — only file I/O to stay within the 10s hook timeout.
#>

if ($env:CLAUDE_INVOKED_BY) { exit 0 }

$REPO_DIR = Split-Path $PSScriptRoot -Parent
. (Join-Path $REPO_DIR "scripts\_config.ps1")   # paths + project helpers
$FLUSH_PS1 = Join-Path $SCRIPTS_DIR "flush.ps1"

$MAX_TURNS         = 30
$MAX_CONTEXT_CHARS = 15000
$MIN_TURNS         = 1

function Write-Log([string]$Level, [string]$Msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts $Level [session-end] $Msg" | Add-Content -Path $FLUSH_LOG -Encoding UTF8
}

# --- Parse stdin ---
try {
    $rawInput = [Console]::In.ReadToEnd()
    $rawInput = $rawInput -replace '(?<!\\)\\(?!["\\/bfnrtu])', '\\\\'
    $hookInput = $rawInput | ConvertFrom-Json
} catch {
    Write-Log "ERROR" "Failed to parse stdin: $_"
    exit 0
}

$sessionId     = $hookInput.session_id    ?? "unknown"
$transcriptStr = $hookInput.transcript_path ?? ""
$source        = $hookInput.source         ?? "unknown"
$cwd           = $hookInput.cwd            ?? ""

Write-Log "INFO" "Fired: session=$sessionId source=$source cwd=$cwd"

if (-not $transcriptStr -or -not (Test-Path $transcriptStr)) {
    Write-Log "INFO" "SKIP: no transcript or missing: $transcriptStr"
    exit 0
}

# --- Extract turns from JSONL transcript ---
$turns = [System.Collections.Generic.List[string]]::new()

foreach ($line in (Get-Content -Path $transcriptStr -Encoding UTF8)) {
    $line = $line.Trim()
    if (-not $line) { continue }
    try { $entry = $line | ConvertFrom-Json } catch { continue }

    $msg = $entry.message
    if ($msg -and $msg.PSObject.Properties['role']) { $role = $msg.role; $content = $msg.content }
    else { $role = $entry.role; $content = $entry.content }

    if ($role -notin @("user", "assistant")) { continue }

    if ($content -isnot [string]) {
        $parts = foreach ($block in @($content)) {
            if ($block.type -eq "text") { $block.text } elseif ($block -is [string]) { $block }
        }
        $content = $parts -join "`n"
    }

    $text = [string]$content
    if (-not $text.Trim()) { continue }
    $label = if ($role -eq "user") { "User" } else { "Assistant" }
    $turns.Add("**${label}:** $($text.Trim())`n")
}

if ($turns.Count -lt $MIN_TURNS) {
    Write-Log "INFO" "SKIP: only $($turns.Count) turns (min $MIN_TURNS)"
    exit 0
}

$recent  = if ($turns.Count -gt $MAX_TURNS) { $turns | Select-Object -Last $MAX_TURNS } else { $turns }
$context = $recent -join "`n"

if ($context.Length -gt $MAX_CONTEXT_CHARS) {
    $context  = $context.Substring($context.Length - $MAX_CONTEXT_CHARS)
    $boundary = $context.IndexOf("`n**")
    if ($boundary -gt 0) { $context = $context.Substring($boundary + 1) }
}

if (-not $context.Trim()) { Write-Log "INFO" "SKIP: empty context"; exit 0 }

# --- Resolve project provenance (source_project) ---
if ($cwd) {
    $projKey  = Get-ProjectKey $cwd
    $projRoot = Get-ProjectRoot $cwd
} else {
    # Fallback: decode the project from the transcript's folder name.
    $projFolder = Split-Path (Split-Path $transcriptStr -Parent) -Leaf
    $projKey    = Get-ProjectLabel $projFolder
    $projRoot   = ""
}
Add-ProjectToRegistry $projKey $projRoot

# --- Write context to brain temp dir, spawn flush ---
$timestamp   = (Get-Date).ToString("yyyyMMdd-HHmmss")
$contextFile = Join-Path $BRAIN_DIR "session-flush-${sessionId}-${timestamp}.md"
[System.IO.File]::WriteAllText($contextFile, $context, [System.Text.Encoding]::UTF8)

try {
    Start-Process pwsh `
        -ArgumentList @("-NonInteractive", "-File", "`"$FLUSH_PS1`"", "`"$contextFile`"", "`"$sessionId`"", "`"$projKey`"", "`"$cwd`"") `
        -WindowStyle Hidden
    Write-Log "INFO" "Spawned flush.ps1 for session $sessionId (project=$projKey, $($recent.Count) turns, $($context.Length) chars)"
} catch {
    Write-Log "ERROR" "Failed to spawn flush.ps1: $_"
}
