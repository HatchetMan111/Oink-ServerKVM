#!/usr/bin/env bash
# =============================================================================
#  🖥️  Proxmox Datacenter Manager (PDM) – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/Oink-ServerKVM
#
#  Erstellt einen unprivilegierten LXC-Container (Debian 13) und installiert
#  darin den OFFIZIELLEN Proxmox Datacenter Manager (v1.1.x, pdm-APT-Repo):
#  eine zentrale Web-GUI (Port 8443, HTTPS), über die sich BESTEHENDE
#  Proxmox-VE-/PBS-Hosts als "Remotes" verbinden lassen – OHNE Cluster.
#  Danach verwaltest du alle Hosts, VMs/CTs, Konsolen (integriertes
#  noVNC/xterm.js) und Migrationen von EINEM Bildschirm aus.
#
#  Architektur im Container: reines APT-Paket
#  `proxmox-datacenter-manager-container-meta` aus dem offiziellen
#  pdm-no-subscription-Repo (oder pdm-test via --repo test). KEIN Docker,
#  kein Build im CT. Der Installer entfernt die vom Paket mitgebrachte
#  pdm-enterprise.sources (404 ohne Subscription) – idempotent.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Oink-ServerKVM/main/install/pdm.sh)"
#
#  Mit Optionen (Befehl einfach fortsetzen – NACH dem schließenden
#  Anführungszeichen, OHNE weiteres Anführungszeichen):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Oink-ServerKVM/main/install/pdm.sh)" --id 210 --memory 4096
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.1"   # wird in --status/-Logs ausgegeben – hilft bei Fehlersuche
APP_NAME="pdm"
PDM_SERVICES="proxmox-datacenter-api proxmox-datacenter-privileged-api"  # systemd-Units des Debs
PDM_MAIN_PKG="proxmox-datacenter-manager"                # Version in --status angezeigt
PDM_META_PKG="proxmox-datacenter-manager-container-meta" # LXC-Variante (ohne Kernel/ZFS-Gepäck)
REPO_COMPONENT="pdm-no-subscription"  # Default; pdm-test via --repo test
KEYRING_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
# SHA256 laut offizieller PDM-Doku – hier 2026-11-18 selbst verifiziert:
KEYRING_SHA256="136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45"
UI_PORT=8443                # PDM-Web-GUI (HTTPS, fix – vom Daemon vorgegeben)
PVE_PORT=8006               # nur für Hinweistexte (Remotes-Wizard)
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="kvmoink"   # Phils Branding (war "pdm" in v1.0.0)
CT_STORAGE="local-lvm"
CT_ROOTFS=16                # GB – PDM-Dokumentation empfiehlt 40 für PROD; Home-Lab reicht 16
CT_CORES=2
CT_MEMORY=2048              # MB – offizielles Minimum (2+ GB empfohlen)
CT_SWAP=512
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren (IST zugleich PDM-Login!)
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Oink-ServerKVM/main/install/pdm.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + PDM-Services), falls schon
# ein Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + PDM):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/pdm-setup.log 2>/dev/null
            echo "--- journalctl der PDM-Services ---"
            journalctl -u proxmox-datacenter-api --no-pager 2>/dev/null | tail -n 10 || true
            journalctl -u proxmox-datacenter-privileged-api --no-pager 2>/dev/null | tail -n 10 || true
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}'
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

verify_ct_started() {
    # Live-Fund 2026-11-19 (CT 212, ProxSmartHome): pct create --start gibt
    # Exit 0 zurück, AUCH wenn der Spawn knallt ("sync_wait ... Failed to
    # spawn container"). Exit 0 heißt NICHT "läuft" – aktiv den Status
    # verifizieren, bevor blind aufs Netzwerk gewartet wird.
    local id="$1" tries=0 state=""
    while true; do
        state=$(pct status "$id" 2>/dev/null | awk '{print $2}' || true)
        if [[ "$state" == "running" ]]; then
            ok "Container $id läuft (Status nach pct create verifiziert)"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 15 ]]; then
            err "Container $id startet NICHT (Status nach pct create: ${state:-unbekannt})."
            info "Häufigste Ursache: falsches Template-Arch (arm64/amd64) oder Storage-/Start-Probleme."
            info "Prüfen: pct config $id | grep -E 'rootfs|arch'   |   pct start $id   (zeigt den Spawn-Fehler direkt)"
            return 1
        fi
        sleep 1
    done
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – APT + Keyring-Download brauchen Namensauflösung.
    # Live-Fund (2026-11-10, CT 200): DNS ist FLAKY – ein einzelner getent-Erfolg
    # reichte, Stunden später war wieder alles tot. Deshalb: 3 Erfolge in Folge
    # verlangen; eine einzige Störung in diesem Fenster → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts deb.debian.org >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts deb.debian.org >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).\n  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1\n  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    # pct status liefert "status: <wert>" – Prefix abschneiden für saubere Meldungen
    state="${state#status: }"
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-" oder Leerzeichen, wird es
    # als Optionsliste gewertet und TOKENWEISE gesplittet. Das fängt auch den
    # Copy-Paste-Klassiker `...)" " --id 210` ab (überzähliges/zu wenig
    # geschlossenes Anführungszeichen → bash hängt am Fortsetzungs-Prompt und
    # $0 landet als " --id 210"): die Optionen werden sauber herausgelesen.
    local args=("$@")
    if [[ "$0" == -* || "$0" == [[:space:]]* ]]; then
        local zero_args=()
        read -r -a zero_args <<< "$0" || true
        if [[ ${#zero_args[@]} -gt 0 ]]; then
            args=("${zero_args[@]}" "$@")
        fi
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --repo)          REPO_COMPONENT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (–help zeigt alle Optionen)" ;;
        esac
    done
    # Repo-Komponente hart validieren – sie landet in der deb822-Sources-Datei.
    # Aliase erlaubt: "test" → pdm-test, "no-subscription" → pdm-no-subscription.
    case "$REPO_COMPONENT" in
        pdm-no-subscription|no-subscription) REPO_COMPONENT="pdm-no-subscription" ;;
        pdm-test|test)                       REPO_COMPONENT="pdm-test" ;;
        *) die "Ungültiges Repo: '$REPO_COMPONENT' (erlaubt: pdm-no-subscription | pdm-test, z. B. --repo test)" ;;
    esac
}

print_help() {
    cat <<'EOF'
🖥️  Proxmox Datacenter Manager (PDM) – Proxmox-Installer
    Offizielle Multi-Host-Verwaltung: bestehende PVE/PBS-Hosts als "Remotes"
    verbinden (KEIN Cluster nötig) und alles von einer GUI steuern.

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Oink-ServerKVM/main/install/pdm.sh)"

Optionen (Befehl einfach fortsetzen, z. B.   ...pdm.sh)" --id 210   – OHNE weiteres Anführungszeichen):
  --id ID          Container-ID (Default: nächste freie ab 200)
  --hostname NAME  Container-Hostname (Default: kvmoink)
  --storage NAME   Storage für rootfs (Default: local-lvm)
  --rootfs GB      Disk-Größe (Default: 16 – Proxmox empfiehlt 40 für Produktion)
  --cores N        vCPUs (Default: 2)
  --memory MB      RAM (Default: 2048 – offizielles Minimum 2+ GB)
  --swap MB        Swap (Default: 512)
  --bridge BR      Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR        Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
                   Empfehlenswert: feste IP (oder DHCP-Reservierung) – PDM
                   speichert Host-Credentials, die URL sollte stabil bleiben.
  --gateway GW     Gateway für statische IP
  --password PW    Root-Passwort (Default: automatisch generiert)
                   WICHTIG: DAS IST ZUGLEICH DER PDM-WEB-LOGIN (root@pam)!
  --sshkey PFAD    Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --repo REPO      pdm-no-subscription (Default) | pdm-test (neuere Versionen,
                   noch nicht "stabil")
  --force          Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y       Rückfragen überspringen
  --update         PDM im bestehenden Container aktualisieren (apt-Pakete)
  --uninstall      Container stoppen und löschen (ALLE Daten gehen verloren!)
  --status         Status anzeigen
  --debug          Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (Repo, Keyring, DNS) kommen als Umgebungsvariablen via
# `pct exec -- env …` in den Container. Das vermeidet Escaping-Gruben komplett.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# PDM In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: REPO_COMPONENT, KEYRING_URL, KEYRING_SHA256, HOST_DNS
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo "✘ $1" >&2; }
ok(){ echo "✔ $1"; }
die(){ err "$1"; exit 1; }

: "${REPO_COMPONENT:?REPO_COMPONENT fehlt (env)}"
: "${KEYRING_URL:?KEYRING_URL fehlt (env)}"
: "${KEYRING_SHA256:?KEYRING_SHA256 fehlt (env)}"
: "${PDM_META_PKG:?PDM_META_PKG fehlt (env)}"

echo ">>> Debian-Version prüfen (PDM-Repos: trixie/bookworm; keyring-URL braucht 13) ..."
CODENAME="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}")"
if [[ "$CODENAME" != "trixie" && "$CODENAME" != "bookworm" ]]; then
    die "Unbekanntes Debian ('$CODENAME') – PDM braucht Debian 12/13.\n  Debug: cat /etc/os-release"
fi
if [[ "$CODENAME" == "bookworm" ]]; then
    die "Debian 12 (bookworm) hat kein eigenes PDM-Keyring-Release – bitte Debian-13-Template nutzen.\n  Fix: Installer mit --force ausführen (legt den CT mit debian-13-standard neu an)"
fi
ok "Debian 13 (trixie) erkannt"

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
# dhclient-Hook: verhindert, dass Lease-Renewals /etc/resolv.conf überschreiben.
# (chattr +i funktioniert in unprivilegierten LXCs nicht – fehlendes Capability.)
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# PDM: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\noptions timeout:8 attempts:3 rotate\n' "${HOST_DNS}" > /etc/resolv.conf
chmod 0644 /etc/resolv.conf /etc/hosts /etc/nsswitch.conf 2>/dev/null || true

echo ">>> apt-Sandbox prüfen (Grube: _apt kann im unprivilegierten LXC nicht resolven) ..."
# apt's http-Methode läuft als _apt; kann der die Resolver-Dateien nicht lesen,
# meldet apt 'Temporary failure resolving' obwohl getent als root funktioniert
# (Live-Fund ZeitTracking: 7 Läufe, 2 Hosts). Rechte fixen, selbst testen,
# im Notfall als root arbeiten.
APT_OPTS=(-o Acquire::Retries=3)
if command -v runuser >/dev/null 2>&1 && id _apt >/dev/null 2>&1; then
    if ! runuser -u _apt -- getent hosts deb.debian.org >/dev/null 2>&1; then
        echo "    _apt kann nicht auflösen – korrigiere Dateirechte ..."
        chmod 0644 /etc/resolv.conf /etc/hosts /etc/nsswitch.conf 2>/dev/null || true
        if runuser -u _apt -- getent hosts deb.debian.org >/dev/null 2>&1; then
            ok "Benutzer _apt löst jetzt auf (Rechte korrigiert)"
        else
            echo "    _apt löst weiterhin nicht – apt-Methoden laufen als root (APT::Sandbox::User=root)"
            APT_OPTS+=(-o APT::Sandbox::User=root)
        fi
    else
        ok "apt-Sandbox (_apt) resolvt korrekt"
    fi
fi

echo ">>> curl sicherstellen (nacktes Debian-Template hat KEIN curl) ..."
# apt_retry: 4 Versuche mit Pause – das Netz im Zielnetz war live flaky
# (ZeitTracking: 7 Läufe bis grün), ein einzelner Versuch ist nicht belastbar.
apt_retry() {
    local attempt
    for attempt in 1 2 3 4; do
        if apt-get "${APT_OPTS[@]}" "$@"; then
            return 0
        fi
        [[ "$attempt" == "4" ]] && return 1
        echo "    apt-Versuch ${attempt} fehlgeschlagen – wiederhole in 10 s ..."
        sleep 10
    done
    return 1
}
if ! command -v curl >/dev/null 2>&1; then
    apt_retry update -qq || die "apt-get update schlägt dauerhaft fehl (curl-Bootstrap).\n  Debug: apt-get update   (voll, ohne -qq)   |  cat /etc/apt/sources.list"
    apt_retry install -y -qq curl ca-certificates >/dev/null || die "curl nicht installiert bekommen (apt-Fehler oben prüfen).\n  Debug: apt-get update && apt-get install -y curl"
fi
if ! command -v curl >/dev/null 2>&1; then
    die "curl nicht installiert bekommen (apt-Fehler oben prüfen).\n  Debug: apt-get update && apt-get install -y curl"
fi
ok "curl vorhanden: $(curl --version 2>/dev/null | head -1 | awk '{print $1, $2}')"

echo ">>> PDM-Keyring laden + SHA256 verifizieren (${KEYRING_URL}) ..."
mkdir -p /usr/share/keyrings
if [[ -f /usr/share/keyrings/proxmox-archive-keyring.gpg ]] \
   && echo "${KEYRING_SHA256}  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum --check --status 2>/dev/null; then
    ok "Keyring bereits vorhanden und korrekt (SHA256 stimmt)"
else
    curl -fsSL --retry 3 "${KEYRING_URL}" -o /usr/share/keyrings/proxmox-archive-keyring.gpg
    chmod 0644 /usr/share/keyrings/proxmox-archive-keyring.gpg
fi
if ! echo "${KEYRING_SHA256}  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum --check --status 2>/dev/null; then
    die "Keyring-SHA256 stimmt NICHT (erwartet ${KEYRING_SHA256}).\n  Download manipuliert oder Datei korrupt – NICHT installieren!\n  Debug: sha256sum /usr/share/keyrings/proxmox-archive-keyring.gpg"
fi
ok "Keyring korrekt (SHA256 verifiziert)"

echo ">>> APT-Quellen schreiben (deb822, Komponente: ${REPO_COMPONENT}) ..."
# Das PDM-Deb bringt /etc/apt/sources.list.d/pdm-enterprise.sources mit – ohne
# Subscription wirft jedes apt update darauf einen 404 (Exit 100). Deshalb
# IMMER VOR jedem apt-get update entfernen (idempotent).
rm -f /etc/apt/sources.list.d/pdm-enterprise.sources
cat > /etc/apt/sources.list.d/pdm-installer.sources <<SOURCES
Types: deb
URIs: http://download.proxmox.com/debian/pdm/
Suites: trixie
Components: ${REPO_COMPONENT}
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SOURCES
chmod 0644 /etc/apt/sources.list.d/pdm-installer.sources

echo ">>> apt update (mit PDM-Repo) ..."
apt_retry update -qq || die "apt-get update schlägt dauerhaft fehl.\n  Debug: apt-get update   (voll, ohne -qq)   |  cat /etc/apt/sources.list.d/pdm-installer.sources"
ok "apt-Index aktualisiert"

echo ">>> PDM installieren / aktualisieren (${PDM_META_PKG}) ..."
# container-meta = LXC-Variante: zieht manager + ui + client + docs, OHNE
# Kernel/ZFS-Gepäck (das LXC nutzt den Host-Kernel).
apt_retry install -y -qq "${PDM_META_PKG}" >/dev/null \
    || die "PDM-Pakete nicht installiert bekommen.\n  Debug: apt-get install -y ${PDM_META_PKG}"
ok "PDM-Pakete installiert ($(dpkg-query -W -f='${Version}' proxmox-datacenter-manager 2>/dev/null || echo '?'))"

echo ">>> pdm-enterprise.sources entfernen (Deb brachte sie (re)installiert mit) ..."
rm -f /etc/apt/sources.list.d/pdm-enterprise.sources

echo ">>> systemd-Services aktivieren (proxmox-datacenter-api + privileged-api) ..."
# Das Deb aktiviert beide selbst; explizit machen wir es trotzdem (idempotent,
# robust gegen entstoppelte Units):
systemctl daemon-reload
systemctl enable proxmox-datacenter-privileged-api proxmox-datacenter-api >/dev/null 2>&1 || true
systemctl restart proxmox-datacenter-privileged-api proxmox-datacenter-api

echo ">>> Warte auf Web-GUI (https://127.0.0.1:8443 – selbstsigniertes Zertifikat) ..."
UI_OK=""
for _ in $(seq 1 60); do
    code=$(curl -sk -o /dev/null --max-time 3 -w '%{http_code}' "https://127.0.0.1:8443/" || true)
    if [[ "$code" == "200" ]]; then
        UI_OK=1
        break
    fi
    sleep 3
done
if [[ -z "$UI_OK" ]]; then
    die "Web-GUI antwortet nicht mit 200 auf Port 8443 (letzter Code: ${code:-keiner}).\n  Debug: systemctl status proxmox-datacenter-api && journalctl -u proxmox-datacenter-api -e\n  Port prüfen: ss -tlnp | grep 8443"
fi
ok "Web-GUI antwortet (HTTPS 200 auf Port 8443)"

echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere PDM im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes war live unzuverlässig, siehe verify_ct_dns)
    HOST_DNS=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden (Grube 14).
    pct exec "$ct_id" -- env REPO_COMPONENT="$REPO_COMPONENT" \
        KEYRING_URL="$KEYRING_URL" KEYRING_SHA256="$KEYRING_SHA256" \
        PDM_META_PKG="$PDM_META_PKG" \
        HOST_DNS="${HOST_DNS:-1.1.1.1}" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/pdm-setup.log'
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # systemd-Services aktiv?
    for svc in $PDM_SERVICES; do
        tries=0
        while true; do
            if pct exec "$ct_id" -- systemctl is-active --quiet "$svc" 2>/dev/null; then
                ok "Service $svc läuft (systemctl is-active)"
                break
            fi
            tries=$((tries + 1))
            if [[ $tries -ge 30 ]]; then
                die "Service $svc läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u $svc -e && pct exec $ct_id -- systemctl status $svc"
            fi
            sleep 1
        done
    done

    # Web-GUI antwortet? (Grube: curl -w gibt bei Verbindungsfehler bereits
    # 000 aus – NIE zusätzlich || echo 000 anhängen, sonst falsch-positiv.)
    # -k nötig: PDM nutzt ein selbstsigniertes Zertifikat.
    tries=0
    while true; do
        code=$(pct exec "$ct_id" -- curl -sk -o /dev/null --max-time 3 -w '%{http_code}' \
               "https://127.0.0.1:${UI_PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-GUI antwortet (HTTPS 200 auf Port ${UI_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Web-GUI antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- journalctl -u proxmox-datacenter-api -e"
        fi
        sleep 2
    done

    # Erreichbarkeit vom PROXMOX-HOST aus (die Nutzer-URL läuft über die CT-IP;
    # im CT-Loopback kann alles OK sein, während eine Firewall draußen blockt).
    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
                    "https://${ct_ip}:${UI_PORT}/" || true)
        if [[ "$host_code" == "200" ]]; then
            ok "Vom Host erreichbar: https://${ct_ip}:${UI_PORT} (HTTPS 200)"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über https://${ct_ip}:${UI_PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🖥️  Proxmox Datacenter Manager ist bereit!"

    local ct_ip=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-UI:   https://${ct_ip}:${UI_PORT}${NC}"
    echo -e "  ${GREEN}  🔑 Login:    root@pam – Passwort: das CT-Root-Passwort${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}     (CT-Root-PW: ${CT_PASSWORD})${NC}"
    fi
    echo -e "  ${GREEN}  🐚 Terminal:  pct enter ${CT_ID}${NC}"
    echo -e "  ${GREEN}  🔧 Installer: v${INSTALLER_VERSION} (Repo ${REPO_COMPONENT})${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Browser-Warnung ist NORMAL:${NC} PDM nutzt ein selbstsigniertes"
    echo "  Zertifikat – Warnung bestätigen (oder später eigenes Zert via ACME)."
    echo ""
    echo -e "  ${CYAN}Deine Proxmox-Hosts verbinden (Add-Remote-Wizard):${NC}"
    echo "  1. https://${ct_ip}:${UI_PORT} öffnen, Login root@pam"
    echo "  2. Dashboard/Remotes → Add Remote → Proxmox VE Remote"
    echo "     - URL:          https://<PVE-Host-IP>:${PVE_PORT}"
    echo "     - Credentials:  root@pam des PVE-Hosts (oder API-Token)"
    echo "     - TLS-Fingerprint: im PVE-Host-GUI → Node → Zertifikate →"
    echo "       pve-ssl.pem ansehen (steht in der zweiten Zeile)"
    echo "     → PDM legt auf dem Host automatisch einen API-Token an"
    echo "  3. Für JEDEN weiteren Host wiederholen – danach erscheinen alle"
    echo "     VMs/CTs in einer Übersicht, inkl. Konsole (noVNC/xterm.js) und"
    echo "     Migration zwischen den Hosts."
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo ""
    warn "PDM speichert die Host-Credentials im CT (/var/lib/proxmox-datacenter-manager)"
    warn "– für Backups: pct backup ${CT_ID} (vzdump). pct destroy löscht alles."
    if [[ "$CT_IP" == "dhcp" ]]; then
        warn "CT hat DHCP – empfohlen: DHCP-Reservierung im Router (oder --ip beim Install),"
        warn "damit die PDM-URL stabil bleibt."
    fi
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "🖥️  Installiere Proxmox Datacenter Manager (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update:  ${ONE_LINER} --update\n  Neu aufsetzen:  ${ONE_LINER} --force"
        fi
    fi

    # Debian-13-Template (PDM-Keyring/Repo braucht trixie – 12 hat kein PDM-Keyring)
    header "🧱 Container-Template"
    # Arch-Filter (Live-Fund 2026-11-19, CT 212 auf ProxSmartHome): Der Host hat
    # BEIDE Arch-Templates gespeichert, und `sort -rV` sortiert arm64 VOR amd64
    # (r > d)! Falsches Arch → lxc "Failed to spawn" – pct create meldet trotzdem
    # Exit 0 (Exit-0-Täuschung). Deshalb EXPLIZIT die Host-Architektur matchen.
    local host_arch arch_tag
    host_arch=$(uname -m 2>/dev/null || echo "x86_64")
    case "$host_arch" in
        x86_64)  arch_tag="amd64" ;;
        aarch64) arch_tag="arm64" ;;
        *) die "Unbekannte Host-Architektur '$host_arch' – kein passendes Debian-13-Template ableitbar." ;;
    esac
    info "Host-Architektur: $host_arch → Template-Arch: $arch_tag"
    local template=""
    template=$(pveam list local 2>/dev/null | awk '{print $1}' | grep -o "debian-13-standard[^ ]*_${arch_tag}\.tar\.zst" | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        info "Kein Debian-13-${arch_tag}-Template vorhanden – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null | grep -o "debian-13-standard[^ ]*_${arch_tag}\.tar\.zst" | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            die "Kein debian-13-standard-Template für ${arch_tag} gefunden (pveam available leer?).\n  PDM braucht Debian 13 (trixie) – Debian-12-Container werden nicht unterstützt."
        fi
        pveam download local "$template"
    fi
    ok "Template: $template"

    # ID & Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="pdm-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    net0+=",firewall=0"
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    ok "Container $CT_ID erstellt"
    verify_ct_started "$CT_ID"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update PDM (apt-Pakete aktualisieren)"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.\n  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – PDM-Daten (/var/lib/proxmox-datacenter-manager) blieben erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere PDM"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "ALLE Daten gehen verloren: PDM-Datenbank, gespeicherte Host-Credentials."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status PDM"
    info "Installer-Version: v${INSTALLER_VERSION}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ") – " $NF}'

    # Gestoppten CT nicht als "Service läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Services/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    local svc
    for svc in $PDM_SERVICES; do
        if pct exec "$ct_id" -- systemctl is-active --quiet "$svc" 2>/dev/null; then
            ok "Service:   $svc läuft"
        else
            err "Service:   $svc läuft NICHT"
            info "Logs:      pct exec $ct_id -- journalctl -u $svc -e"
        fi
    done

    local pdm_version
    # SC2016 bewusst: '${Version}' ist dpkg-query-Formatliteral, KEINE Shell-Expansion
    # shellcheck disable=SC2016
    pdm_version=$(pct exec "$ct_id" -- dpkg-query -W -f='${Version}' "$PDM_MAIN_PKG" 2>/dev/null || true)
    if [[ -n "$pdm_version" ]]; then
        ok "PDM:       v$pdm_version"
    else
        warn "PDM-Paket: nicht gefunden (Installation unvollständig? → ${ONE_LINER} --update)"
    fi

    # Vom Paket mitgebrachte enterprise.sources regelmäßiger Ärgernis-Check
    if pct exec "$ct_id" -- sh -c 'test -f /etc/apt/sources.list.d/pdm-enterprise.sources' 2>/dev/null; then
        warn "pdm-enterprise.sources wieder vorhanden (Deb-Update?) – --update entfernt sie erneut"
    fi

    local ip code=""
    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${ip}:${UI_PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI:    https://${ip}:${UI_PORT}  (HTTPS 200)"
        else
            warn "Web-UI:    HTTP-Code ${code:-unbekannt} von https://${ip}:${UI_PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi
