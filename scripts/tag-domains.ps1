#Requires -Version 7
<#
.SYNOPSIS
    Tag knowledge articles with DOMAINS from the controlled vocabulary (domains.md),
    writing the `domains:` field straight into each article's frontmatter. This is the
    LIVE pipeline step: compile.ps1 calls it after writing articles and before reindex,
    so every new or CHANGED article gets its domains automatically — no manual Excel
    pass. The vocabulary stays closed: anything outside domains.md is dropped.

    CHANGE DETECTION (hash gate). Each tagged article's content hash is remembered in
    state.json (`domains_tagged`). On the next run an article is (re)classified only if
    it is new or its content changed since last time; unchanged articles are skipped —
    including ones that legitimately matched no domain (asked once, not re-asked). On
    first run after this feature, articles that already carry domains are seeded into the
    hash store without an LLM call.

    -Force ignores the hash store and re-classifies everything.

.EXAMPLE
    pwsh -File tag-domains.ps1              # tag new / changed articles only
    pwsh -File tag-domains.ps1 -DryRun      # show what would happen, write nothing
    pwsh -File tag-domains.ps1 -Limit 3     # smoke test on the first 3 candidates
    pwsh -File tag-domains.ps1 -Force       # re-classify every article
#>
param([switch]$DryRun, [int]$Limit = 0, [switch]$Force)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$env:CLAUDE_INVOKED_BY = "memory_domains"
. "$PSScriptRoot\_config.ps1"
. "$PSScriptRoot\_api.ps1"

$vocab = @(Get-DomainVocabulary)
if ($vocab.Count -eq 0) { Write-Host "Словарь доменов пуст: $DOMAINS_FILE"; exit 1 }

$articles = @(Get-AllArticles)   # concepts + connections (qa is never domain-tagged)

# True if the article already carries at least one real domain (not empty / not `[]`).
function Test-HasDomains([string]$Raw) {
    $d = (Get-ArticleFields $Raw).domains
    if (-not $d) { return $false }
    return (($d -replace '[\[\]",\s]', '') -ne '')
}

# --- Decide which articles need (re)classification via the content-hash store ---
$state = Load-State
if (-not $state.ContainsKey('domains_tagged')) { $state['domains_tagged'] = @{} }
$tagState   = $state['domains_tagged']   # snapshot, for skip/seed read decisions
$tagUpdates = @{}                        # writes accumulate here, applied atomically at the end

$toClassify = @()
$skipped = 0; $seeded = 0
foreach ($a in $articles) {
    $rel = Get-ArticleKey $a.FullName
    $cur = Get-FileHash256 $a.FullName

    if (-not $Force) {
        if ($tagState[$rel] -eq $cur) { $skipped++; continue }            # unchanged since last tag
        if (-not $tagState.ContainsKey($rel) -and (Test-HasDomains (Get-Content $a.FullName -Raw -Encoding UTF8))) {
            if (-not $DryRun) { $tagUpdates[$rel] = $cur }                # migration seed: trust existing domains
            $seeded++; continue
        }
    }
    $toClassify += [pscustomobject]@{ file = $a; rel = $rel; hash = $cur }
}
if ($Limit -gt 0) { $toClassify = @($toClassify | Select-Object -First $Limit) }

$prefix = if ($DryRun) { "[DRY RUN] " } else { "" }
Write-Host "${prefix}Домены: $($articles.Count) статей | без изменений: $skipped | засеяно: $seeded | к классификации: $($toClassify.Count). Словарь: $($vocab.Count) доменов."

# --- Classify and write ---
$i = 0; $tagged = 0; $failed = 0
foreach ($c in $toClassify) {
    $i++
    $raw = Get-Content $c.file.FullName -Raw -Encoding UTF8
    try { $picked = @(Get-DomainsForArticle -Body $raw -Vocab $vocab) }
    catch { Write-Host "  [$i/$($toClassify.Count)] $($c.file.Name) -> ОШИБКА LLM, пропуск ($_)"; $failed++; continue }

    if ($picked.Count -eq 0) {
        Write-Host "  [$i/$($toClassify.Count)] $($c.file.Name) -> (нет подходящих)"
        if (-not $DryRun) { $tagUpdates[$c.rel] = $c.hash }              # asked once; don't re-ask until it changes
        continue
    }

    Write-Host "  [$i/$($toClassify.Count)] $($c.file.Name) -> $($picked -join ', ')"
    if (-not $DryRun) {
        $new = Set-FrontmatterField $raw 'domains' "[$($picked -join ', ')]"
        [System.IO.File]::WriteAllText($c.file.FullName, $new, [System.Text.Encoding]::UTF8)
        $tagUpdates[$c.rel] = Get-FileHash256 $c.file.FullName           # store the post-write hash
        $tagged++
    }
}

if (-not $DryRun -and $tagUpdates.Count) {
    Update-State {
        param($s)
        if (-not $s.ContainsKey('domains_tagged')) { $s['domains_tagged'] = @{} }
        foreach ($k in $tagUpdates.Keys) { $s['domains_tagged'][$k] = $tagUpdates[$k] }
    } | Out-Null
}
Write-Host "`nГотово. Проставлено: $tagged | без изменений: $skipped | засеяно: $seeded | ошибок LLM: $failed$(if ($DryRun) { ' (dry-run, ничего не записано)' })."
