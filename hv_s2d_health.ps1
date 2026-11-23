# hv_s2d_health.ps1 - Checkmk local check: Storage Spaces Direct of a Hyper-V cluster
# Modules: hv_cluster_health.ps1  (all clusters)
#          hv_s2d_health.ps1      (this script, S2D only)
#          hv_node_health.ps1     (node-specific)
# Deploy to EVERY cluster node: C:\ProgramData\checkmk\agent\local\
# Output is identical on all nodes -> assign to the cluster host via the
# "Clustered services" rule (regex: ^HV Cluster )
# Auto-detection: no cluster or S2D not enabled -> no output
# Requirement: Windows Server 2019+ (Get-HealthFault, Get-ClusterPerf)
# Output format: <state> "<service name>" <metrics> <text>  (ASCII only)

$ErrorActionPreference = 'Stop'
# Force dot as decimal separator (agent runs as SYSTEM, possibly with de-DE culture)
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-State($health) {
    switch ("$health") {
        'Healthy'   { 0 }
        'Warning'   { 1 }
        'Unhealthy' { 2 }
        default     { 3 }
    }
}

function Out-Check($state, $name, $perf, $text) {
    if (-not $perf) { $perf = '-' }
    $text = ("$text" -replace '[\r\n"]', ' ')
    Write-Output ('{0} "{1}" {2} {3}' -f $state, $name, $perf, $text)
}

# =====================================================================
# Auto-detection: run on S2D clusters only
# (an unreachable cluster is already reported by hv_cluster_health.ps1)
# =====================================================================
if (-not (Get-Command Get-Cluster -ErrorAction SilentlyContinue)) { return }
try { $cluster = Get-Cluster } catch { return }
if ($cluster.S2DEnabled -ne 1) { return }

# =====================================================================
# Health Service Faults
# =====================================================================
try {
    # Warning comes from module scope, -WarningAction has no effect there -> redirect streams
    # 3 = Warning, 6 = Information/Write-Host
    $faults = @(Get-HealthFault 3>$null 6>$null)
    $state = 0
    if ($faults.Count -gt 0) {
        $state = 1
        if ($faults | Where-Object { "$($_.PerceivedSeverity)" -match 'Major|Critical|Fatal' }) { $state = 2 }
    }
    $detail = ($faults | Select-Object -First 3 | ForEach-Object { "$($_.PerceivedSeverity): $($_.Reason)" }) -join ' | '
    if (-not $detail) { $detail = 'no faults' }
    Out-Check $state 'HV Cluster S2D Health Faults' "faults=$($faults.Count)" "$($faults.Count) Faults - $detail"
} catch {
    Out-Check 3 'HV Cluster S2D Health Faults' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Storage pool: health and free capacity vs. reserve
# Reserve per Microsoft recommendation: largest capacity disk x number of nodes (max. 4)
#   CRIT: free < reserve           -> repair after disk failure no longer guaranteed
#   WARN: free < reserve x factor  -> early warning
# =====================================================================
# 1.0 = no early warning: OK as long as free >= reserve, otherwise CRIT
# (e.g. 1.25 for WARN below a 25 % buffer above the reserve)
$reserveWarnFactor = 1.0
try {
    $nodeCount = [math]::Min(@(Get-ClusterNode).Count, 4)
    foreach ($pool in Get-StoragePool -IsPrimordial $false) {
        $capDisk = $pool | Get-PhysicalDisk |
                   Where-Object { "$($_.Usage)" -ne 'Journal' } |
                   Sort-Object Size -Descending | Select-Object -First 1

        $free    = $pool.Size - $pool.AllocatedSize
        $reserve = $capDisk.Size * $nodeCount
        $warnB   = $reserve * $reserveWarnFactor

        $freeTB    = [math]::Round($free    / 1TB, 2)
        $reserveTB = [math]::Round($reserve / 1TB, 2)
        $warnTB    = [math]::Round($warnB   / 1TB, 2)
        $sizeTB    = [math]::Round($pool.Size / 1TB, 2)
        $pct       = [math]::Round($pool.AllocatedSize / $pool.Size * 100, 1)

        $state = Get-State $pool.HealthStatus
        if     ($free -lt $reserve) { $state = [math]::Max($state, 2) }
        elseif ($free -lt $warnB)   { $state = [math]::Max($state, 1) }

        # Separate multiple metrics with "|" (a space ends the metrics field).
        # Checkmk threshold format lower:upper -> alert below warnTB or reserveTB
        $perf = "free_tb=$freeTB;${warnTB}:${sizeTB};${reserveTB}:${sizeTB};0;$sizeTB|allocated_pct=$pct;;;0;100"
        Out-Check $state "HV Cluster S2D Pool $($pool.FriendlyName)" $perf `
            "Health: $($pool.HealthStatus), $freeTB TB free, reserve $reserveTB TB ($nodeCount x $([math]::Round($capDisk.Size/1TB,2)) TB), $pct% allocated"
    }
} catch {
    Out-Check 3 'HV Cluster S2D Pool' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Virtual disks (one service per volume)
# =====================================================================
try {
    foreach ($vd in Get-VirtualDisk) {
        Out-Check (Get-State $vd.HealthStatus) "HV Cluster S2D VDisk $($vd.FriendlyName)" '-' `
            "Health: $($vd.HealthStatus), Status: $($vd.OperationalStatus -join ',')"
    }
} catch {
    Out-Check 3 'HV Cluster S2D VDisk' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Physical disks in the pool
# Disks on paused nodes or in storage maintenance mode -> WARN (maintenance)
# All other non-healthy disks -> CRIT (with serial number)
# =====================================================================
try {
    $pd  = @(Get-StoragePool -IsPrimordial $false | Get-PhysicalDisk)
    $bad = @($pd | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' })

    # Paused nodes (short name, upper case)
    $pausedNodes = @(Get-ClusterNode | Where-Object { "$($_.State)" -eq 'Paused' } |
                     ForEach-Object { "$($_.Name)".ToUpper() })

    # Map disk -> node (UniqueId -> short name)
    $diskNode = @{}
    foreach ($sn in Get-StorageNode) {
        $short = ("$($sn.Name)" -split '\.')[0].ToUpper()
        try {
            foreach ($d in (Get-PhysicalDisk -StorageNode $sn -PhysicallyConnected -ErrorAction Stop)) {
                $diskNode["$($d.UniqueId)"] = $short
            }
        } catch { }
    }

    $maint = @(); $defect = @()
    foreach ($d in $bad) {
        $node = $diskNode["$($d.UniqueId)"]
        if ("$($d.OperationalStatus)" -match 'Maintenance' -or ($node -and $pausedNodes -contains $node)) {
            $maint += $d
        } else {
            $defect += $d
        }
    }

    $state = 0
    if     ($defect.Count -gt 0) { $state = 2 }
    elseif ($maint.Count  -gt 0) { $state = 1 }

    $text = "$($pd.Count) disks in pool, $($defect.Count) defective, $($maint.Count) in maintenance"
    if ($maint.Count -gt 0) {
        $perNode = ($maint | Group-Object { $n = $diskNode["$($_.UniqueId)"]; if ($n) { $n } else { 'unknown' } } |
                    ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
        $text += " ($perNode)"
    }
    if ($defect.Count -gt 0) {
        $text += ' - DEFECTIVE: ' + (($defect | ForEach-Object {
            "$($diskNode["$($_.UniqueId)"]) SN $("$($_.SerialNumber)".TrimEnd('.')) ($($_.HealthStatus)/$($_.OperationalStatus -join ','))"
        }) -join ', ')
    }

    Out-Check $state 'HV Cluster S2D Physical Disks' "disks=$($pd.Count)|defect=$($defect.Count)|maintenance=$($maint.Count)" $text
} catch {
    Out-Check 3 'HV Cluster S2D Physical Disks' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Latency and IOPS per CSV volume (Health Service / performance history)
# Thresholds for average latency in ms (all-flash NVMe)
# =====================================================================
$latWarnMs = 10
$latCritMs = 25
try {
    foreach ($vol in (Get-Volume | Where-Object { "$($_.FileSystem)" -eq 'CSVFS' })) {
        $series = @($vol | Get-ClusterPerf 3>$null)

        # MetricId has the format "Volume.Latency.Average,Volume=\\?\Volume{GUID}\" -> use only the part before the comma
        # Health Service reports latency in seconds -> convert to ms
        $val = @{}
        foreach ($p in $series) {
            $id = ("$($p.MetricId)" -split ',')[0]
            $v  = [double]$p.Value
            if ($id -like 'Volume.Latency*') { $v = $v * 1000 }
            $val[$id] = $v
        }
        if (-not $val.ContainsKey('Volume.Latency.Average')) {
            Out-Check 3 "HV Cluster S2D Latency $($vol.FileSystemLabel)" '-' 'No performance data (check Health Service / ClusterPerformanceHistory)'
            continue
        }

        $avg  = [math]::Round($val['Volume.Latency.Average'], 2)
        $rd   = [math]::Round($val['Volume.Latency.Read'], 2)
        $wr   = [math]::Round($val['Volume.Latency.Write'], 2)
        $iops = [math]::Round($val['Volume.IOPS.Total'], 0)
        $mbs  = [math]::Round($val['Volume.Throughput.Total'] / 1MB, 1)

        $state = 0
        if     ($avg -ge $latCritMs) { $state = 2 }
        elseif ($avg -ge $latWarnMs) { $state = 1 }

        $perf = "latency_ms=$avg;$latWarnMs;$latCritMs;0|latency_read_ms=$rd|latency_write_ms=$wr|iops=$iops|throughput_mbs=$mbs"
        Out-Check $state "HV Cluster S2D Latency $($vol.FileSystemLabel)" $perf `
            "Latency avg $avg ms (read $rd / write $wr ms), $iops IOPS, $mbs MB/s"
    }
} catch {
    Out-Check 3 'HV Cluster S2D Latency' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# Storage jobs (repair/rebalance = reduced resiliency)
# =====================================================================
try {
    $jobs  = @(Get-StorageJob | Where-Object { "$($_.JobState)" -eq 'Running' })
    $state = if ($jobs.Count -gt 0) { 1 } else { 0 }
    $info  = ($jobs | ForEach-Object { "$($_.Name) $($_.PercentComplete)%" }) -join ', '
    Out-Check $state 'HV Cluster S2D Storage Jobs' "running=$($jobs.Count)" "$($jobs.Count) running jobs $info"
} catch {
    Out-Check 3 'HV Cluster S2D Storage Jobs' '-' "Query failed: $($_.Exception.Message)"
}
