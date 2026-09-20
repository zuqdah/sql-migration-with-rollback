<#
    .SYNOPSIS
        Exports the source database to a BACPAC.

    .DESCRIPTION
        This file is the rollback artifact. It is produced before anything is
        written to the target, kept as a build artifact, and later restored to
        prove it works. A backup nobody has restored is a hope, not a plan.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Progress output for an operator watching a migration.')]
param(
    [Parameter(Mandatory)][string]$ServerInstance,
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$OutFile,
    [pscredential]$Credential,
    [switch]$TrustServerCertificate
)

$ErrorActionPreference = 'Stop'
$sqlpackage = if ($env:SQLPACKAGE) { $env:SQLPACKAGE } else { 'sqlpackage' }

$dir = Split-Path $OutFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (Test-Path $OutFile) { [System.IO.File]::Delete((Resolve-Path $OutFile)) }

$sqlArgs = @(
    '/a:Export'
    "/ssn:$ServerInstance"
    "/sdn:$Database"
    "/tf:$OutFile"
    '/p:VerifyExtraction=True'
)
if ($Credential) {
    # sqlpackage is an external process and takes the password as an argument;
    # it has no way to accept a SecureString. The value is unwrapped here, at
    # the boundary, rather than being carried as plain text throughout.
    $sqlArgs += @("/su:$($Credential.UserName)", "/sp:$($Credential.GetNetworkCredential().Password)")
}
if ($TrustServerCertificate) { $sqlArgs += '/stsc:True' }

Write-Host "Exporting $Database from $ServerInstance"
& $sqlpackage @sqlArgs
if ($LASTEXITCODE -ne 0) { throw "sqlpackage export failed with exit code $LASTEXITCODE." }
if (-not (Test-Path $OutFile)) { throw "sqlpackage reported success but produced no file at $OutFile." }

$size = [math]::Round((Get-Item $OutFile).Length / 1MB, 2)
Write-Host "  wrote $OutFile ($size MB)"

[pscustomobject]@{ Database = $Database; Path = $OutFile; SizeMB = $size }