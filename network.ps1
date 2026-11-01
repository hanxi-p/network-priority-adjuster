$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Get-NetworkState {
    $adapters = @(Get-NetAdapter | Where-Object { $_.ifIndex -gt 1 })
    $interfaces = @(Get-NetIPInterface -ErrorAction Stop)
    $addresses = @(Get-NetIPAddress -ErrorAction Stop)
    $routes = @(Get-NetRoute -ErrorAction Stop | Where-Object {
        $_.DestinationPrefix -eq '0.0.0.0/0' -or $_.DestinationPrefix -eq '::/0'
    })
    $items = @(
        foreach ($adapter in $adapters) {
            $idx = [int]$adapter.ifIndex
            $families = @(
                foreach ($family in @('IPv4', 'IPv6')) {
                    $iface = $interfaces | Where-Object { $_.InterfaceIndex -eq $idx -and [string]$_.AddressFamily -eq $family } | Select-Object -First 1
                    if ($null -eq $iface) { continue }
                    $familyRoutes = @($routes | Where-Object { $_.InterfaceIndex -eq $idx -and [string]$_.AddressFamily -eq $family })
                    $routeMetric = $null
                    if ($familyRoutes.Count -gt 0) { $routeMetric = [long]($familyRoutes | Measure-Object RouteMetric -Minimum).Minimum }
                    [pscustomobject]@{
                        family = $family
                        metric = [int]$iface.InterfaceMetric
                        automatic = ([string]$iface.AutomaticMetric -eq 'Enabled')
                        routeMetric = $routeMetric
                        effectiveMetric = $(if ($null -ne $routeMetric) { [long]$iface.InterfaceMetric + $routeMetric } else { $null })
                        gateway = @($familyRoutes | Select-Object -ExpandProperty NextHop -Unique)
                    }
                }
            )
            $ipv4 = $families | Where-Object family -eq 'IPv4' | Select-Object -First 1
            $rankMetric = if ($null -ne $ipv4 -and $null -ne $ipv4.effectiveMetric) { $ipv4.effectiveMetric } elseif ($families.Count -gt 0) { ($families | Measure-Object metric -Minimum).Minimum } else { 99999 }
            $kind = if ($adapter.Virtual -or -not $adapter.HardwareInterface) { 'virtual' } elseif ([string]$adapter.MediaType -eq 'Native 802.11') { 'wifi' } else { 'wired' }
            [pscustomobject]@{
                id = $idx
                guid = [string]$adapter.InterfaceGuid
                name = [string]$adapter.Name
                description = [string]$adapter.InterfaceDescription
                kind = $kind
                connected = ([string]$adapter.Status -eq 'Up')
                status = [string]$adapter.Status
                speed = [string]$adapter.LinkSpeed
                addresses = @($addresses | Where-Object { $_.InterfaceIndex -eq $idx -and [string]$_.AddressFamily -eq 'IPv4' } | Select-Object -ExpandProperty IPAddress)
                families = $families
                rankMetric = [long]$rankMetric
            }
        }
    )
    $items = @($items | Sort-Object rankMetric,id)
    $preferred = $items | Where-Object { $_.connected -and @($_.families | Where-Object { $_.family -eq 'IPv4' -and $null -ne $_.effectiveMetric }).Count -gt 0 } | Sort-Object rankMetric | Select-Object -First 1
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    [pscustomobject]@{
        adapters = $items
        admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        computer = $env:COMPUTERNAME
        preferredId = $(if ($null -ne $preferred) { $preferred.id } else { $null })
        readAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}

function Get-PriorityPlan($state, $order) {
    if ($null -eq $order -or @($order).Count -eq 0) { throw '没有提交接口顺序，请刷新后重试。' }
    $order = @($order)
    if ($order.Count -gt 64) { throw '接口数量超出支持范围。' }
    $ids = @($order | ForEach-Object { [int]$_.id })
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw '接口列表含有重复项目。' }
    if ($ids.Count -ne @($state.adapters).Count) { throw '网卡列表发生了变化，请刷新后重新排序。' }
    foreach ($entry in $order) {
        $adapter = $state.adapters | Where-Object id -eq ([int]$entry.id) | Select-Object -First 1
        if ($null -eq $adapter -or $adapter.guid -ne [string]$entry.guid) { throw '网卡已变化或重新连接，请刷新后重试。' }
    }

    # Account for default-route costs without changing routes or gateway settings.
    $plan = @(
        foreach ($family in @('IPv4', 'IPv6')) {
            $maxCost = 0L
            foreach ($adapter in $state.adapters) {
                $f = $adapter.families | Where-Object family -eq $family | Select-Object -First 1
                if ($null -ne $f -and $null -ne $f.routeMetric -and $f.routeMetric -gt $maxCost) { $maxCost = [long]$f.routeMetric }
            }
            for ($rank = 0; $rank -lt $order.Count; $rank++) {
                $adapter = $state.adapters | Where-Object id -eq ([int]$order[$rank].id) | Select-Object -First 1
                $f = $adapter.families | Where-Object family -eq $family | Select-Object -First 1
                if ($null -eq $f) { continue }
                $ownCost = if ($null -ne $f.routeMetric) { [long]$f.routeMetric } else { 0L }
                $metric = 100L + $rank * 100L + $maxCost - $ownCost
                if ($metric -gt 9999 -or $metric -lt 1) { throw '现有默认路由的跃点值差异过大，无法仅通过接口优先级安全排序。' }
                [pscustomobject]@{ id=$adapter.id; guid=$adapter.guid; family=$family; metric=[int]$metric }
            }
        }
    )
    return $plan
}

function Set-PriorityConfiguration($state, $plan, [bool]$automatic) {
    if (-not $state.admin) { throw '修改优先级需要管理员权限。请退出预览模式，双击 EXE 并允许管理员权限。' }
    # Verify every interface before making any change, then roll back on failure.
    $changed = New-Object System.Collections.ArrayList
    try {
        foreach ($entry in $plan) {
            $currentAdapter = Get-NetAdapter -ErrorAction Stop | Where-Object ifIndex -eq $entry.id | Select-Object -First 1
            if ($null -eq $currentAdapter -or [string]$currentAdapter.InterfaceGuid -ne $entry.guid) { throw '接口在保存过程中发生变化，请刷新后重试。' }
            $original = $state.adapters | Where-Object id -eq $entry.id | Select-Object -First 1
            $originalFamily = $original.families | Where-Object family -eq $entry.family | Select-Object -First 1
            [void]$changed.Add([pscustomobject]@{ id=$entry.id; guid=$entry.guid; family=$entry.family; automatic=$originalFamily.automatic; metric=$originalFamily.metric })
            if ($automatic) {
                Set-NetIPInterface -InterfaceIndex $entry.id -AddressFamily $entry.family -AutomaticMetric Enabled -ErrorAction Stop | Out-Null
            } else {
                Set-NetIPInterface -InterfaceIndex $entry.id -AddressFamily $entry.family -AutomaticMetric Disabled -InterfaceMetric $entry.metric -ErrorAction Stop | Out-Null
            }
        }
    } catch {
        $failure = $_.Exception.Message
        $rollbackErrors = @()
        for ($i=$changed.Count-1; $i -ge 0; $i--) {
            $old = $changed[$i]
            try {
                $rollbackAdapter = Get-NetAdapter -ErrorAction Stop | Where-Object ifIndex -eq $old.id | Select-Object -First 1
                if ($null -eq $rollbackAdapter -or [string]$rollbackAdapter.InterfaceGuid -ne $old.guid) { throw '接口标识已变化' }
                if ($old.automatic) { Set-NetIPInterface -InterfaceIndex $old.id -AddressFamily $old.family -AutomaticMetric Enabled -ErrorAction Stop | Out-Null }
                else { Set-NetIPInterface -InterfaceIndex $old.id -AddressFamily $old.family -AutomaticMetric Disabled -InterfaceMetric $old.metric -ErrorAction Stop | Out-Null }
            } catch { $rollbackErrors += "$($old.id)/$($old.family): $($_.Exception.Message)" }
        }
        if ($rollbackErrors.Count -gt 0) { throw "保存失败：$failure。部分接口恢复失败，请重新读取并检查：$($rollbackErrors -join '; ')" }
        throw "保存失败，已恢复修改前设置：$failure"
    }
}

try {
    $raw = [Console]::In.ReadToEnd()
    $request = $raw | ConvertFrom-Json
    $state = Get-NetworkState
    switch ([string]$request.action) {
        'state' { $result = @{ ok=$true; state=$state } }
        'plan' { $result = @{ ok=$true; plan=@(Get-PriorityPlan $state $request.order) } }
        'save' {
            $plan = @(Get-PriorityPlan $state $request.order)
            Set-PriorityConfiguration $state $plan $false
            $result = @{ ok=$true; message='优先级已保存，IPv4 和 IPv6 均已应用。'; state=(Get-NetworkState) }
        }
        'defaults' {
            $plan = @($state.adapters | ForEach-Object { $a=$_; $a.families | ForEach-Object { [pscustomobject]@{ id=$a.id; guid=$a.guid; family=$_.family } } })
            Set-PriorityConfiguration $state $plan $true
            $result = @{ ok=$true; message='已恢复 Windows 自动优先级。'; state=(Get-NetworkState) }
        }
        default { throw '不支持的操作。' }
    }
    $result | ConvertTo-Json -Depth 10 -Compress
} catch {
    @{ ok=$false; error=$_.Exception.Message } | ConvertTo-Json -Depth 4 -Compress
    exit 1
}
