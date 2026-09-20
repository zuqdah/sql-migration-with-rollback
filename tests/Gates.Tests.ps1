<#
    Tests for the gates themselves. A gate that has never refused anything is
    not a gate, so each of these drives the real script with mutated facts and
    requires it to fail.
#>

BeforeAll {
    $script:Root    = Split-Path $PSScriptRoot -Parent
    $script:Assess  = Join-Path -Path (Join-Path -Path $script:Root -ChildPath 'scripts') -ChildPath 'Invoke-Assessment.ps1'
    $script:Parity  = Join-Path -Path (Join-Path -Path $script:Root -ChildPath 'scripts') -ChildPath 'Test-MigrationParity.ps1'

    function New-FactSet {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture, not a cmdlet.')]
        param([hashtable]$Overrides = @{})
        $facts = [ordered]@{
            GeneratedUtc = '2026-09-20T00:00:00Z'
            Server       = 'src'
            Database     = 'AppDb'
            Inventory    = [ordered]@{
                Columns = @(@{ SchemaName='dbo'; TableName='Orders'; ColumnName='OrderId'; DataType='int' })
                Tables  = @(@{ SchemaName='dbo'; TableName='Orders'; HasClusteredIndex=$true; HasPrimaryKey=$true })
                Modules = @(@{ SchemaName='dbo'; Name='vThing'; Type='VIEW'; Definition='SELECT 1' })
            }
            Snapshot     = [ordered]@{
                Tables = @(@{ Name='dbo.Orders'; RowCount=2000; Checksum='111'; ColumnSignature='OrderId:int'; ExcludedFromHash=@() })
            }
        }
        foreach ($k in $Overrides.Keys) { $facts[$k] = $Overrides[$k] }
        $facts
    }

    function Save-FactSet {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture, not a cmdlet.')]
        param([object]$Facts, [string]$Path)
        [System.IO.File]::WriteAllText($Path, ($Facts | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        $Path
    }
}

Describe 'Assessment gate' {
    It 'passes a database with no blocking findings' {
        $p = Save-FactSet (New-FactSet) (Join-Path $TestDrive 'clean.json')
        { & $script:Assess -FactsPath $p *> $null } | Should -Not -Throw
    }

    It 'refuses to proceed when a module uses shell execution' {
        $f = New-FactSet
        $f.Inventory.Modules[0].Definition = "EXEC xp_cmdshell 'whoami'"
        $p = Save-FactSet $f (Join-Path $TestDrive 'block.json')
        { & $script:Assess -FactsPath $p *> $null } | Should -Throw -ExpectedMessage '*blocking finding*'
    }

    It 'does not refuse over warnings alone' {
        # A heap is worth reporting and not worth blocking a migration over.
        $f = New-FactSet
        $f.Inventory.Tables[0].HasClusteredIndex = $false
        $f.Inventory.Tables[0].HasPrimaryKey     = $false
        $p = Save-FactSet $f (Join-Path $TestDrive 'warn.json')
        { & $script:Assess -FactsPath $p *> $null } | Should -Not -Throw
    }
}

Describe 'Parity gate' {
    BeforeAll {
        $script:SrcPath = Save-FactSet (New-FactSet) (Join-Path $TestDrive 'src.json')
    }

    It 'passes when the target matches' {
        $p = Save-FactSet (New-FactSet) (Join-Path $TestDrive 'same.json')
        { & $script:Parity -SourceFacts $script:SrcPath -TargetFacts $p *> $null } | Should -Not -Throw
    }

    It 'fails when a row went missing' {
        $f = New-FactSet
        $f.Snapshot.Tables[0].RowCount = 1999
        $p = Save-FactSet $f (Join-Path $TestDrive 'rows.json')
        { & $script:Parity -SourceFacts $script:SrcPath -TargetFacts $p *> $null } | Should -Throw -ExpectedMessage '*does not match*'
    }

    It 'fails when content changed but the row count did not' {
        $f = New-FactSet
        $f.Snapshot.Tables[0].Checksum = '999'
        $p = Save-FactSet $f (Join-Path $TestDrive 'sum.json')
        { & $script:Parity -SourceFacts $script:SrcPath -TargetFacts $p *> $null } | Should -Throw -ExpectedMessage '*does not match*'
    }

    It 'fails when a column type changed silently' {
        $f = New-FactSet
        $f.Snapshot.Tables[0].ColumnSignature = 'OrderId:bigint'
        $p = Save-FactSet $f (Join-Path $TestDrive 'type.json')
        { & $script:Parity -SourceFacts $script:SrcPath -TargetFacts $p *> $null } | Should -Throw -ExpectedMessage '*does not match*'
    }

    It 'fails when a table did not arrive' {
        $f = New-FactSet
        $f.Snapshot.Tables = @()
        $p = Save-FactSet $f (Join-Path $TestDrive 'gone.json')
        { & $script:Parity -SourceFacts $script:SrcPath -TargetFacts $p *> $null } | Should -Throw -ExpectedMessage '*does not match*'
    }
}