#Requires -Version 7
<#
.SYNOPSIS
    One-shot legacy reclassification. Adds type/scope/source_project/summary to the
    frontmatter of existing knowledge articles WITHOUT moving or rewriting their body.

    - concepts/    : LLM assigns scope (global|project, biased to global), type
                     (concept|rule) and source_project (best-effort, else "unknown").
    - connections/ : deterministic — type=concept, scope=global (no LLM call).
    - summary      : copied from the current index.md when available (preserves the
                     curated one-liners); otherwise reindex.ps1 falls back to the lead.

    Frontmatter is patched line-by-line in PowerShell; the LLM never rewrites the file,
    so article bodies cannot be corrupted. Resumable via reclassify-state.json.

.EXAMPLE
    pwsh -File reclassify.ps1 -DryRun         # list what would be processed
    pwsh -File reclassify.ps1                  # classify all pending concepts
    pwsh -File reclassify.ps1 -Limit 5         # only 5 (smoke test)
    pwsh -File reclassify.ps1 -Force           # redo already-processed files
#>

param(
    [int]$BatchSize = 10,
    [int]$Limit     = 0,
    [switch]$Force,
    [switch]$DryRun
)

. "$PSScriptRoot\_config.ps1"
. "$PSScriptRoot\_api.ps1"

$env:CLAUDE_INVOKED_BY = "memory_reclassify"
$RC_STATE = Join-Path $CLAUDE_DIR "reclassify-state.json"

function Load-RC {
    if (Test-Path $RC_STATE) {
        try { return (Get-Content $RC_STATE -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable) } catch {}
    }
    return @{ done = @{} }
}
function Save-RC([hashtable]$S) { $S | ConvertTo-Json -Depth 5 | Set-Content -Path $RC_STATE -Encoding UTF8 }

# Map article key (leaf, e.g. "amocrm-note-type-v4") → its current index summary.
function Get-OldIndexSummaries {
    $map = @{}
    if (-not (Test-Path $INDEX_FILE)) { return $map }
    $headerParsed = $false; $artIdx = -1; $sumIdx = -1
    foreach ($line in (Get-Content $INDEX_FILE -Encoding UTF8)) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = ($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() }
        if (-not $headerParsed) {
            for ($i = 0; $i -lt $cells.Count; $i++) {
                $h = $cells[$i].ToLower()
                if     ($h -in @('article', 'статья'))            { $artIdx = $i }
                elseif ($h -in @('summary', 'краткое описание'))  { $sumIdx = $i }
            }
            $headerParsed = $true; continue
        }
        if ($line -match '^\s*\|\s*-{2,}') { continue }
        if ($artIdx -lt 0 -or $sumIdx -lt 0 -or $artIdx -ge $cells.Count) { continue }
        $m = [regex]::Match($cells[$artIdx], '\[\[([^\]]+)\]\]')
        if ($m.Success) {
            $key = Split-Path $m.Groups[1].Value -Leaf
            $map[$key] = if ($sumIdx -lt $cells.Count) { $cells[$sumIdx] } else { "" }
        }
    }
    return $map
}

# Set-FrontmatterField moved to _config.ps1 (shared with apply-review).

# Ask the LLM for scope/type/source_project. Returns hashtable or $null on failure.
function Invoke-Classify([string]$Body) {
    $prompt = @"
Ты классификатор знаний. Ниже статья базы знаний. Определи для неё три поля.

ЭВРИСТИКА scope:
- global — урок полезен в ЛЮБОМ проекте (поведение инструмента/языка/OS, переносимый механизм).
  СМЕЩЕНИЕ В GLOBAL: при любом сомнении выбирай global.
- project — факт только конкретного проекта (схема БД, имена/типы полей, ключи API конкретной
  системы, бизнес-логика домена).

ЭВРИСТИКА type:
- rule — императивный урок «делай / не-делай / подвох» (грабли, анти-паттерн, предписание).
- concept — энциклопедическая статья, объясняющая тему.

source_project — имя проекта-происхождения, если его можно определить из содержания/источников;
иначе ровно: unknown.

Ответь РОВНО тремя строками, без пояснений и без markdown:
scope: <global|project>
type: <concept|rule>
source_project: <имя|unknown>

## Статья
$Body
"@
    try { $resp = Invoke-ClaudeCLI -Prompt $prompt } catch { return $null }

    $scope = ([regex]::Match($resp, '(?im)^\s*scope\s*:\s*(global|project)\b')).Groups[1].Value.ToLower()
    $type  = ([regex]::Match($resp, '(?im)^\s*type\s*:\s*(concept|rule)\b')).Groups[1].Value.ToLower()
    $sp    = ([regex]::Match($resp, '(?im)^\s*source_project\s*:\s*(.+)$')).Groups[1].Value.Trim().Trim('"', '`', "'")
    if (-not $scope -or -not $type) { return $null }
    if (-not $sp) { $sp = "unknown" }
    return @{ scope = $scope; type = $type; source_project = $sp }
}

function Patch-Article([string]$Path, [string]$Scope, [string]$Type, [string]$SourceProject, [string]$Summary) {
    $raw = Get-Content $Path -Raw -Encoding UTF8
    $raw = Set-FrontmatterField $raw 'type'   $Type
    $raw = Set-FrontmatterField $raw 'scope'  $Scope
    if ($SourceProject) { $raw = Set-FrontmatterField $raw 'source_project' $SourceProject }
    if ($Summary) {
        $q = '"' + ($Summary -replace '"', "'") + '"'
        $raw = Set-FrontmatterField $raw 'summary' $q
    }
    [System.IO.File]::WriteAllText($Path, $raw, [System.Text.Encoding]::UTF8)
}

# --- Main ---
$oldSummaries = Get-OldIndexSummaries
$state = Load-RC
if (-not $state.ContainsKey('done')) { $state['done'] = @{} }

# 1) Connections — deterministic (no LLM)
if (Test-Path $CONNECTIONS_DIR) {
    foreach ($c in (Get-ChildItem $CONNECTIONS_DIR -Filter "*.md" | Sort-Object Name)) {
        $key = "connections/$($c.BaseName)"
        if ($state['done'][$key] -and -not $Force) { continue }
        $sum = $oldSummaries[$c.BaseName]
        if ($DryRun) { Write-Host "[DRY] connection: $($c.Name) -> scope=global type=concept"; continue }
        Patch-Article $c.FullName 'global' 'concept' '' $sum
        $state['done'][$key] = (Get-NowIso)
        Save-RC $state
    }
}

# 2) Concepts — LLM classification
$concepts = if (Test-Path $CONCEPTS_DIR) { @(Get-ChildItem $CONCEPTS_DIR -Filter "*.md" | Sort-Object Name) } else { @() }
$pending  = $concepts | Where-Object { $Force -or -not $state['done']["concepts/$($_.BaseName)"] }
if ($Limit -gt 0) { $pending = $pending | Select-Object -First $Limit }
$pending  = @($pending)

Write-Host "Concepts: $($concepts.Count) total, $($pending.Count) to process$(if($Force){' (force)'})."
if ($DryRun) {
    foreach ($a in $pending) { Write-Host "[DRY] concept: $($a.Name)" }
    Write-Host "`n[DRY RUN] No files changed."
    exit 0
}

$done = 0
foreach ($a in $pending) {
    $done++
    $raw  = Get-Content $a.FullName -Raw -Encoding UTF8
    $res  = Invoke-Classify $raw
    if (-not $res) {
        Write-Host "  ! SKIP (classification failed, will retry next run): $($a.Name)"
        continue
    }
    $sum = $oldSummaries[$a.BaseName]
    Patch-Article $a.FullName $res.scope $res.type $res.source_project $sum
    $state['done']["concepts/$($a.BaseName)"] = (Get-NowIso)
    Save-RC $state
    Write-Host "  [$done/$($pending.Count)] $($a.Name) -> scope=$($res.scope) type=$($res.type) project=$($res.source_project)"

    if ($BatchSize -gt 0 -and ($done % $BatchSize) -eq 0) {
        Write-Host "  --- batch checkpoint: $done/$($pending.Count) done ---"
    }
}

# Rebuild the index from the freshly-patched frontmatter.
$reindexPs = Join-Path $SCRIPTS_DIR "reindex.ps1"
if (Test-Path $reindexPs) {
    Write-Host "`nRebuilding index..."
    & $reindexPs
}
Write-Host "`nReclassification complete."
