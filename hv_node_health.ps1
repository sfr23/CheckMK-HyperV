# hv_node_health.ps1 - Checkmk Local Check: knotenspezifische Sicht eines Hyper-V-Hosts
# Module:  hv_cluster_health.ps1  (alle Cluster)
#          hv_s2d_health.ps1      (nur S2D)
#          hv_node_health.ps1     (dieses Skript, knotenspezifisch)
# Ablage auf JEDEM Hyper-V-Host: C:\ProgramData\checkmk\agent\local\
# Diese Services bleiben am jeweiligen Knoten (NICHT in "Clustered services" aufnehmen).
# Auto-Erkennung: SET, MPIO, FC und iSCSI erscheinen nur, wenn vorhanden.
# Ausgabeformat: <Status> "<Servicename>" <Metriken> <Text>  (ohne Umlaute)

$ErrorActionPreference = 'Stop'
# Punkt als Dezimaltrenner erzwingen (Agent laeuft als SYSTEM, ggf. mit de-DE)
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Out-Check($state, $name, $perf, $text) {
    if (-not $perf) { $perf = '-' }
    $text = ("$text" -replace '[\r\n"]', ' ')
    Write-Output ('{0} "{1}" {2} {3}' -f $state, $name, $perf, $text)
}

$hasHyperV = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)

# =====================================================================
# Patchlevel: Build.UBR, Alter des letzten Updates, Reboot ausstehend
# Hinweis: Get-HotFix (Win32_QuickFixEngineering) liefert nicht immer ein InstalledOn;
# Eintraege ohne Datum werden ignoriert.
# =====================================================================
$patchWarnDays = 45
$patchCritDays = 75
try {
    $cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = "$($cv.CurrentBuild).$($cv.UBR)"

    $last = Get-HotFix | Where-Object { $_.InstalledOn } |
            Sort-Object InstalledOn -Descending | Select-Object -First 1
    $age  = if ($last) { [int]((Get-Date) - $last.InstalledOn).TotalDays } else { -1 }

    $rebootPending =
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')

    $state = 0
    if     ($age -lt 0)              { $state = 3 }
    elseif ($age -ge $patchCritDays) { $state = 2 }
    elseif ($age -ge $patchWarnDays) { $state = 1 }
    if ($rebootPending) { $state = [math]::Max($state, 1) }

    $lastText = if ($last) { "$($last.HotFixID) am $($last.InstalledOn.ToString('yyyy-MM-dd')) ($age Tage)" } else { 'unbekannt' }
    $rbText   = if ($rebootPending) { ', REBOOT AUSSTEHEND' } else { '' }

    Out-Check $state 'HV Host Patchlevel' "patch_age_days=$age;$patchWarnDays;$patchCritDays" `
        "Build $build, letztes Update: $lastText$rbText"
} catch {
    Out-Check 3 'HV Host Patchlevel' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
}

# =====================================================================
# SET-Uplinks: physische Member-Adapter jedes Switch Embedded Teaming vSwitch
#   alle Uplinks Up, gleiche Geschwindigkeit -> OK
#   einzelne Uplinks down / fehlend          -> WARN (keine Redundanz mehr)
#   unterschiedliche Link-Speeds              -> WARN
#   kein Uplink Up                            -> CRIT
# =====================================================================
if ($hasHyperV) {
    try {
        foreach ($sw in (Get-VMSwitch -SwitchType External | Where-Object { $_.EmbeddedTeamingEnabled })) {
            $descs   = @((Get-VMSwitchTeam -Name $sw.Name).NetAdapterInterfaceDescription)
            $nics    = @(Get-NetAdapter -Physical | Where-Object { $descs -contains $_.InterfaceDescription })
            $up      = @($nics | Where-Object { "$($_.Status)" -eq 'Up' })
            $speeds  = @($up | ForEach-Object { $_.Speed } | Sort-Object -Unique)
            $missing = $descs.Count - $nics.Count

            $state = 0
            if     ($up.Count -eq 0)            { $state = 2 }
            elseif ($up.Count -lt $descs.Count) { $state = 1 }
            elseif ($speeds.Count -gt 1)        { $state = 1 }

            $detail = ($nics | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Status) $($_.LinkSpeed)" }) -join ', '
            if ($missing -gt 0)      { $detail += ", $missing Adapter nicht gefunden" }
            if ($speeds.Count -gt 1) { $detail += ', UNTERSCHIEDLICHE LINK-SPEEDS' }

            Out-Check $state "HV Host SET $($sw.Name)" "uplinks=$($descs.Count)|up=$($up.Count)" `
                "$($up.Count) von $($descs.Count) Uplinks Up - $detail"
        }
    } catch {
        Out-Check 3 'HV Host SET' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
    }
}

# =====================================================================
# Checkpoints der VMs, die aktuell auf DIESEM Knoten laufen
# (Detail pro VM liefert der offizielle Check "Hyper-V VM Checkpoints")
# =====================================================================
$cpWarnDays = 3
$cpCritDays = 7
if ($hasHyperV) {
    try {
        $cps   = @(Get-VM | Get-VMSnapshot)
        $now   = Get-Date
        $old   = @($cps | Where-Object { ($now - $_.CreationTime).TotalDays -ge $cpWarnDays })
        $state = 0
        if ($old.Count -gt 0) {
            $state = 1
            if ($cps | Where-Object { ($now - $_.CreationTime).TotalDays -ge $cpCritDays }) { $state = 2 }
        }
        $oldest = $cps | Sort-Object CreationTime | Select-Object -First 1
        $oText  = if ($oldest) {
            "aeltester: $($oldest.VMName) / $($oldest.Name) ($([int]($now - $oldest.CreationTime).TotalDays) Tage)"
        } else { 'keine Checkpoints' }
        $maxAge = if ($oldest) { [math]::Round(($now - $oldest.CreationTime).TotalDays, 1) } else { 0 }

        Out-Check $state 'HV Host Checkpoints' "checkpoints=$($cps.Count)|old=$($old.Count)|max_age_days=$maxAge;$cpWarnDays;$cpCritDays" `
            "$($cps.Count) Checkpoints, $($old.Count) aelter als $cpWarnDays Tage, $oText"
    } catch {
        Out-Check 3 'HV Host Checkpoints' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
    }
}

# =====================================================================
# MPIO: Pfade pro LUN (FC und iSCSI)
# $mpioExpectedPaths = 0 -> Sollwert = hoechste Pfadanzahl aller LUNs (auto)
#   ACHTUNG auto: faellt bei allen LUNs gleichzeitig ein Pfad weg (z.B. ganze Fabric),
#   sinkt auch der Sollwert -> dann greifen FC-Ports/iSCSI unten. Besser fest eintragen.
#   weniger Pfade als Soll -> WARN, nur noch 1 Pfad (bei Soll > 1) -> CRIT
# =====================================================================
$mpioExpectedPaths = 0
$mpioDisks = @()
try {
    $mpioDisks = @(Get-CimInstance -Namespace root\wmi -ClassName MPIO_DISK_INFO -ErrorAction Stop |
                   ForEach-Object { $_.DriveInfo } | Where-Object { $_ })
} catch { }   # MPIO nicht installiert -> keine Ausgabe

if ($mpioDisks.Count -gt 0) {
    try {
        $expected = if ($mpioExpectedPaths -gt 0) { $mpioExpectedPaths } else {
            ($mpioDisks | Measure-Object NumberPaths -Maximum).Maximum
        }
        $degraded = @($mpioDisks | Where-Object { $_.NumberPaths -lt $expected })
        $single   = @($mpioDisks | Where-Object { $_.NumberPaths -le 1 })

        $state = 0
        if     ($expected -gt 1 -and $single.Count -gt 0) { $state = 2 }
        elseif ($degraded.Count -gt 0)                    { $state = 1 }

        $minPaths = ($mpioDisks | Measure-Object NumberPaths -Minimum).Minimum
        $mode     = if ($mpioExpectedPaths -gt 0) { 'fest' } else { 'auto' }
        $text     = "$($mpioDisks.Count) LUNs, Soll $expected Pfade ($mode), minimal $minPaths"
        if ($degraded.Count -gt 0) {
            $text += ' - ' + (($degraded | ForEach-Object {
                "$($_.Name) SN $("$($_.SerialNumber)".Trim()): $($_.NumberPaths) Pfade"
            }) -join ', ')
        }
        Out-Check $state 'HV Host MPIO' "luns=$($mpioDisks.Count)|min_paths=$minPaths|degraded=$($degraded.Count)" $text
    } catch {
        Out-Check 3 'HV Host MPIO' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
    }
}

# =====================================================================
# FC-HBA-Ports
#   alle Ports Online -> OK, einzelne nicht Online -> WARN, keiner Online -> CRIT
#   Bewusst ungenutzte Ports per WWPN ausnehmen (Format wie PortAddress, z.B. '10000090FA123456')
# =====================================================================
$fcIgnorePorts = @()
$fcPorts = @()
if (Get-Command Get-InitiatorPort -ErrorAction SilentlyContinue) {
    try {
        $fcPorts = @(Get-InitiatorPort | Where-Object {
            "$($_.ConnectionType)" -eq 'Fibre Channel' -and $fcIgnorePorts -notcontains "$($_.PortAddress)"
        })
    } catch { }
}
if ($fcPorts.Count -gt 0) {
    try {
        $on    = @($fcPorts | Where-Object { "$($_.OperationalStatus)" -eq 'Online' })
        $state = 0
        if     ($on.Count -eq 0)              { $state = 2 }
        elseif ($on.Count -lt $fcPorts.Count) { $state = 1 }

        $detail = ($fcPorts | Sort-Object PortAddress | ForEach-Object {
            "WWPN $($_.PortAddress): $($_.OperationalStatus -join ',')"
        }) -join ', '
        Out-Check $state 'HV Host FC Ports' "ports=$($fcPorts.Count)|online=$($on.Count)" `
            "$($on.Count) von $($fcPorts.Count) Ports Online - $detail"
    } catch {
        Out-Check 3 'HV Host FC Ports' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
    }
}

# =====================================================================
# iSCSI: Sessions pro Target
# $iscsiExpectedSessions = 0 -> Sollwert = hoechste Session-Anzahl aller Targets (auto)
#   Target ohne Session          -> CRIT
#   weniger Sessions als Soll    -> WARN (Pfadredundanz verloren)
#   Bewusst ungenutzte Targets per IQN in $iscsiIgnoreTargets ausnehmen
# =====================================================================
$iscsiExpectedSessions = 0
$iscsiIgnoreTargets    = @()
$iscsiTargets = @()
$svc = Get-Service MSiSCSI -ErrorAction SilentlyContinue
if ($svc -and "$($svc.Status)" -eq 'Running' -and (Get-Command Get-IscsiTarget -ErrorAction SilentlyContinue)) {
    try {
        $iscsiTargets = @(Get-IscsiTarget | Where-Object { $iscsiIgnoreTargets -notcontains "$($_.NodeAddress)" })
    } catch { }
}
if ($iscsiTargets.Count -gt 0) {
    try {
        $sessions = @(Get-IscsiSession -ErrorAction SilentlyContinue | Where-Object { $_.IsConnected })
        $perTarget = @(foreach ($t in $iscsiTargets) {
            [pscustomobject]@{
                Target   = "$($t.NodeAddress)"
                Sessions = @($sessions | Where-Object { "$($_.TargetNodeAddress)" -eq "$($t.NodeAddress)" }).Count
            }
        })
        $expected = if ($iscsiExpectedSessions -gt 0) { $iscsiExpectedSessions } else {
            ($perTarget | Measure-Object Sessions -Maximum).Maximum
        }
        $none     = @($perTarget | Where-Object { $_.Sessions -eq 0 })
        $degraded = @($perTarget | Where-Object { $_.Sessions -gt 0 -and $_.Sessions -lt $expected })

        $state = 0
        if     ($none.Count -gt 0)     { $state = 2 }
        elseif ($degraded.Count -gt 0) { $state = 1 }

        $mode = if ($iscsiExpectedSessions -gt 0) { 'fest' } else { 'auto' }
        $text = "$($perTarget.Count) Targets, $($sessions.Count) Sessions, Soll $expected pro Target ($mode)"
        $prob = @($none + $degraded)
        if ($prob.Count -gt 0) {
            $text += ' - ' + (($prob | ForEach-Object { "$($_.Target): $($_.Sessions) Sessions" }) -join ', ')
        }
        Out-Check $state 'HV Host iSCSI' "targets=$($perTarget.Count)|sessions=$($sessions.Count)|degraded=$($prob.Count)" $text
    } catch {
        Out-Check 3 'HV Host iSCSI' '-' "Abfrage fehlgeschlagen: $($_.Exception.Message)"
    }
}
