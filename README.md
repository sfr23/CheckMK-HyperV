# CheckMK-HyperV

Checkmk **local checks** (PowerShell) for monitoring Hyper-V hosts and Hyper-V failover clusters, with or without Storage Spaces Direct (S2D).

The scripts complement the official Checkmk Hyper-V checks with cluster-wide views such as memory N+1 reserve, quorum, CSV access mode and S2D pool reserve, plus path redundancy for SAN connectivity (MPIO, FC, iSCSI).

## Modules

| Script | Applies to | Service prefix | Assignment in Checkmk |
| --- | --- | --- | --- |
| [hv_cluster_health.ps1](hv_cluster_health.ps1) | every failover cluster | `HV Cluster …` | cluster host (clustered services) |
| [hv_s2d_health.ps1](hv_s2d_health.ps1) | S2D clusters only | `HV Cluster S2D …` | cluster host (clustered services) |
| [hv_node_health.ps1](hv_node_health.ps1) | every Hyper-V host | `HV Host …` | stays on the individual node |

Each script detects whether it applies and produces **no output** otherwise, so all three can be deployed uniformly to every Hyper-V host:

- `hv_cluster_health.ps1` stays silent if Failover Clustering is not installed
- `hv_s2d_health.ps1` stays silent without a cluster or without S2D enabled
- `hv_node_health.ps1` only emits the SET, MPIO, FC and iSCSI services if the component is present

## Requirements

- Windows Server with Hyper-V and the Checkmk agent for Windows
- PowerShell modules `FailoverClusters`, `Hyper-V`, `Storage` (present on cluster nodes anyway)
- For `hv_s2d_health.ps1`: Windows Server 2019 or later (`Get-HealthFault`, `Get-ClusterPerf`)
- The Network ATC check only runs if `Get-NetIntentStatus` is available (Azure Local / Windows Server 2025)
- **Memory N+1 without S2D:** values of the other nodes are queried via WinRM/CIM and `Get-VM -ComputerName`. Each node's computer account needs local admin or Hyper-V Administrators rights on the other nodes. With S2D the data comes from the Health Service and no remote access is needed.

## Installation

1. Copy the scripts to **every** cluster node / Hyper-V host:

   ```text
   C:\ProgramData\checkmk\agent\local\
   ```

2. Make sure the agent executes `.ps1` files (default in current agents; otherwise enable it in `check_mk.user.yml` under `local` → `execution`).

3. Optional, but recommended for larger clusters: run the scripts asynchronously with caching, e.g. in `check_mk.user.yml`:

   ```yaml
   local:
     execution:
       - pattern: '$CUSTOM_LOCAL_PATH$\hv_*.ps1'
         async: yes
         cache_age: 300
         timeout: 120
         run: yes
   ```

4. Run a service discovery on the nodes in Checkmk.

## Checkmk configuration: clustered services

`hv_cluster_health.ps1` and `hv_s2d_health.ps1` return **identical** results on every node. To avoid duplicate services, assign them to a cluster host:

1. Create a cluster host in Checkmk (e.g. named after the failover cluster) and add the nodes as cluster nodes.
2. Create a **Clustered services** rule for the nodes with the service pattern:

   ```text
   ^HV Cluster 
   ```

   (The trailing space is intentional. The pattern also covers all `HV Cluster S2D …` services.)
3. Run a service discovery on the nodes and the cluster host.

The `HV Host …` services from `hv_node_health.ps1` are node-specific and must **not** be included in the rule.

## Services

States: 0 = OK, 1 = WARN, 2 = CRIT, 3 = UNKNOWN (e.g. when a query fails).

### hv_cluster_health.ps1

| Service | Check | Evaluation |
| --- | --- | --- |
| `HV Cluster Node <name>` | State of each cluster node | Up = OK, Paused/Joining = WARN, Down = CRIT |
| `HV Cluster Roles` | Cluster roles (VMs etc., excluding core groups) incl. distribution across nodes | Failed = CRIT; Offline/Pending reported as info only |
| `HV Cluster Memory N+1` | Do all running VMs still fit if one node fails? The worst failure scenario is evaluated | WARN ≥ 90 %, CRIT ≥ 95 %; WARN if fewer than 2 nodes are Up |
| `HV Cluster Quorum` | Quorum type, witness state, votes | Witness Online = OK, Pending = WARN, otherwise CRIT; no witness: CRIT with ≤ 2 nodes, otherwise WARN |
| `HV Cluster CSV <name>` | State and access mode per CSV and node | Direct or FS-redirected due to ReFS = OK; other FS-redirected / block-redirected = WARN; offline = CRIT |
| `HV Cluster CSV Space <name>` | Usage per CSV | WARN ≥ 85 %, CRIT ≥ 95 % |
| `HV Cluster Disk <name>` | Cluster disks that are not CSVs (disk witness, Available Storage) | Online = OK, otherwise CRIT |
| `HV Cluster NetATC <intent>` | Network ATC intents across all hosts | Success/Completed = OK, in progress = WARN, failed = CRIT |

### hv_s2d_health.ps1

| Service | Check | Evaluation |
| --- | --- | --- |
| `HV Cluster S2D Health Faults` | Health Service faults | faults present = WARN, Major/Critical/Fatal = CRIT |
| `HV Cluster S2D Pool <name>` | Pool health and free capacity vs. repair reserve (largest capacity disk × node count, max. 4) | free < reserve = CRIT |
| `HV Cluster S2D VDisk <name>` | Health of each virtual disk | Healthy/Warning/Unhealthy → OK/WARN/CRIT |
| `HV Cluster S2D Physical Disks` | Physical disks in the pool | disks in maintenance (storage maintenance mode, paused node) = WARN, defective disks = CRIT (with node and serial number) |
| `HV Cluster S2D Latency <volume>` | Latency, IOPS and throughput per CSV volume (performance history) | WARN ≥ 10 ms, CRIT ≥ 25 ms (average) |
| `HV Cluster S2D Storage Jobs` | Running repair/rebalance jobs | running job = WARN (reduced resiliency) |

### hv_node_health.ps1

| Service | Check | Evaluation |
| --- | --- | --- |
| `HV Host Patchlevel` | Build.UBR, age of the last update, pending reboot | WARN ≥ 45 days, CRIT ≥ 75 days; pending reboot = at least WARN |
| `HV Host SET <vSwitch>` | Physical uplinks of each Switch Embedded Teaming vSwitch | individual uplinks down/missing or differing link speeds = WARN, no uplink Up = CRIT |
| `HV Host Checkpoints` | Checkpoints of the VMs on this node | WARN ≥ 3 days, CRIT ≥ 7 days (oldest checkpoint) |
| `HV Host MPIO` | Paths per LUN (FC and iSCSI) | fewer paths than expected = WARN, only 1 path left = CRIT |
| `HV Host FC Ports` | FC HBA ports | some ports not Online = WARN, none Online = CRIT |
| `HV Host iSCSI` | Sessions per iSCSI target | fewer sessions than expected = WARN, target without session = CRIT |

Most services emit metrics (performance data), so Checkmk creates graphs for them.

## Adjusting thresholds

Thresholds are defined as variables directly before the corresponding section in each script:

| Script | Variable | Default | Meaning |
| --- | --- | --- | --- |
| hv_cluster_health.ps1 | `$nplusWarnPct` / `$nplusCritPct` | 90 / 95 | RAM utilization after a node failure in % |
| hv_cluster_health.ps1 | `$csvWarnPct` / `$csvCritPct` | 85 / 95 | CSV usage in % |
| hv_s2d_health.ps1 | `$reserveWarnFactor` | 1.0 | Early warning above the pool reserve (1.0 = no early warning, e.g. 1.25 = WARN below 125 % of the reserve) |
| hv_s2d_health.ps1 | `$latWarnMs` / `$latCritMs` | 10 / 25 | Average volume latency in ms (tuned for all-flash NVMe) |
| hv_node_health.ps1 | `$patchWarnDays` / `$patchCritDays` | 45 / 75 | Age of the last update in days |
| hv_node_health.ps1 | `$cpWarnDays` / `$cpCritDays` | 3 / 7 | Checkpoint age in days |
| hv_node_health.ps1 | `$mpioExpectedPaths` | 0 (auto) | Expected path count per LUN |
| hv_node_health.ps1 | `$fcIgnorePorts` | empty | Intentionally unused FC ports (WWPN, e.g. `'10000090FA123456'`) |
| hv_node_health.ps1 | `$iscsiExpectedSessions` | 0 (auto) | Expected sessions per iSCSI target |
| hv_node_health.ps1 | `$iscsiIgnoreTargets` | empty | Intentionally unused iSCSI targets (IQN) |

> **Note on "auto" for MPIO/iSCSI:** the expected value is then the highest path or session count across all LUNs/targets. If all of them lose a path at the same time (e.g. an entire fabric), the expected value drops as well and the outage is not reported as WARN. Set a fixed value where possible.

## Manual test

On a node, in an elevated PowerShell:

```powershell
cd C:\ProgramData\checkmk\agent\local
.\hv_cluster_health.ps1
.\hv_s2d_health.ps1
.\hv_node_health.ps1
```

Example output:

```text
0 "HV Cluster Node HV01" - State: Up, DrainStatus: NotInitiated
0 "HV Cluster Memory N+1" nplus1_pct=78.4;90;95;0;100 Worst case after failover: 78.4% - ...
0 "HV Cluster CSV Space Volume01" used_pct=62.3;85;95;0;100|free_tb=3.77;;;0;10 62.3% used, 3.77 TB free of 10 TB (CSVFS)
```

To see the section as the agent reports it, use `check_mk_agent.exe test` or look for the `<<<local:sep(0)>>>` section in the agent output.

## Technical notes

- Output format: `<state> "<service name>" <metrics> <text>` (Checkmk local check). Texts are intentionally ASCII only.
- The scripts force `InvariantCulture` so metrics use a dot as decimal separator even on German-language systems (the agent runs as `SYSTEM`).
- An error in one section results in an UNKNOWN service with the error message; the remaining sections keep running.

## License

Released under the [MIT License](LICENSE).
