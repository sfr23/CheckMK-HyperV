# hv_node_health.ps1 - Checkmk local check: node-specific view of a Hyper-V host
# Modules: hv_cluster_health.ps1  (all clusters)
#          hv_s2d_health.ps1      (S2D only)
#          hv_node_health.ps1     (this script, node-specific)
# Deploy to EVERY Hyper-V host: C:\ProgramData\checkmk\agent\local\
# These services stay on their node (do NOT add them to "Clustered services").
# Auto-detection: SET, MPIO, FC and iSCSI only appear if present.
# Output format: <state> "<service name>" <metrics> <text>  (ASCII only)

$ErrorActionPreference = 'Stop'
# Force dot as decimal separator (agent runs as SYSTEM, possibly with de-DE culture)
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Out-Check($state, $name, $perf, $text) {
    if (-not $perf) { $perf = '-' }
    $text = ("$text" -replace '[\r\n"]', ' ')
    Write-Output ('{0} "{1}" {2} {3}' -f $state, $name, $perf, $text)
}

$hasHyperV = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)

# =====================================================================
# Patch level: Build.UBR, age of the last update, pending reboot
# Note: Get-HotFix (Win32_QuickFixEngineering) does not always return InstalledOn;
# entries without a date are ignored.
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

    $lastText = if ($last) { "$($last.HotFixID) on $($last.InstalledOn.ToString('yyyy-MM-dd')) ($age days)" } else { 'unknown' }
    $rbText   = if ($rebootPending) { ', REBOOT PENDING' } else { '' }

    Out-Check $state 'HV Host Patchlevel' "patch_age_days=$age;$patchWarnDays;$patchCritDays" `
        "Build $build, last update: $lastText$rbText"
} catch {
    Out-Check 3 'HV Host Patchlevel' '-' "Query failed: $($_.Exception.Message)"
}

# =====================================================================
# SET uplinks: physical member adapters of each Switch Embedded Teaming vSwitch
#   all uplinks Up, same speed               -> OK
#   individual uplinks down / missing        -> WARN (no redundancy left)
#   differing link speeds                    -> WARN
#   no uplink Up                             -> CRIT
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
            if ($missing -gt 0)      { $detail += ", $missing adapter(s) not found" }
            if ($speeds.Count -gt 1) { $detail += ', MISMATCHED LINK SPEEDS' }

            Out-Check $state "HV Host SET $($sw.Name)" "uplinks=$($descs.Count)|up=$($up.Count)" `
                "$($up.Count) of $($descs.Count) uplinks up - $detail"
        }
    } catch {
        Out-Check 3 'HV Host SET' '-' "Query failed: $($_.Exception.Message)"
    }
}

# =====================================================================
# Checkpoints of VMs currently running on THIS node
# (per-VM detail is provided by the official check "Hyper-V VM Checkpoints")
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
            "oldest: $($oldest.VMName) / $($oldest.Name) ($([int]($now - $oldest.CreationTime).TotalDays) days)"
        } else { 'no checkpoints' }
        $maxAge = if ($oldest) { [math]::Round(($now - $oldest.CreationTime).TotalDays, 1) } else { 0 }

        Out-Check $state 'HV Host Checkpoints' "checkpoints=$($cps.Count)|old=$($old.Count)|max_age_days=$maxAge;$cpWarnDays;$cpCritDays" `
            "$($cps.Count) checkpoints, $($old.Count) older than $cpWarnDays days, $oText"
    } catch {
        Out-Check 3 'HV Host Checkpoints' '-' "Query failed: $($_.Exception.Message)"
    }
}

# =====================================================================
# MPIO: paths per LUN (FC and iSCSI)
# $mpioExpectedPaths = 0 -> expected value = highest path count of all LUNs (auto)
#   CAUTION auto: if all LUNs lose a path at the same time (e.g. an entire fabric),
#   the expected value drops too -> then the FC ports/iSCSI checks below apply. Better set a fixed value.
#   fewer paths than expected -> WARN, only 1 path left (when expected > 1) -> CRIT
# =====================================================================
$mpioExpectedPaths = 0
$mpioDisks = @()
try {
    $mpioDisks = @(Get-CimInstance -Namespace root\wmi -ClassName MPIO_DISK_INFO -ErrorAction Stop |
                   ForEach-Object { $_.DriveInfo } | Where-Object { $_ })
} catch { }   # MPIO not installed -> no output

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
        $mode     = if ($mpioExpectedPaths -gt 0) { 'fixed' } else { 'auto' }
        $text     = "$($mpioDisks.Count) LUNs, expected $expected paths ($mode), minimum $minPaths"
        if ($degraded.Count -gt 0) {
            $text += ' - ' + (($degraded | ForEach-Object {
                "$($_.Name) SN $("$($_.SerialNumber)".Trim()): $($_.NumberPaths) paths"
            }) -join ', ')
        }
        Out-Check $state 'HV Host MPIO' "luns=$($mpioDisks.Count)|min_paths=$minPaths|degraded=$($degraded.Count)" $text
    } catch {
        Out-Check 3 'HV Host MPIO' '-' "Query failed: $($_.Exception.Message)"
    }
}

# =====================================================================
# FC HBA ports
#   all ports Online -> OK, some not Online -> WARN, none Online -> CRIT
#   Exclude intentionally unused ports by WWPN (same format as PortAddress, e.g. '10000090FA123456')
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
            "$($on.Count) of $($fcPorts.Count) ports online - $detail"
    } catch {
        Out-Check 3 'HV Host FC Ports' '-' "Query failed: $($_.Exception.Message)"
    }
}

# =====================================================================
# iSCSI: sessions per target
# $iscsiExpectedSessions = 0 -> expected value = highest session count of all targets (auto)
#   target without session          -> CRIT
#   fewer sessions than expected    -> WARN (path redundancy lost)
#   Exclude intentionally unused targets by IQN in $iscsiIgnoreTargets
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

        $mode = if ($iscsiExpectedSessions -gt 0) { 'fixed' } else { 'auto' }
        $text = "$($perTarget.Count) targets, $($sessions.Count) sessions, expected $expected per target ($mode)"
        $prob = @($none + $degraded)
        if ($prob.Count -gt 0) {
            $text += ' - ' + (($prob | ForEach-Object { "$($_.Target): $($_.Sessions) sessions" }) -join ', ')
        }
        Out-Check $state 'HV Host iSCSI' "targets=$($perTarget.Count)|sessions=$($sessions.Count)|degraded=$($prob.Count)" $text
    } catch {
        Out-Check 3 'HV Host iSCSI' '-' "Query failed: $($_.Exception.Message)"
    }
}
