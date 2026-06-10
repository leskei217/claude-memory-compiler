#Requires -Version 7
<#
.SYNOPSIS
    Rebuild knowledge/index.md deterministically from article frontmatter.

    The index is a pure projection of every article's frontmatter. session-start
    filtering depends on accurate Type/Scope/Project columns, so the index is built
    by code here — NOT by the LLM during compile.

.EXAMPLE
    pwsh -File reindex.ps1
#>

. "$PSScriptRoot\_config.ps1"

# First prose line after the frontmatter / heading — used as a Summary fallback
# when an article has no `summary:` field (legacy concepts, connections).
function Get-LeadSentence([string]$Raw) {
    if (-not $Raw) { return "" }
    $t    = $Raw.TrimStart([char]0xFEFF)
    $body = $t
    if ($t.StartsWith("---")) {
        $idx = $t.IndexOf("`n---", 3)
        # Frontmatter opened but never closed → there is no body to summarize. Returning
        # here avoids leaking a frontmatter line (e.g. "title: ...") as the Summary.
        if ($idx -lt 0) { return "" }
        $nl = $t.IndexOf("`n", $idx + 1)
        if ($nl -ge 0) { $body = $t.Substring($nl + 1) }
    }
    foreach ($line in ($body -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith("#") -or $l.StartsWith("---")) { continue }
        if ($l.Length -gt 140) { $l = $l.Substring(0, 137) + "..." }
        return $l
    }
    return ""
}

# Escape pipes / newlines so a cell never breaks the markdown table.
function Format-Cell([string]$s) {
    if (-not $s) { return "" }
    return ($s -replace '\r?\n', ' ' -replace '\|', '\|')
}

$rows = [System.Collections.Generic.List[string]]::new()

foreach ($md in (Get-AllArticles -IncludeQa)) {
    $raw     = Get-Content $md.FullName -Raw -Encoding UTF8
    $f       = Get-ArticleFields $raw
    $link    = "[[" + (Get-ArticleKey $md.FullName) + "]]"
    $type    = if ($f.type)           { $f.type }           else { "concept" }
    $scope   = if ($f.scope)          { $f.scope }          else { "" }
    $proj    = if ($f.source_project) { $f.source_project } else { "" }
    $summary = if ($f.summary)        { $f.summary }        else { Get-LeadSentence $raw }
    $src     = if ($f.first_source)   { $f.first_source }   else { "" }
    $upd     = if ($f.updated)        { $f.updated }        elseif ($f.filed) { $f.filed } else { "" }
    $dom     = if ($f.domains)        { ($f.domains -replace '[\[\]"]', '').Trim() } else { "" }

    $rows.Add("| $link | $(Format-Cell $type) | $(Format-Cell $scope) | $(Format-Cell $proj) | $(Format-Cell $dom) | $(Format-Cell $summary) | $(Format-Cell $src) | $(Format-Cell $upd) |")
}

$header = @(
    "# Knowledge Base Index",
    "",
    "| Article | Type | Scope | Project | Domains | Summary | Compiled From | Updated |",
    "|---------|------|-------|---------|---------|---------|---------------|---------|"
)

$content = (($header + $rows) -join "`n") + "`n"
if (-not (Test-Path $KNOWLEDGE_DIR)) { New-Item -ItemType Directory -Path $KNOWLEDGE_DIR -Force | Out-Null }
[System.IO.File]::WriteAllText($INDEX_FILE, $content, [System.Text.Encoding]::UTF8)
Write-Host "Index rebuilt: $($rows.Count) articles -> $INDEX_FILE"
