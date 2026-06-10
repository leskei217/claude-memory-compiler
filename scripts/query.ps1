#Requires -Version 7
<#
.SYNOPSIS
    Query the knowledge base using index-guided retrieval (no RAG).
    Uses claude CLI — no API key required.

.EXAMPLE
    pwsh -File query.ps1 "How do I usually handle API errors?"
    pwsh -File query.ps1 "What auth patterns do I use?" -FileBack
#>

param(
    [Parameter(Mandatory, Position = 0)][string]$Question,
    [switch]$FileBack
)

. "$PSScriptRoot\_config.ps1"
. "$PSScriptRoot\_api.ps1"

$env:CLAUDE_INVOKED_BY = "memory_query"

# Get-AllWikiContent moved to _config.ps1 (shared with compile.ps1).
$wikiContent = Get-AllWikiContent
$timestamp   = Get-NowIso

$fileBackSection = ""
if ($FileBack) {
    $fileBackSection = @"

## File Back

After answering, save the Q&A using the file-operation format below.

<<<WRITE:knowledge/qa/[kebab-case-filename].md>>>
[Q&A article content per AGENTS.md schema]
<<<END>>>

<<<APPEND:knowledge/index.md>>>
| [[qa/[filename]]] | [one-line summary] | query | $(($timestamp -split 'T')[0]) |
<<<END>>>

<<<APPEND:knowledge/log.md>>>
## [$timestamp] query (filed) | $Question
- Filed to: [[qa/[filename]]]
<<<END>>>

Replace [kebab-case-filename] with a slug of the question. Output the answer FIRST, then the file operations.
"@
}

$prompt = @"
You are a knowledge base query engine. Answer the user's question by consulting
the knowledge base below.

## How to Answer
1. Read the INDEX first.
2. Identify relevant articles.
3. Synthesize a clear answer with [[wikilink]] citations.
4. If the knowledge base has no relevant info, say so honestly.

## Knowledge Base
$wikiContent

## Question
$Question
$fileBackSection
"@

Write-Host "Question: $Question"
Write-Host "File back: $(if ($FileBack) { 'yes' } else { 'no' })"
Write-Host ("-" * 60)

try {
    $response = Invoke-ClaudeCLI -Prompt $prompt

    if ($FileBack) {
        # Split answer text from file ops
        $firstOp = $response.IndexOf("<<<WRITE:")
        if ($firstOp -lt 0) { $firstOp = $response.IndexOf("<<<APPEND:") }
        $answer = if ($firstOp -gt 0) { $response.Substring(0, $firstOp).Trim() } else { $response }

        Write-Host $answer
        Write-Host ""

        $opsCount = Invoke-ParseFileOps -Text $response -RootDir $CLAUDE_DIR -AllowedSubdir 'knowledge'
        Update-State { param($s) $s['query_count'] = ([int]($s['query_count'] ?? 0)) + 1 } | Out-Null

        Write-Host "`n$("-" * 60)"
        $qaCount = if (Test-Path $QA_DIR) { @(Get-ChildItem $QA_DIR -Filter "*.md").Count } else { 0 }
        Write-Host "Answer filed to knowledge\qa\ ($qaCount Q&A articles total, $opsCount file ops)"
    }
    else {
        Write-Host $response
        Update-State { param($s) $s['query_count'] = ([int]($s['query_count'] ?? 0)) + 1 } | Out-Null
    }
}
catch {
    Write-Error "Query failed: $_"
    exit 1
}
