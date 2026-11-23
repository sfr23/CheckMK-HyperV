# hv_s2d_health.ps1 - Checkmk Local Check: Storage Spaces Direct eines Hyper-V-Clusters
# Module:  hv_cluster_health.ps1  (alle Cluster)
#          hv_s2d_health.ps1      (dieses Skript, nur S2D)
#          hv_node_health.ps1     (knotenspezifisch)
# Ablage auf JEDEM Clusterknoten: C:\ProgramData\checkmk\agent\local\
# Die Ausgabe ist auf allen Knoten identisch -> per Regel "Clustered services"
# auf den Cluster-Host ziehen (Regex: ^HV Cluster )
# Auto-Erkennung: kein Cluster oder S2D nicht aktiviert -> keine Ausgabe
# Voraussetzung: Windows Server 2019+ (Get-HealthFault, Get-ClusterPerf)
# Ausgabeformat: <Status> "<Servicename>" <Metriken> <Text>  (ohne Umlaute)

$ErrorActionPreference = 'Stop'
# Punkt als Dezimaltrenner erzwingen (Agent laeuft als SYSTEM, ggf. mit de-DE)
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
# Auto-Erkennung: nur auf S2D-Clustern ausfuehren
# (Cluster nicht erreichbar meldet bereits hv_cluster_health.ps1)
# =====================================================================
if (-not (Get-Command Get-Cluster -ErrorAction SilentlyContinue)) { return }
try { $cluster = Get-Cluster } catch { return }
if ($cluster.S2DEnabled -ne 1) { return }

# =====================================================================
# Health Service Faults
# =====================================================================
try {
    # Warnung kommt aus dem Modul-Scope, -WarningAction greift dort nicht -> Streams umleiten
    # 3 = Warning, 6 = Information/Write-Host
    $faults = @(Get-HealthFault 3>$null 6>$null)
    $state = 0
    if ($faults.Count -gt 0) {
        $state = 1
        if ($faults | Where-Object { "$($_.PerceivedSeverity)" -match 'Major|Critical|Fatal' }) { $state = 2 }
    }
    $detail = ($faults | Select-Object -First 3 | ForEach-Object { "$($_.PerceivedSeverity): $($_.Reason)" }) -join ' | '
    if (-not $detail) { $detail = 'keine Faults' }
    Out-Check $state 'HV Cluster S2D Health Faults' "faults=$($faults.Count)" "$($faults.Count) Faults - $detail"
} catch {
    Out-Check 3 'HV Cluster S2D Health Faults' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Storage Pool: Health und freie Kapazitaet gegen Reserve
# Reserve nach MS-Empfehlung: groesste Kapazitaetsdisk x Anzahl Knoten (max. 4)
#   CRIT: frei < Reserve           -> Repair nach Disk-Ausfall nicht mehr sicher
#   WARN: frei < Reserve x Faktor  -> Vorwarnung
# =====================================================================
# 1.0 = keine Vorwarnung: OK solange frei >= Reserve, sonst CRIT
# (z.B. 1.25 fuer WARN ab 25 % Puffer ueber der Reserve)
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

        # Mehrere Metriken mit "|" trennen (Leerzeichen beendet das Metrikfeld).
        # Checkmk-Schwellenformat untere:obere -> Alarm unterhalb von warnTB bzw. reserveTB
        $perf = "free_tb=$freeTB;${warnTB}:${sizeTB};${reserveTB}:${sizeTB};0;$sizeTB|allocated_pct=$pct;;;0;100"
        Out-Check $state "HV Cluster S2D Pool $($pool.FriendlyName)" $perf `
            "Health: $($pool.HealthStatus), $freeTB TB frei, Reserve $reserveTB TB ($nodeCount x $([math]::Round($capDisk.Size/1TB,2)) TB), $pct% belegt"
    }
} catch {
    Out-Check 3 'HV Cluster S2D Pool' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Virtual Disks (ein Service pro Volume)
# =====================================================================
try {
    foreach ($vd in Get-VirtualDisk) {
        Out-Check (Get-State $vd.HealthStatus) "HV Cluster S2D VDisk $($vd.FriendlyName)" '-' `
            "Health: $($vd.HealthStatus), Status: $($vd.OperationalStatus -join ',')"
    }
} catch {
    Out-Check 3 'HV Cluster S2D VDisk' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Physische Disks im Pool
# Disks auf pausierten Knoten bzw. im Storage Maintenance Mode -> WARN (Wartung)
# Alle anderen nicht-healthy Disks -> CRIT (mit Seriennummer)
# =====================================================================
try {
    $pd  = @(Get-StoragePool -IsPrimordial $false | Get-PhysicalDisk)
    $bad = @($pd | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' })

    # Pausierte Knoten (Kurzname, gross)
    $pausedNodes = @(Get-ClusterNode | Where-Object { "$($_.State)" -eq 'Paused' } |
                     ForEach-Object { "$($_.Name)".ToUpper() })

    # Zuordnung Disk -> Knoten (UniqueId -> Kurzname)
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

    $text = "$($pd.Count) Disks im Pool, $($defect.Count) defekt, $($maint.Count) in Wartung"
    if ($maint.Count -gt 0) {
        $perNode = ($maint | Group-Object { $n = $diskNode["$($_.UniqueId)"]; if ($n) { $n } else { 'unbekannt' } } |
                    ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
        $text += " ($perNode)"
    }
    if ($defect.Count -gt 0) {
        $text += ' - DEFEKT: ' + (($defect | ForEach-Object {
            "$($diskNode["$($_.UniqueId)"]) SN $("$($_.SerialNumber)".TrimEnd('.')) ($($_.HealthStatus)/$($_.OperationalStatus -join ','))"
        }) -join ', ')
    }

    Out-Check $state 'HV Cluster S2D Physical Disks' "disks=$($pd.Count)|defect=$($defect.Count)|maintenance=$($maint.Count)" $text
} catch {
    Out-Check 3 'HV Cluster S2D Physical Disks' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Latenz und IOPS pro CSV-Volume (Health Service / Performance History)
# Schwellen fuer durchschnittliche Latenz in ms (All-Flash NVMe)
# =====================================================================
$latWarnMs = 10
$latCritMs = 25
try {
    foreach ($vol in (Get-Volume | Where-Object { "$($_.FileSystem)" -eq 'CSVFS' })) {
        $series = @($vol | Get-ClusterPerf 3>$null)

        # MetricId hat das Format "Volume.Latency.Average,Volume=\\?\Volume{GUID}\" -> nur den Teil vor dem Komma nutzen
        # Latenz liefert der Health Service in Sekunden -> in ms umrechnen
        $val = @{}
        foreach ($p in $series) {
            $id = ("$($p.MetricId)" -split ',')[0]
            $v  = [double]$p.Value
            if ($id -like 'Volume.Latency*') { $v = $v * 1000 }
            $val[$id] = $v
        }
        if (-not $val.ContainsKey('Volume.Latency.Average')) {
            Out-Check 3 "HV Cluster S2D Latency $($vol.FileSystemLabel)" '-' 'Keine Performance-Daten (Health Service / ClusterPerformanceHistory pruefen)'
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
            "Latenz avg $avg ms (read $rd / write $wr ms), $iops IOPS, $mbs MB/s"
    }
} catch {
    Out-Check 3 'HV Cluster S2D Latency' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Storage Jobs (Repair/Rebalance = reduzierte Resilienz)
# =====================================================================
try {
    $jobs  = @(Get-StorageJob | Where-Object { "$($_.JobState)" -eq 'Running' })
    $state = if ($jobs.Count -gt 0) { 1 } else { 0 }
    $info  = ($jobs | ForEach-Object { "$($_.Name) $($_.PercentComplete)%" }) -join ', '
    Out-Check $state 'HV Cluster S2D Storage Jobs' "running=$($jobs.Count)" "$($jobs.Count) laufende Jobs $info"
} catch {
    Out-Check 3 'HV Cluster S2D Storage Jobs' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}
