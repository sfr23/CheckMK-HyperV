# hv_cluster_health.ps1 - Checkmk local check: cluster-wide view of a Hyper-V failover cluster
# Modules: hv_cluster_health.ps1  (this script, all clusters)
#          hv_s2d_health.ps1      (S2D only, self-detecting)
#          hv_node_health.ps1     (node-specific)
# Deploy to EVERY cluster node: C:\ProgramData\checkmk\agent\local\
# Output is identical on all nodes -> assign to the cluster host in Checkmk
# via the "Clustered services" rule (regex: ^HV Cluster )
# Auto-detection: Failover Clustering not installed -> no output
# Output format: <state> "<service name>" <metrics> <text>  (ASCII only)

$ErrorActionPreference = 'Stop'
# Force dot as decimal separator (agent runs as SYSTEM, possibly with de-DE culture)
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Out-Check($state, $name, $perf, $text) {
    if (-not $perf) { $perf = '-' }
    $text = ("$text" -replace '[\r\n"]', ' ')
    Write-Output ('{0} "{1}" {2} {3}' -f $state, $name, $perf, $text)
}

# =====================================================================
# Prerequisites / auto-detection
# =====================================================================
if (-not (Get-Command Get-Cluster -ErrorAction SilentlyContinue)) { return }   # not a cluster node
try {
    $cluster = Get-Cluster
} catch {
    Out-Check 2 'HV Cluster Service' '-' "Cluster not reachable from $env:COMPUTERNAME: $($_.Exception.Message)"
    return
}
$isS2D = ($cluster.S2DEnabled -eq 1)   # Health Service only exists with S2D

# =====================================================================
# Cluster nodes
# =====================================================================
try {
    foreach ($node in Get-ClusterNode) {
        $state = switch ("$($node.State)") {
            'Up'      { 0 }
            'Paused'  { 1 }   # maintenance / drain
            'Joining' { 1 }
            'Down'    { 2 }
            default   { 3 }
        }
        Out-Check $state "HV Cluster Node $($node.Name)" '-' `
            "State: $($node.State), DrainStatus: $($node.DrainStatus)"
    }
} catch {
    Out-Check 3 'HV Cluster Node Status' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Cluster roles (VMs and other roles, excluding core groups)
#   Failed -> CRIT
#   Offline / PartialOnline / Pending -> info in text only (powered off = expected)
# =====================================================================
try {
    $groups = @(Get-ClusterGroup | Where-Object { -not $_.IsCoreGroup -and "$($_.GroupType)" -ne 'AvailableStorage' })
    $online = @($groups | Where-Object { "$($_.State)" -eq 'Online' })
    $failed = @($groups | Where-Object { "$($_.State)" -eq 'Failed' })
    $other  = @($groups | Where-Object { "$($_.State)" -notin @('Online','Failed') })

    $state = if ($failed.Count -gt 0) { 2 } else { 0 }

    $dist = ($groups | Group-Object { "$($_.OwnerNode)" } | Sort-Object Name |
             ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    $text = "$($groups.Count) roles, $($online.Count) online, $($failed.Count) failed, $($other.Count) other, distribution: $dist"
    if ($failed.Count -gt 0) {
        $text += ' - FAILED: ' + (($failed | ForEach-Object { "$($_.Name) on $($_.OwnerNode)" }) -join ', ')
    }
    if ($other.Count -gt 0) {
        $text += ' - Info: ' + (($other | ForEach-Object { "$($_.Name) ($($_.State))" }) -join ', ')
    }
    Out-Check $state 'HV Cluster Roles' "roles=$($groups.Count)|online=$($online.Count)|failed=$($failed.Count)|other=$($other.Count)" $text
} catch {
    Out-Check 3 'HV Cluster Roles' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Memory N+1: do all running VMs still fit if one node fails?
# Per failure scenario: (usage of remaining nodes + guest RAM of the failed node)
#                       / total RAM of remaining nodes
# The worst scenario is evaluated.
# Data source:
#   S2D:     Health Service (Get-ClusterPerf), no remote access required
#   no S2D:  WinRM/CIM + Get-VM against the other nodes. This node's computer account
#            needs local admin or Hyper-V Administrators rights there.
# =====================================================================
$nplusWarnPct = 90
$nplusCritPct = 95

function Get-NodeMemory($nodeName) {
    if ($isS2D) {
        $vals = @{}
        foreach ($p in @(Get-ClusterNode -Name $nodeName | Get-ClusterPerf 3>$null)) {
            $vals[("$($p.MetricId)" -split ',')[0]] = [double]$p.Value
        }
        if ($vals.ContainsKey('ClusterNode.Memory.Total') -and $vals.ContainsKey('ClusterNode.Memory.Usage')) {
            return [pscustomobject]@{
                Total = $vals['ClusterNode.Memory.Total']
                Usage = $vals['ClusterNode.Memory.Usage']
                Guest = if ($vals.ContainsKey('ClusterNode.Memory.Usage.Guest')) { $vals['ClusterNode.Memory.Usage.Guest'] } else { 0 }
            }
        }
    }
    # Fallback: CIM / Hyper-V directly (local without, otherwise with remote access)
    if ($nodeName -ieq $env:COMPUTERNAME) {
        $os  = Get-CimInstance Win32_OperatingSystem
        $vms = @(Get-VM)
    } else {
        $os  = Get-CimInstance Win32_OperatingSystem -ComputerName $nodeName
        $vms = @(Get-VM -ComputerName $nodeName)
    }
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $guest = [double](($vms | Where-Object { "$($_.State)" -eq 'Running' } | Measure-Object MemoryAssigned -Sum).Sum)
    return [pscustomobject]@{
        Total = $total
        Usage = $total - [double]$os.FreePhysicalMemory * 1KB
        Guest = $guest
    }
}

try {
    $mem    = @{}
    $errors = @()
    foreach ($n in (Get-ClusterNode | Where-Object { "$($_.State)" -eq 'Up' })) {
        try   { $mem["$($n.Name)"] = Get-NodeMemory "$($n.Name)" }
        catch { $errors += "$($n.Name): $($_.Exception.Message)" }
    }

    if ($errors.Count -gt 0) {
        Out-Check 3 'HV Cluster Memory N+1' '-' "Query failed - $($errors -join '; ')"
    } elseif ($mem.Count -lt 2) {
        Out-Check 1 'HV Cluster Memory N+1' '-' "Cannot calculate: only $($mem.Count) node(s) up (no N+1 redundancy)"
    } else {
        $worst = -1
        $scen  = @()
        foreach ($f in ($mem.Keys | Sort-Object)) {
            $surv = @($mem.Keys | Where-Object { $_ -ne $f })
            $tot  = ($surv | ForEach-Object { $mem[$_].Total } | Measure-Object -Sum).Sum
            $use  = ($surv | ForEach-Object { $mem[$_].Usage } | Measure-Object -Sum).Sum + $mem[$f].Guest
            $pct  = [math]::Round($use / $tot * 100, 1)
            $scen += "Failure of $f -> $pct% ($([math]::Round($use/1GB)) of $([math]::Round($tot/1GB)) GB, +$([math]::Round($mem[$f].Guest/1GB)) GB guests)"
            if ($pct -gt $worst) { $worst = $pct }
        }

        $state = 0
        if     ($worst -ge $nplusCritPct) { $state = 2 }
        elseif ($worst -ge $nplusWarnPct) { $state = 1 }

        $now = ($mem.Keys | Sort-Object | ForEach-Object {
            "$_ $([math]::Round($mem[$_].Usage / $mem[$_].Total * 100, 1))%"
        }) -join ', '
        $src = if ($isS2D) { 'Health Service' } else { 'CIM/Hyper-V' }

        Out-Check $state 'HV Cluster Memory N+1' "nplus1_pct=$worst;$nplusWarnPct;$nplusCritPct;0;100" `
            "Worst case after failover: $worst% - current: $now - $($scen -join '; ') (source: $src)"
    }
} catch {
    Out-Check 3 'HV Cluster Memory N+1' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Quorum / witness
#   Witness Online = OK, Pending = WARN, otherwise CRIT
#   No witness: CRIT with <= 2 nodes, otherwise WARN
# =====================================================================
try {
    $q     = Get-ClusterQuorum
    $res   = $q.QuorumResource
    $nodes = @(Get-ClusterNode)
    $votes = @($nodes | Where-Object { $_.DynamicWeight -eq 1 }).Count
    $wVote = $cluster.WitnessDynamicWeight

    if ($res) {
        $state = switch ("$($res.State)") {
            'Online'        { 0 }
            'OnlinePending' { 1 }
            default         { 2 }
        }
        $text = "Type: $($q.QuorumType), witness: $($res.Name) ($($res.ResourceType)) $($res.State), votes: $votes node(s) + witness $wVote"
    } else {
        $state = if ($nodes.Count -le 2) { 2 } else { 1 }
        $text  = "Type: $($q.QuorumType), NO witness configured, votes: $votes node(s)"
    }
    Out-Check $state 'HV Cluster Quorum' "node_votes=$votes|witness_vote=$wVote" $text
} catch {
    Out-Check 3 'HV Cluster Quorum' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# CSV: state and access mode per node (one service per CSV)
#   Direct                           -> OK (expected state with NTFS, e.g. SAN)
#   FileSystemRedirected due to ReFS -> OK (by design with ReFS, e.g. S2D)
#   other FileSystemRedirected       -> WARN (e.g. incompatible filter driver, backup)
#   BlockRedirected                  -> WARN (node has no direct path to the disk)
#   CSV not Online / Unavailable     -> CRIT
# =====================================================================
try {
    $csvList   = @(Get-ClusterSharedVolume)
    $csvStates = @(Get-ClusterSharedVolumeState)
    foreach ($csv in $csvList) {
        $short  = "$($csv.Name)" -replace '^Cluster Virtual Disk \((.*)\)$', '$1'
        $rows   = @($csvStates | Where-Object { "$($_.Name)" -eq "$($csv.Name)" })
        $state  = 0
        $issues = @()

        if ("$($csv.State)" -ne 'Online') { $state = 2; $issues += "CSV $($csv.State)" }

        foreach ($r in $rows) {
            switch ("$($r.StateInfo)") {
                'Direct' { }
                'FileSystemRedirected' {
                    if ("$($r.FileSystemRedirectedIOReason)" -notmatch 'ReFs') {
                        $state = [math]::Max($state, 1)
                        $issues += "$($r.Node): FS-Redirected ($($r.FileSystemRedirectedIOReason))"
                    }
                }
                'BlockRedirected' {
                    $state = [math]::Max($state, 1)
                    $issues += "$($r.Node): Block-Redirected ($($r.BlockRedirectedIOReason))"
                }
                default {
                    $state = 2
                    $issues += "$($r.Node): $($r.StateInfo)"
                }
            }
        }

        $modes = ($rows | Sort-Object Node | ForEach-Object { "$($_.Node)=$($_.StateInfo)" }) -join ', '
        $text  = "State: $($csv.State), owner: $($csv.OwnerNode), mode: $modes"
        if ($issues.Count -gt 0) { $text += ' - ' + ($issues -join ', ') }
        Out-Check $state "HV Cluster CSV $short" '-' $text
    }
} catch {
    Out-Check 3 'HV Cluster CSV' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# CSV usage (one service per CSV)
# With S2D in addition to the pool reserve, with SAN the only capacity view
# =====================================================================
$csvWarnPct = 85
$csvCritPct = 95
try {
    foreach ($csv in Get-ClusterSharedVolume) {
        $short = "$($csv.Name)" -replace '^Cluster Virtual Disk \((.*)\)$', '$1'
        $part  = $csv.SharedVolumeInfo | Select-Object -First 1 -ExpandProperty Partition
        if (-not $part -or -not $part.Size) {
            Out-Check 3 "HV Cluster CSV Space $short" '-' 'No partition data (CSV offline?)'
            continue
        }
        $usedPct = [math]::Round(($part.Size - $part.FreeSpace) / $part.Size * 100, 1)
        $freeTB  = [math]::Round($part.FreeSpace / 1TB, 2)
        $sizeTB  = [math]::Round($part.Size / 1TB, 2)

        $state = 0
        if     ($usedPct -ge $csvCritPct) { $state = 2 }
        elseif ($usedPct -ge $csvWarnPct) { $state = 1 }

        Out-Check $state "HV Cluster CSV Space $short" "used_pct=$usedPct;$csvWarnPct;$csvCritPct;0;100|free_tb=$freeTB;;;0;$sizeTB" `
            "$usedPct% used, $freeTB TB free of $sizeTB TB ($($part.FileSystem))"
    }
} catch {
    Out-Check 3 'HV Cluster CSV Space' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Cluster disks that are not CSVs (e.g. disk witness, disks in "Available Storage")
#   Online -> OK, otherwise CRIT
# =====================================================================
try {
    $csvNames = @(Get-ClusterSharedVolume | ForEach-Object { "$($_.Name)" })
    foreach ($disk in (Get-ClusterResource | Where-Object {
                "$($_.ResourceType)" -eq 'Physical Disk' -and $csvNames -notcontains "$($_.Name)" })) {
        $state = if ("$($disk.State)" -eq 'Online') { 0 } else { 2 }
        Out-Check $state "HV Cluster Disk $($disk.Name)" '-' `
            "State: $($disk.State), group: $($disk.OwnerGroup), owner: $($disk.OwnerNode)"
    }
} catch {
    Out-Check 3 'HV Cluster Disk' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Network ATC - one service per intent, evaluated across all hosts
# Only if Network ATC is available and intents are defined
# OK only if ConfigurationStatus = Success AND ProvisioningStatus = Completed
# =====================================================================
if (Get-Command Get-NetIntentStatus -ErrorAction SilentlyContinue) {
    try {
        $status = @(Get-NetIntentStatus 3>$null)
        foreach ($grp in ($status | Group-Object IntentName)) {
            $bad = @($grp.Group | Where-Object {
                "$($_.ConfigurationStatus)" -ne 'Success' -or "$($_.ProvisioningStatus)" -ne 'Completed'
            })
            $state = 0
            if ($bad.Count -gt 0) {
                $state = 1   # e.g. Provisioning/Validating/Retrying
                if ($bad | Where-Object { "$($_.ConfigurationStatus)$($_.ProvisioningStatus)" -match 'Fail' }) { $state = 2 }
            }
            $detail = ($bad | ForEach-Object { "$($_.Host): $($_.ConfigurationStatus)/$($_.ProvisioningStatus)" }) -join ', '
            if (-not $detail) { $detail = 'all hosts Success/Completed' }
            Out-Check $state "HV Cluster NetATC $($grp.Name)" "hosts=$($grp.Count)|bad=$($bad.Count)" `
                "$($grp.Count) hosts, $($bad.Count) deviating - $detail"
        }
    } catch {
        Out-Check 3 'HV Cluster NetATC' '-' "Query failed: $($_.Exception.Message)"
    }
}
