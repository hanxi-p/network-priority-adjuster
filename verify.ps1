$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'network.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($functionName in @('Get-PriorityPlan','Set-PriorityConfiguration')) {
    $definition = $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -eq $functionName
    . ([scriptblock]::Create($definition.Extent.Text))
}
$state = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tests\fixtures.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json).state
$order = @($state.adapters | Sort-Object id -Descending | ForEach-Object { [pscustomobject]@{id=$_.id;guid=$_.guid} })
$plan = @(Get-PriorityPlan $state $order)
if ($plan.Count -ne ($state.adapters.families.Count)) { throw 'Missing address families' }
foreach ($family in @('IPv4','IPv6')) {
    $previous = -1L
    foreach ($item in $plan | Where-Object family -eq $family) {
        $original = $state.adapters | Where-Object id -eq $item.id
        $route = ($original.families | Where-Object family -eq $family).routeMetric
        $total = $item.metric + [long]$route
        if ($total -le $previous) { throw 'Priority order does not match effective route costs' }
        $previous = $total
    }
}
function Assert-Rejected($label,$badOrder) {
    $failed=$false
    try { Get-PriorityPlan $state $badOrder | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw "Unexpected acceptance: $label" }
    Write-Output "PASS: $label"
}
$duplicate = @($order);$duplicate[1]=$duplicate[0]
Assert-Rejected 'duplicate interface' $duplicate
Assert-Rejected 'missing interface' @($order | Select-Object -Skip 1)
$stale = @($order | ForEach-Object { [pscustomobject]@{id=$_.id;guid=$_.guid} });$stale[0].guid='stale'
Assert-Rejected 'stale interface identity' $stale
Write-Output 'PASS: IPv4/IPv6 effective route ordering'

# Only these test doubles handle writes. No real Windows setting is changed.
$script:fakeAdapters = @($state.adapters | ForEach-Object { [pscustomobject]@{ifIndex=$_.id;InterfaceGuid=$_.guid} })
$script:fakeSettings = @{}
foreach ($a in $state.adapters) { foreach ($f in $a.families) { $script:fakeSettings["$($a.id)/$($f.family)"] = @{automatic=$f.automatic;metric=$f.metric;originalMetric=$f.metric} } }
$before = $script:fakeSettings | ConvertTo-Json -Depth 5 -Compress
function Get-NetAdapter { [CmdletBinding()]param() $script:fakeAdapters }
function Set-NetIPInterface {
    [CmdletBinding()]param([int]$InterfaceIndex,[string]$AddressFamily,[string]$AutomaticMetric,[int]$InterfaceMetric)
    $key="$InterfaceIndex/$AddressFamily"
    $setting=$script:fakeSettings[$key]
    $setting.automatic=($AutomaticMetric -eq 'Enabled')
    $setting.metric=if($setting.automatic){$setting.originalMetric}else{$InterfaceMetric}
    if ($key -eq $script:failureKey -and -not $script:failedOnce) { $script:failedOnce=$true;throw 'Simulated write failure after partial change' }
}
$state.admin=$true
$script:failureKey="$($plan[2].id)/$($plan[2].family)";$script:failedOnce=$false
$threw=$false
try { Set-PriorityConfiguration $state $plan $false } catch { $threw=$true }
if (-not $threw -or -not $script:failedOnce) { throw 'Failure injection was not exercised' }
$after = $script:fakeSettings | ConvertTo-Json -Depth 5 -Compress
if ($before -ne $after) { throw 'Rollback did not restore original automatic/manual states and metrics' }
Write-Output 'PASS: partial failure rolls back all changed families'
$script:failureKey='none'
Set-PriorityConfiguration $state $plan $false
foreach ($item in $plan) { $setting=$script:fakeSettings["$($item.id)/$($item.family)"];if($setting.automatic -or $setting.metric -ne $item.metric){throw 'Manual save mismatch'} }
Write-Output 'PASS: save applies the complete ordered plan'
Set-PriorityConfiguration $state $plan $true
foreach ($setting in $script:fakeSettings.Values) { if(-not $setting.automatic){throw 'Automatic restore mismatch'} }
Write-Output 'PASS: restore enables automatic priorities for both families'
