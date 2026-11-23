# hv_cluster_health.ps1 - Checkmk Local Check: clusterweite Sicht eines Hyper-V-Failover-Clusters
# Module:  hv_cluster_health.ps1  (dieses Skript, alle Cluster)
#          hv_s2d_health.ps1      (nur S2D, erkennt sich selbst)
#          hv_node_health.ps1     (knotenspezifisch)
# Ablage auf JEDEM Clusterknoten: C:\ProgramData\checkmk\agent\local\
# Die Ausgabe ist auf allen Knoten identisch -> in Checkmk per Regel "Clustered services"
# auf den Cluster-Host ziehen (Regex: ^HV Cluster )
# Auto-Erkennung: kein Failover-Clustering installiert -> keine Ausgabe
# Ausgabeformat: <Status> "<Servicename>" <Metriken> <Text>  (ohne Umlaute)

$ErrorActionPreference = 'Stop'
# Punkt als Dezimaltrenner erzwingen (Agent laeuft als SYSTEM, ggf. mit de-DE)
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Out-Check($state, $name, $perf, $text) {
    if (-not $perf) { $perf = '-' }
    $text = ("$text" -replace '[\r\n"]', ' ')
    Write-Output ('{0} "{1}" {2} {3}' -f $state, $name, $perf, $text)
}

# =====================================================================
# Voraussetzungen / Auto-Erkennung
# =====================================================================
if (-not (Get-Command Get-Cluster -ErrorAction SilentlyContinue)) { return }   # kein Clusterknoten
try {
    $cluster = Get-Cluster
} catch {
    Out-Check 2 'HV Cluster Service' '-' "Cluster auf $env:COMPUTERNAME nicht erreichbar: $($_.Exception.Message)"
    return
}
$isS2D = ($cluster.S2DEnabled -eq 1)   # Health Service nur bei S2D vorhanden

# =====================================================================
# Clusterknoten
# =====================================================================
try {
    foreach ($node in Get-ClusterNode) {
        $state = switch ("$($node.State)") {
            'Up'      { 0 }
            'Paused'  { 1 }   # Wartung / Drain
            'Joining' { 1 }
            'Down'    { 2 }
            default   { 3 }
        }
        Out-Check $state "HV Cluster Node $($node.Name)" '-' `
            "State: $($node.State), DrainStatus: $($node.DrainStatus)"
    }
} catch {
    Out-Check 3 'HV Cluster Node Status' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Cluster-Rollen (VMs und sonstige Rollen, ohne Core-Gruppen)
#   Failed -> CRIT
#   Offline / PartialOnline / Pending -> nur Info im Text (ausgeschaltet = erwartet)
# =====================================================================
try {
    $groups = @(Get-ClusterGroup | Where-Object { -not $_.IsCoreGroup -and "$($_.GroupType)" -ne 'AvailableStorage' })
    $online = @($groups | Where-Object { "$($_.State)" -eq 'Online' })
    $failed = @($groups | Where-Object { "$($_.State)" -eq 'Failed' })
    $other  = @($groups | Where-Object { "$($_.State)" -notin @('Online','Failed') })

    $state = if ($failed.Count -gt 0) { 2 } else { 0 }

    $dist = ($groups | Group-Object { "$($_.OwnerNode)" } | Sort-Object Name |
             ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    $text = "$($groups.Count) Rollen, $($online.Count) Online, $($failed.Count) Failed, $($other.Count) sonstige, Verteilung: $dist"
    if ($failed.Count -gt 0) {
        $text += ' - FAILED: ' + (($failed | ForEach-Object { "$($_.Name) auf $($_.OwnerNode)" }) -join ', ')
    }
    if ($other.Count -gt 0) {
        $text += ' - Info: ' + (($other | ForEach-Object { "$($_.Name) ($($_.State))" }) -join ', ')
    }
    Out-Check $state 'HV Cluster Roles' "roles=$($groups.Count)|online=$($online.Count)|failed=$($failed.Count)|other=$($other.Count)" $text
} catch {
    Out-Check 3 'HV Cluster Roles' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Memory N+1: passen alle laufenden VMs noch, wenn ein Knoten ausfaellt?
# Pro Ausfallszenario: (Nutzung der verbleibenden Knoten + Gast-RAM des ausgefallenen Knotens)
#                      / Gesamt-RAM der verbleibenden Knoten
# Bewertet wird das schlechteste Szenario.
# Datenquelle:
#   S2D:      Health Service (Get-ClusterPerf), kein Remotezugriff noetig
#   ohne S2D: WinRM/CIM + Get-VM auf die anderen Knoten. Das Computerkonto dieses
#             Knotens braucht dort lokale Admin- bzw. Hyper-V-Administratorrechte.
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
    # Fallback: CIM / Hyper-V direkt (lokal ohne, sonst mit Remotezugriff)
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
        Out-Check 3 'HV Cluster Memory N+1' '-' "Abfrage fehlgeschlagen - $($errors -join '; ')"
    } elseif ($mem.Count -lt 2) {
        Out-Check 1 'HV Cluster Memory N+1' '-' "Nicht berechenbar: nur $($mem.Count) Knoten Up (keine N+1-Redundanz)"
    } else {
        $worst = -1
        $scen  = @()
        foreach ($f in ($mem.Keys | Sort-Object)) {
            $surv = @($mem.Keys | Where-Object { $_ -ne $f })
            $tot  = ($surv | ForEach-Object { $mem[$_].Total } | Measure-Object -Sum).Sum
            $use  = ($surv | ForEach-Object { $mem[$_].Usage } | Measure-Object -Sum).Sum + $mem[$f].Guest
            $pct  = [math]::Round($use / $tot * 100, 1)
            $scen += "Ausfall $f -> $pct% ($([math]::Round($use/1GB)) von $([math]::Round($tot/1GB)) GB, +$([math]::Round($mem[$f].Guest/1GB)) GB Gaeste)"
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
            "Worst Case nach Failover: $worst% - aktuell: $now - $($scen -join '; ') (Quelle: $src)"
    }
} catch {
    Out-Check 3 'HV Cluster Memory N+1' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Quorum / Witness
#   Witness Online = OK, Pending = WARN, sonst CRIT
#   Kein Witness: bei <= 2 Knoten CRIT, sonst WARN
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
        $text = "Typ: $($q.QuorumType), Witness: $($res.Name) ($($res.ResourceType)) $($res.State), Stimmen: $votes Knoten + Witness $wVote"
    } else {
        $state = if ($nodes.Count -le 2) { 2 } else { 1 }
        $text  = "Typ: $($q.QuorumType), KEIN Witness konfiguriert, Stimmen: $votes Knoten"
    }
    Out-Check $state 'HV Cluster Quorum' "node_votes=$votes|witness_vote=$wVote" $text
} catch {
    Out-Check 3 'HV Cluster Quorum' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# CSV: Status und Zugriffsmodus pro Knoten (ein Service pro CSV)
#   Direct                           -> OK (Sollzustand bei NTFS, z.B. SAN)
#   FileSystemRedirected wegen ReFS  -> OK (bei ReFS by design, z.B. S2D)
#   sonstiges FileSystemRedirected   -> WARN (z.B. inkompatibler Filtertreiber, Backup)
#   BlockRedirected                  -> WARN (Knoten ohne eigenen Pfad zum Datentraeger)
#   CSV nicht Online / Unavailable   -> CRIT
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
        $text  = "Status: $($csv.State), Owner: $($csv.OwnerNode), Modus: $modes"
        if ($issues.Count -gt 0) { $text += ' - ' + ($issues -join ', ') }
        Out-Check $state "HV Cluster CSV $short" '-' $text
    }
} catch {
    Out-Check 3 'HV Cluster CSV' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# CSV-Belegung (ein Service pro CSV)
# Bei S2D zusaetzlich zur Pool-Reserve, bei SAN die einzige Kapazitaetssicht
# =====================================================================
$csvWarnPct = 85
$csvCritPct = 95
try {
    foreach ($csv in Get-ClusterSharedVolume) {
        $short = "$($csv.Name)" -replace '^Cluster Virtual Disk \((.*)\)$', '$1'
        $part  = $csv.SharedVolumeInfo | Select-Object -First 1 -ExpandProperty Partition
        if (-not $part -or -not $part.Size) {
            Out-Check 3 "HV Cluster CSV Space $short" '-' 'Keine Partitionsdaten (CSV offline?)'
            continue
        }
        $usedPct = [math]::Round(($part.Size - $part.FreeSpace) / $part.Size * 100, 1)
        $freeTB  = [math]::Round($part.FreeSpace / 1TB, 2)
        $sizeTB  = [math]::Round($part.Size / 1TB, 2)

        $state = 0
        if     ($usedPct -ge $csvCritPct) { $state = 2 }
        elseif ($usedPct -ge $csvWarnPct) { $state = 1 }

        Out-Check $state "HV Cluster CSV Space $short" "used_pct=$usedPct;$csvWarnPct;$csvCritPct;0;100|free_tb=$freeTB;;;0;$sizeTB" `
            "$usedPct% belegt, $freeTB TB frei von $sizeTB TB ($($part.FileSystem))"
    }
} catch {
    Out-Check 3 'HV Cluster CSV Space' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Cluster-Disks, die keine CSV sind (z.B. Disk-Witness, Disks in "Available Storage")
#   Online -> OK, sonst CRIT
# =====================================================================
try {
    $csvNames = @(Get-ClusterSharedVolume | ForEach-Object { "$($_.Name)" })
    foreach ($disk in (Get-ClusterResource | Where-Object {
                "$($_.ResourceType)" -eq 'Physical Disk' -and $csvNames -notcontains "$($_.Name)" })) {
        $state = if ("$($disk.State)" -eq 'Online') { 0 } else { 2 }
        Out-Check $state "HV Cluster Disk $($disk.Name)" '-' `
            "State: $($disk.State), Gruppe: $($disk.OwnerGroup), Owner: $($disk.OwnerNode)"
    }
} catch {
    Out-Check 3 'HV Cluster Disk' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# Network ATC - ein Service pro Intent, bewertet ueber alle Hosts
# Nur wenn Network ATC vorhanden und Intents definiert sind
# OK nur bei ConfigurationStatus = Success UND ProvisioningStatus = Completed
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
                $state = 1   # z.B. Provisioning/Validating/Retrying
                if ($bad | Where-Object { "$($_.ConfigurationStatus)$($_.ProvisioningStatus)" -match 'Fail' }) { $state = 2 }
            }
            $detail = ($bad | ForEach-Object { "$($_.Host): $($_.ConfigurationStatus)/$($_.ProvisioningStatus)" }) -join ', '
            if (-not $detail) { $detail = 'alle Hosts Success/Completed' }
            Out-Check $state "HV Cluster NetATC $($grp.Name)" "hosts=$($grp.Count)|bad=$($bad.Count)" `
                "$($grp.Count) Hosts, $($bad.Count) abweichend - $detail"
        }
    } catch {
        Out-Check 3 'HV Cluster NetATC' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
    }
}
