# CheckMK-HyperV

Checkmk **Local Checks** (PowerShell) zur Überwachung von Hyper-V-Hosts und Hyper-V-Failover-Clustern – mit und ohne Storage Spaces Direct (S2D).

Die Skripte ergänzen die offiziellen Checkmk-Hyper-V-Checks um clusterweite Sichten wie Memory-N+1-Reserve, Quorum, CSV-Zugriffsmodus, S2D-Pool-Reserve sowie Pfad-Redundanz für SAN-Anbindungen (MPIO, FC, iSCSI).

## Module

| Skript | Einsatz | Service-Präfix | Zuordnung in Checkmk |
|---|---|---|---|
| [hv_cluster_health.ps1](hv_cluster_health.ps1) | jeder Failover-Cluster | `HV Cluster …` | Cluster-Host (Clustered services) |
| [hv_s2d_health.ps1](hv_s2d_health.ps1) | nur S2D-Cluster | `HV Cluster S2D …` | Cluster-Host (Clustered services) |
| [hv_node_health.ps1](hv_node_health.ps1) | jeder Hyper-V-Host | `HV Host …` | bleibt am jeweiligen Knoten |

Alle Skripte erkennen selbst, ob sie zuständig sind, und erzeugen sonst **keine Ausgabe**. Sie können deshalb einheitlich auf alle Hyper-V-Hosts verteilt werden:

- `hv_cluster_health.ps1` – schweigt, wenn kein Failover-Clustering installiert ist
- `hv_s2d_health.ps1` – schweigt ohne Cluster oder ohne aktiviertes S2D
- `hv_node_health.ps1` – SET-, MPIO-, FC- und iSCSI-Services erscheinen nur, wenn die Komponente vorhanden ist

## Voraussetzungen

- Windows Server mit Hyper-V, Checkmk-Agent für Windows
- PowerShell-Module `FailoverClusters`, `Hyper-V`, `Storage` (bei Clusterknoten ohnehin vorhanden)
- Für `hv_s2d_health.ps1`: Windows Server 2019 oder neuer (`Get-HealthFault`, `Get-ClusterPerf`)
- Network-ATC-Check nur, wenn `Get-NetIntentStatus` verfügbar ist (Azure Local / Windows Server 2025)
- **Memory N+1 ohne S2D:** Die Werte der anderen Knoten werden per WinRM/CIM und `Get-VM -ComputerName` abgefragt. Das Computerkonto jedes Knotens benötigt dafür auf den anderen Knoten lokale Admin- bzw. Hyper-V-Administratorrechte. Mit S2D kommen die Daten aus dem Health Service, Remotezugriff ist dann nicht nötig.

## Installation

1. Skripte auf **jeden** Clusterknoten bzw. Hyper-V-Host kopieren nach:

   ```
   C:\ProgramData\checkmk\agent\local\
   ```

2. Sicherstellen, dass der Agent `.ps1`-Dateien ausführt (Standard bei aktuellen Agenten, sonst in der `check_mk.user.yml` unter `local` → `execution` freigeben).

3. Optional, aber bei größeren Clustern empfohlen: Skripte asynchron mit Cache ausführen lassen, z. B. in der `check_mk.user.yml`:

   ```yaml
   local:
     execution:
       - pattern: '$CUSTOM_LOCAL_PATH$\hv_*.ps1'
         async: yes
         cache_age: 300
         timeout: 120
         run: yes
   ```

4. In Checkmk eine Service-Erkennung auf den Knoten ausführen.

## Checkmk-Konfiguration: Clustered services

`hv_cluster_health.ps1` und `hv_s2d_health.ps1` liefern auf allen Knoten **identische** Ergebnisse. Damit diese Services nicht mehrfach erscheinen, werden sie einem Cluster-Host zugeordnet:

1. In Checkmk einen Cluster-Host anlegen (z. B. Name des Failover-Clusters) und die Knoten als Cluster-Knoten eintragen.
2. Regel **Clustered services** für die Knoten anlegen mit dem Service-Muster:

   ```
   ^HV Cluster 
   ```

   (Das Leerzeichen am Ende gehört dazu. Das Muster erfasst auch alle `HV Cluster S2D …`-Services.)
3. Service-Erkennung auf Knoten und Cluster-Host ausführen.

Die `HV Host …`-Services aus `hv_node_health.ps1` sind knotenspezifisch und dürfen **nicht** in die Regel aufgenommen werden.

## Services

Status: 0 = OK, 1 = WARN, 2 = CRIT, 3 = UNKNOWN (z. B. wenn eine Abfrage fehlschlägt).

### hv_cluster_health.ps1

| Service | Prüfung | Bewertung |
|---|---|---|
| `HV Cluster Node <Name>` | Zustand jedes Clusterknotens | Up = OK, Paused/Joining = WARN, Down = CRIT |
| `HV Cluster Roles` | Cluster-Rollen (VMs etc., ohne Core-Gruppen) inkl. Verteilung auf die Knoten | Failed = CRIT; Offline/Pending nur als Info |
| `HV Cluster Memory N+1` | Passen alle laufenden VMs noch, wenn ein Knoten ausfällt? Bewertet wird das schlechteste Ausfallszenario | WARN ≥ 90 %, CRIT ≥ 95 %; WARN, wenn weniger als 2 Knoten Up |
| `HV Cluster Quorum` | Quorum-Typ, Witness-Zustand, Stimmen | Witness Online = OK, Pending = WARN, sonst CRIT; kein Witness: CRIT bei ≤ 2 Knoten, sonst WARN |
| `HV Cluster CSV <Name>` | Status und Zugriffsmodus pro CSV und Knoten | Direct bzw. FS-Redirected wegen ReFS = OK; sonstiges FS-Redirected / Block-Redirected = WARN; offline = CRIT |
| `HV Cluster CSV Space <Name>` | Belegung pro CSV | WARN ≥ 85 %, CRIT ≥ 95 % |
| `HV Cluster Disk <Name>` | Cluster-Disks, die keine CSV sind (Disk-Witness, Available Storage) | Online = OK, sonst CRIT |
| `HV Cluster NetATC <Intent>` | Network-ATC-Intents über alle Hosts | Success/Completed = OK, in Bearbeitung = WARN, Failed = CRIT |

### hv_s2d_health.ps1

| Service | Prüfung | Bewertung |
|---|---|---|
| `HV Cluster S2D Health Faults` | Faults des Health Service | Faults vorhanden = WARN, Major/Critical/Fatal = CRIT |
| `HV Cluster S2D Pool <Name>` | Pool-Health und freie Kapazität gegen Repair-Reserve (größte Kapazitätsdisk × Knotenanzahl, max. 4) | frei < Reserve = CRIT |
| `HV Cluster S2D VDisk <Name>` | Health jeder Virtual Disk | Healthy/Warning/Unhealthy → OK/WARN/CRIT |
| `HV Cluster S2D Physical Disks` | Physische Disks im Pool | Disks in Wartung (Storage Maintenance Mode, pausierter Knoten) = WARN, defekte Disks = CRIT (mit Knoten und Seriennummer) |
| `HV Cluster S2D Latency <Volume>` | Latenz, IOPS und Durchsatz pro CSV-Volume (Performance History) | WARN ≥ 10 ms, CRIT ≥ 25 ms (Durchschnitt) |
| `HV Cluster S2D Storage Jobs` | Laufende Repair-/Rebalance-Jobs | laufender Job = WARN (reduzierte Resilienz) |

### hv_node_health.ps1

| Service | Prüfung | Bewertung |
|---|---|---|
| `HV Host Patchlevel` | Build.UBR, Alter des letzten Updates, ausstehender Neustart | WARN ≥ 45 Tage, CRIT ≥ 75 Tage; Reboot ausstehend = mind. WARN |
| `HV Host SET <vSwitch>` | Physische Uplinks jedes Switch-Embedded-Teaming-vSwitch | einzelne Uplinks down/fehlend oder unterschiedliche Link-Speeds = WARN, kein Uplink Up = CRIT |
| `HV Host Checkpoints` | Checkpoints der VMs auf diesem Knoten | WARN ≥ 3 Tage, CRIT ≥ 7 Tage (ältester Checkpoint) |
| `HV Host MPIO` | Pfade pro LUN (FC und iSCSI) | weniger Pfade als Soll = WARN, nur noch 1 Pfad = CRIT |
| `HV Host FC Ports` | FC-HBA-Ports | einzelne Ports nicht Online = WARN, keiner Online = CRIT |
| `HV Host iSCSI` | Sessions pro iSCSI-Target | weniger Sessions als Soll = WARN, Target ohne Session = CRIT |

Die meisten Services liefern Metriken (Performance-Daten), sodass Checkmk Graphen erzeugt.

## Schwellwerte anpassen

Die Schwellwerte sind als Variablen direkt vor dem jeweiligen Abschnitt im Skript definiert:

| Skript | Variable | Standard | Bedeutung |
|---|---|---|---|
| hv_cluster_health.ps1 | `$nplusWarnPct` / `$nplusCritPct` | 90 / 95 | RAM-Auslastung nach Knotenausfall in % |
| hv_cluster_health.ps1 | `$csvWarnPct` / `$csvCritPct` | 85 / 95 | CSV-Belegung in % |
| hv_s2d_health.ps1 | `$reserveWarnFactor` | 1.0 | Vorwarnung oberhalb der Pool-Reserve (1.0 = keine Vorwarnung, z. B. 1.25 = WARN bei < 125 % der Reserve) |
| hv_s2d_health.ps1 | `$latWarnMs` / `$latCritMs` | 10 / 25 | Durchschnittliche Volume-Latenz in ms (ausgelegt auf All-Flash NVMe) |
| hv_node_health.ps1 | `$patchWarnDays` / `$patchCritDays` | 45 / 75 | Alter des letzten Updates in Tagen |
| hv_node_health.ps1 | `$cpWarnDays` / `$cpCritDays` | 3 / 7 | Alter von Checkpoints in Tagen |
| hv_node_health.ps1 | `$mpioExpectedPaths` | 0 (auto) | Soll-Pfadanzahl pro LUN |
| hv_node_health.ps1 | `$fcIgnorePorts` | leer | Bewusst ungenutzte FC-Ports (WWPN, z. B. `'10000090FA123456'`) |
| hv_node_health.ps1 | `$iscsiExpectedSessions` | 0 (auto) | Soll-Sessions pro iSCSI-Target |
| hv_node_health.ps1 | `$iscsiIgnoreTargets` | leer | Bewusst ungenutzte iSCSI-Targets (IQN) |

> **Hinweis zu „auto“ bei MPIO/iSCSI:** Der Sollwert ist dann die höchste Pfad- bzw. Session-Anzahl aller LUNs/Targets. Fällt bei allen gleichzeitig ein Pfad weg (z. B. komplette Fabric), sinkt auch der Sollwert und der Ausfall wird nicht als WARN erkannt. Den Sollwert daher möglichst fest eintragen.

## Manueller Test

Auf einem Knoten in einer administrativen PowerShell:

```powershell
cd C:\ProgramData\checkmk\agent\local
.\hv_cluster_health.ps1
.\hv_s2d_health.ps1
.\hv_node_health.ps1
```

Beispielausgabe:

```
0 "HV Cluster Node HV01" - State: Up, DrainStatus: NotInitiated
0 "HV Cluster Memory N+1" nplus1_pct=78.4;90;95;0;100 Worst Case nach Failover: 78.4% - ...
0 "HV Cluster CSV Space Volume01" used_pct=62.3;85;95;0;100|free_tb=3.77;;;0;10 62.3% belegt, 3.77 TB frei von 10 TB (CSVFS)
```

Den Abschnitt aus Sicht des Agenten zeigt `check_mk_agent.exe test` bzw. die Sektion `<<<local:sep(0)>>>` in der Agentenausgabe.

## Technische Hinweise

- Ausgabeformat: `<Status> "<Servicename>" <Metriken> <Text>` (Checkmk Local Check). Texte enthalten bewusst keine Umlaute.
- Die Skripte erzwingen `InvariantCulture`, damit Metriken auch auf deutschsprachigen Systemen mit Punkt als Dezimaltrenner ausgegeben werden (der Agent läuft als `SYSTEM`).
- Fehler in einem Abschnitt führen zu einem UNKNOWN-Service mit Fehlermeldung, die übrigen Abschnitte laufen weiter.
