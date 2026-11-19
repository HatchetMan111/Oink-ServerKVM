# 🖥️ Oink-ServerKVM – Proxmox Datacenter Manager als One-Click-LXC

> **Namens-Klarstellung:** [oinkvm/oink](https://github.com/oinkvm/oink) ist eine
> Software-KVM-App (Tastatur/Maus-Sharing) für **Mac & Windows-Desktops** – sie hat
> keinen Linux-Build und kann nicht in einem LXC laufen. Dies hier ist der passende
> Proxmox-Ersatz für die Idee „Server zentral von einem Platz aus steuern": der
> **offizielle [Proxmox Datacenter Manager (PDM)](https://pdm.proxmox.com)** als
> LXC-Installer. Ein Web-GUI (Port 8443), in dem sich **bestehende Proxmox-VE-Hosts
> als „Remotes" verbinden** – ganz ohne Cluster. Danach verwaltest du alle Hosts,
> VMs/CTs, Konsolen (integriertes noVNC/xterm.js) und Migrationen von **einem
> Bildschirm** aus.

## Installation (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Oink-ServerKVM/main/install/pdm.sh)"
```

Optionen (Befehl einfach fortsetzen — **ohne** weiteres Anführungszeichen):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Oink-ServerKVM/main/install/pdm.sh)" --id 210 --memory 4096
```

| Option | Default | Bedeutung |
|---|---|---|
| `--id ID` | nächste freie ab 200 | Container-ID |
| `--hostname NAME` | `kvmoink` | Container-Hostname |
| `--rootfs GB` | 16 | Disk (Proxmox empfiehlt 40 für Produktion) |
| `--cores N` | 2 | vCPUs |
| `--memory MB` | 2048 | RAM (offizielles Minimum 2+ GB) |
| `--ip CIDR` | DHCP | feste IP, z. B. `192.168.178.50/24` (+ `--gateway`) |
| `--password PW` | auto | **CT-Root-PW = zugleich PDM-Web-Login (root@pam)!** |
| `--sshkey PFAD` | – | Public-Key-Datei/URL für root-SSH-Login |
| `--repo REPO` | `pdm-no-subscription` | oder `test` (neuere Builds) |
| `--force` | – | bestehenden CT löschen und neu anlegen |
| `--update` | – | PDM-Pakete im CT aktualisieren (apt) |
| `--uninstall` | – | CT stoppen und löschen |
| `--status` | – | Status anzeigen |

## Nach dem Install: deine Hosts verbinden (2 Minuten)

1. **`https://<CT-IP>:8443`** öffnen – die Browser-Warnung wegen des
   selbstsignierten Zertifikats ist normal (bestätigen).
2. Login: **root@pam** mit dem CT-Root-Passwort (wird am Ende des Installs
   angezeigt).
3. **Remotes → Add Remote → Proxmox VE Remote** und für jeden Host:
   - URL: `https://<PVE-Host-IP>:8006`
   - Credentials: `root@pam` des PVE-Hosts (oder ein API-Token)
   - TLS-Fingerprint: im PVE-GUI des Hosts → *Node → Zertifikate → pve-ssl.pem*
     ansehen (steht in der zweiten Zeile) und einfügen
   - PDM legt auf dem Host **automatisch einen API-Token** an – weiter nichts zu tun
4. Fertig: alle VMs/CTs beider Hosts erscheinen in einer Übersicht – inkl.
   Konsole, Snapshots, Backups und **Migration zwischen den Hosts**.

## Architektur im Container

- Debian 13 (trixie), unprivilegiert, KEIN Docker
- Offizielles APT-Paket `proxmox-datacenter-manager-container-meta`
  (manager + UI + client + docs – ohne Kernel/ZFS-Gepäck)
- Repo `pdm-no-subscription` (Default) oder `pdm-test` via `--repo test`
- Keyring-Download mit **SHA256-Prüfung** gegen die offizielle Prüfsumme
- Der Installer entfernt die vom Deb mitgebrachte `pdm-enterprise.sources`
  (404 ohne Subscription) – idempotent bei jedem Lauf
- systemd-Units: `proxmox-datacenter-api` + `proxmox-datacenter-privileged-api`

## Verifikation

- Mock-Harness: **189/189 grün** (`bash harness/run.sh`) – E2E-Install gegen
  gemockte pct/pveam/apt/curl/systemctl-Umgebung, inkl. Bootstrap-Reihenfolge
  (nacktes Debian → curl via apt), Keyring-SHA256 mit den ECHTEN Keyring-Bytes,
  enterprise.sources-Entfernung, Update/Repo-Wechsel, DNS-Fallback, Fehlerpfade
- **v1.0.1 Live-Fix (ProxSmartHome, CT 212):** Host hat beide Template-Arches
  gespeichert und `sort -rV` wählt arm64 VOR amd64 (r>d) → lxc „Failed to spawn"
  mit pct-Exit-0-Täuschung. Jetzt: Host-Arch via `uname -m` → Template explizit
  nach amd64/arm64 gefiltert + nach `pct create` aktive Status-Verifikation
  (`verify_ct_started`) statt blindes 60-s-IP-Timeout
- ShellCheck: sauber (Installer + Harness)
- PDM-Version im Repo-Index Stand 2026-11-18: **1.1.10** (pdm-test und
  pdm-no-subscription auf trixie)

## Hinweise

- PDM speichert die Host-Credentials im CT
  (`/var/lib/proxmox-datacenter-manager`) – Backups via `pct backup`/vzdump.
- Dem CT eine **feste IP bzw. DHCP-Reservierung** geben (`--ip` …), damit die
  PDM-URL stabil bleibt.
- `--update` aktualisiert via apt und startet die Services neu; Daten bleiben.
- Update-Kanal: nach einem `--repo test`-Install kehrt ein neuerlicher
  `--update` ohne `--repo` zur `pdm-no-subscription`-Quelle zurück.

## Lizenz

MIT – siehe [LICENSE](LICENSE). PDM selbst: AGPL-3.0 / GPL-3.0 (Proxmox) –
dieses Repo installiert nur die offiziellen Pakete.
