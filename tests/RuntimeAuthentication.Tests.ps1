BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'Deploy-FinOpsHub-V3-Fabric.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors -join "`n") }
    foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $script:sub = '11111111-1111-1111-1111-111111111111'
    $script:principal = '22222222-2222-2222-2222-222222222222'
    $script:ExportsApiVersion = '2025-03-01'
    $script:hub = @{
        StorageId = "/subscriptions/$sub/resourceGroups/hub/providers/Microsoft.Storage/storageAccounts/hubdata"
        StorageName = 'hubdata'
        DataFactoryId = "/subscriptions/$sub/resourceGroups/hub/providers/Microsoft.DataFactory/factories/hub"
    }
    $script:storageService = @{
        name = 'hub/hubdata'
        properties = @{ type = 'AzureBlobFS'; typeProperties = @{ url = 'https://hubdata.dfs.core.windows.net' } }
    }
    $script:export = @{
        id = "/subscriptions/$sub/providers/Microsoft.CostManagement/exports/daily"
        name = 'daily'
        identity = @{ type = 'SystemAssigned'; principalId = $principal }
        properties = @{ deliveryInfo = @{ destination = @{ resourceId = $hub.StorageId; container = 'msexports' } } }
    }
}

Describe 'Keyless template configuration' {
    It 'rejects optional key-based remote-hub configuration' -ForEach @(
        @{ Values = @{ remoteHubStorageKey = 'placeholder' } },
        @{ Values = @{ remoteHubStorageUri = 'https://remote.dfs.core.windows.net' } }
    ) {
        { Assert-KeylessTemplateParameters -Values $Values } | Should -Throw '*remote-hub*'
    }

    It 'accepts empty remote-hub parameters' {
        { Assert-KeylessTemplateParameters -Values @{ remoteHubStorageKey = ''; remoteHubStorageUri = '' } } | Should -Not -Throw
    }

    It 'disables all eight hub storage definitions but preserves supporting storage and the source file' {
        $path = Join-Path $root 'template.json'
        $before = (Get-FileHash $path).Hash
        $text = ConvertTo-KeylessHubTemplate -TemplateJson (Get-Content $path -Raw)
        ([regex]::Matches($text, "'allowSharedKeyAccess', false\(\)")).Count | Should -Be 8
        $text | Should -Not -Match "'allowSharedKeyAccess', true\(\)"
        $text | Should -Match '"allowSharedKeyAccess":true'
        $document = $text | ConvertFrom-Json -Depth 100
        $document.resources.hub.properties.template.resources.core.properties.template.resources.infrastructure.properties.template.resources.scriptStorageAccount.properties.allowSharedKeyAccess | Should -BeTrue
        $original = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 | ConvertTo-Json -Depth 100 -Compress
        $text.Replace("'allowSharedKeyAccess', false()", "'allowSharedKeyAccess', true()") | Should -BeExactly $original
        (Get-FileHash $path).Hash | Should -Be $before
    }

    It 'rejects unrecognized templates instead of claiming keyless configuration' {
        { ConvertTo-KeylessHubTemplate '{"resources":{}}' } | Should -Throw '*No recognized*'
    }

    It 'rejects unexpected hub storage authentication definitions' {
        $fixture = @{ resources = @{ storage = @{ type = 'Microsoft.Storage/storageAccounts'; name = "[parameters('app').storage]"; properties = @{} } } } | ConvertTo-Json -Depth 10
        { ConvertTo-KeylessHubTemplate $fixture } | Should -Throw '*Unrecognized*'
    }
}

Describe 'Storage and ingestion dependency validation' {
    BeforeEach {
        $script:service = $storageService | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        Mock Get-ArmList { @($script:service) }
    }

    It 'accepts implicit Data Factory system-assigned identity' {
        Assert-KeylessStorageLinkedServices -Hub $hub | Should -Be 1
    }

    It 'rejects key, SAS and service-principal storage credentials' -ForEach @(
        @{ Key = 'accountKey' }, @{ Key = 'sasUri' }, @{ Key = 'sasToken' },
        @{ Key = 'connectionString' }, @{ Key = 'servicePrincipalId' },
        @{ Key = 'servicePrincipalKey' }, @{ Key = 'servicePrincipalCredential' }, @{ Key = 'credential' }
    ) {
        $script:service.properties.typeProperties[$Key] = @{ type = 'SecureString'; value = 'placeholder' }
        { Assert-KeylessStorageLinkedServices -Hub $hub } | Should -Throw '*not the Data Factory system-assigned identity*'
    }

    It 'rejects a separate credential reference' {
        $script:service.properties.credential = @{ referenceName = 'anotherIdentity' }
        { Assert-KeylessStorageLinkedServices -Hub $hub } | Should -Throw '*separate credential*'
    }

    It 'rejects another storage account with unverified permissions' {
        $script:service.properties.typeProperties.url = 'https://another.dfs.core.windows.net'
        { Assert-KeylessStorageLinkedServices -Hub $hub } | Should -Throw '*another account*'
    }

    It 'rejects dynamic URLs' {
        $script:service.properties.typeProperties.url = '@{linkedService().url}'
        { Assert-KeylessStorageLinkedServices -Hub $hub } | Should -Throw '*invalid URL*'
    }

    It 'rejects a missing hub linked service' {
        Mock Get-ArmList { @() }
        { Assert-KeylessStorageLinkedServices -Hub $hub } | Should -Throw '*No managed-identity*'
    }

    It 'accepts Entra-impersonated Fabric ingestion' {
        Mock Get-ArmList { @(@{ name = 'ingest'; properties = @{ command = '.ingest into table Costs ("abfss://container@hubdata.dfs.core.windows.net/file;impersonate")' } }) }
        { Assert-KeylessFabricIngestion -Hub $hub } | Should -Not -Throw
    }

    It 'rejects ingestion without impersonation' {
        Mock Get-ArmList { @(@{ name = 'ingest'; properties = @{ command = '.ingest into table Costs ("https://hubdata.blob.core.windows.net/file?sig=placeholder")' } }) }
        { Assert-KeylessFabricIngestion -Hub $hub } | Should -Throw '*supported Entra-authenticated*'
    }

    It 'does not let one impersonated activity hide a key-based activity in the same pipeline' {
        Mock Get-ArmList {
            @(@{ name = 'ingest'; properties = @{ commands = @(
                '.ingest into table Costs ("abfss://container@hubdata.dfs.core.windows.net/file;impersonate")',
                '.ingest into table Costs ("https://hubdata.blob.core.windows.net/file?sig=placeholder")'
            ) } })
        }
        { Assert-KeylessFabricIngestion -Hub $hub } | Should -Throw '*supported Entra-authenticated*'
    }
}

Describe 'Cost export authentication' {
    It 'finds identity-based exports targeting the hub' {
        Mock Get-ArmList { @($export) }
        $result = @(Get-KeylessHubExports -Hub $hub -Scopes "/subscriptions/$sub")
        $result.Count | Should -Be 1
        $result[0].PrincipalId | Should -Be $principal
        $result[0].Container | Should -Be 'msexports'
    }

    It 'ignores exports targeting other accounts' {
        $other = $export | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        $other.properties.deliveryInfo.destination.resourceId = '/another/account'
        Mock Get-ArmList { @($other) }
        @(Get-KeylessHubExports -Hub $hub -Scopes "/subscriptions/$sub").Count | Should -Be 0
    }

    It 'rejects exports without a principal before storage changes' {
        $legacy = $export | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        $legacy.identity = @{ type = 'None' }
        Mock Get-ArmList { @($legacy) }
        { Get-KeylessHubExports -Hub $hub -Scopes "/subscriptions/$sub" } | Should -Throw '*no system-assigned identity*'
    }
}

Describe 'Scoped identity role grants' {
    BeforeEach {
        Mock Get-ArmList { @() }
        Mock Invoke-Arm {}
    }

    It 'grants export write access at container scope, not account scope' {
        $scope = "$($hub.StorageId)/blobServices/default/containers/msexports"
        Set-HubStorageDataRole -StorageId $scope -PrincipalId $principal -RoleId 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        Should -Invoke Invoke-Arm -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and $Path.StartsWith("$scope/providers/Microsoft.Authorization/roleAssignments/") -and
            $Body.properties.principalId -eq $principal -and $Body.properties.principalType -eq 'ServicePrincipal'
        }
    }

    It 'does not recreate an existing scoped grant' {
        $role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        Mock Get-ArmList { @(@{ properties = @{ principalId = $principal; scope = $hub.StorageId; roleDefinitionId = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/$role" } }) }
        Set-HubStorageDataRole -StorageId $hub.StorageId -PrincipalId $principal -RoleId $role
        Should -Invoke Invoke-Arm -Times 0
    }

    It 'propagates grant failures' {
        Mock Invoke-Arm { throw 'role grant denied' }
        { Set-HubStorageDataRole -StorageId $hub.StorageId -PrincipalId $principal -RoleId 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' } | Should -Throw '*role grant denied*'
    }
}

Describe 'Runtime key disablement' {
    BeforeEach {
        $script:allowKeys = $true
        Mock Assert-KeylessStorageLinkedServices { 1 }
        Mock Assert-KeylessFabricIngestion {}
        Mock Get-KeylessHubExports { @([pscustomobject]@{ PrincipalId = $principal; Container = 'msexports' }) }
        Mock Set-HubStorageDataRole {}
        Mock Invoke-Arm {
            if ($Method -eq 'PATCH') { $script:allowKeys = $Body.properties.allowSharedKeyAccess }
            return @{ Content = @{ properties = @{ allowSharedKeyAccess = $script:allowKeys } } }
        }
    }

    It 'disables keys without changing networking, then reads back the policy' {
        $result = Set-KeylessHubRuntime -Hub $hub -FactoryPrincipalId $principal -Scopes "/subscriptions/$sub"
        $result.AllowSharedKeyAccess | Should -BeFalse
        $result.Exports | Should -Be 1
        Should -Invoke Set-HubStorageDataRole -Times 2 -Exactly
        Should -Invoke Invoke-Arm -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PATCH' -and $Body.properties.Count -eq 1 -and $Body.properties.allowSharedKeyAccess -eq $false
        }
        Should -Invoke Invoke-Arm -Times 2 -Exactly -ParameterFilter { $Method -ne 'PATCH' }
    }

    It 'does not disable keys when dependencies fail' {
        Mock Get-KeylessHubExports { throw 'export identity missing' }
        { Set-KeylessHubRuntime -Hub $hub -FactoryPrincipalId $principal -Scopes "/subscriptions/$sub" } | Should -Throw '*export identity missing*'
        Should -Invoke Invoke-Arm -Times 0
        Should -Invoke Set-HubStorageDataRole -Times 0
    }

    It 'does not disable keys when role grants fail' {
        Mock Set-HubStorageDataRole { throw 'role grant denied' }
        { Set-KeylessHubRuntime -Hub $hub -FactoryPrincipalId $principal -Scopes "/subscriptions/$sub" } | Should -Throw '*role grant denied*'
        Should -Invoke Invoke-Arm -Times 0
    }

    It 'is idempotent when keys are already disabled' {
        $script:allowKeys = $false
        $null = Set-KeylessHubRuntime -Hub $hub -FactoryPrincipalId $principal -Scopes "/subscriptions/$sub"
        Should -Invoke Invoke-Arm -Times 0 -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'fails explicitly when the updated setting does not persist' {
        Mock Invoke-Arm { @{ Content = @{ properties = @{ allowSharedKeyAccess = $true } } } }
        { Set-KeylessHubRuntime -Hub $hub -FactoryPrincipalId $principal -Scopes "/subscriptions/$sub" } | Should -Throw '*still permits shared-key*'
    }
}

Describe 'Deployment-script exception isolation' {
    It 'uses explicit supporting-storage references, including auto-created storage' {
        $scripts = @(
            @{ properties = @{ storageAccountSettings = @{ storageAccountName = 'supportstorage' } } },
            @{ properties = @{ status = @{ storageAccountId = "/subscriptions/$sub/resourceGroups/hub/providers/Microsoft.Storage/storageAccounts/generatedazscripts" } } },
            @{ properties = @{} }
        )
        $ids = @(Get-DeploymentScriptStorageIds -Scripts $scripts -Subscription $sub -Group 'hub')
        $ids.Count | Should -Be 2
        $ids | Should -Not -Contain $hub.StorageId
    }

    It 'refuses accounts outside the deployment resource group' {
        $scripts = @(@{ properties = @{ status = @{ storageAccountId = "/subscriptions/$sub/resourceGroups/other/providers/Microsoft.Storage/storageAccounts/supportstorage" } } })
        { Get-DeploymentScriptStorageIds -Scripts $scripts -Subscription $sub -Group 'hub' } | Should -Throw '*outside the hub resource group*'
    }

    It 'accepts the Azure CLI flattened property shape without guessing account names' {
        $scripts = @(
            @{ storageAccountSettings = @{ storageAccountName = 'supportstorage' } },
            @{ status = @{ storageAccountId = "/subscriptions/$sub/resourceGroups/hub/providers/Microsoft.Storage/storageAccounts/generatedazscripts" } }
        )
        @(Get-DeploymentScriptStorageIds -Scripts $scripts -Subscription $sub -Group 'hub').Count | Should -Be 2
    }

    It 'does not select accounts using name guesses' {
        @(Get-DeploymentScriptStorageIds -Scripts @(@{ name = 'somethingazscripts'; properties = @{} }) -Subscription $sub -Group 'hub').Count | Should -Be 0
    }

    Describe 'Existing hub pre-flight' {
        BeforeEach {
            $script:SubscriptionId = $sub
            $script:ResourceGroupName = 'hub'
            $script:DeploymentPrefix = 'finopshub-fabric'
            $script:ExportScopes = @('/providers/Microsoft.Billing/billingAccounts/example')
            Mock Get-ArmList {
                @(@{
                    name = 'finopshub-fabric-existing'
                    properties = @{
                        provisioningState = 'Succeeded'
                        timestamp = '2026-01-01T00:00:00Z'
                        outputs = @{ storageAccountId = @{ value = $hub.StorageId }; dataFactoryName = @{ value = 'hub' } }
                    }
                })
            }
            Mock Assert-KeylessStorageLinkedServices { 1 }
            Mock Assert-KeylessFabricIngestion {}
            Mock Get-DefaultExportScopes { "/subscriptions/$sub" }
            Mock Get-KeylessHubExports {}
            Mock Invoke-Arm { throw 'Pre-flight must not write resources' }
        }

        It 'validates a single visible subscription and explicit billing scopes separately' {
            Assert-KeylessExistingHub -TemplateValues @{ location = 'centralus' }
            Should -Invoke Get-KeylessHubExports -Times 1 -Exactly -ParameterFilter {
                $Scopes.Count -eq 2 -and $Scopes -contains "/subscriptions/$sub" -and $Scopes -contains '/providers/Microsoft.Billing/billingAccounts/example'
            }
            Should -Invoke Assert-KeylessFabricIngestion -Times 1 -Exactly
            Should -Invoke Invoke-Arm -Times 0
        }

        It 'stops on unsupported existing dependencies without changing resources' {
            Mock Assert-KeylessStorageLinkedServices { throw 'legacy account-key connection' }
            { Assert-KeylessExistingHub -TemplateValues @{ location = 'centralus' } } | Should -Throw '*legacy account-key*'
            Should -Invoke Invoke-Arm -Times 0
        }
    }
}
