#Requires -Version 7
<#
.SYNOPSIS
    Lint the knowledge base for structural and semantic health.
    Runs 8 checks: broken links, orphan pages, orphan sources, stale articles,
    missing backlinks, sparse articles, scope audit, and LLM contradiction detection.

.EXAMPLE
    pwsh -File lint.ps1                     # all checks
    pwsh -File lint.ps1 -StructuralOnly     # skip LLM checks (free)
#>

param([switch]$StructuralOnly)

. "$PSScriptRoot\_config.ps1"
. "$PSScriptRoot\_api.ps1"

# --- Utility: extract [[wikilinks]] from markdown ---
function Get-Wikilinks([string]$Content) {
    [regex]::Matches($Content, '\[\[([^\]]+)\]\]') | ForEach-Object { $_.Groups[1].Value }
}

function Test-WikiArticleExists([string]$Link) {
    Test-Path (Join-Path $KNOWLEDGE_DIR "$Link.md")
}

# Get-AllArticles moved to _config.ps1 (shared) — lint calls it with -IncludeQa.

function Get-RelPath([string]$FullPath) {
    $FullPath.Substring($KNOWLEDGE_DIR.Length).TrimStart('\', '/')
}

# --- Check functions ---

function Check-BrokenLinks {
    $issues = @()
    foreach ($article in Get-AllArticles -IncludeQa) {
        $content = Get-Content $article.FullName -Raw -Encoding UTF8
        $rel     = Get-RelPath $article.FullName
        foreach ($link in Get-Wikilinks $content) {
            if ($link.StartsWith("daily/")) { continue }
            if (-not (Test-WikiArticleExists $link)) {
                $issues += @{ severity = "error"; check = "broken_link"; file = $rel;
                    detail = "Broken link: [[$link]] — target does not exist" }
            }
        }
    }
    return $issues
}

function Check-OrphanPages {
    $issues   = @()
    $articles = Get-AllArticles -IncludeQa
    # Collect every outbound link target once (O(n) reads instead of O(n^2)). Skip an
    # article's link to itself so a page that only self-references still reads as an orphan.
    $linked = @{}
    foreach ($article in $articles) {
        $self    = Get-ArticleKey $article.FullName
        $content = Get-Content $article.FullName -Raw -Encoding UTF8
        foreach ($link in (Get-Wikilinks $content)) {
            if ($link.StartsWith('daily/') -or $link -eq $self) { continue }
            $linked[$link] = $true
        }
    }
    foreach ($article in $articles) {
        $rel    = Get-RelPath $article.FullName
        $target = Get-ArticleKey $article.FullName
        if (-not $linked.ContainsKey($target)) {
            $issues += @{ severity = "warning"; check = "orphan_page"; file = $rel;
                detail = "Orphan page: no other articles link to [[$target]]" }
        }
    }
    return $issues
}

function Check-OrphanSources {
    $issues  = @()
    $state   = Load-State
    $ingested = $state['ingested'] ?? @{}
    if (-not (Test-Path $DAILY_DIR)) { return $issues }
    foreach ($log in (Get-ChildItem $DAILY_DIR -Filter "*.md")) {
        if (-not $ingested.ContainsKey($log.Name)) {
            $issues += @{ severity = "warning"; check = "orphan_source"; file = "daily/$($log.Name)";
                detail = "Uncompiled daily log: $($log.Name) has not been ingested" }
        }
    }
    return $issues
}

function Check-StaleArticles {
    $issues   = @()
    $state    = Load-State
    $ingested = $state['ingested'] ?? @{}
    if (-not (Test-Path $DAILY_DIR)) { return $issues }
    foreach ($log in (Get-ChildItem $DAILY_DIR -Filter "*.md")) {
        $prev = $ingested[$log.Name]
        if ($prev -and $prev['hash'] -ne (Get-FileHash256 $log.FullName)) {
            $issues += @{ severity = "warning"; check = "stale_article"; file = "daily/$($log.Name)";
                detail = "Stale: $($log.Name) changed since last compilation" }
        }
    }
    return $issues
}

function Check-MissingBacklinks {
    $issues = @()
    foreach ($article in Get-AllArticles -IncludeQa) {
        $content    = Get-Content $article.FullName -Raw -Encoding UTF8
        $rel        = Get-RelPath $article.FullName
        $sourceLink = Get-ArticleKey $article.FullName
        foreach ($link in Get-Wikilinks $content) {
            if ($link.StartsWith("daily/")) { continue }
            $targetPath = Join-Path $KNOWLEDGE_DIR "$link.md"
            if (Test-Path $targetPath) {
                $targetContent = Get-Content $targetPath -Raw -Encoding UTF8
                if ($targetContent -notmatch [regex]::Escape("[[$sourceLink]]")) {
                    $issues += @{ severity = "suggestion"; check = "missing_backlink"; file = $rel;
                        auto_fixable = $true
                        detail = "[[$sourceLink]] links to [[$link]] but not vice versa" }
                }
            }
        }
    }
    return $issues
}

function Check-SparseArticles {
    $issues = @()
    foreach ($article in Get-AllArticles -IncludeQa) {
        $content = Get-Content $article.FullName -Raw -Encoding UTF8
        # Strip YAML frontmatter at line boundaries (a `---` inside a value must not end it)
        $body = $content
        if ($content.StartsWith("---")) {
            $ls = $content -split "`r?`n"
            for ($i = 1; $i -lt $ls.Count; $i++) {
                if ($ls[$i].Trim() -eq '---') {
                    $body = if ($i + 1 -lt $ls.Count) { ($ls[($i + 1)..($ls.Count - 1)] -join "`n") } else { "" }
                    break
                }
            }
        }
        $wordCount = ($body -split '\s+' | Where-Object { $_ }).Count
        if ($wordCount -lt 200) {
            $rel = Get-RelPath $article.FullName
            $issues += @{ severity = "suggestion"; check = "sparse_article"; file = $rel;
                detail = "Sparse article: $wordCount words (min recommended: 200)" }
        }
    }
    return $issues
}

function Check-ScopeAudit {
    # Provenance/scope hygiene: every concept must carry type/scope/source_project.
    # This is an AUDITOR — it only flags, it never moves or relabels files.
    $issues     = @()
    $validScope = @('global', 'project')
    $validType  = @('concept', 'rule')

    foreach ($article in Get-AllArticles -IncludeQa) {
        $rel = Get-RelPath $article.FullName
        if ($rel -match '^qa[\\/]') { continue }                       # qa/ exempt
        $isConnection = $rel -match '^connections[\\/]'

        $raw = Get-Content $article.FullName -Raw -Encoding UTF8
        $f   = Get-ArticleFields $raw

        if (-not $f.scope) {
            $issues += @{ severity = "warning"; check = "scope_missing"; file = $rel;
                detail = "Нет поля scope (global|project)" }
        }
        elseif ($f.scope.ToLower() -notin $validScope) {
            $issues += @{ severity = "error"; check = "scope_invalid"; file = $rel;
                detail = "Недопустимый scope: '$($f.scope)' (ожидается global|project)" }
        }

        if (-not $f.type) {
            $issues += @{ severity = "warning"; check = "type_missing"; file = $rel;
                detail = "Нет поля type (concept|rule)" }
        }
        elseif ($f.type.ToLower() -notin $validType) {
            $issues += @{ severity = "error"; check = "type_invalid"; file = $rel;
                detail = "Недопустимый type: '$($f.type)' (ожидается concept|rule)" }
        }

        if (-not $isConnection -and -not $f.source_project) {
            $issues += @{ severity = "warning"; check = "source_project_missing"; file = $rel;
                detail = "Нет поля source_project (имя проекта или unknown)" }
        }
    }
    return $issues
}

function Check-Contradictions {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($article in Get-AllArticles -IncludeQa) {
        $rel     = Get-RelPath $article.FullName
        $content = Get-Content $article.FullName -Raw -Encoding UTF8
        $parts.Add("### $rel`n$content")
    }
    $wikiContent = $parts -join "`n`n---`n`n"

    $prompt = @"
Review this knowledge base for contradictions, inconsistencies, or conflicting claims.

## Knowledge Base
$wikiContent

## Instructions
Look for:
- Direct contradictions (article A says X, article B says not-X)
- Inconsistent recommendations
- Outdated information conflicting with newer entries

For each issue output EXACTLY one line:
CONTRADICTION: [file1] vs [file2] - description
INCONSISTENCY: [file] - description

If no issues found, output exactly: NO_ISSUES
Do NOT output anything else.
"@

    try {
        $text   = Invoke-ClaudeCLI -Prompt $prompt
        $issues = @()
        if ($text -notmatch "NO_ISSUES") {
            foreach ($line in ($text -split "`n")) {
                $line = $line.Trim()
                if ($line -match "^(CONTRADICTION|INCONSISTENCY):") {
                    $issues += @{ severity = "warning"; check = "contradiction";
                        file = "(cross-article)"; detail = $line }
                }
            }
        }
        return $issues
    }
    catch {
        return @(@{ severity = "error"; check = "contradiction"; file = "(system)";
            detail = "LLM check failed: $_" })
    }
}

# --- Run all checks ---

Write-Host "Running knowledge base lint checks..."
$allIssues = @()

$structuralChecks = @(
    @{ name = "Broken links";     fn = { Check-BrokenLinks } },
    @{ name = "Orphan pages";     fn = { Check-OrphanPages } },
    @{ name = "Orphan sources";   fn = { Check-OrphanSources } },
    @{ name = "Stale articles";   fn = { Check-StaleArticles } },
    @{ name = "Missing backlinks";fn = { Check-MissingBacklinks } },
    @{ name = "Sparse articles";  fn = { Check-SparseArticles } },
    @{ name = "Scope audit";      fn = { Check-ScopeAudit } }
)

foreach ($check in $structuralChecks) {
    Write-Host "  Checking: $($check.name)..."
    $issues = @(& $check.fn)
    $allIssues += $issues
    Write-Host "    Found $($issues.Count) issue(s)"
}

if (-not $StructuralOnly) {
    Write-Host "  Checking: Contradictions (LLM)..."
    $issues = @(Check-Contradictions)
    $allIssues += $issues
    Write-Host "    Found $($issues.Count) issue(s)"
}
else {
    Write-Host "  Skipping: Contradictions (--structural-only)"
}

# --- Generate report ---
$errors      = @($allIssues | Where-Object { $_.severity -eq "error" })
$warnings    = @($allIssues | Where-Object { $_.severity -eq "warning" })
$suggestions = @($allIssues | Where-Object { $_.severity -eq "suggestion" })
$today       = Get-TodayIso

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Lint Report — $today")
$lines.Add("")
$lines.Add("**Total issues:** $($allIssues.Count)")
$lines.Add("- Errors: $($errors.Count)")
$lines.Add("- Warnings: $($warnings.Count)")
$lines.Add("- Suggestions: $($suggestions.Count)")
$lines.Add("")

foreach ($group in @(
    @{ label = "Errors";      items = $errors;      marker = "x" },
    @{ label = "Warnings";    items = $warnings;    marker = "!" },
    @{ label = "Suggestions"; items = $suggestions; marker = "?" }
)) {
    if ($group.items.Count -gt 0) {
        $lines.Add("## $($group.label)")
        $lines.Add("")
        foreach ($issue in $group.items) {
            $fix = if ($issue.auto_fixable) { " (auto-fixable)" } else { "" }
            $lines.Add("- **[$($group.marker)]** ``$($issue.file)`` — $($issue.detail)$fix")
        }
        $lines.Add("")
    }
}

if (-not $allIssues) { $lines.Add("All checks passed. Knowledge base is healthy."); $lines.Add("") }

$report = $lines -join "`n"

if (-not (Test-Path $REPORTS_DIR)) { New-Item -ItemType Directory -Path $REPORTS_DIR -Force | Out-Null }
$reportPath = Join-Path $REPORTS_DIR "lint-$today.md"
[System.IO.File]::WriteAllText($reportPath, $report, [System.Text.Encoding]::UTF8)
Write-Host "`nReport saved to: $reportPath"

# Update state (atomic — a concurrent compile may be writing ingested at the same time)
Update-State { param($s) $s['last_lint'] = Get-NowIso } | Out-Null

Write-Host "`nResults: $($errors.Count) errors, $($warnings.Count) warnings, $($suggestions.Count) suggestions"
if ($errors.Count -gt 0) { Write-Host "`nErrors found — knowledge base needs attention!"; exit 1 }
