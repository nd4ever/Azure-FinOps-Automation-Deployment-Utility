BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'Update-SubscriptionTagInventory.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors -join "`n") }
    foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $script:sub1 = '11111111-1111-1111-1111-111111111111'
    $script:sub2 = '22222222-2222-2222-2222-222222222222'
    $script:tenant = '33333333-3333-3333-3333-333333333333'
}

Describe 'Azure CLI launcher' {
    It 'bypasses the Windows batch shell using the same bundled CLI entry point' -Skip:(-not $IsWindows) {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\AzureCLI\wbin\az.cmd' } } -ParameterFilter { $Name -eq 'az' }
        Mock Test-Path { $true }
        $launcher = Get-SubscriptionTagAzLauncher
        $launcher.FilePath | Should -Be 'C:\AzureCLI\python.exe'
        $launcher.Prefix -join ' ' | Should -Be '-IBm azure.cli'
    }

    It 'preserves a native executable launcher' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\AzureCLI\az.exe' } } -ParameterFilter { $Name -eq 'az' }
        $launcher = Get-SubscriptionTagAzLauncher
        $launcher.FilePath | Should -Be 'C:\AzureCLI\az.exe'
        $launcher.Prefix.Count | Should -Be 0
    }

    It 'reports a broken batch installation explicitly' -Skip:(-not $IsWindows) {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\AzureCLI\wbin\az.cmd' } } -ParameterFilter { $Name -eq 'az' }
        Mock Test-Path { $false }
        { Get-SubscriptionTagAzLauncher } | Should -Throw '*Repair the Azure CLI*'
    }
}

Describe 'Subscription tag snapshot' {
    BeforeEach {
        Mock Invoke-SubscriptionTagAz {
            param($Arguments)
            if ($Arguments[0] -eq 'account') {
                return @(
                    @{ id = $sub1; name = 'Same name'; state = 'Enabled'; tenantId = $tenant },
                    @{ id = $sub2; name = 'Same name'; state = 'Enabled'; tenantId = $tenant },
                    @{ id = '44444444-4444-4444-4444-444444444444'; name = 'Disabled'; state = 'Disabled'; tenantId = $tenant },
                    @{ id = '55555555-5555-5555-5555-555555555555'; name = 'Other tenant'; state = 'Enabled'; tenantId = 'other' }
                )
            }
            return @{ properties = @{ tags = @{ Environment = 'Prod'; CostCenter = 'Finance' } } }
        }
    }

    It 'reads enabled subscriptions in the current tenant without merging duplicate names' {
        $rows = @(Get-SubscriptionTagSnapshot -TenantId $tenant)
        $rows.Count | Should -Be 2
        @($rows.SubscriptionId | Sort-Object -Unique).Count | Should -Be 2
        @($rows.SnapshotAt | Sort-Object -Unique).Count | Should -Be 1
        Should -Invoke Invoke-SubscriptionTagAz -Times 2 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'rest' -and $Arguments[2] -eq 'get'
        }
    }

    It 'supports a deduplicated explicit subscription selection' {
        $rows = @(Get-SubscriptionTagSnapshot -TenantId $tenant -Ids @($sub1, $sub1))
        $rows.Count | Should -Be 1
        $rows[0].SubscriptionId | Should -Be $sub1
    }

    It 'rejects subscriptions outside the visible enabled set' {
        { Get-SubscriptionTagSnapshot -TenantId $tenant -Ids '66666666-6666-6666-6666-666666666666' } |
            Should -Throw '*previous snapshot was not changed*'
        Should -Invoke Invoke-SubscriptionTagAz -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'rest' }
    }

    It 'represents a successful untagged response as an empty bag' {
        Mock Invoke-SubscriptionTagAz { @{ properties = @{ tags = $null } } } -ParameterFilter { $Arguments[0] -eq 'rest' }
        $rows = @(Get-SubscriptionTagSnapshot -TenantId $tenant)
        $rows[0].Tags.Count | Should -Be 0
    }

    It 'does not return a successful snapshot when any subscription read fails' {
        Mock Invoke-SubscriptionTagAz { throw 'HTTP 403' } -ParameterFilter { $Arguments -contains $sub2 }
        { @(Get-SubscriptionTagSnapshot -TenantId $tenant) } | Should -Throw '*tags/read*previous snapshot was not changed*'
    }

    It 'rejects malformed tag API responses instead of assuming no tags' {
        Mock Invoke-SubscriptionTagAz { @{} } -ParameterFilter { $Arguments[0] -eq 'rest' }
        { Get-SubscriptionTagSnapshot -TenantId $tenant } | Should -Throw '*returned no properties*'
    }

    It 'does not clear an inventory when no subscriptions are visible' {
        Mock Invoke-SubscriptionTagAz { @() } -ParameterFilter { $Arguments[0] -eq 'account' }
        { Get-SubscriptionTagSnapshot -TenantId $tenant } | Should -Throw '*No enabled subscriptions*'
    }

    It 'rejects an explicit selection when the visible set is empty' {
        Mock Invoke-SubscriptionTagAz { @() } -ParameterFilter { $Arguments[0] -eq 'account' }
        { Get-SubscriptionTagSnapshot -TenantId $tenant -Ids $sub1 } |
            Should -Throw '*not visible and enabled*'
    }

    It 'rejects malformed properties instead of treating them as untagged' {
        Mock Invoke-SubscriptionTagAz { @{ properties = 'unexpected' } } -ParameterFilter { $Arguments[0] -eq 'rest' }
        { Get-SubscriptionTagSnapshot -TenantId $tenant } | Should -Throw '*returned no properties*'
    }
}

Describe 'ARM resource inventory' {
    BeforeEach {
        $script:subscriptions = @([pscustomobject]@{
            SubscriptionId = $sub1; SubscriptionName = 'Same name'
            SnapshotAt = '2026-10-13T19:02:03.1234567Z'
        })
        $script:resourceId = "/subscriptions/$sub1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1"
        Mock Invoke-SubscriptionTagAz {
            @{
                value = @(@{
                    id = $resourceId; name = 'vm1'; type = 'Microsoft.Compute/virtualMachines'
                    location = 'centralus'; tags = @{ Environment = 'Prod'; Owner = 'Team' }
                })
            }
        }
    }

    It 'normalizes IDs and records current resource metadata and tags' {
        $rows = @(Get-ResourceTagSnapshot -Subscriptions $subscriptions)
        $rows.Count | Should -Be 2
        $rows[0].ResourceId | Should -Be ''
        $rows[1].ResourceId | Should -BeExactly $resourceId.ToLowerInvariant()
        $rows[1].ResourceGroup | Should -Be 'rg'
        $rows[1].Tags.Environment | Should -Be 'Prod'
        $rows[1].SnapshotAt | Should -Be $subscriptions[0].SnapshotAt
    }

    It 'follows every page without duplicating resource IDs' {
        Mock Invoke-SubscriptionTagAz {
            param($Arguments)
            $record = @{ id = $resourceId; name = 'vm1'; type = 'Microsoft.Compute/virtualMachines' }
            if ($Arguments[4] -notlike '*page=2*') {
                return @{ value = @($record); nextLink = "https://management.azure.com/subscriptions/$sub1/resources?api-version=2021-04-01&page=2" }
            }
            return @{ value = @($record, @{ id = $resourceId.Replace('vm1', 'vm2'); name = 'vm2'; type = 'Microsoft.Compute/virtualMachines' }) }
        }
        $rows = @(Get-ResourceTagSnapshot -Subscriptions $subscriptions)
        $rows.Count | Should -Be 3
        Should -Invoke Invoke-SubscriptionTagAz -Times 2 -Exactly
    }

    It 'keeps a successful empty subscription as a summary row' {
        Mock Invoke-SubscriptionTagAz { @{ value = @() } }
        $rows = @(Get-ResourceTagSnapshot -Subscriptions $subscriptions)
        $rows.Count | Should -Be 1
        $rows[0].ResourceId | Should -Be ''
        (ConvertTo-ResourceTagCommand -Rows $rows) | Should -Match 'ResourceTagInventory'
    }

    It 'fails explicitly when a later page is unreadable' {
        Mock Invoke-SubscriptionTagAz {
            param($Arguments)
            if ($Arguments[4] -like '*page=2*') { throw 'HTTP 403' }
            return @{ value = @(); nextLink = "https://management.azure.com/subscriptions/$sub1/resources?page=2" }
        }
        { @(Get-ResourceTagSnapshot -Subscriptions $subscriptions) } |
            Should -Throw '*Reader*previous snapshots were not changed*'
    }

    It 'rejects a pagination URL outside the requested subscription' {
        Mock Invoke-SubscriptionTagAz { @{ value = @(); nextLink = 'https://example.com/resources?page=2' } }
        { @(Get-ResourceTagSnapshot -Subscriptions $subscriptions) } | Should -Throw '*Invalid or repeated*'
        Should -Invoke Invoke-SubscriptionTagAz -Times 1 -Exactly
    }

    It 'rejects looping pagination' {
        Mock Invoke-SubscriptionTagAz { @{ value = @(); nextLink = "https://management.azure.com/subscriptions/$sub1/resources?api-version=2021-04-01" } }
        { @(Get-ResourceTagSnapshot -Subscriptions $subscriptions) } | Should -Throw '*Invalid or repeated*'
    }

    It 'rejects malformed lists, resource IDs and tags rather than silently skipping records' {
        Mock Invoke-SubscriptionTagAz { @{ value = 'invalid' } }
        { @(Get-ResourceTagSnapshot -Subscriptions $subscriptions) } | Should -Throw '*Invalid resource list*'
        Mock Invoke-SubscriptionTagAz { @{ value = @(@{ id = "/subscriptions/$sub2/resources/other"; name = 'other'; type = 'test' }) } }
        { @(Get-ResourceTagSnapshot -Subscriptions $subscriptions) } | Should -Throw '*Invalid resource record*'
        Mock Invoke-SubscriptionTagAz { @{ value = @(@{ id = $resourceId; name = 'vm1'; type = 'test'; tags = 'invalid' }) } }
        { @(Get-ResourceTagSnapshot -Subscriptions $subscriptions) } | Should -Throw '*Invalid resource tags*'
    }

    It 'serializes quotes and control characters without KQL injection' {
        Mock Invoke-SubscriptionTagAz {
            @{ value = @(@{ id = $resourceId; name = "Name `"quoted`"`nnext"; type = 'test'; tags = @{ Owner = "A`"B`nnext" } }) }
        }
        $rows = @(Get-ResourceTagSnapshot -Subscriptions $subscriptions)
        $command = ConvertTo-ResourceTagCommand -Rows $rows
        $command | Should -Match '^\.set-or-replace ResourceTagInventory'
        $command | Should -Match '\\"quoted\\"'
        $command | Should -Match '\\n'
    }
}

Describe 'Snapshot command serialization' {
    It 'safely serializes quotes, line breaks, Unicode and punctuation in names and tags' {
        $rows = @([pscustomobject]@{
            SubscriptionId = $sub1
            SubscriptionName = "Name `"quoted`"`nnext"
            Tags = @{ "Owner's team" = "A`"B\C`nnext"; Empty = '' }
            SnapshotAt = '2026-10-13T10:00:00Z'
        })
        $command = ConvertTo-SubscriptionTagCommand -Rows $rows
        $command | Should -Match '^\.set-or-replace SubscriptionTagInventory'
        $command | Should -Match '\\n'
        $command | Should -Match '\\"quoted\\"'
        $command | Should -Match '"Empty":""'
        $command | Should -Match 'datetime\(2026-10-13T10:00:00'
    }

    It 'rejects an empty replacement' {
        { ConvertTo-SubscriptionTagCommand -Rows @() } | Should -Throw
    }
}

Describe 'Repository integration' {
    It 'parses both PowerShell entry points' {
        foreach ($name in 'Deploy-FinOpsHub-V3-Fabric.ps1', 'Update-SubscriptionTagInventory.ps1') {
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name), [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0
        }
    }
}

Describe 'Snapshot verification' {
    BeforeEach {
        $script:expectedTime = '2026-10-13T19:02:03.1234567Z'
        $script:expectedRows = @([pscustomobject]@{ SnapshotAt = $expectedTime })
    }

    It 'preserves precision and timezone when JSON produces a DateTime' {
        $response = '{"Tables":[{"Rows":[[1,"2026-10-13T19:02:03.1234567Z"]]}]}' | ConvertFrom-Json
        { Assert-SubscriptionTagSnapshot -Response $response -Rows $expectedRows } | Should -Not -Throw
    }

    It 'accepts a matching string timestamp' {
        $response = [pscustomobject]@{ Tables = @([pscustomobject]@{ Rows = @(, @(1, $expectedTime)) }) }
        { Assert-SubscriptionTagSnapshot -Response $response -Rows $expectedRows } | Should -Not -Throw
    }

    It 'rejects a genuinely different timestamp' {
        $response = '{"Tables":[{"Rows":[[1,"2026-10-13T19:02:03.1234568Z"]]}]}' | ConvertFrom-Json
        { Assert-SubscriptionTagSnapshot -Response $response -Rows $expectedRows } | Should -Throw '*did not match*'
    }

    It 'rejects a different subscription count' {
        $response = [pscustomobject]@{ Tables = @([pscustomobject]@{ Rows = @(, @(2, $expectedTime)) }) }
        { Assert-SubscriptionTagSnapshot -Response $response -Rows $expectedRows } | Should -Throw '*did not match*'
    }

    It 'rejects a missing inventory summary' {
        $response = [pscustomobject]@{ Tables = @() }
        { Assert-SubscriptionTagSnapshot -Response $response -Rows $expectedRows } | Should -Throw '*no inventory summary*'
    }
}

Describe 'Kusto response handling' {
    BeforeEach {
        $script:QueryUri = 'https://example.z0.kusto.fabric.microsoft.com'
        $script:Database = 'Hub'
    }

    It 'rejects an explicit Kusto service error' {
        Mock Invoke-RestMethod { [pscustomobject]@{ error = @{ code = 'Forbidden' } } }
        { Invoke-SubscriptionTagKusto -Command 'test' -Token 'test-token' } | Should -Throw '*Kusto rejected*'
    }

    It 'rejects a partial query failure returned with HTTP 200' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                Tables = @([pscustomobject]@{
                    TableName = 'QueryStatus'
                    Columns = @([pscustomobject]@{ ColumnName = 'Severity' })
                    Rows = @(, @(2))
                })
            }
        }
        { Invoke-SubscriptionTagKusto -Command 'test' -Token 'test-token' -Query } | Should -Throw '*query failure*'
    }

    It 'uses a JSON payload and a query endpoint for verification' {
        Mock Invoke-RestMethod { [pscustomobject]@{ Tables = @() } }
        $null = Invoke-SubscriptionTagKusto -Command 'SubscriptionTagInventory | count' -Token 'test-token' -Query
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://example.z0.kusto.fabric.microsoft.com/v1/rest/query' -and
            ([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json).db -eq 'Hub'
        }
    }
}
