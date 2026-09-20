<#
    .SYNOPSIS
        Restores the pre-migration BACPAC and proves it matches the original.

    .DESCRIPTION
        Taking a backup before a migration is routine. Knowing it restores is
        not, and the gap between the two is where outages live. This restores
        the artifact into a database of its own and compares it against the
        facts captured before anything was migrated.

        It restores alongside the target rather than over it, so a drill can
        run after a successful cutover without touching live data.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Drill report for an operator.')]
param(
    [Parameter(Mandatory)][string]$ServerInstance,
    [Parameter(Mandatory)][string]$BacpacPath,
    [Parameter(Mandatory)][string]$SourceFacts,
    [string]$DrillDatabase = 'AppDb_rollback_drill',
    [pscredential]$Credential,
    [string]$AccessToken,
    [switch]$TrustServerCertificate,
    [string]$ServiceObjective,
    [string]$OutFile,
    [switch]$KeepDatabase
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

$auth = @{}
if ($AccessToken)    { $auth['AccessToken'] = $AccessToken }
elseif ($Credential) { $auth['Credential']  = $Credential }
if ($TrustServerCertificate) { $auth['TrustServerCertificate'] = $true }

function Remove-DrillDatabase {
    # Dropping the scratch database is the point of the function, so
    # ShouldProcess would only add ceremony to something the caller asked for
    # explicitly via -KeepDatabase.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Removal is gated by the -KeepDatabase switch on the script.')]
    param([string]$Name)

    Import-Module SqlServer -ErrorAction Stop
    $conn = @{ ServerInstance = $ServerInstance; Database = 'master'; ErrorAction = 'Stop' }
    if ($AccessToken)    { $conn['AccessToken'] = $AccessToken }
    elseif ($Credential) { $conn['Credential']  = $Credential }
    if ($TrustServerCertificate) { $conn['TrustServerCertificate'] = $true }

    # ADO.NET keeps a pooled connection open after the last query returns,
    # which holds the database and makes the drop fail. Releasing the pool is
    # the portable fix; SINGLE_USER is not available on Azure SQL.
    foreach ($typeName in 'Microsoft.Data.SqlClient.SqlConnection', 'System.Data.SqlClient.SqlConnection') {
        $type = $typeName -as [type]
        if ($type) { try { $type::ClearAllPools() } catch { Write-Verbose "No pool to clear for $typeName." } }
    }

    foreach ($attempt in 1..3) {
        try {
            Invoke-Sqlcmd @conn -Query "DROP DATABASE IF EXISTS [$Name];"
            return $true
        }
        catch {
            if ($attempt -eq 3) {
                Write-Host "  could not drop $Name : $($_.Exception.Message)"
                return $false
            }
            Start-Sleep -Seconds 5
        }
    }
}

Write-Host ''
Write-Host "Rollback drill: restoring $BacpacPath into $DrillDatabase"

# A drill has to be repeatable. sqlpackage refuses to import into a database
# that already holds user objects, so any remnant of an earlier run goes first.
Remove-DrillDatabase -Name $DrillDatabase | Out-Null

$importArgs = @{ ServerInstance = $ServerInstance; Database = $DrillDatabase; BacpacPath = $BacpacPath } + $auth
if ($ServiceObjective) { $importArgs['ServiceObjective'] = $ServiceObjective }
& (Join-Path -Path $scriptDir -ChildPath 'Import-Bacpac.ps1') @importArgs | Out-Null

$drillFacts = Join-Path ([System.IO.Path]::GetTempPath()) "drill-facts-$PID.json"
$factArgs = @{ ServerInstance = $ServerInstance; Database = $DrillDatabase; OutFile = $drillFacts } + $auth
& (Join-Path -Path $scriptDir -ChildPath 'Get-DatabaseFacts.ps1') @factArgs | Out-Null

$parityArgs = @{ SourceFacts = $SourceFacts; TargetFacts = $drillFacts }
if ($OutFile) { $parityArgs['OutFile'] = $OutFile }

try {
    & (Join-Path -Path $scriptDir -ChildPath 'Test-MigrationParity.ps1') @parityArgs
    $restored = $true
}
catch {
    $restored = $false
    Write-Host "  DRILL FAILED: $($_.Exception.Message)"
}
finally {
    if (Test-Path $drillFacts) { [System.IO.File]::Delete($drillFacts) }
    if (-not $KeepDatabase) {
        Write-Host "  dropping $DrillDatabase"
        if (Remove-DrillDatabase -Name $DrillDatabase) { Write-Host "  dropped $DrillDatabase" }
    }
}

if (-not $restored) {
    throw "The rollback artifact did not restore to a state matching the source. The backup cannot be relied on."
}

Write-Host 'Rollback artifact restored and verified against the pre-migration source.'
[pscustomobject]@{ Drill = $DrillDatabase; Artifact = $BacpacPath; Restored = $true }