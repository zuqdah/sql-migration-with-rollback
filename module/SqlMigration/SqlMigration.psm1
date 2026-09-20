<#
    Pure logic for assessing a source database and proving parity after a
    migration. Nothing here connects to a database: the scripts gather facts
    and these functions decide what those facts mean. That split is what
    makes the decisions testable without a server.
#>

# Features that Azure SQL Database does not offer. A migration that carries
# one of these across does not fail at import; it fails in production later.
$script:BlockingPatterns = @(
    @{ Code = 'XP_CMDSHELL';   Pattern = 'xp_cmdshell';                    Detail = 'Shell execution is not available in Azure SQL Database.' }
    @{ Code = 'OPENROWSET';    Pattern = 'OPENROWSET|OPENDATASOURCE';      Detail = 'Ad hoc distributed queries are not supported.' }
    @{ Code = 'LINKED_SERVER'; Pattern = 'sp_addlinkedserver|\[\w+\]\.\[\w+\]\.\[\w+\]\.\[\w+\]'; Detail = 'Linked servers and four-part names are not supported.' }
    @{ Code = 'FILESTREAM';    Pattern = 'FILESTREAM';                     Detail = 'FILESTREAM is not supported.' }
    @{ Code = 'CLR';           Pattern = 'CREATE\s+ASSEMBLY';              Detail = 'CLR assemblies are not supported.' }
    @{ Code = 'SERVICE_BROKER';Pattern = 'CREATE\s+(QUEUE|SERVICE)\b';     Detail = 'Service Broker is not supported.' }
)

# Types that migrate cleanly but should not survive a migration unexamined.
$script:DeprecatedTypes = @('text', 'ntext', 'image')

function New-MigrationFinding {
    <#
        .SYNOPSIS
            Builds one finding.
        .PARAMETER Severity
            Blocking stops a migration. Warning is reported and does not.
        .PARAMETER Code
            Stable identifier, so findings can be counted across runs.
        .PARAMETER Object
            The schema-qualified object the finding is about.
        .PARAMETER Detail
            Why it matters, in a sentence an operator can act on.
        .EXAMPLE
            New-MigrationFinding -Severity Warning -Code HEAP -Object dbo.AuditLog -Detail 'No clustered index.'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    # This builds an object and changes nothing, so there is no state for
    # -WhatIf to protect. The verb is correct for a constructor.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructs an in-memory object; changes no state.')]
    param(
        [Parameter(Mandatory)][ValidateSet('Blocking', 'Warning', 'Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Object,
        [Parameter(Mandatory)][string]$Detail
    )
    [pscustomobject]@{
        Severity = $Severity
        Code     = $Code
        Object   = $Object
        Detail   = $Detail
    }
}

function Test-SchemaCompatibility {
    <#
        .SYNOPSIS
            Turns a source inventory into findings.
        .PARAMETER Inventory
            Object with Columns, Tables and Modules collections.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Inventory
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($module in @($Inventory.Modules)) {
        $definition = [string]$module.Definition
        if ([string]::IsNullOrWhiteSpace($definition)) { continue }
        foreach ($rule in $script:BlockingPatterns) {
            if ($definition -match $rule.Pattern) {
                $findings.Add((New-MigrationFinding -Severity 'Blocking' -Code $rule.Code `
                    -Object "$($module.SchemaName).$($module.Name)" -Detail $rule.Detail))
            }
        }
    }

    foreach ($column in @($Inventory.Columns)) {
        if ($script:DeprecatedTypes -contains [string]$column.DataType) {
            $findings.Add((New-MigrationFinding -Severity 'Warning' -Code 'DEPRECATED_TYPE' `
                -Object "$($column.SchemaName).$($column.TableName).$($column.ColumnName)" `
                -Detail "Column uses $($column.DataType), deprecated since SQL Server 2005."))
        }
    }

    foreach ($table in @($Inventory.Tables)) {
        $name = "$($table.SchemaName).$($table.TableName)"
        if (-not $table.HasClusteredIndex) {
            $findings.Add((New-MigrationFinding -Severity 'Warning' -Code 'HEAP' -Object $name `
                -Detail 'Table is a heap; Azure SQL Database performs better with a clustered index.'))
        }
        if (-not $table.HasPrimaryKey) {
            $findings.Add((New-MigrationFinding -Severity 'Warning' -Code 'NO_PRIMARY_KEY' -Object $name `
                -Detail 'Table has no primary key, so row identity cannot be proven after migration.'))
        }
    }

    [pscustomobject]@{
        Findings = $findings.ToArray()
        Blocking = @($findings | Where-Object Severity -eq 'Blocking').Count
        Warning  = @($findings | Where-Object Severity -eq 'Warning').Count
        Tables   = @($Inventory.Tables).Count
        Modules  = @($Inventory.Modules).Count
    }
}

function Compare-DatabaseSnapshot {
    <#
        .SYNOPSIS
            Compares a source and target snapshot and reports every difference.
        .DESCRIPTION
            Row counts alone are weak evidence: a truncated column or a
            mangled encoding keeps the count identical. Each table also
            carries a checksum over its rows, so content is compared, not
            just quantity.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Source,
        [Parameter(Mandatory)][pscustomobject]$Target
    )

    $differences = [System.Collections.Generic.List[object]]::new()
    $sourceTables = @($Source.Tables)
    $targetTables = @($Target.Tables)
    $targetByName = @{}
    foreach ($t in $targetTables) { $targetByName[$t.Name] = $t }

    foreach ($s in $sourceTables) {
        $t = $targetByName[$s.Name]
        if (-not $t) {
            $differences.Add([pscustomobject]@{
                Table = $s.Name; Kind = 'Missing'; Source = $s.RowCount; Target = $null
                Detail = 'Table exists in the source and not in the target.'
            })
            continue
        }
        if ([int64]$s.RowCount -ne [int64]$t.RowCount) {
            $differences.Add([pscustomobject]@{
                Table = $s.Name; Kind = 'RowCount'; Source = $s.RowCount; Target = $t.RowCount
                Detail = 'Row counts differ.'
            })
        }
        elseif ([string]$s.Checksum -ne [string]$t.Checksum) {
            # Equal counts and different checksums means the rows moved but the
            # content did not survive intact, which is the failure a count hides.
            $differences.Add([pscustomobject]@{
                Table = $s.Name; Kind = 'Checksum'; Source = $s.Checksum; Target = $t.Checksum
                Detail = 'Row counts match but content checksums differ.'
            })
        }
        if ([string]$s.ColumnSignature -ne [string]$t.ColumnSignature) {
            $differences.Add([pscustomobject]@{
                Table = $s.Name; Kind = 'Schema'; Source = $s.ColumnSignature; Target = $t.ColumnSignature
                Detail = 'Column names or types differ.'
            })
        }
    }

    $extra = @($targetTables | Where-Object { $_.Name -notin $sourceTables.Name })
    foreach ($e in $extra) {
        $differences.Add([pscustomobject]@{
            Table = $e.Name; Kind = 'Unexpected'; Source = $null; Target = $e.RowCount
            Detail = 'Table exists in the target and not in the source.'
        })
    }

    [pscustomobject]@{
        Differences  = $differences.ToArray()
        InParity     = ($differences.Count -eq 0)
        TablesSource = $sourceTables.Count
        TablesTarget = $targetTables.Count
        RowsSource   = ($sourceTables | Measure-Object -Property RowCount -Sum).Sum
        RowsTarget   = ($targetTables | Measure-Object -Property RowCount -Sum).Sum
    }
}

Export-ModuleMember -Function New-MigrationFinding, Test-SchemaCompatibility, Compare-DatabaseSnapshot