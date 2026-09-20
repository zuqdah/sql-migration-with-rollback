<#
    .SYNOPSIS
        Decides whether a database is safe to migrate, from a facts file.

    .DESCRIPTION
        Reads no database. It loads facts gathered earlier and applies the
        compatibility rules, so the same evidence can be re-assessed later
        without rerunning anything against a live server.

        Blocking findings fail the run. Warnings are reported and do not,
        because a migration that refuses to proceed over a heap would never
        run against a real estate.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Assessment report for an operator.')]
param(
    [Parameter(Mandatory)][string]$FactsPath,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path -Path (Join-Path -Path (Join-Path -Path $root -ChildPath 'module') -ChildPath 'SqlMigration') -ChildPath 'SqlMigration.psm1') -Force

$facts  = [System.IO.File]::ReadAllText($FactsPath) | ConvertFrom-Json
$result = Test-SchemaCompatibility -Inventory $facts.Inventory

Write-Host ""
Write-Host "Assessment of $($facts.Database) on $($facts.Server)"
Write-Host "  tables $($result.Tables), modules $($result.Modules)"
Write-Host ""

if ($result.Findings.Count) {
    $result.Findings |
        Sort-Object @{ Expression = { switch ($_.Severity) { 'Blocking' { 0 } 'Warning' { 1 } default { 2 } } } }, Object |
        Format-Table -AutoSize Severity, Code, Object, Detail |
        Out-String -Width 160 | Write-Host
}
else { Write-Host '  no findings' }

if ($OutFile) {
    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($OutFile, ($result | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "Blocking: $($result.Blocking)   Warning: $($result.Warning)"
if ($result.Blocking -gt 0) {
    throw "Assessment found $($result.Blocking) blocking finding(s); the migration must not proceed."
}
Write-Host 'No blocking findings. Safe to migrate.'
$result