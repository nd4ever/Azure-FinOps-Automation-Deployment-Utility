#requires -Version 7.2
<#
.SYNOPSIS
    Refreshes current subscription tags and resource inventory used by the Fabric tag cost view.
.DESCRIPTION
    Reads enabled subscriptions in the signed-in Azure CLI tenant and their subscription-level tags.
    Reads all pages of Azure Resource Manager resources, including resources without cost records.
    Replaces the Hub database snapshots only after every selected subscription has been read successfully.
    Does not modify Azure tags or create exports. Requires the subscription-tags KQL setup first.
.PARAMETER QueryUri
    The Fabric eventhouse query URI from the deployment summary.
.PARAMETER Database
    Hub database name (not the Fabric database item GUID).
.PARAMETER SubscriptionIds
    Optional subscription GUIDs. By default includes every visible enabled subscription in the current tenant.
.EXAMPLE
    ./Update-SubscriptionTagInventory.ps1 -QueryUri 'https://example.z0.kusto.fabric.microsoft.com'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://[a-z0-9.-]+\.kusto\.fabric\.microsoft\.com/?$')]
    [string] $QueryUri,
    [ValidateNotNullOrEmpty()][string] $Database = 'Hub',
    [guid[]] $SubscriptionIds = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SubscriptionTagAzLauncher {
    $command = Get-Command az -ErrorAction Stop
    if ([IO.Path]::GetExtension($command.Source) -ieq '.cmd') {
        $python = [IO.Path]::GetFullPath((Join-Path (Split-Path $command.Source -Parent) '..\python.exe'))
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
            throw 'The Azure CLI Windows launcher has no bundled Python executable. Repair the Azure CLI installation.'
        }
        # az.cmd uses this entry point; bypass cmd.exe to preserve pagination URLs containing & and %.
        return [pscustomobject]@{ FilePath = $python; Prefix = @('-IBm', 'azure.cli') }
    }
    return [pscustomobject]@{ FilePath = $command.Source; Prefix = @() }
}

function Invoke-SubscriptionTagAz {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $launcher = Get-SubscriptionTagAzLauncher
    $prefix = @($launcher.Prefix)
    $output = & $launcher.FilePath @prefix @Arguments --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments[0]) $($Arguments[1]) failed: $($output -join "`n")"
    }
    return (($output -join "`n") | ConvertFrom-Json -AsHashtable)
}

function Get-SubscriptionTagSnapshot {
    param([Parameter(Mandatory)][string] $TenantId, [guid[]] $Ids = @())
    $available = @(Invoke-SubscriptionTagAz -Arguments @('account', 'list', '--all') |
        Where-Object { $_.state -eq 'Enabled' -and $_.tenantId -eq $TenantId })
    $requested = @($Ids | ForEach-Object { $_.ToString() } | Sort-Object -Unique)
    if ($requested.Count -gt 0) {
        $availableIds = @($available | ForEach-Object { $_.id })
        $missing = @($requested | Where-Object { $_ -notin $availableIds })
        if ($missing.Count -gt 0) {
            throw "Subscription(s) are not visible and enabled in tenant ${TenantId}: $($missing -join ', '). The previous snapshot was not changed."
        }
        $available = @($available | Where-Object { $_.id -in $requested })
    }
    if ($available.Count -eq 0) {
        throw 'No enabled subscriptions were found in the current tenant. The previous snapshot was not changed.'
    }
    $timestamp = [DateTime]::UtcNow.ToString('o')
    foreach ($subscription in @($available | Sort-Object id -Unique)) {
        $id = [guid]::Parse($subscription.id).ToString()
        $url = "https://management.azure.com/subscriptions/$id/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
        try {
            $response = Invoke-SubscriptionTagAz -Arguments @('rest', '--method', 'get', '--url', $url, '--subscription', $id)
        }
        catch {
            throw "Could not read subscription tags for $($subscription.name) ($id). Check Microsoft.Resources/tags/read permission. The previous snapshot was not changed. $($_.Exception.Message)"
        }
        if (-not $response.ContainsKey('properties') -or $response.properties -isnot [System.Collections.IDictionary]) {
            throw "The tags API returned no properties for subscription $id. The previous snapshot was not changed."
        }
        $tags = $response.properties['tags']
        if ($null -eq $tags) { $tags = @{} }
        if ($tags -isnot [System.Collections.IDictionary]) {
            throw "The tags API returned invalid tags for subscription $id. The previous snapshot was not changed."
        }
        [pscustomobject]@{
            SubscriptionId = $id
            SubscriptionName = [string]$subscription.name
            Tags = $tags
            SnapshotAt = $timestamp
        }
    }
}

function ConvertTo-SubscriptionTagCommand {
    param([Parameter(Mandatory)][object[]] $Rows)
    if ($Rows.Count -eq 0) { throw 'An empty snapshot cannot replace the subscription inventory.' }
    $values = foreach ($row in $Rows) {
        $id = [guid]::Parse($row.SubscriptionId).ToString() | ConvertTo-Json -Compress
        $name = [string]$row.SubscriptionName | ConvertTo-Json -Compress
        $tags = ConvertTo-Json -InputObject $row.Tags -Compress -Depth 20
        $time = [DateTime]::Parse($row.SnapshotAt).ToUniversalTime().ToString('o')
        "$id, $name, dynamic($tags), datetime($time)"
    }
    return @"
.set-or-replace SubscriptionTagInventory <|
datatable(SubscriptionId:string, SubscriptionName:string, Tags:dynamic, SnapshotAt:datetime)
[
$($values -join ",`n")
]
"@
}

function Get-ResourceTagSnapshot {
    param([Parameter(Mandatory)][object[]] $Subscriptions)
    foreach ($subscription in $Subscriptions) {
        $id = [guid]::Parse($subscription.SubscriptionId).ToString()
        $url = "https://management.azure.com/subscriptions/$id/resources?api-version=2021-04-01"
        $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $resources = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        do {
            $uri = [uri]$url
            if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or
                $uri.AbsolutePath -ine "/subscriptions/$id/resources" -or -not $visited.Add($url)) {
                throw "Invalid or repeated resource inventory page for subscription $id. The previous snapshots were not changed."
            }
            try {
                $response = Invoke-SubscriptionTagAz -Arguments @('rest', '--method', 'get', '--url', $url, '--subscription', $id)
            }
            catch {
                throw "Could not read resource inventory for $($subscription.SubscriptionName) ($id). Check subscription-wide Reader access. The previous snapshots were not changed. $($_.Exception.Message)"
            }
            if ($response -isnot [System.Collections.IDictionary] -or -not $response.Contains('value') -or
                $response['value'] -isnot [System.Collections.IList]) {
                throw "Invalid resource list for subscription $id. The previous snapshots were not changed."
            }
            foreach ($resource in $response['value']) {
                if ($resource -isnot [System.Collections.IDictionary] -or
                    [string]$resource['id'] -in @('', $null) -or
                    -not ([string]$resource['id']).StartsWith("/subscriptions/$id/", [StringComparison]::OrdinalIgnoreCase) -or
                    [string]::IsNullOrWhiteSpace([string]$resource['name']) -or
                    [string]::IsNullOrWhiteSpace([string]$resource['type'])) {
                    throw "Invalid resource record for subscription $id. The previous snapshots were not changed."
                }
                $tags = $resource['tags']
                if ($null -eq $tags) { $tags = @{} }
                if ($tags -isnot [System.Collections.IDictionary]) {
                    throw "Invalid resource tags for $($resource['id']). The previous snapshots were not changed."
                }
                $resourceId = ([string]$resource['id']).ToLowerInvariant()
                $group = ''
                if ($resourceId -match '^/subscriptions/[^/]+/resourcegroups/([^/]+)/') { $group = $Matches[1] }
                $resources[$resourceId] = [pscustomobject]@{
                    SubscriptionId = $id
                    SubscriptionName = $subscription.SubscriptionName
                    ResourceId = $resourceId
                    ResourceName = [string]$resource['name']
                    ResourceGroup = $group
                    ResourceType = [string]$resource['type']
                    Location = [string]$resource['location']
                    Tags = $tags
                    SnapshotAt = $subscription.SnapshotAt
                }
            }
            $url = [string]$response['nextLink']
        } while (-not [string]::IsNullOrWhiteSpace($url))
        # A summary row records successful collection even for an empty subscription.
        [pscustomobject]@{
            SubscriptionId = $id; SubscriptionName = $subscription.SubscriptionName
            ResourceId = ''; ResourceName = ''; ResourceGroup = ''; ResourceType = ''; Location = ''
            Tags = @{}; SnapshotAt = $subscription.SnapshotAt
        }
        foreach ($resource in @($resources.Values | Sort-Object ResourceId)) { $resource }
    }
}

function ConvertTo-ResourceTagCommand {
    param([Parameter(Mandatory)][object[]] $Rows)
    if ($Rows.Count -eq 0) { throw 'An empty collection cannot replace the resource inventory.' }
    $values = foreach ($row in $Rows) {
        $strings = foreach ($name in 'SubscriptionId', 'SubscriptionName', 'ResourceId', 'ResourceName', 'ResourceGroup', 'ResourceType', 'Location') {
            [string]$row.$name | ConvertTo-Json -Compress
        }
        $tags = ConvertTo-Json -InputObject $row.Tags -Compress -Depth 20
        $time = ([DateTime]$row.SnapshotAt).ToUniversalTime().ToString('o')
        "$($strings -join ', '), dynamic($tags), datetime($time)"
    }
    return @"
.set-or-replace ResourceTagInventory <|
datatable(SubscriptionId:string, SubscriptionName:string, ResourceId:string, ResourceName:string,
    ResourceGroup:string, ResourceType:string, Location:string, Tags:dynamic, SnapshotAt:datetime)
[
$($values -join ",`n")
]
"@
}

function Invoke-SubscriptionTagKusto {
    param([Parameter(Mandatory)][string] $Command, [Parameter(Mandatory)][string] $Token, [switch] $Query)
    $endpoint = if ($Query) { 'query' } else { 'mgmt' }
    $body = @{ db = $Database; csl = $Command } | ConvertTo-Json -Compress
    $response = Invoke-RestMethod -Method Post -Uri "$($QueryUri.TrimEnd('/'))/v1/rest/$endpoint" `
        -Headers @{ Authorization = "Bearer $Token" } -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 300
    if ($response.PSObject.Properties['error']) {
        throw "Kusto rejected the subscription inventory request: $($response.error | ConvertTo-Json -Compress -Depth 10)"
    }
    foreach ($table in $response.Tables) {
        if ($table.TableName -ne 'QueryStatus') { continue }
        $names = @($table.Columns | ForEach-Object ColumnName)
        $severity = [array]::IndexOf($names, 'Severity')
        if ($severity -ge 0 -and @($table.Rows | Where-Object { [int]$_[$severity] -le 2 }).Count -gt 0) {
            throw "Kusto reported a query failure: $($table.Rows | ConvertTo-Json -Compress -Depth 10)"
        }
    }
    return $response
}

function Assert-SubscriptionTagSnapshot {
    param([Parameter(Mandatory)][object] $Response, [Parameter(Mandatory)][object[]] $Rows,
        [string] $Inventory = 'Subscription tag')
    if ($Response.Tables.Count -eq 0 -or $Response.Tables[0].Rows.Count -ne 1) {
        throw 'The snapshot write completed, but the verification query returned no inventory summary.'
    }
    $actual = $Response.Tables[0].Rows[0]
    $actualTime = ([DateTime]$actual[1]).ToUniversalTime()
    $expectedTime = ([DateTime]$Rows[0].SnapshotAt).ToUniversalTime()
    if ([long]$actual[0] -ne $Rows.Count -or $actualTime -ne $expectedTime) {
        throw "The $Inventory snapshot did not match the expected count and timestamp. Another refresh may have run concurrently."
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required. Sign in with az login first.' }
$cloud = Invoke-SubscriptionTagAz -Arguments @('cloud', 'show')
if ($cloud.name -ne 'AzureCloud') { throw 'Subscription tag inventory supports Azure public cloud only.' }
$account = Invoke-SubscriptionTagAz -Arguments @('account', 'show')
$rows = @(Get-SubscriptionTagSnapshot -TenantId $account.tenantId -Ids $SubscriptionIds)
$resourceRows = @(Get-ResourceTagSnapshot -Subscriptions $rows)
$command = ConvertTo-SubscriptionTagCommand -Rows $rows
$resourceCommand = ConvertTo-ResourceTagCommand -Rows $resourceRows
$auth = Invoke-SubscriptionTagAz -Arguments @('account', 'get-access-token', '--resource', 'https://kusto.kusto.windows.net', '--tenant', $account.tenantId)
if ([string]::IsNullOrWhiteSpace($auth.accessToken)) { throw 'Azure CLI did not return a Kusto access token.' }
try {
    $null = Invoke-SubscriptionTagKusto -Command $command -Token $auth.accessToken
    $null = Invoke-SubscriptionTagKusto -Command $resourceCommand -Token $auth.accessToken
}
catch {
    throw "Inventory snapshot update failed; its outcome may be unknown or partially complete. Check SubscriptionTagInventory and ResourceTagInventory before retrying. $($_.Exception.Message)"
}
$verification = Invoke-SubscriptionTagKusto -Command 'SubscriptionTagInventory | summarize Subscriptions = count(), SnapshotAt = min(SnapshotAt)' -Token $auth.accessToken -Query
Assert-SubscriptionTagSnapshot -Response $verification -Rows $rows
$resourceVerification = Invoke-SubscriptionTagKusto -Command 'ResourceTagInventory | summarize Rows = count(), SnapshotAt = min(SnapshotAt)' -Token $auth.accessToken -Query
Assert-SubscriptionTagSnapshot -Response $resourceVerification -Rows $resourceRows -Inventory 'Resource inventory'
[pscustomobject]@{
    Subscriptions = $rows.Count
    Resources = @($resourceRows | Where-Object { $_.ResourceId }).Count
    SnapshotAt = $rows[0].SnapshotAt
    Database = $Database
}
