#Requires -Version 7
<#
.SYNOPSIS
    List articles whose frontmatter has NO domains yet (empty/missing `domains:`).
    These are the ones to tag (via the Excel review, or tag-domains.ps1).

.EXAMPLE
    pwsh -File list-no-domains.ps1
#>

. "$PSScriptRoot\_config.ps1"

$articles = @()
# Same set as tag-domains / suggest-domains (concepts + connections). QA articles
# aren't domain-tagged, so listing them here would flag them as missing forever.
foreach ($d in @($CONCEPTS_DIR, $CONNECTIONS_DIR)) {
    if (Test-Path $d) { $articles += Get-ChildItem $d -Filter "*.md" }
}

$noDom = @()
foreach ($a in $articles) {
    $f = Get-ArticleFields (Get-Content $a.FullName -Raw -Encoding UTF8)
    $d = if ($f.domains) { ($f.domains -replace '[\[\]"\s]', '') } else { '' }
    if (-not $d) {
        $noDom += (($a.FullName.Substring($KNOWLEDGE_DIR.Length).TrimStart('\', '/')) -replace '\\', '/') -replace '\.md$', ''
    }
}

Write-Host "Без доменов: $($noDom.Count) из $($articles.Count)"
$noDom | Sort-Object | ForEach-Object { Write-Host "  $_" }
