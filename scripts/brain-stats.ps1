#Requires -Version 7
<#
.SYNOPSIS
    The "brain tax" report. Recomputes exactly what session-start would inject for the
    CURRENT project (same shared parser/predicate from _config), and prints the size:
    how many articles, the global/project/rule breakdown, lines, chars, ~tokens.
    Invoked by the /brain slash command. Read-only — changes nothing.
#>

param([string]$Mode = "")

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
. "$PSScriptRoot\_config.ps1"

$full = ($Mode.Trim().TrimStart('-').ToLower()) -in @('full', 'f', 'подробно', 'details')

$cwd  = (Get-Location).Path
$key  = Get-ProjectKey $cwd
$rows = Get-IndexRows
$total = $rows.Count

if ($total -eq 0) {
    Write-Host "База знаний пуста (нет index.md)."
    exit 0
}

# When the project is unknown (home dir / no repo) session-start injects everything.
$kept = if ($key -eq 'unknown') { @($rows) } else { @($rows | Where-Object { Test-RowInjected $_ $key }) }
$cut  = $total - $kept.Count

$globalN = @($kept | Where-Object { $_.scope -eq 'global'  }).Count
$projN   = @($kept | Where-Object { $_.scope -eq 'project' }).Count
$blankN  = @($kept | Where-Object { $_.scope -eq ''        }).Count
$rulesN  = @($kept | Where-Object { $_.type  -eq 'rule'    }).Count

# Size of the injected index block (the part that grows with the base).
$text  = (@($kept | ForEach-Object { $_.raw }) -join "`n")
$chars = $text.Length
$tok   = [int]([math]::Round($chars / 3.0))   # rough estimate for Cyrillic-heavy markdown

$reg     = Load-Registry
$domains = if ($reg.ContainsKey($key)) { @($reg[$key]['domains']) } else { @() }
$domStr  = if ($domains.Count) { " · домены: $($domains -join ', ')" } else { " · домены не заданы" }

Write-Host "🧠 Второй мозг — налог инжекта"
Write-Host "Проект: $key$domStr"
Write-Host "Подмешивается: $($kept.Count) из $total статей (отрезано $cut чужих проектных)"
$breakdown = "  global: $globalN · этот проект: $projN · правил(rule): $rulesN"
if ($blankN) { $breakdown += " · без scope(легаси): $blankN" }
Write-Host $breakdown
Write-Host "Объём индекса: $($kept.Count) строк, $chars символов, ≈ $tok токенов (грубо)"
Write-Host "(замер только индекса знаний; «## Today» и недавний дневной лог не считаются — они малы и не растут)"

if ($full) {
    Write-Host ""
    Write-Host "— подробности: $($kept.Count) статей (правила сверху, [тип·scope]) —"
    $sorted = @($kept | Sort-Object @{ Expression = { $_.type -ne 'rule' } }, @{ Expression = { Split-Path $_.article -Leaf } })
    foreach ($r in $sorted) {
        $name = if ($r.article) { Split-Path $r.article -Leaf } else { '?' }
        $tg   = if ($r.type) { $r.type.Substring(0, 1) } else { '?' }
        $sc   = if ($r.scope -eq 'project') { "proj:$($r.project)" } elseif ($r.scope) { $r.scope } else { 'legacy' }
        $sum  = [string]$r.summary
        if ($sum.Length -gt 64) { $sum = $sum.Substring(0, 61) + '...' }
        Write-Host ("  [{0}·{1}] {2} — {3}" -f $tg, $sc, $name, $sum)
    }
}
