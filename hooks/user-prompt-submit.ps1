#Requires -Version 7
<#
.SYNOPSIS
    UserPromptSubmit hook — domain accrual + mid-session top-up + vocab-gap logging.

    On every prompt (best-effort, ONE light-model call):
      1. Classifies the prompt against the controlled vocabulary (domains.md).
      2. Adds any domains missing from the project's profile (projects.json).
      3. Mid-session top-up: when $DOMAIN_FILTER is on, injects the global articles of the
         newly added domains right now — they were NOT in this session's start injection.
      4. Logs a suspected out-of-vocabulary domain to domain-gaps.log for later review.

    Never blocks or fails the prompt — any error just exits 0 with no output.
#>

# Cyrillic in additionalContext must reach Claude Code as UTF-8, not OEM mojibake.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$REPO_DIR = Split-Path $PSScriptRoot -Parent
. (Join-Path $REPO_DIR "scripts\_config.ps1")   # paths + registry + vocab + Get-RowDomains
. (Join-Path $REPO_DIR "scripts\_api.ps1")      # Invoke-ClaudeCLI + Get-DomainsForPrompt

# --- Current project + prompt from hook stdin ---
$projKey = ""
$prompt  = ""
try {
    $hookInput = Read-HookStdin
    if ($hookInput) {
        if ($hookInput.cwd)    { $projKey = Get-ProjectKey $hookInput.cwd }
        if ($hookInput.prompt) { $prompt  = [string]$hookInput.prompt }
    }
} catch { exit 0 }

if (-not $projKey -or $projKey -eq 'unknown' -or -not $prompt) { exit 0 }

try {
    $vocab = Get-DomainVocabulary
    if (-not $vocab -or $vocab.Count -eq 0) { exit 0 }

    # Profile BEFORE this prompt — to know what session-start already injected.
    $regBefore  = Load-Registry
    $oldDomains = if ($regBefore.ContainsKey($projKey)) {
        @($regBefore[$projKey]['domains'] | ForEach-Object { ([string]$_).ToLower() })
    } else { @() }

    $res    = Get-DomainsForPrompt -Prompt $prompt -Vocab $vocab
    $picked = @($res.Domains)
    $gap    = [string]$res.Gap

    # 4. Log out-of-vocabulary suspicion (independent of accrual).
    if ($gap) {
        try {
            $snip = ($prompt -replace '\r?\n', ' ')
            if ($snip.Length -gt 160) { $snip = $snip.Substring(0, 160) + '…' }
            $line = "[{0}] [{1}] кандидат: {2} | промпт: {3}" -f `
                (Get-Date -Format 'yyyy-MM-dd HH:mm'), $projKey, $gap, $snip
            Add-Content -Path $DOMAIN_GAPS_LOG -Value $line -Encoding UTF8
        } catch {}
    }

    if ($picked.Count -eq 0) { exit 0 }

    $added = Add-DomainsToRegistry -Key $projKey -Domains $picked
    if (-not $added -or @($added).Count -eq 0) { exit 0 }   # all already in profile

    $list = ($added -join ', ')
    $msg  = "[memory-compiler] В профиль проекта '$projKey' из этого запроса добавлены новые домены: $list."

    # 3. Mid-session top-up: global articles unlocked by the NEW domains — i.e. not already
    #    visible under the old profile (so not in this session's start injection).
    if ($DOMAIN_FILTER -and (Test-Path $INDEX_FILE)) {
        $addedLc = @($added | ForEach-Object { ([string]$_).ToLower() })
        $newRows = @(Get-IndexRows | Where-Object {
            ($_.scope -eq 'global' -or $_.scope -eq '')
        } | Where-Object {
            $rd = Get-RowDomains $_
            (@($rd | Where-Object { $_ -in $addedLc }).Count -gt 0) -and
            (@($rd | Where-Object { $_ -in $oldDomains }).Count -eq 0)
        })
        if ($newRows.Count) {
            $header = Get-IndexHeader
            $table  = "$header`n" + ((@($newRows | ForEach-Object { $_.raw })) -join "`n")
            $msg += "`n`nДогружены global-статьи новых доменов (стали релевантны прямо сейчас, $($newRows.Count) шт.):`n`n$table"
        }
    }

    $msg += "`n`nСообщи пользователю одной короткой строкой, что добавлены домены: $list (лишний убрать — /domains -<домен>)."

    Write-Output (@{
        hookSpecificOutput = @{
            hookEventName     = "UserPromptSubmit"
            additionalContext = $msg
        }
    } | ConvertTo-Json -Depth 5 -Compress)
} catch { exit 0 }

exit 0
