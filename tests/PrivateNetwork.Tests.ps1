BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:source = Get-Content (Join-Path $root 'Deploy-FinOpsHub-V3-Fabric.ps1') -Raw
    $tokens = $null
    $errors = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors -join "`n") }
    foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $preflightMatch = [regex]::Match($source, '(?s)    \$vnet = \$null.*?(?=    if \(\$guided\) \{\s+\$planScopes)')
    if (-not $preflightMatch.Success) { throw 'Network pre-flight block not found in the entry point.' }
    $script:networkPreflight = [scriptblock]::Create($preflightMatch.Value)
    $script:sub = '11111111-1111-1111-1111-111111111111'
    $script:vnetId = "/subscriptions/$sub/resourceGroups/hub-network/providers/Microsoft.Network/virtualNetworks/vnet-hub"
    $script:planArguments = @{
        Subscription = $sub; Group = 'hub-network'; Name = 'vnet-hub'; RegionName = 'centralus'
        AddressPrefix = '10.30.0.0/24'; SubnetName = 'snet-private-endpoints'; SubnetPrefix = '10.30.0.0/28'; HubPrefix = '10.20.30.0/26'
    }
    $script:fixture = @{
        id = $vnetId; name = 'vnet-hub'; location = 'centralus'
        properties = @{
            provisioningState = 'Succeeded'
            addressSpace = @{ addressPrefixes = @('10.30.0.0/24') }
            subnets = @(@{
                id = "$vnetId/subnets/snet-private-endpoints"; name = 'snet-private-endpoints'
                properties = @{ addressPrefix = '10.30.0.0/28'; delegations = @(); ipConfigurations = @() }
            })
        }
    }
}

Describe 'Network address validation' {
    It 'computes actual usable IPv4 addresses' {
        $range = Get-Ipv4CidrRange '10.30.0.0/28'
        $range.Prefix | Should -Be 28
        $range.FreeAddresses | Should -Be 11
        $range.End - $range.Start | Should -Be 15
    }

    It 'rejects malformed, noncanonical or nonaligned ranges' -ForEach @(
        @{ Cidr = '999.30.0.0/24' }, @{ Cidr = '10.30.0.1/24' }, @{ Cidr = '10.30.0.0/33' },
        @{ Cidr = '10.30/24' }, @{ Cidr = '::/64' }, @{ Cidr = '10.030.0.0/24' }
    ) {
        { Get-Ipv4CidrRange $Cidr } | Should -Throw
    }

    It 'rejects a subnet outside the VNet before any Azure request' {
        Mock Invoke-Arm { throw 'No Azure request expected' }
        $arguments = $planArguments.Clone()
        $arguments.SubnetPrefix = '10.31.0.0/28'
        { Get-NewVirtualNetworkPlan @arguments } | Should -Throw '*contained*'
        Should -Invoke Invoke-Arm -Times 0
    }

    It 'rejects a subnet with fewer than eight usable addresses' {
        Mock Invoke-Arm {}
        $arguments = $planArguments.Clone()
        $arguments.SubnetPrefix = '10.30.0.0/29'
        { Get-NewVirtualNetworkPlan @arguments } | Should -Throw '*8 usable addresses*'
        Should -Invoke Invoke-Arm -Times 0
    }

    It 'rejects overlap with the hub internal network' {
        Mock Invoke-Arm {}
        $arguments = $planArguments.Clone()
        $arguments.HubPrefix = '10.30.0.0/26'
        { Get-NewVirtualNetworkPlan @arguments } | Should -Throw '*overlaps the hub internal*'
        Should -Invoke Invoke-Arm -Times 0
    }
}

Describe 'Network naming defaults' {
    It 'derives isolated names from the hub resource group' {
        $settings = Get-NewVirtualNetworkSettings -HubGroup 'rg-finops-private'
        $settings.VirtualNetworkResourceGroupName | Should -Be 'rg-finops-private-network'
        $settings.VirtualNetworkName | Should -Be 'vnet-rg-finops-private'
        $settings.PrivateEndpointSubnetName | Should -Be 'snet-private-endpoints'
    }

    It 'preserves explicit names' {
        $settings = Get-NewVirtualNetworkSettings -HubGroup 'hub' -NetworkName 'custom-vnet' -NetworkGroup 'custom-network' -SubnetName 'custom-subnet'
        $settings.VirtualNetworkName | Should -Be 'custom-vnet'
        $settings.VirtualNetworkResourceGroupName | Should -Be 'custom-network'
        $settings.PrivateEndpointSubnetName | Should -Be 'custom-subnet'
    }

    It 'keeps generated names within Azure length limits' {
        $settings = Get-NewVirtualNetworkSettings -HubGroup ('a' * 90)
        $settings.VirtualNetworkName.Length | Should -BeLessOrEqual 64
        $settings.VirtualNetworkResourceGroupName.Length | Should -BeLessOrEqual 90
    }

    It 'rejects the hub RG as the network RG' {
        { Get-NewVirtualNetworkSettings -HubGroup 'hub' -NetworkGroup 'hub' } | Should -Throw '*separate*'
    }

    It 'rejects reserved subnet names' {
        { Get-NewVirtualNetworkSettings -HubGroup 'hub' -SubnetName 'GatewaySubnet' } | Should -Throw '*non-reserved*'
    }
}

Describe 'Read-only network planning' {
    BeforeEach { Mock Invoke-Arm { $null } }

    It 'plans a new VNet/subnet without provisioning resources' {
        $plan = Get-NewVirtualNetworkPlan @planArguments
        $plan.Existing | Should -BeFalse
        $plan.VirtualNetwork.id | Should -Be $vnetId
        $plan.Subnet.id | Should -Be "$vnetId/subnets/snet-private-endpoints"
        $plan.Subnet.properties.privateEndpointNetworkPolicies | Should -Be 'Disabled'
        Should -Invoke Invoke-Arm -Times 1 -Exactly -ParameterFilter { $Method -ne 'PUT' -and $AllowNotFound }
    }

    It 'honors custom address ranges rather than hard-coding the defaults' {
        $arguments = $planArguments.Clone()
        $arguments.AddressPrefix = '10.42.0.0/16'
        $arguments.SubnetPrefix = '10.42.7.0/24'
        $plan = Get-NewVirtualNetworkPlan @arguments
        $plan.VirtualNetwork.properties.addressSpace.addressPrefixes[0] | Should -Be '10.42.0.0/16'
        $plan.Subnet.properties.addressPrefix | Should -Be '10.42.7.0/24'
    }

    It 'plans safe reuse of an existing compatible VNet' {
        Mock Invoke-Arm { @{ Content = $fixture } }
        $plan = Get-NewVirtualNetworkPlan @planArguments
        $plan.Existing | Should -BeTrue
        Should -Invoke Invoke-Arm -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'rejects existing incompatible addressing' {
        $different = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $different.properties.addressSpace.addressPrefixes = @('10.31.0.0/24')
        Mock Invoke-Arm { @{ Content = $different } }
        { Get-NewVirtualNetworkPlan @planArguments } | Should -Throw '*conflicts*'
    }

    It 'rejects delegated subnets' {
        $different = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $different.properties.subnets[0].properties.delegations = @(@{ name = 'service' })
        Mock Invoke-Arm { @{ Content = $different } }
        { Get-NewVirtualNetworkPlan @planArguments } | Should -Throw '*delegation*'
    }

    It 'rejects missing subnets instead of expanding an existing VNet' {
        $different = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $different.properties.subnets = @()
        Mock Invoke-Arm { @{ Content = $different } }
        { Get-NewVirtualNetworkPlan @planArguments } | Should -Throw '*no subnets were added*'
    }
}

Describe 'Network provisioning and rerun safety' {
    BeforeEach {
        Mock Invoke-Arm { $null }
        $script:plan = Get-NewVirtualNetworkPlan @planArguments
        Mock Set-ResourceGroup {}
        Mock Wait-ArmAsyncOperation {}
    }

    It 'creates exactly one non-delegated subnet and verifies persisted state' {
        $script:written = $false
        Mock Invoke-Arm {
            if ($Method -eq 'PUT') { $script:written = $true; return @{ Headers = @{} } }
            if ($script:written) { return @{ Content = $fixture } }
            return $null
        }
        $result = Set-NewVirtualNetwork -Plan $plan -ResourceTags @{ Workload = 'FinOps' }
        $result.Created | Should -BeTrue
        $result.Subnet.id | Should -Be "$vnetId/subnets/snet-private-endpoints"
        Should -Invoke Set-ResourceGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'hub-network' -and $Subscription -eq $sub }
        Should -Invoke Invoke-Arm -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and $Path -eq "$vnetId`?api-version=2024-05-01" -and
            $Body.location -eq 'centralus' -and $Body.tags.Workload -eq 'FinOps' -and
            $Body.properties.subnets.Count -eq 1 -and
            $Body.properties.subnets[0].properties.addressPrefix -eq '10.30.0.0/28' -and
            $Body.properties.subnets[0].properties.privateEndpointNetworkPolicies -eq 'Disabled'
        }
        Should -Invoke Wait-ArmAsyncOperation -Times 1 -Exactly
    }

    It 'reuses existing settings without replacing unrelated subnets or tags' {
        $existing = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $existing.tags = @{ Owner = 'existing' }
        $existing.properties.subnets += @{ name = 'another-subnet'; properties = @{ addressPrefix = '10.30.0.16/28' } }
        Mock Invoke-Arm { @{ Content = $existing } }
        $result = Set-NewVirtualNetwork -Plan $plan -ResourceTags @{ Owner = 'new' }
        $result.Created | Should -BeFalse
        $result.VirtualNetwork.properties.subnets.Count | Should -Be 2
        $result.VirtualNetwork.tags.Owner | Should -Be 'existing'
        Should -Invoke Invoke-Arm -Times 0 -ParameterFilter { $Method -eq 'PUT' }
        Should -Invoke Set-ResourceGroup -Times 0
    }

    It 'refuses to overwrite a conflicting VNet that appeared after planning' {
        $different = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $different.location = 'eastus'
        Mock Invoke-Arm { @{ Content = $different } }
        { Set-NewVirtualNetwork -Plan $plan -ResourceTags @{} } | Should -Throw '*conflicts*'
        Should -Invoke Invoke-Arm -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'allows reruns after existing private endpoints consume subnet addresses' {
        $existing = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $existing.properties.subnets[0].properties.ipConfigurations = @(
            @{ id = 'existing-endpoint-1' }, @{ id = 'existing-endpoint-2' },
            @{ id = 'existing-endpoint-3' }, @{ id = 'existing-endpoint-4' }, @{ id = 'existing-endpoint-5' }
        )
        Mock Invoke-Arm { @{ Content = $existing } }
        $rerunPlan = Get-NewVirtualNetworkPlan @planArguments
        $result = Set-NewVirtualNetwork -Plan $rerunPlan -ResourceTags @{}
        $result.Created | Should -BeFalse
        Should -Invoke Invoke-Arm -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'does not recreate an existing VNet deleted after planning' {
        $plan.Existing = $true
        { Set-NewVirtualNetwork -Plan $plan -ResourceTags @{} } | Should -Throw '*disappeared*'
        Should -Invoke Invoke-Arm -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'propagates creation failures explicitly' {
        Mock Invoke-Arm { throw 'network write denied' } -ParameterFilter { $Method -eq 'PUT' }
        { Set-NewVirtualNetwork -Plan $plan -ResourceTags @{} } | Should -Throw '*network write denied*'
    }

    It 'rejects a failed provisioning result' {
        $script:written = $false
        Mock Invoke-Arm {
            if ($Method -eq 'PUT') { $script:written = $true; return @{ Headers = @{} } }
            if ($script:written) { return @{ Content = @{ properties = @{ provisioningState = 'Failed' } } } }
            return $null
        }
        { Set-NewVirtualNetwork -Plan $plan -ResourceTags @{} } | Should -Throw "*ended with 'Failed'*"
    }

    It 'waits for a pending resource before declaring creation successful' {
        $script:written = $false
        $script:reads = 0
        Mock Start-Sleep {}
        Mock Invoke-Arm {
            if ($Method -eq 'PUT') { $script:written = $true; return @{ Headers = @{} } }
            if (-not $script:written) { return $null }
            $script:reads++
            if ($script:reads -eq 1) { return @{ Content = @{ properties = @{ provisioningState = 'Updating' } } } }
            return @{ Content = $fixture }
        }
        (Set-NewVirtualNetwork -Plan $plan -ResourceTags @{}).Created | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }
}

Describe 'New network DNS planning' {
    BeforeEach {
        $script:SubscriptionId = $sub
        $script:ResourceGroupName = 'hub'
        Mock Invoke-ResourceGraph { @() }
        Mock Get-ArmList { throw 'Cannot list zones in an absent resource group' }
    }

    It 'plans DNS creation without querying a nonexistent network RG' {
        $zones = @(Get-PrivateDnsZonePlan -ZoneNames (Get-HubDnsZoneNames) -VirtualNetworkId $vnetId -DnsSubscription $sub -DnsResourceGroup 'hub-network' -DnsResourceGroupMissing)
        $zones.Count | Should -Be 4
        @($zones | Where-Object Action -eq 'Create').Count | Should -Be 4
        Should -Invoke Get-ArmList -Times 0
    }

    It 'retains existing central DNS zone reuse' {
        Mock Get-ArmList { @(@{ name = 'privatelink.blob.core.windows.net'; id = '/central/zone' }) }
        $zones = @(Get-PrivateDnsZonePlan -ZoneNames @('privatelink.blob.core.windows.net') -VirtualNetworkId $vnetId -DnsSubscription $sub -DnsResourceGroup 'central-dns')
        $zones[0].Action | Should -Be 'Link'
        $zones[0].Id | Should -Be '/central/zone'
    }
}

Describe 'Guided creation workflow' {
    It 'does not require an existing network or existing DNS RG to list' {
        $script:TenantId = 'tenant'
        $script:SubscriptionId = $sub
        $script:ResourceGroupName = 'hub'
        $script:Location = 'centralus'
        $script:CreateVirtualNetwork = $true
        $script:UsePublicNetworking = $false
        $script:SkipPrivateDnsZones = $false
        $script:PrivateDnsZoneResourceGroupName = ''
        $script:VirtualNetworkName = ''
        $script:VirtualNetworkResourceGroupName = ''
        $script:VirtualNetworkSubscriptionId = ''
        Mock Get-ArmList { @(@{ subscriptionId = $sub; displayName = 'Test'; state = 'Enabled'; tenantId = 'tenant' }) }
        Mock Invoke-ResourceGraph { throw 'No existing-network discovery expected' }
        Mock Invoke-Arm { throw 'No existing-network lookup expected' }
        Mock Read-Selection { throw 'No existing-network selection expected' }
        Mock Write-Info {}
        { Invoke-GuidedSetup -CurrentSubscriptionId $sub } | Should -Not -Throw
        Should -Invoke Invoke-ResourceGraph -Times 0
        Should -Invoke Invoke-Arm -Times 0
    }

    Describe 'Entry-point network pre-flight integration' {
        BeforeEach {
            $script:SubscriptionId = $sub
            $script:ResourceGroupName = 'hub'
            $script:VirtualNetworkSubscriptionId = $sub
            $script:VirtualNetworkResourceGroupName = 'hub-network'
            $script:VirtualNetworkName = 'vnet-hub'
            $script:PrivateEndpointSubnetName = 'snet-private-endpoints'
            $script:VirtualNetworkAddressPrefix = '10.30.0.0/24'
            $script:PrivateEndpointSubnetAddressPrefix = '10.30.0.0/28'
            $script:PrivateDnsZoneSubscriptionId = $sub
            $script:PrivateDnsZoneResourceGroupName = 'hub-network'
            $script:PrivateEndpointResourceGroupName = 'hub'
            $script:SkipPrivateDnsZones = $false
            $script:UsePublicNetworking = $false
            $script:CreateVirtualNetwork = $true
            $script:hubLocation = 'centralus'
            $script:templateValues = @{ virtualNetworkAddressPrefix = '10.20.30.0/26' }
            $script:capacityGroup = 'hub'
            Mock Invoke-Arm { $null }
            Mock Invoke-ResourceGraph { @() }
            Mock Get-ArmList { @() }
            Mock Test-ArmPermission { $true }
            Mock Set-NewVirtualNetwork { throw 'No provisioning during pre-flight' }
            Mock Write-Info {}
            Mock Write-Ok {}
            Mock Write-Warn {}
        }

        It 'checks creation permissions at an existing ancestor scope, not at planned resource IDs' {
            . $networkPreflight
            $networkPlan.Existing | Should -BeFalse
            $dnsGroupWillBeCreated | Should -BeTrue
            Should -Invoke Test-ArmPermission -Times 1 -Exactly -ParameterFilter {
                $Scope -eq "/subscriptions/$sub" -and $Action -eq 'Microsoft.Resources/subscriptions/resourceGroups/write'
            }
            Should -Invoke Test-ArmPermission -Times 1 -Exactly -ParameterFilter {
                $Scope -eq "/subscriptions/$sub" -and $Action -eq 'Microsoft.Network/virtualNetworks/write'
            }
            Should -Invoke Test-ArmPermission -Times 0 -ParameterFilter { $Scope -like "$vnetId*" }
            Should -Invoke Invoke-Arm -Times 0 -ParameterFilter { $Method -in 'PUT', 'PATCH', 'POST' }
            Should -Invoke Set-NewVirtualNetwork -Times 0
        }

        It 'stops before provisioning if permission to create the network RG is missing' {
            Mock Test-ArmPermission { $Action -ne 'Microsoft.Resources/subscriptions/resourceGroups/write' }
            { . $networkPreflight } | Should -Throw '*Missing permissions*resourceGroups/write*'
            Should -Invoke Set-NewVirtualNetwork -Times 0
            Should -Invoke Invoke-Arm -Times 0 -ParameterFilter { $Method -in 'PUT', 'PATCH', 'POST' }
        }

        It 'preserves the existing-network path without requiring network write permissions' {
            $script:CreateVirtualNetwork = $false
            Mock Invoke-Arm {
                if ($Path -eq "$vnetId`?api-version=2024-05-01") { return @{ Content = $fixture } }
                return @{ Content = @{ location = 'centralus' } }
            }
            . $networkPreflight
            $vnet.id | Should -Be $vnetId
            $networkPlan | Should -BeNullOrEmpty
            Should -Invoke Test-ArmPermission -Times 0 -ParameterFilter { $Action -eq 'Microsoft.Network/virtualNetworks/write' }
            Should -Invoke Set-NewVirtualNetwork -Times 0
        }

        It 'skips all private networking planning for public networking' {
            $script:UsePublicNetworking = $true
            $script:CreateVirtualNetwork = $false
            . $networkPreflight
            $vnet | Should -BeNullOrEmpty
            $networkPlan | Should -BeNullOrEmpty
            Should -Invoke Test-ArmPermission -Times 0 -ParameterFilter { $Action -like 'Microsoft.Network/*' }
            Should -Invoke Set-NewVirtualNetwork -Times 0
        }

        It 'honors managed-DNS opt-out when planning a new network' {
            $script:SkipPrivateDnsZones = $true
            Mock Get-PrivateDnsZonePlan { throw 'DNS planning must be skipped' }
            . $networkPreflight
            $networkPlan.Existing | Should -BeFalse
            $dnsPlan.Count | Should -Be 0
            Should -Invoke Get-PrivateDnsZonePlan -Times 0
            Should -Invoke Test-ArmPermission -Times 0 -ParameterFilter { $Action -like 'Microsoft.Network/privateDnsZones/*' }
        }

        It 'rejects the creation switch with public networking before Azure operations' {
            $script:CreateVirtualNetwork = $true
            $script:UsePublicNetworking = $true
            Mock Write-Banner {}
            $match = [regex]::Match($source, '(?s)    Write-Banner\s+.*?(?=    # --- 1\. Pre-flight)')
            $startup = [scriptblock]::Create($match.Value)
            { . $startup } | Should -Throw '*cannot be combined*'
            Should -Invoke Invoke-Arm -Times 0
        }
    }
}
