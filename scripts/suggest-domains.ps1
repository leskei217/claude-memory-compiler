#Requires -Version 7
<#
.SYNOPSIS
    Suggest knowledge DOMAINS for each article via the LLM, picking only from the
    controlled vocabulary (domains.md). Writes a suggestions map to
    domain-suggestions.json — it does NOT modify article frontmatter. The suggestions
    are reviewed in Excel and then written for real by apply-review. Resumable.

.EXAMPLE
    pwsh -File suggest-domains.ps1            # all articles not yet suggested
    pwsh -File suggest-domains.ps1 -Limit 5   # smoke test
    pwsh -File suggest-domains.ps1 -Force     # redo all
#>
param([int]$Limit = 0, [switch]$Force)

$env:CLAUDE_INVOKED_BY = "memory_domains"
. "$PSScriptRoot\_config.ps1"
. "$PSScriptRoot\_api.ps1"

$OUT   = Join-Path $CLAUDE_DIR "domain-suggestions.json"
$vocab = @(Get-DomainVocabulary)
if ($vocab.Count -eq 0) { Write-Host "Словарь доменов пуст: $DOMAINS_FILE"; exit 1 }

$sug = @{}
if (Test-Path $OUT) {
    try { $sug = Get-Content $OUT -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { $sug = @{} }
}
if ($sug -isnot [hashtable]) { $sug = @{} }

$articles = @()
foreach ($d in @($CONCEPTS_DIR, $CONNECTIONS_DIR)) {
    if (Test-Path $d) { $articles += Get-ChildItem $d -Filter "*.md" | Sort-Object Name }
}
function Get-RelKey([string]$Full) { (($Full.Substring($KNOWLEDGE_DIR.Length).TrimStart('\', '/')) -replace '\\', '/') -replace '\.md$', '' }

$pending = @($articles | Where-Object { $Force -or -not $sug.ContainsKey((Get-RelKey $_.FullName)) })
if ($Limit -gt 0) { $pending = $pending | Select-Object -First $Limit }
$pending = @($pending)

Write-Host "Домены: $($articles.Count) статей, к обработке $($pending.Count). Словарь: $($vocab.Count) доменов."

$i = 0
foreach ($a in $pending) {
    $i++
    $key    = Get-RelKey $a.FullName
    $body   = Get-Content $a.FullName -Raw -Encoding UTF8
    try { $picked = @(Get-DomainsForArticle -Body $body -Vocab $vocab) }
    catch { Write-Host "  ! $($a.Name): ошибка LLM, пропуск"; continue }

    $sug[$key] = $picked
    $sug | ConvertTo-Json -Depth 5 | Set-Content -Path $OUT -Encoding UTF8
    Write-Host "  [$i/$($pending.Count)] $($a.Name) -> $(if ($picked.Count) { $picked -join ', ' } else { '(нет)' })"
}

Write-Host "`nГотово. Подсказки доменов: $OUT"
