<#
    .SYNOPSIS
        Gathers everything the pipeline needs to know about a database.

    .DESCRIPTION
        The only script here that connects to SQL. It writes a facts file:
        an inventory used to assess compatibility, and a snapshot used to
        prove parity. Keeping gathering separate from judgement means the
        decisions can be tested without a server, and the evidence survives
        the run as an artifact.

    .PARAMETER AccessToken
        Entra token. The Azure SQL target allows no SQL logins at all, so
        this is how the pipeline reaches it.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Progress output for an operator watching a migration.')]
param(
    [Parameter(Mandatory)][string]$ServerInstance,
    [Parameter(Mandatory)][string]$Database,
    [pscredential]$Credential,
    [string]$AccessToken,
    [Parameter(Mandatory)][string]$OutFile,
    [switch]$TrustServerCertificate
)

$ErrorActionPreference = 'Stop'
Import-Module SqlServer -ErrorAction Stop

$common = @{
    ServerInstance = $ServerInstance
    Database       = $Database
    QueryTimeout   = 300
    ErrorAction    = 'Stop'
}
if ($TrustServerCertificate) { $common['TrustServerCertificate'] = $true }
if ($AccessToken)     { $common['AccessToken'] = $AccessToken }
elseif ($Credential)  { $common['Credential']  = $Credential }

function Invoke-Q {
    param([Parameter(Mandatory)][string]$Query)
    Invoke-Sqlcmd @common -Query $Query
}

Write-Host "Reading $Database on $ServerInstance"

# --- inventory -------------------------------------------------------------
$columns = Invoke-Q @"
SELECT  s.name AS SchemaName, t.name AS TableName, c.name AS ColumnName,
        ty.name AS DataType, c.column_id AS ColumnId
FROM    sys.columns c
JOIN    sys.tables t  ON t.object_id = c.object_id
JOIN    sys.schemas s ON s.schema_id = t.schema_id
JOIN    sys.types ty  ON ty.user_type_id = c.user_type_id
WHERE   t.is_ms_shipped = 0
ORDER BY s.name, t.name, c.column_id;
"@

$tables = Invoke-Q @"
SELECT  s.name AS SchemaName, t.name AS TableName,
        CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                               WHERE i.object_id = t.object_id AND i.type = 1)
                  THEN 1 ELSE 0 END AS BIT) AS HasClusteredIndex,
        CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints k
                               WHERE k.parent_object_id = t.object_id AND k.type = 'PK')
                  THEN 1 ELSE 0 END AS BIT) AS HasPrimaryKey
FROM    sys.tables t
JOIN    sys.schemas s ON s.schema_id = t.schema_id
WHERE   t.is_ms_shipped = 0
ORDER BY s.name, t.name;
"@

$modules = Invoke-Q @"
SELECT  s.name AS SchemaName, o.name AS Name, o.type_desc AS Type,
        m.definition AS Definition
FROM    sys.sql_modules m
JOIN    sys.objects o ON o.object_id = m.object_id
JOIN    sys.schemas s ON s.schema_id = o.schema_id
WHERE   o.is_ms_shipped = 0;
"@

# --- snapshot --------------------------------------------------------------
# BINARY_CHECKSUM cannot read the deprecated large types, so those columns are
# excluded and named in the facts rather than quietly dropped. A checksum that
# silently skips a column is worse than no checksum.
$unhashable = @('text', 'ntext', 'image', 'xml', 'geography', 'geometry', 'hierarchyid', 'sql_variant')

$snapshotTables = foreach ($t in $tables) {
    $full = "$($t.SchemaName).$($t.TableName)"
    $cols = @($columns | Where-Object { $_.SchemaName -eq $t.SchemaName -and $_.TableName -eq $t.TableName })
    $hashable = @($cols | Where-Object { $unhashable -notcontains $_.DataType })
    $excluded = @($cols | Where-Object { $unhashable -contains $_.DataType } | ForEach-Object { $_.ColumnName })

    $signature = ($cols | ForEach-Object { "$($_.ColumnName):$($_.DataType)" }) -join ','

    if ($hashable.Count -gt 0) {
        $list = ($hashable | ForEach-Object { "[$($_.ColumnName)]" }) -join ', '
        $q = "SELECT COUNT_BIG(*) AS [RowCount], CHECKSUM_AGG(BINARY_CHECKSUM($list)) AS Checksum FROM [$($t.SchemaName)].[$($t.TableName)];"
    }
    else {
        $q = "SELECT COUNT_BIG(*) AS [RowCount], CAST(NULL AS INT) AS Checksum FROM [$($t.SchemaName)].[$($t.TableName)];"
    }
    $r = Invoke-Q -Query $q

    [pscustomobject]@{
        Name             = $full
        RowCount         = [int64]$r.RowCount
        Checksum         = if ($null -eq $r.Checksum -or $r.Checksum -is [System.DBNull]) { '' } else { [string]$r.Checksum }
        ColumnSignature  = $signature
        ExcludedFromHash = $excluded
    }
}

$facts = [pscustomobject]@{
    GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Server       = $ServerInstance
    Database     = $Database
    Inventory    = [pscustomobject]@{
        Columns = @($columns | Select-Object SchemaName, TableName, ColumnName, DataType)
        Tables  = @($tables  | Select-Object SchemaName, TableName, HasClusteredIndex, HasPrimaryKey)
        Modules = @($modules | Select-Object SchemaName, Name, Type, Definition)
    }
    Snapshot     = [pscustomobject]@{ Tables = @($snapshotTables) }
}

$dir = Split-Path $OutFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$json = $facts | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))

$totalRows = ($snapshotTables | Measure-Object -Property RowCount -Sum).Sum
Write-Host "  tables=$(@($tables).Count) modules=$(@($modules).Count) rows=$totalRows -> $OutFile"

[pscustomobject]@{
    Database = $Database
    Tables   = @($tables).Count
    Modules  = @($modules).Count
    Rows     = $totalRows
    OutFile  = $OutFile
}