#Requires -Version 7
<#
.SYNOPSIS
    One-time setup: configures brain directory, creates folder structure,
    registers global Claude Code hooks, sets PowerShell execution policy.

.PARAMETER BrainDir
    Path to your knowledge base directory. Prompted interactively if not provided.
#>

param([string]$BrainDir = "")

$ROOT_DIR        = $PSScriptRoot
$GLOBAL_SETTINGS = Join-Path $env:USERPROFILE ".claude\settings.json"

Write-Host ""
Write-Host "claude-memory-compiler setup"
Write-Host ("=" * 40)

# --- 0. PowerShell execution policy ---
Write-Host ""
Write-Host "[0] Execution policy"
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -in @('Restricted', 'AllSigned')) {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Write-Host "  Set to RemoteSigned (CurrentUser)"
} else {
    Write-Host "  $policy (ok)"
}

# --- 1. Brain directory ---
Write-Host ""
Write-Host "[1] Knowledge base (brain) directory"
Write-Host "  This is where all your data will live: daily logs, knowledge articles, reports."
Write-Host "  Keep it OUTSIDE this repository so you can update scripts with git pull."
Write-Host ""

if (-not $BrainDir) {
    $default  = Join-Path $env:USERPROFILE "brain"
    $response = Read-Host "  Path [Enter for default: $default]"
    $BrainDir = if ($response.Trim()) { $response.Trim() } else { $default }
}

$brainPathFile = Join-Path $ROOT_DIR "brain.path"
Set-Content -Path $brainPathFile -Value $BrainDir -Encoding UTF8 -NoNewline
Write-Host "  Saved: brain.path -> $BrainDir"

# --- 2. Create brain directory structure ---
Write-Host ""
Write-Host "[2] Brain directory structure"
$brainDirs = @(
    $BrainDir,
    (Join-Path $BrainDir ".claude"),
    (Join-Path $BrainDir ".claude\daily"),
    (Join-Path $BrainDir ".claude\knowledge\concepts"),
    (Join-Path $BrainDir ".claude\knowledge\connections"),
    (Join-Path $BrainDir ".claude\knowledge\qa"),
    (Join-Path $BrainDir ".claude\reports")
)
foreach ($dir in $brainDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "  Created: $dir"
    } else {
        Write-Host "  Exists:  $dir"
    }
}

# --- 3. Create repo memory dir (Claude project memory, stays in repo) ---
$memoryIndex = Join-Path $ROOT_DIR "memory\MEMORY.md"
if (-not (Test-Path (Split-Path $memoryIndex))) {
    New-Item -ItemType Directory -Path (Split-Path $memoryIndex) -Force | Out-Null
}
if (-not (Test-Path $memoryIndex)) {
    Set-Content -Path $memoryIndex -Value "# Memory Index`n" -Encoding UTF8
    Write-Host "  Created: $memoryIndex"
}

# --- 4. Check claude CLI ---
Write-Host ""
Write-Host "[3] Claude CLI"
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-Host "  Found: $($claudeCmd.Source)"
} else {
    Write-Warning "  'claude' not found in PATH."
    Write-Host "  Install Claude Code: https://claude.ai/download"
    Write-Host "  Then authenticate:   claude auth login"
}

# --- 5. Configure global hooks ---
Write-Host ""
Write-Host "[4] Global Claude Code hooks"
Write-Host "  Target: $GLOBAL_SETTINGS"

$hooksDir = Join-Path $ROOT_DIR "hooks"

$hookConfig = @{
    SessionStart     = @(@{ matcher = ""; hooks = @(@{
        type = "command"; command = "pwsh -NonInteractive -File `"$hooksDir\session-start.ps1`""; timeout = 15
    })})
    UserPromptSubmit = @(@{ matcher = ""; hooks = @(@{
        type = "command"; command = "pwsh -NonInteractive -File `"$hooksDir\user-prompt-submit.ps1`""; timeout = 20
    })})
    PreCompact       = @(@{ matcher = ""; hooks = @(@{
        type = "command"; command = "pwsh -NonInteractive -File `"$hooksDir\pre-compact.ps1`""; timeout = 10
    })})
    SessionEnd       = @(@{ matcher = ""; hooks = @(@{
        type = "command"; command = "pwsh -NonInteractive -File `"$hooksDir\session-end.ps1`""; timeout = 10
    })})
}

# Replace only OUR entries for an event (matched by the repo hooks path in the command),
# preserving any hooks the user added themselves and staying idempotent on repeat runs.
function Merge-OurHook([hashtable]$Existing, [string]$EventName, $OurEntries, [string]$HooksDir) {
    if (-not $Existing.ContainsKey('hooks') -or $Existing['hooks'] -isnot [hashtable]) { $Existing['hooks'] = @{} }
    $cur  = @($Existing['hooks'][$EventName])
    $kept = @($cur | Where-Object {
        if (-not $_) { return $false }
        $cmds = @($_.hooks | ForEach-Object { [string]$_.command })
        -not (@($cmds | Where-Object { $_ -like "*$HooksDir*" }).Count)
    })
    $Existing['hooks'][$EventName] = @($kept + $OurEntries)
}

$settingsDir = Split-Path $GLOBAL_SETTINGS -Parent
if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }

if (Test-Path $GLOBAL_SETTINGS) {
    try {
        $existing = Get-Content $GLOBAL_SETTINGS -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        Write-Host "  Merging into existing settings.json (your other hooks are preserved)"
    } catch {
        Copy-Item $GLOBAL_SETTINGS "$GLOBAL_SETTINGS.bak" -Force
        Write-Host "  Backed up unparseable settings.json -> settings.json.bak"
        $existing = @{}
    }
} else {
    $existing = @{}
    Write-Host "  Creating new settings.json"
}
if ($existing -isnot [hashtable]) { $existing = @{} }

foreach ($evt in @('SessionStart', 'UserPromptSubmit', 'PreCompact', 'SessionEnd')) {
    Merge-OurHook $existing $evt $hookConfig[$evt] $hooksDir
}

# Backup before overwriting a healthy file too — not only on the parse-error path.
if (Test-Path $GLOBAL_SETTINGS) { Copy-Item $GLOBAL_SETTINGS "$GLOBAL_SETTINGS.bak" -Force }
$existing | ConvertTo-Json -Depth 32 | Set-Content -Path $GLOBAL_SETTINGS -Encoding UTF8
Write-Host "  Saved (SessionStart + UserPromptSubmit + PreCompact + SessionEnd; existing hooks preserved)."

# --- Done ---
Write-Host ""
Write-Host ("=" * 40)
Write-Host "Setup complete!"
Write-Host ""
Write-Host "Brain:  $BrainDir"
Write-Host "Hooks:  $GLOBAL_SETTINGS"
Write-Host ""
Write-Host "Commands:"
Write-Host "  pwsh -File scripts\compile.ps1            # compile daily logs"
Write-Host "  pwsh -File scripts\query.ps1 `"question`"   # query knowledge base"
Write-Host "  pwsh -File scripts\lint.ps1               # health checks"
