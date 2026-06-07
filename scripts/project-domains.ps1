#Requires -Version 7
<#
.SYNOPSIS
    Show / add / remove the knowledge DOMAINS of the current project (detected from
    the current working directory) in projects.json. Adds are validated against the
    controlled vocabulary in domains.md; duplicates are ignored; unknown domains are
    rejected without changing anything. Invoked by the /domains slash command.

.PARAMETER Spec
    Whitespace/comma-separated tokens (one string). Bare or +prefixed = add,
    -prefixed = remove. Empty = show current domains + the vocabulary. Case-insensitive.

.EXAMPLE
    pwsh -File project-domains.ps1 "wordpress, php-web"   # add two
    pwsh -File project-domains.ps1 "+sqlite -css-frontend" # add one, remove one
    pwsh -File project-domains.ps1                          # show current + vocab
#>
param([string]$Spec = "")

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
. "$PSScriptRoot\_config.ps1"

$cwd = (Get-Location).Path
$key = Get-ProjectKey $cwd
if ($key -eq 'unknown') {
    Write-Host "Не удалось определить проект из текущей папки: $cwd"
    Write-Host "Запусти команду внутри папки проекта (где выше по дереву есть .git)."
    exit 1
}

$vocab = @(Get-DomainVocabulary)
if ($vocab.Count -eq 0) {
    Write-Host "Словарь доменов пуст или не найден: $DOMAINS_FILE"
    exit 1
}

$reg = Load-Registry
if (-not $reg.ContainsKey($key)) { $reg[$key] = @{ roots = @(Get-ProjectRoot $cwd); domains = @() } }
$current = [System.Collections.Generic.List[string]]@(@($reg[$key]['domains']) | Where-Object { $_ } | ForEach-Object { $_.ToLower() })

# No args → show
if (-not $Spec.Trim()) {
    Write-Host "Проект: $key"
    Write-Host "Домены проекта: $(if ($current.Count) { $current -join ', ' } else { '(пусто)' })"
    Write-Host "Словарь: $($vocab -join ', ')"
    exit 0
}

$tokens  = $Spec -split '[\s,]+' | Where-Object { $_ }
$adds    = @(); $removes = @(); $unknown = @()
foreach ($t in $tokens) {
    if ($t -eq '+' -or $t -eq '-') { continue }
    if ($t.StartsWith('-')) {
        $name = $t.Substring(1).ToLower()
        if ($name) { $removes += $name }
    }
    else {
        $name = ($t.TrimStart('+')).ToLower()
        if (-not $name) { continue }
        if ($name -notin $vocab) { $unknown += $name } else { $adds += $name }
    }
}

# Partial apply: each token is handled independently — valid adds/removes are applied,
# unknown domains are reported but never abort the command.
foreach ($a in @($adds    | Select-Object -Unique)) { if ($current -notcontains $a) { [void]$current.Add($a) } }
foreach ($r in @($removes | Select-Object -Unique)) { [void]$current.Remove($r) }

$reg[$key]['domains'] = @($current | Select-Object -Unique | Sort-Object)
if (@($reg[$key]['roots']).Count -eq 0) { $reg[$key]['roots'] = @(Get-ProjectRoot $cwd) }
Save-Registry $reg

Write-Host "Проект: $key"
Write-Host "Домены теперь: $(if ($reg[$key]['domains'].Count) { $reg[$key]['domains'] -join ', ' } else { '(пусто)' })"
if ($unknown.Count) {
    Write-Host "Пропущены (нет в словаре): $(@($unknown | Select-Object -Unique) -join ', ')"
    Write-Host "Если нужны — добавь их строкой в $DOMAINS_FILE и повтори для них."
}
