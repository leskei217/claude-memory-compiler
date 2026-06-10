#Requires -Version 7
<#
.SYNOPSIS
    List articles whose frontmatter has NO domains yet (empty/missing `domains:`).
    These are the ones to tag (via the Excel review, or tag-domains.ps1).

.EXAMPLE
    pwsh -File list-no-domains.ps1
#>

. "$PSScriptRoot\_config.ps1"

# Same set as tag-domains / suggest-domains (concepts + connections). QA articles
# aren't domain-tagged, so listing them here would flag them as missing forever.
$articles = @(Get-AllArticles)

$noDom = @()
foreach ($a in $articles) {
    $f = Get-ArticleFields (Get-Content $a.FullName -Raw -Encoding UTF8)
    $d = if ($f.domains) { ($f.domains -replace '[\[\]"\s]', '') } else { '' }
    if (-not $d) {
        $noDom += Get-ArticleKey $a.FullName
    }
}

Write-Host "Без доменов: $($noDom.Count) из $($articles.Count)"
$noDom | Sort-Object | ForEach-Object { Write-Host "  $_" }
