<#
    Tests for the decisions, not the plumbing. Every case here is a judgement
    the pipeline makes about whether a migration is safe, so each one runs
    without a database.
#>

BeforeAll {
    $module = Join-Path -Path (Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath 'module') -ChildPath 'SqlMigration'
    Import-Module (Join-Path -Path $module -ChildPath 'SqlMigration.psm1') -Force
}

Describe 'Test-SchemaCompatibility' {
    It 'reports a clean database as having nothing blocking' {
        $inv = [pscustomobject]@{
            Columns = @([pscustomobject]@{ SchemaName='dbo'; TableName='T'; ColumnName='C'; DataType='int' })
            Tables  = @([pscustomobject]@{ SchemaName='dbo'; TableName='T'; HasClusteredIndex=$true; HasPrimaryKey=$true })
            Modules = @()
        }
        $r = Test-SchemaCompatibility -Inventory $inv
        $r.Blocking | Should -Be 0
        $r.Warning  | Should -Be 0
    }

    It 'blocks on shell execution' {
        $inv = [pscustomobject]@{
            Columns = @(); Tables = @()
            Modules = @([pscustomobject]@{ SchemaName='dbo'; Name='DoThing'; Definition='EXEC xp_cmdshell ''dir''' })
        }
        $r = Test-SchemaCompatibility -Inventory $inv
        $r.Blocking | Should -Be 1
        ($r.Findings | Where-Object Code -eq 'XP_CMDSHELL').Count | Should -Be 1
    }

    It 'blocks on four-part names' {
        $inv = [pscustomobject]@{
            Columns = @(); Tables = @()
            Modules = @([pscustomobject]@{ SchemaName='dbo'; Name='V'; Definition='SELECT * FROM [SRV].[DB].[dbo].[T]' })
        }
        (Test-SchemaCompatibility -Inventory $inv).Blocking | Should -Be 1
    }

    It 'blocks on ad hoc distributed queries' {
        $inv = [pscustomobject]@{
            Columns = @(); Tables = @()
            Modules = @([pscustomobject]@{ SchemaName='dbo'; Name='V'; Definition='SELECT * FROM OPENROWSET(...)' })
        }
        (Test-SchemaCompatibility -Inventory $inv).Blocking | Should -Be 1
    }

    It 'warns about deprecated column types without blocking' {
        $inv = [pscustomobject]@{
            Columns = @([pscustomobject]@{ SchemaName='dbo'; TableName='P'; ColumnName='Notes'; DataType='ntext' })
            Tables  = @(); Modules = @()
        }
        $r = Test-SchemaCompatibility -Inventory $inv
        $r.Blocking | Should -Be 0
        $r.Warning  | Should -Be 1
        ($r.Findings | Where-Object Code -eq 'DEPRECATED_TYPE').Count | Should -Be 1
    }

    It 'warns about heaps and missing primary keys separately' {
        $inv = [pscustomobject]@{
            Columns = @(); Modules = @()
            Tables  = @([pscustomobject]@{ SchemaName='dbo'; TableName='AuditLog'; HasClusteredIndex=$false; HasPrimaryKey=$false })
        }
        $r = Test-SchemaCompatibility -Inventory $inv
        $r.Warning | Should -Be 2
        ($r.Findings | Where-Object Code -eq 'HEAP').Count           | Should -Be 1
        ($r.Findings | Where-Object Code -eq 'NO_PRIMARY_KEY').Count | Should -Be 1
    }

    It 'reports every blocking feature in one module rather than stopping at the first' {
        $inv = [pscustomobject]@{
            Columns = @(); Tables = @()
            Modules = @([pscustomobject]@{ SchemaName='dbo'; Name='Bad'
                          Definition='EXEC xp_cmdshell ''x''; SELECT * FROM OPENROWSET(...)' })
        }
        (Test-SchemaCompatibility -Inventory $inv).Blocking | Should -Be 2
    }
}

Describe 'Compare-DatabaseSnapshot' {
    BeforeAll {
        $script:MakeSnap = {
            param($tables)
            [pscustomobject]@{ Tables = $tables }
        }
    }

    It 'reports parity when the two sides match' {
        $t = @([pscustomobject]@{ Name='dbo.Orders'; RowCount=2000; Checksum='abc'; ColumnSignature='sig' })
        $r = Compare-DatabaseSnapshot -Source (& $script:MakeSnap $t) -Target (& $script:MakeSnap $t)
        $r.InParity | Should -BeTrue
        $r.Differences.Count | Should -Be 0
    }

    It 'catches a missing table' {
        $s = @([pscustomobject]@{ Name='dbo.Orders'; RowCount=10; Checksum='a'; ColumnSignature='s' })
        $r = Compare-DatabaseSnapshot -Source (& $script:MakeSnap $s) -Target (& $script:MakeSnap @())
        $r.InParity | Should -BeFalse
        $r.Differences[0].Kind | Should -Be 'Missing'
    }

    It 'catches a row count difference' {
        $s = @([pscustomobject]@{ Name='dbo.Orders'; RowCount=2000; Checksum='a'; ColumnSignature='s' })
        $t = @([pscustomobject]@{ Name='dbo.Orders'; RowCount=1999; Checksum='a'; ColumnSignature='s' })
        $r = Compare-DatabaseSnapshot -Source (& $script:MakeSnap $s) -Target (& $script:MakeSnap $t)
        $r.Differences[0].Kind | Should -Be 'RowCount'
    }

    It 'catches corrupted content that row counts alone would hide' {
        # The case that makes checksums worth the trouble.
        $s = @([pscustomobject]@{ Name='dbo.Products'; RowCount=120; Checksum='source-hash'; ColumnSignature='s' })
        $t = @([pscustomobject]@{ Name='dbo.Products'; RowCount=120; Checksum='other-hash';  ColumnSignature='s' })
        $r = Compare-DatabaseSnapshot -Source (& $script:MakeSnap $s) -Target (& $script:MakeSnap $t)
        $r.InParity | Should -BeFalse
        $r.Differences[0].Kind | Should -Be 'Checksum'
    }

    It 'catches a column type change' {
        $s = @([pscustomobject]@{ Name='dbo.P'; RowCount=1; Checksum='a'; ColumnSignature='Id:int,Name:nvarchar' })
        $t = @([pscustomobject]@{ Name='dbo.P'; RowCount=1; Checksum='a'; ColumnSignature='Id:int,Name:varchar' })
        $r = Compare-DatabaseSnapshot -Source (& $script:MakeSnap $s) -Target (& $script:MakeSnap $t)
        ($r.Differences | Where-Object Kind -eq 'Schema').Count | Should -Be 1
    }

    It 'catches an unexpected table in the target' {
        $s = @([pscustomobject]@{ Name='dbo.A'; RowCount=1; Checksum='a'; ColumnSignature='s' })
        $t = @(
            [pscustomobject]@{ Name='dbo.A'; RowCount=1; Checksum='a'; ColumnSignature='s' }
            [pscustomobject]@{ Name='dbo.Leftover'; RowCount=5; Checksum='b'; ColumnSignature='s' }
        )
        $r = Compare-DatabaseSnapshot -Source (& $script:MakeSnap $s) -Target (& $script:MakeSnap $t)
        ($r.Differences | Where-Object Kind -eq 'Unexpected').Count | Should -Be 1
    }

    It 'totals rows on both sides' {
        $s = @(
            [pscustomobject]@{ Name='dbo.A'; RowCount=100; Checksum='a'; ColumnSignature='s' }
            [pscustomobject]@{ Name='dbo.B'; RowCount=50;  Checksum='b'; ColumnSignature='s' }
        )
        $r = Compare-DatabaseSnapshot -Source (& $script:MakeSnap $s) -Target (& $script:MakeSnap $s)
        $r.RowsSource | Should -Be 150
        $r.RowsTarget | Should -Be 150
    }
}