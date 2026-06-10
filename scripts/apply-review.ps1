#Requires -Version 7
<#
.SYNOPSIS
    Apply the reviewed metadata back into article frontmatter, then rebuild the index
    and lint. Input JSON (review-applied.json), produced from the edited review.xlsx:

        [ { "file": "concepts/x", "scope": "project", "project": "legal-finance",
            "domains": ["legal-finance"] }, ... ]

    Patches scope / source_project / domains (domains validated against the vocabulary)
    line-by-line — never rewrites the article body. Then reindex + structural lint.

    By default reads the edited review.xlsx back via read-review-xlsx.py (Python + openpyxl)
    to produce review-applied.json. Use -NoConvert to skip that and consume an existing JSON.

.EXAMPLE
    pwsh -File apply-review.ps1                       # convert review.xlsx, then apply
    pwsh -File apply-review.ps1 -NoConvert            # use existing .claude/review-applied.json
    pwsh -File apply-review.ps1 -InputFile path.json  # apply a specific JSON (no conversion)
    pwsh -File apply-review.ps1 -DryRun
#>
param([string]$InputFile = "", [switch]$DryRun, [switch]$NoConvert)

. "$PSScriptRoot\_config.ps1"

if (-not $InputFile) {
    $InputFile = Join-Path $CLAUDE_DIR "review-applied.json"
    if (-not $NoConvert) {
        # Regenerate review-applied.json from the edited review.xlsx
        $xlsx = Join-Path $CLAUDE_DIR "review.xlsx"
        if (-not (Test-Path $xlsx)) { Write-Host "Нет review.xlsx: $xlsx (сначала export-review.ps1)"; exit 1 }
        $py = Get-PythonCmd
        if (-not $py) { Write-Host "Python не найден. Установи Python, либо запусти с -NoConvert / -InputFile."; exit 1 }
        $readPy = Join-Path $SCRIPTS_DIR "read-review-xlsx.py"
        $pre = @($py.Pre)
        $env:PYTHONIOENCODING = 'utf-8'
        & $py.Exe @pre $readPy $CLAUDE_DIR
        if ($LASTEXITCODE -ne 0) { Write-Host "read-review-xlsx.py завершился с кодом $LASTEXITCODE"; exit 1 }
    }
}
if (-not (Test-Path $InputFile)) { Write-Host "Нет файла применения: $InputFile"; exit 1 }

$vocab = @(Get-DomainVocabulary)
$data  = Get-Content $InputFile -Raw -Encoding UTF8 | ConvertFrom-Json

$applied = 0; $notFound = @(); $droppedDomains = @()
foreach ($rec in @($data)) {
    if (-not $rec.file) { continue }
    $path = Join-Path $KNOWLEDGE_DIR ("$($rec.file).md")
    if (-not (Test-Path $path)) { $notFound += $rec.file; continue }

    $doms = @($rec.domains | ForEach-Object { ([string]$_).Trim().ToLower() } | Where-Object { $_ })
    foreach ($bad in @($doms | Where-Object { $_ -notin $vocab })) { $droppedDomains += "$($rec.file): $bad" }
    $doms = @($doms | Where-Object { $_ -in $vocab } | Select-Object -Unique)

    if ($DryRun) {
        Write-Host "[DRY] $($rec.file) -> scope=$($rec.scope) project=$($rec.project) domains=[$($doms -join ', ')]"
        continue
    }

    $raw = Get-Content $path -Raw -Encoding UTF8
    if ($rec.scope)   { $raw = Set-FrontmatterField $raw 'scope'          (([string]$rec.scope).Trim().ToLower()) }
    if ($rec.project) { $raw = Set-FrontmatterField $raw 'source_project' (([string]$rec.project).Trim()) }
    # Only write domains when the row actually has ticked ones — an empty set means
    # "not reviewed", not "clear domains". Writing [] unconditionally wiped existing /
    # live-tagged domains on every untouched row (incl. qa/, which is never tagged).
    if ($doms.Count) {
        $raw = Set-FrontmatterField $raw 'domains' ('[' + ($doms -join ', ') + ']')
    }
    [System.IO.File]::WriteAllText($path, $raw, [System.Text.Encoding]::UTF8)
    $applied++
}

if ($droppedDomains.Count) {
    Write-Host "Отброшены домены вне словаря:"
    $droppedDomains | ForEach-Object { Write-Host "  $_" }
}
if ($notFound.Count) { Write-Host "Не найдены статьи: $($notFound -join ', ')" }

if ($DryRun) { Write-Host "`n[DRY RUN] Ничего не записано."; exit 0 }

Write-Host "Применено к $applied статьям. Пересобираю индекс и линтую..."
try { & (Join-Path $SCRIPTS_DIR "reindex.ps1") }
catch { Write-Host "⚠ reindex.ps1 упал — индекс мог не обновиться: $_" }
try { & (Join-Path $SCRIPTS_DIR "lint.ps1") -StructuralOnly }
catch { Write-Host "⚠ lint.ps1 упал: $_" }
