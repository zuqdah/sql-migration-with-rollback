<#
    .SYNOPSIS
        Proves the target matches the source, or fails.

    .DESCRIPTION
        Compares two facts files. Row counts are necessary and not
        sufficient: a truncated column moves every row and leaves the count
        identical, so content checksums and column signatures are compared
        too. Any difference fails the run.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Parity report for an operator.')]
param(
    [Parameter(Mandatory)][string]$SourceFacts,
    [Parameter(Mandatory)][string]$TargetFacts,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path -Path (Join-Path -Path (Join-Path -Path $root -ChildPath 'module') -ChildPath 'SqlMigration') -ChildPath 'SqlMigration.psm1') -Force

$source = [System.IO.File]::ReadAllText($SourceFacts) | ConvertFrom-Json
$target = [System.IO.File]::ReadAllText($TargetFacts) | ConvertFrom-Json

$result = Compare-DatabaseSnapshot -Source $source.Snapshot -Target $target.Snapshot

Write-Host ""
Write-Host "Parity: $($source.Database) -> $($target.Database)"
Write-Host "  tables $($result.TablesSource) -> $($result.TablesTarget)"
Write-Host "  rows   $($result.RowsSource) -> $($result.RowsTarget)"
Write-Host ""

# Columns left out of the checksum are stated, so nobody reads a pass as
# stronger evidence than it is.
$excluded = @($source.Snapshot.Tables | Where-Object { @($_.ExcludedFromHash).Count -gt 0 })
if ($excluded.Count) {
    Write-Host '  Columns not covered by the content checksum:'
    foreach ($t in $excluded) { Write-Host "    $($t.Name): $(@($t.ExcludedFromHash) -join ', ')" }
    Write-Host ''
}

if ($result.Differences.Count) {
    $result.Differences | Format-Table -AutoSize Table, Kind, Source, Target, Detail |
        Out-String -Width 160 | Write-Host
}

if ($OutFile) {
    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($OutFile, ($result | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

if (-not $result.InParity) {
    throw "Target does not match source: $($result.Differences.Count) difference(s)."
}
Write-Host 'Source and target are in parity.'
$result