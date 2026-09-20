<#
    .SYNOPSIS
        Imports a BACPAC into a target database.

    .DESCRIPTION
        Used twice by the pipeline: once to migrate, and once more to restore
        the same artifact into a separate database as a rollback drill. The
        second use is the one that turns a backup into a tested backup.

    .PARAMETER AccessToken
        Entra token. The Azure SQL target has no SQL logins at all.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Progress output for an operator watching a migration.')]
param(
    [Parameter(Mandatory)][string]$ServerInstance,
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$BacpacPath,
    [pscredential]$Credential,
    [string]$AccessToken,
    [switch]$TrustServerCertificate,
    [string]$ServiceObjective
)

$ErrorActionPreference = 'Stop'
$sqlpackage = if ($env:SQLPACKAGE) { $env:SQLPACKAGE } else { 'sqlpackage' }

if (-not (Test-Path $BacpacPath)) { throw "No BACPAC at $BacpacPath." }

$sqlArgs = @(
    '/a:Import'
    "/tsn:$ServerInstance"
    "/tdn:$Database"
    "/sf:$BacpacPath"
)
if ($AccessToken) { $sqlArgs += "/at:$AccessToken" }
elseif ($Credential) {
    # Unwrapped at the boundary: sqlpackage is an external process and cannot
    # accept a SecureString.
    $sqlArgs += @("/tu:$($Credential.UserName)", "/tp:$($Credential.GetNetworkCredential().Password)")
}
if ($TrustServerCertificate) { $sqlArgs += '/ttsc:True' }
if ($ServiceObjective) { $sqlArgs += "/p:DatabaseServiceObjective=$ServiceObjective" }

Write-Host "Importing $BacpacPath into $Database on $ServerInstance"
& $sqlpackage @sqlArgs
if ($LASTEXITCODE -ne 0) { throw "sqlpackage import failed with exit code $LASTEXITCODE." }
Write-Host "  imported into $Database"

[pscustomobject]@{ Database = $Database; Source = $BacpacPath }