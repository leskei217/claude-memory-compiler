#Requires -Version 7
<#
.SYNOPSIS
    Build review-data.json for the manual Excel review: one record per article with its
    current frontmatter (title/type/scope/source_project/summary) plus suggested domains
    (from domain-suggestions.json, or existing frontmatter domains if already set).
    A separate step renders this into review.xlsx with one checkbox column per domain.
#>

. "$PSScriptRoot\_config.ps1"

$SUGFILE = Join-Path $CLAUDE_DIR "domain-suggestions.json"
$sug = @{}
if (Test-Path $SUGFILE) {
    try { $sug = Get-Content $SUGFILE -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { $sug = @{} }
}
$vocab = @(Get-DomainVocabulary)

$records = [System.Collections.Generic.List[object]]::new()
foreach ($md in (Get-AllArticles -IncludeQa)) {
    $raw = Get-Content $md.FullName -Raw -Encoding UTF8
    $f   = Get-ArticleFields $raw
    $rel = Get-ArticleKey $md.FullName

    # current = domains already in frontmatter (empty → needs tagging)
    $cur = @()
    if ($f.domains) {
        $cur = @(($f.domains -replace '[\[\]"]', '') -split '[,;]' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    }
    # domains = checkbox prefill: current if present, else LLM suggestion
    $dom = if ($cur.Count) { $cur } elseif ($sug.ContainsKey($rel)) { @($sug[$rel]) } else { @() }

    $records.Add([pscustomobject]@{
        file    = $rel
        title   = [string]$f.title
        type    = [string]$f.type
        scope   = [string]$f.scope
        project = [string]$f.source_project
        summary = [string]$f.summary
        current = @($cur | Where-Object { $_ -in $vocab } | Select-Object -Unique)
        domains = @($dom | Where-Object { $_ -in $vocab } | Select-Object -Unique)
    })
}

$out = Join-Path $CLAUDE_DIR "review-data.json"
([ordered]@{ vocab = $vocab; records = $records }) | ConvertTo-Json -Depth 6 | Set-Content -Path $out -Encoding UTF8
Write-Host "review-data.json: $($records.Count) статей, словарь $($vocab.Count) доменов -> $out"

# --- Render review.xlsx (Python + openpyxl) ---
$buildPy = Join-Path $SCRIPTS_DIR "build-review-xlsx.py"
$py = Get-PythonCmd
if (-not $py) {
    Write-Host "Python не найден — review.xlsx не собран. Установи Python и собери вручную:"
    Write-Host "  py -3 `"$buildPy`" `"$CLAUDE_DIR`""
    exit 1
}
$pre = @($py.Pre)
$env:PYTHONIOENCODING = 'utf-8'
& $py.Exe @pre $buildPy $CLAUDE_DIR
if ($LASTEXITCODE -ne 0) { Write-Host "build-review-xlsx.py завершился с кодом $LASTEXITCODE"; exit 1 }
Write-Host "Отредактируй review.xlsx в $CLAUDE_DIR, затем: pwsh -File scripts/apply-review.ps1"
