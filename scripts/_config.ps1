# Shared path constants — dot-source this file: . "$PSScriptRoot\_config.ps1"

# --- Repo paths (code, scripts, config) ---
$REPO_DIR    = Split-Path $PSScriptRoot -Parent
$SCRIPTS_DIR = $PSScriptRoot
$HOOKS_DIR   = Join-Path $REPO_DIR "hooks"
$AGENTS_FILE = Join-Path $REPO_DIR "AGENTS.md"

# --- Brain directory (personal data — configured once via setup.ps1) ---
$BRAIN_PATH_FILE = Join-Path $REPO_DIR "brain.path"
if (Test-Path $BRAIN_PATH_FILE) {
    $BRAIN_DIR = (Get-Content $BRAIN_PATH_FILE -Raw -Encoding UTF8).Trim()
} else {
    $BRAIN_DIR = $REPO_DIR
    Write-Warning "brain.path not configured. Run: pwsh -File setup.ps1"
}

# --- Claude data root (hidden subfolder, like .git/) ---
$CLAUDE_DIR      = Join-Path $BRAIN_DIR ".claude"

# --- Data paths (all inside .claude/) ---
$DAILY_DIR       = Join-Path $CLAUDE_DIR "daily"
$KNOWLEDGE_DIR   = Join-Path $CLAUDE_DIR "knowledge"
$CONCEPTS_DIR    = Join-Path $KNOWLEDGE_DIR "concepts"
$CONNECTIONS_DIR = Join-Path $KNOWLEDGE_DIR "connections"
$QA_DIR          = Join-Path $KNOWLEDGE_DIR "qa"
$REPORTS_DIR     = Join-Path $CLAUDE_DIR "reports"
$INDEX_FILE      = Join-Path $KNOWLEDGE_DIR "index.md"
$KB_LOG_FILE     = Join-Path $KNOWLEDGE_DIR "log.md"
$STATE_FILE      = Join-Path $CLAUDE_DIR "state.json"
$FLUSH_LOG       = Join-Path $CLAUDE_DIR "flush.log"
$REGISTRY_FILE   = Join-Path $CLAUDE_DIR "projects.json"
$RETRO_STATE_FILE = Join-Path $CLAUDE_DIR "retro-processed.json"
$DOMAINS_FILE    = Join-Path $CLAUDE_DIR "domains.md"
$DOMAIN_GAPS_LOG = Join-Path $CLAUDE_DIR "domain-gaps.log"

# --- Model / tuning ---
$DEFAULT_MODEL      = "claude-sonnet-4-6"
$DOMAINIZE_MODEL    = "claude-haiku-4-5"   # лёгкий классификатор промпт→домены (UserPromptSubmit)
$DOMAIN_FILTER      = $true                 # инжект global фильтруется по доменам проекта (fail-closed); $false → весь global (прежнее поведение)
$COMPILE_AFTER_HOUR = 18
$MAX_TURNS          = 30
$MAX_CONTEXT_CHARS  = 15000

# --- Helpers ---
function Get-NowIso  { (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz") }
function Get-TodayIso { (Get-Date).ToString("yyyy-MM-dd") }

function Get-FileHash256([string]$Path) {
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hex   = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').ToLower()
    $sha.Dispose()
    return $hex.Substring(0, 16)
}

function Load-State {
    if (Test-Path $STATE_FILE) {
        try { return (Get-Content $STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable) }
        catch {}
    }
    return @{ ingested = @{}; query_count = 0; last_lint = $null; total_tokens = 0 }
}

function Save-State([hashtable]$State) {
    # Atomic write: serialize to a temp file then rename over the target. A crash or a
    # concurrent writer (the end-of-day compile spawn) can no longer leave a half-written
    # state.json that Load-State would silently reset to defaults.
    $tmp = "$STATE_FILE.tmp"
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $STATE_FILE -Force
}

# Cross-process-safe read-modify-write of state.json. Holds a named mutex (keyed to the
# state-file path) only for the brief reload→mutate→save window, so two concurrent runs
# (e.g. the end-of-day compile spawn racing a manual compile, or compile vs its child
# tag-domains) can't lose each other's updates the way Load→…→Save in each process would.
# $Mutator receives the freshly-reloaded [hashtable] and mutates it in place.
function Update-State([scriptblock]$Mutator) {
    $keyHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($STATE_FILE))
    ).Replace('-', '').Substring(0, 16)
    $mutex = [System.Threading.Mutex]::new($false, "Global\cmc_state_$keyHash")
    $owned = $false
    try {
        # AbandonedMutex = a previous holder died mid-write; we still get ownership.
        try { $owned = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        $state = Load-State
        & $Mutator $state
        Save-State $state
        return $state
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Read and parse hook stdin JSON. Tries a clean parse first (the normal case — valid JSON);
# only on failure applies a best-effort fix for un-escaped Windows backslashes (a lone "\"
# in cwd) and retries. Valid input is never mangled. Returns the parsed object, or $null.
# Shared by all four hooks so they handle stdin identically.
function Read-HookStdin {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch {}
    try {
        $fixed = $raw -replace '(?<!\\)\\(?!["\\/bfnrtu])', '\\'
        return ($fixed | ConvertFrom-Json)
    } catch { return $null }
}

# retro-processed.json: which transcript sessions are already in the daily logs.
# Written by retrocompile (batch) AND flush (live hook), so the schema lives here.
function Load-RetroState {
    if (Test-Path $RETRO_STATE_FILE) {
        try { return (Get-Content $RETRO_STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable) }
        catch {}
    }
    return @{ processed = @{} }
}

function Save-RetroState([hashtable]$State) {
    if (-not $State.ContainsKey('processed')) { $State['processed'] = @{} }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $RETRO_STATE_FILE -Encoding UTF8
}

# Resolve a Python 3 launcher for the optional Excel-review tooling (needs openpyxl).
# Returns @{ Exe='py'; Pre=@('-3') } / @{ Exe='python'; Pre=@() }, or $null if none found.
function Get-PythonCmd {
    if (Get-Command py      -ErrorAction SilentlyContinue) { return @{ Exe = 'py';      Pre = @('-3') } }
    if (Get-Command python  -ErrorAction SilentlyContinue) { return @{ Exe = 'python';  Pre = @() } }
    if (Get-Command python3 -ErrorAction SilentlyContinue) { return @{ Exe = 'python3'; Pre = @() } }
    return $null
}

# Extract user/assistant turns from a Claude Code JSONL transcript as
# "**<Label>:** <text>" strings. ONE parser shared by the session-end / pre-compact
# hooks and retrocompile, so transcript handling (roles, content flattening, new block
# types) can never drift between them.
function Get-TranscriptTurns {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$UserLabel      = 'User',
        [string]$AssistantLabel = 'Assistant',
        [int]$MaxTurnChars      = 0,      # 0 = no per-turn truncation
        [switch]$SkipInjected             # drop hook-injected payloads (KB index etc.)
    )
    $turns = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content -Path $Path -Encoding UTF8)) {
        $line = $line.Trim()
        if (-not $line) { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }

        $msg = $entry.message
        if ($msg -and $msg.PSObject.Properties['role']) { $role = $msg.role; $content = $msg.content }
        else { $role = $entry.role; $content = $entry.content }
        if ($role -notin @('user', 'assistant')) { continue }

        # Flatten array content (tool results, image blocks, etc.)
        if ($content -isnot [string]) {
            $parts = foreach ($block in @($content)) {
                if ($block.type -eq 'text') { $block.text } elseif ($block -is [string]) { $block }
            }
            $content = (@($parts | Where-Object { $_ }) -join "`n")
        }
        $text = ([string]$content).Trim()
        if (-not $text) { continue }
        if ($SkipInjected -and $role -eq 'user' -and $text.Length -gt 1000 -and
            ($text -match 'Knowledge Base Index|SessionStart hook|## Today\b')) { continue }
        if ($MaxTurnChars -gt 0 -and $text.Length -gt $MaxTurnChars) {
            $text = $text.Substring(0, $MaxTurnChars) + '…'
        }
        $label = if ($role -eq 'user') { $UserLabel } else { $AssistantLabel }
        $turns.Add("**${label}:** $text")
    }
    return , $turns
}

# --- Project provenance (scope routing) ---

# Decode a Claude Code project-folder name into a readable project label.
#   E:\Leskei\project            → E--Leskei-project       (: → --, \ → -)
#   E:\Leskei\deep\nested\proj   → E--Leskei--deep--nested--proj
function Get-ProjectLabel([string]$FolderName) {
    $clean = ($FolderName -replace '^[A-Za-z]--', '').TrimEnd('-')
    $segments = @(($clean -split '-{2,}') | Where-Object { $_ -ne '' -and $_.Length -gt 1 })

    if ($segments.Count -gt 1) { return $segments[-1] }

    $target  = if ($segments.Count -eq 1) { $segments[0] } else { $clean }
    $dashPos = $target.IndexOf('-')
    if ($dashPos -gt 0) {
        $rest = $target.Substring($dashPos + 1)
        if ($rest.Length -ge 3) { return $rest }
    }
    return $target
}

# Walk up from a path to the nearest git repo root. Returns the repo root, or the
# path itself if no .git is found above it.
function Get-ProjectRoot([string]$Path) {
    if (-not $Path) { return $null }
    $cur = $Path
    while ($cur) {
        if (Test-Path (Join-Path $cur ".git")) { return $cur }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return $Path
}

# Stable project key for scope matching: the folder name of the git repo root
# (or of the cwd if not a repo). Home directory / empty → "unknown".
function Get-ProjectKey([string]$Path) {
    if (-not $Path) { return "unknown" }
    $userHome = [Environment]::GetFolderPath('UserProfile')
    $root = Get-ProjectRoot $Path
    if (-not $root) { return "unknown" }
    $norm = $root.TrimEnd('\', '/')
    if ($norm -ieq $userHome.TrimEnd('\', '/')) { return "unknown" }
    return (Split-Path $norm -Leaf)
}

# Project registry (.claude/projects.json). Schema: key → @{ roots=[paths]; domains=[...] }.
# Load migrates the legacy array form (key → [paths]) to the object form on read.
function Load-Registry {
    $reg = @{}
    if (Test-Path $REGISTRY_FILE) {
        try { $reg = Get-Content $REGISTRY_FILE -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
        catch {
            Write-Warning "Load-Registry: повреждён $REGISTRY_FILE — $_"
            try { Copy-Item $REGISTRY_FILE "$REGISTRY_FILE.bak" -Force } catch {}
            $reg = @{}
        }
    }
    if ($reg -isnot [hashtable]) { $reg = @{} }
    foreach ($k in @($reg.Keys)) {
        $v = $reg[$k]
        if ($v -is [hashtable]) {
            # Always materialize roots/domains as arrays — ConvertTo-Json collapses a
            # single-element list to a scalar on disk; @() restores the array shape.
            $v['roots']   = @($v['roots']   | Where-Object { $null -ne $_ -and $_ -ne '' })
            $v['domains'] = @($v['domains'] | Where-Object { $null -ne $_ -and $_ -ne '' })
        }
        elseif ($v -is [System.Collections.IList]) { $reg[$k] = @{ roots = @($v); domains = @() } }
        else { $reg[$k] = @{ roots = @(); domains = @() } }
    }
    return $reg
}

function Save-Registry([hashtable]$Reg) {
    try { $Reg | ConvertTo-Json -Depth 6 | Set-Content -Path $REGISTRY_FILE -Encoding UTF8 }
    catch { Write-Warning "Save-Registry: не удалось записать $REGISTRY_FILE — $_" }
}

# Record key → repo-root path. Collision signal: a key mapping to 2+ distinct roots
# means the folder-name key is ambiguous. Preserves any existing domains.
function Add-ProjectToRegistry([string]$Key, [string]$Root) {
    if (-not $Key -or $Key -eq 'unknown' -or -not $Root) { return }
    $reg = Load-Registry
    if (-not $reg.ContainsKey($Key)) { $reg[$Key] = @{ roots = @(); domains = @() } }
    $roots = @($reg[$Key]['roots']) | Where-Object { $_ }
    if ($roots -notcontains $Root) { $reg[$Key]['roots'] = @($roots + $Root | Select-Object -Unique) }
    Save-Registry $reg
}

# Union domains into a project's profile in the registry. Creates the entry if missing
# (roots stay empty — session-end fills them). Returns only the domains actually added.
function Add-DomainsToRegistry([string]$Key, [string[]]$Domains) {
    if (-not $Key -or $Key -eq 'unknown') { return @() }
    $incoming = @($Domains | Where-Object { $_ } | ForEach-Object { $_.ToLower() } | Select-Object -Unique)
    if ($incoming.Count -eq 0) { return @() }
    $reg = Load-Registry
    if (-not $reg.ContainsKey($Key)) { $reg[$Key] = @{ roots = @(); domains = @() } }
    $current = @($reg[$Key]['domains'])
    $added   = @($incoming | Where-Object { $_ -notin $current })
    if ($added.Count -eq 0) { return @() }
    $reg[$Key]['domains'] = @($current + $added | Select-Object -Unique)
    Save-Registry $reg
    return $added
}

# Controlled domain vocabulary from domains.md: the first whitespace-token of each
# non-comment line (hyphens kept, e.g. "legal-finance"). Lowercased, unique.
function Get-DomainVocabulary {
    $vocab = @()
    if (Test-Path $DOMAINS_FILE) {
        foreach ($line in (Get-Content $DOMAINS_FILE -Encoding UTF8)) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            $key = ($t -split '\s+', 2)[0].Trim().ToLower()
            if ($key) { $vocab += $key }
        }
    }
    return @($vocab | Select-Object -Unique)
}

# Enumerate knowledge articles (concepts + connections, optionally qa), each subdir
# sorted by name. One definition instead of nine hand-rolled loops with drifting
# subdir sets and sort flags.
function Get-AllArticles([switch]$IncludeQa) {
    $dirs = @($CONCEPTS_DIR, $CONNECTIONS_DIR)
    if ($IncludeQa) { $dirs += $QA_DIR }
    $result = @()
    foreach ($d in $dirs) {
        if (Test-Path $d) { $result += Get-ChildItem $d -Filter "*.md" | Sort-Object Name }
    }
    return $result
}

# Knowledge-relative article key: "concepts/foo" (forward slashes, no .md) — the form
# used as the [[wikilink]] target, the index link, and the hash-store key. Replaces
# the Get-Rel/Get-RelKey/inline variants that drifted across scripts.
function Get-ArticleKey([string]$FullPath) {
    (($FullPath.Substring($KNOWLEDGE_DIR.Length).TrimStart('\', '/')) -replace '\\', '/') -replace '\.md$', ''
}

# First two table lines of index.md (header + separator) — for rendering filtered
# index tables. Shared by session-start and the user-prompt-submit top-up.
function Get-IndexHeader {
    if (-not (Test-Path $INDEX_FILE)) { return "" }
    $tableLines = @(Get-Content $INDEX_FILE -Encoding UTF8 | Where-Object { $_ -match '^\s*\|' })
    return (@($tableLines | Select-Object -First 2)) -join "`n"
}

# Serialize the whole knowledge base (index + every article) for LLM prompts.
# Shared by compile and query; $EmptyIndexText is what to show when index.md is missing.
function Get-AllWikiContent([string]$EmptyIndexText = "(empty — no articles compiled yet)") {
    $parts = [System.Collections.Generic.List[string]]::new()
    $idxContent = if (Test-Path $INDEX_FILE) { Get-Content $INDEX_FILE -Raw -Encoding UTF8 } else { $EmptyIndexText }
    $parts.Add("## INDEX`n`n$idxContent")

    foreach ($md in (Get-AllArticles -IncludeQa)) {
        $rel     = $md.FullName.Substring($KNOWLEDGE_DIR.Length).TrimStart('\', '/')
        $content = Get-Content $md.FullName -Raw -Encoding UTF8
        $parts.Add("## $rel`n`n$content")
    }
    return $parts -join "`n`n---`n`n"
}

# Pragmatic YAML-frontmatter reader. Returns a hashtable of scalar fields (lowercased
# keys) plus 'first_source'. Not a full YAML parser — handles `key: value` lines and
# the `sources:` block list. Used by reindex / lint / reclassify.
function Get-ArticleFields([string]$Raw) {
    $fields = @{}
    if (-not $Raw) { return $fields }
    $trimmed = $Raw.TrimStart([char]0xFEFF)
    if (-not $trimmed.StartsWith("---")) { return $fields }

    $lines  = $trimmed -split "`r?`n"
    $endIdx = $lines.Count - 1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "---") { $endIdx = $i; break }
        if ($lines[$i] -match '^\s*([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
            $key = $matches[1].ToLower()
            $val = $matches[2].Trim().Trim('"')
            if ($val) { $fields[$key] = $val }
        }
    }
    # Inner frontmatter only (between the --- fences) so the closing --- can't be
    # mistaken for a list item.
    $fm = if ($endIdx -gt 1) { ($lines[1..($endIdx - 1)] -join "`n") } else { "" }

    # `domains` may be inline ([a, b]) — caught above — or a YAML block list. Normalize
    # the block form to the inline string "[a, b]" that every reader already expects.
    if (-not $fields.ContainsKey('domains')) {
        $dm = [regex]::Match($fm, '(?m)^domains:[ \t]*\r?\n((?:[ \t]*-[ \t]*.+\r?\n?)+)')
        if ($dm.Success) {
            $items = @($dm.Groups[1].Value -split "`r?`n" | ForEach-Object {
                if ($_ -match '^\s*-\s*"?([^"]+?)"?\s*$') { $matches[1].Trim() }
            } | Where-Object { $_ })
            if ($items.Count) { $fields['domains'] = '[' + ($items -join ', ') + ']' }
        }
    }

    $m = [regex]::Match($fm, '(?ms)^sources:\s*\r?\n\s*-\s*"?([^"\r\n]+)')
    if ($m.Success) { $fields['first_source'] = $m.Groups[1].Value.Trim() }
    return $fields
}

# Parse index.md into row objects {raw, scope, project, type}. Shared by session-start
# (injection filter) and brain-stats (/brain tax report) so the two never drift.
function Get-IndexRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path $INDEX_FILE)) { return $rows }
    $headerParsed = $false
    $col = @{}
    foreach ($line in (Get-Content $INDEX_FILE -Encoding UTF8)) {
        if ($line -notmatch '^\s*\|') { continue }
        # Split on unescaped pipes only, then un-escape "\|" back to "|" — reindex's
        # Format-Cell escapes literal pipes in a cell, so a pipe inside a summary must not
        # be read as a column boundary (which would shift every later column).
        $cells = ($line.Trim().Trim('|') -split '(?<!\\)\|') | ForEach-Object { ($_.Trim()) -replace '\\\|', '|' }
        if (-not $headerParsed) {
            for ($i = 0; $i -lt $cells.Count; $i++) { $col[$cells[$i].ToLower()] = $i }
            $headerParsed = $true; continue
        }
        if ($line -match '^\s*\|\s*-{2,}') { continue }
        $scope = if ($col.ContainsKey('scope')   -and $col['scope']   -lt $cells.Count) { $cells[$col['scope']].ToLower() } else { '' }
        $proj  = if ($col.ContainsKey('project') -and $col['project'] -lt $cells.Count) { $cells[$col['project']] }         else { '' }
        $type  = if ($col.ContainsKey('type')    -and $col['type']    -lt $cells.Count) { $cells[$col['type']].ToLower() }  else { '' }
        $summ  = if ($col.ContainsKey('summary') -and $col['summary'] -lt $cells.Count) { $cells[$col['summary']] }         else { '' }
        $dom   = if ($col.ContainsKey('domains') -and $col['domains'] -lt $cells.Count) { $cells[$col['domains']] }         else { '' }
        $m     = [regex]::Match($line, '\[\[([^\]]+)\]\]')
        $art   = if ($m.Success) { $m.Groups[1].Value } else { '' }
        $rows.Add([pscustomobject]@{ raw = $line; scope = $scope; project = $proj; type = $type; article = $art; summary = $summ; domains = $dom })
    }
    return $rows
}

# Parse the index "Domains" cell into a lowercased domain list. Shared by the injection
# predicate and the mid-session top-up so both read article domains identically.
function Get-RowDomains($Row) {
    return @(([string]$Row.domains) -split ',' | ForEach-Object { $_.Trim().Trim('[', ']', '"', "'", ' ').ToLower() } | Where-Object { $_ })
}

# Injection predicate, shared by session-start (inject) and brain-stats (/brain) so the
# two never drift. A row injects if:
#   • it belongs to the current project (project == ProjKey) — domain never gates it; OR
#   • it is global (or legacy-blank scope) AND, when $DOMAIN_FILTER is on, its domains
#     intersect the project's profile. Fail-closed: no article domains, or an empty
#     project profile → the global row is NOT injected.
function Test-RowInjected($Row, [string]$ProjKey, [string[]]$ProjDomains = @()) {
    if ($ProjKey -and $Row.project -ieq $ProjKey) { return $true }
    if ($Row.scope -ne 'global' -and $Row.scope -ne '') { return $false }
    if (-not $DOMAIN_FILTER) { return $true }
    if (@($ProjDomains).Count -eq 0) { return $false }

    $pd = @($ProjDomains | ForEach-Object { ([string]$_).Trim().ToLower() } | Where-Object { $_ })
    $rd = Get-RowDomains $Row
    foreach ($d in $rd) { if ($d -in $pd) { return $true } }
    return $false
}

# Set (replace or insert) one `Key: Value` line inside a file's YAML frontmatter.
# Shared by reclassify and apply-review. Returns the updated raw text.
function Set-FrontmatterField([string]$Raw, [string]$Key, [string]$Value) {
    $nl = if ($Raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $t  = ($Raw -replace "`r`n", "`n").TrimStart([char]0xFEFF)
    if (-not $t.StartsWith("---")) { return $Raw }
    $lines  = [System.Collections.Generic.List[string]]($t -split "`n")
    $endIdx = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $endIdx = $i; break } }
    if ($endIdx -lt 0) { return $Raw }

    $newLine = "${Key}: ${Value}"
    $escKey  = [regex]::Escape($Key)
    for ($i = 1; $i -lt $endIdx; $i++) {
        if ($lines[$i] -match "^\s*$escKey\s*:") {
            $lines[$i] = $newLine
            # If the old value was a YAML block list (domains:\n  - foo\n  - bar), drop its
            # "- item" continuation lines so they don't dangle under the new inline value
            # and corrupt the frontmatter. Stops at the next key (no leading "- ").
            $j = $i + 1
            while ($j -lt $endIdx -and $lines[$j] -match '^\s+-\s') {
                $lines.RemoveAt($j); $endIdx--
            }
            return ($lines -join $nl)
        }
    }
    # not present — insert before the first of sources/created/updated (keeps block lists last)
    $insertAt = $endIdx
    for ($i = 1; $i -lt $endIdx; $i++) {
        if ($lines[$i] -match '^\s*(sources|created|updated)\s*:') { $insertAt = $i; break }
    }
    $lines.Insert($insertAt, $newLine)
    return ($lines -join $nl)
}
