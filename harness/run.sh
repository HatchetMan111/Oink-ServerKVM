#!/usr/bin/env bash
# =============================================================================
#  🧪 DatacenterManager-Proxmox – Mock-Harness
#  Testet install/pdm.sh End-to-End gegen gemockte Proxmox-/APT-Umgebung:
#   - `unshare -rm` mappt den Harness-User auf root (EUID-Prüfung des Scripts)
#   - pct/pveam/curl/apt-get/systemctl/getent/dpkg-query als Mocks (Fakebin)
#   - Inner-Script läuft ECHT (nur Pfade auf Mock-Root umgeschrieben; apt,
#     systemctl, curl, dpkg-query gemockt) – inkl. Bootstrap-Reihenfolge
#     (nacktes Debian: kein curl → apt "installiert" curl)
#   - Keyring-Fixture = ECHTE Proxmox-Keyring-Bytes (base64) → der SHA256-Check
#     des Installers läuft im Harness mit der echten Prüfsumme durch
#  Usage: bash harness/run.sh   (Exit 0 = alle Cases grün; HARNESS_KEEP=1 behält /tmp)
# =============================================================================
set -u
SCRIPT="/home/phil/Proxmox-Scripts/Oink-ServerKVM/install/pdm.sh"
[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }

MK=$(mktemp -d /tmp/pdm-harness.XXXXXX)
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK"; fi' EXIT
HS="$MK/state"                       # Mock-Status (ct_list, Calls, Hebel)
HOSTBIN="$MK/bin-host"               # Mocks für das HOST-Script
INNERBIN="$MK/bin-inner"             # Mocks für pct-exec (im CT)
CASES="$MK/cases"; mkdir -p "$HS" "$HOSTBIN" "$INNERBIN" "$CASES" \
    "$MK/etc" "$MK/root" "$MK/var/log" "$MK/tmp" \
    "$MK/etc/apt/sources.list.d" "$MK/usr/share/keyrings" "$MK/usr/lib/systemd/system"
CT_IP="10.120.5.42"
# SHA256 des echten Proxmox-Keyrings (offizielle PDM-Doku; 2026-11-18 selbst verifiziert)
KEY_SHA="136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45"

# Keyring-Fixture (ECHTE Bytes – sha256sum im Installer prüft die echte Summe)
cat > "$MK/keyring.b64" <<'B64EOF'
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
B64EOF
: > "$HS/ct_list"                    # Zeilen: "VMID Status Lock-Name(=Name letztes Feld)"
echo "$CT_IP" > "$HS/ct_ip"
echo "getent_mode=ok" > "$HS/getent_mode"

PASSED=0; FAILED=0; CUR_NAME=""; CUR_DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR_NAME – $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR_NAME – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }

t()    { CUR_NAME="$1"; CUR_DIR=$(mktemp -d "$CASES/case.XXXXXX"); }
assert_exit() {
    local want="$1" got="$2"
    if [[ "$got" == "$want" ]]; then pass "exit=$got (erwartet $want)"
    else fail "exit=$got, erwartet $want"; fi
}
assert_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
assert_no_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht: $1"; fi
}
assert_file() {
    if [[ -f "$1" ]]; then pass "Datei: $1"
    else fail "Datei fehlt: $1"; fi
}
assert_no_file() {
    if [[ -f "$1" ]]; then fail "Datei existiert (sollte nicht): $1"
    else pass "Datei fehlt (korrekt): $1"; fi
}
assert_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then pass "$1 enthält: $2"
    else fail "$1 enthält NICHT: $2"; fi
}
assert_no_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then fail "$1 enthält (sollte nicht): $2"
    else pass "$1 ohne: $2"; fi
}
assert_fregex() {
    if [[ -f "$1" ]] && /bin/grep -qE -- "$2" "$1"; then pass "$1 matcht: $2"
    else fail "$1 matcht NICHT: $2"; fi
}
assert_calls() { # COUNT needle in mock-calls log (pct/systemctl/apt/curl)
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Calls ≥$want: $needle (ist $got)"
    else fail "Calls <$want: $needle (ist $got)"; fi
}
assert_no_calls() {
    if /bin/grep -qF -- "$1" "$HS/calls.log" 2>/dev/null; then fail "Unerwarteter Call: $1"
    else pass "Kein Call: $1"; fi
}

# ── Mock-Umgebung bauen (env -i: Profil-Funktionen wie grep→ugrep meiden) ──
realbin() { env -i /bin/sh -c "command -v $1" || { echo "✘ real binary fehlt: $1"; exit 1; }; }
link_real() { # echte Binaries per Symlink verfügbar halten (Shadowing via PATH-Reihenfolge)
    local dest="$1"; shift
    local b
    for b in "$@"; do ln -sf "$(realbin "$b")" "$dest/$b"; done
}
link_real "$HOSTBIN" bash sh env awk sed grep cut head tail tr od mktemp tee openssl \
    seq cat mv cp rm mkdir chmod dirname basename sort uniq readlink date printf ls touch \
    stat id uname hostname sha256sum base64
ln -sf "$MK/mock-pct"   "$HOSTBIN/pct"
ln -sf "$MK/mock-pveam" "$HOSTBIN/pveam"
ln -sf "$MK/mock-curl"  "$HOSTBIN/curl"
ln -sf "$MK/mock-sleep" "$HOSTBIN/sleep"
ln -sf "$MK/mock-sleep" "$INNERBIN/sleep"
# uname-Mock (HOST-Seite): Host-Arch per Hebel $HS/host_arch umschaltbar
# (x86_64 = Default) – arm64-Host-Szenario ProxSmartHome testbar.
cat > "$MK/mock-uname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
ARCH="x86_64"
[[ -f "$HS/host_arch" ]] && ARCH=$(/bin/cat "$HS/host_arch")
echo "$ARCH"
exit 0
EOF
ln -sf "$MK/mock-uname" "$HOSTBIN/uname"

# ── Inner-Fakebin: nacktes Debian simulieren (KEIN curl, KEINE pdm-Pakete) ──
# PATH im Inner ist AUSSCHLIESSLICH $INNERBIN (kein /usr/bin!) – sonst würde
# ein echtes curl des Desktops das Bootstrap-Design aushebeln.
link_real "$INNERBIN" bash sh env awk sed grep cut head tail tr od seq cat mv cp rm \
    mkdir chmod dirname basename sort uniq printf ls touch readlink stat uname \
    tee id sha256sum base64 wc ln openssl
ln -sf "$MK/mock-aptget"    "$INNERBIN/apt-get"
ln -sf "$MK/mock-systemctl" "$INNERBIN/systemctl"
ln -sf "$MK/mock-hostname"  "$INNERBIN/hostname"
ln -sf "$MK/mock-getent"    "$INNERBIN/getent"
ln -sf "$MK/mock-dpkgq"     "$INNERBIN/dpkg-query"

seed_inner_tools() { # simuliert bereits installiertes curl (Update-Pfad)
    ln -sf "$MK/mock-curl" "$INNERBIN/curl"
}
unseed_inner_tools() {
    rm -f "$INNERBIN/curl"
}

# ══════════════════════════ Mock-Binaries ══════════════════════════════════
cat > "$MK/mock-sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-pct" <<'EOF'
#!/usr/bin/env bash
# pct-Mock: State in $HARNESS_STATE, Mock-Root = dirname davon
set -u
HS="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MK="$(dirname "$HS")"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"; id="${2:-}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ $# -gt 0 ]]; then shift; fi

case "$cmd" in
    list)
        printf 'VMID       Status     Lock Name\n'
        [[ -s "$HS/ct_list" ]] && cat "$HS/ct_list"
        exit 0 ;;
    status)
        f="$HS/ct_${id}.status"
        [[ -f "$f" ]] || exit 2
        echo "status: $(cat "$f")"; exit 0 ;;
    create)
        # pct create ID TEMPLATE --flags...
        if [[ -f "$HS/create_fail" ]]; then echo "mock: create fehlgeschlagen" >&2; exit 255; fi
        tmpl="$1"; shift
        tmpl_base="${tmpl##*/}"
        if [[ ! -f "$HS/templates/$tmpl_base" ]]; then
            echo "mock: Template $tmpl nicht vorhanden" >&2; exit 2
        fi
        { echo "TEMPLATE=$tmpl"; echo "ARGS=$*"; } > "$HS/ct_${id}.create"
        hostname="ct-$id"
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
            prev="$a"
        done
        echo "$hostname" > "$HS/ct_${id}.hostname"
        if [[ -f "$HS/spawn_fail" ]]; then
            # Exit-0-Täuschung (Live-Fund CT 212): create "erfolgreich",
            # Spawn knallt aber → CT bleibt gestoppt, pct create meldet Exit 0
            echo "$id stopped $hostname" >> "$HS/ct_list"
            echo "stopped" > "$HS/ct_${id}.status"
        else
            echo "$id running $hostname" >> "$HS/ct_list"
            echo "running" > "$HS/ct_${id}.status"
        fi
        exit 0 ;;
    start)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "running" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id running $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    stop)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "stopped" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    destroy)
        /bin/sed -i "/^$id /d" "$HS/ct_list"
        rm -f "$HS/ct_${id}".status "$HS/ct_${id}".create "$HS/ct_${id}".hostname
        exit 0 ;;
    push)
        src="$1"; dst="$2"; shift 2
        mkdir -p "$MK$(dirname "$dst")"
        # Inner-Script: Pfade auf Mock-Root umschreiben. Reihenfolge WICHTIG:
        # /tmp zuerst – die folgenden Ersetzungen injizieren selbst ein /tmp/
        # (Mock-Root liegt unter /tmp) und würden doppelt umgeschrieben.
        /bin/sed -e "s|/tmp/|$MK/tmp/|g" -e "s|/etc/|$MK/etc/|g" \
                 -e "s|/usr/share/keyrings|$MK/usr/share/keyrings|g" \
                 -e "s|/var/log|$MK/var/log|g" \
                 -e "s|/usr/lib/systemd|$MK/usr/lib/systemd|g" \
                 "$src" > "$MK$dst"
        exit 0 ;;
    exec)
        # pct exec ID -- env K=V... cmd...   (Grube 10: gestoppter CT → Exit 255)
        [[ "${1:-}" == "--" ]] && shift
        envs=()
        if [[ "${1:-}" == "env" ]]; then
            shift
            while [[ "${1:-}" == *=* && "${1:-}" != -* ]]; do envs+=("$1"); shift; done
        fi
        if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
            echo "mock: CT $id läuft nicht" >&2
            echo "pct exec $id (ABGELEHNT – CT gestoppt)" >> "$HS/calls.log"
            exit 255
        fi
        if [[ -f "$HS/exec_fail" ]]; then
            echo "mock: exec erzwingt Fehler" >&2
            exit 255
        fi
        # Quoted-Heredoc: INNERBIN erst zur LAUFZEIT ableiten ($MK = dirname($HS))
        INNERBIN="$MK/bin-inner"
        # Pfad-Umschreibung: Kommando-Args UND env-Args (Mock-Root).
        # /etc auch umschreiben – sonst schreibt der DNS-Fallback des Installers
        # ins echte /etc der Sandbox!
        rewrite_path() {
            local a="$1"
            a="${a//\/root\//$MK/root/}"
            a="${a//\/var\/log/$MK/var/log}"
            a="${a//\/etc\//$MK/etc/}"
            printf '%s' "$a"
        }
        newargs=()
        for a in "$@"; do
            newargs+=("$(rewrite_path "$a")")
        done
        newenvs=()
        for a in ${envs[@]+"${envs[@]}"}; do
            newenvs+=("$(rewrite_path "$a")")
        done
        exec env -i PATH="$INNERBIN" \
            HARNESS_STATE="$HS" MKROOT="$MK" \
            HOME=/root TERM=dumb LANG=C.UTF-8 \
            ${newenvs[@]+"${newenvs[@]}"} \
            "${newargs[@]}"
        ;;
    enter|config|rollback|clone|resume|suspend|reboot|snapshot|delvolume|mount|resize|move|reindex|set)
        exit 0 ;;
    *)
        echo "mock-pct: unbekannter Befehl $cmd" >&2; exit 1 ;;
esac
EOF

cat > "$MK/mock-pveam" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pveam $*" >> "$HS/calls.log"
# Arch-bewusst: list zeigt, was im templates-Dir LIEGT (getrennt pro Arch),
# available bietet das Host-Arch an (Live-Szenario ProxSmartHome: BEIDE Arches
# liegen lokal, Installer muss per uname -m das richtige wählen).
ARCH="x86_64"
[[ -f "$HS/host_arch" ]] && ARCH=$(/bin/cat "$HS/host_arch")
TAG="amd64"; [[ "$ARCH" == "aarch64" ]] && TAG="arm64"
case "${1:-}" in
    list)
        for f in "$HS"/templates/debian-13-standard*_"${TAG}".tar.zst; do
            [[ -f "$f" ]] && echo "local:vztmpl/$(basename "$f")  123456789"
        done
        exit 0 ;;
    available)
        if [[ ! -f "$HS/pveam_empty" ]]; then
            echo "system          local:vztmpl/debian-13-standard_13.2-1_${TAG}.tar.zst  123456789"
        fi
        exit 0 ;;
    update)   exit 0 ;;
    download)
        mkdir -p "$HS/templates"
        name="${3##*/}"
        [[ -z "$name" ]] && name="debian-13-standard_13.2-1_${TAG}.tar.zst"
        touch "$HS/templates/$name"
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-curl" <<'EOF'
#!/usr/bin/env bash
# curl-Mock: Keyring-Download → echte Fixture-Bytes; Health-Checks → 200/000
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "curl 8.11.1 (mock)"; exit 0
fi
url=""; outfile=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "-o" ]]; then outfile="$a"; fi
    case "$a" in http://*|https://*) url="$a" ;; esac
    prev="$a"
done
echo "curl $*" >> "$HS/calls.log" 2>/dev/null || true

case "$url" in
    https://enterprise.proxmox.com/*keyring*)
        [[ -n "$outfile" ]] || { echo "curl mock: keyring-URL ohne -o" >&2; exit 1; }
        if [[ -f "$HS/keyring_bad" ]]; then
            printf 'CORRUPTED-KEYRING-BAIT' > "$outfile"
        else
            base64 -d "$MK/keyring.b64" > "$outfile"
        fi
        exit 0 ;;
esac

# Health-/HTTP-Checks (host_curl_fail gilt NUR auf Host-Ebene; inner erkennt
# man an MKROOT)
code="200"
if [[ -f "$HS/host_curl_fail" && -z "${MKROOT:-}" ]]; then
    code="000"
fi
case "$url" in
    https://127.0.0.1:8443*) [[ -f "$HS/fail_ui" ]] && code="000" ;;
    https://*:8443*)         [[ -f "$HS/fail_ui" ]] && code="000" ;;
    http://127.0.0.1:*)      code="000" ;;
esac
echo "$code"
[[ "$code" == "200" ]] && exit 0 || exit 7
EOF

cat > "$MK/mock-aptget" <<'EOF'
#!/usr/bin/env bash
# apt-Mock: installiert curl real in der Inner-Fakebin (Bootstrap-Reihenfolge);
# PDM-Meta-Install erzeugt Unit-Dateien + (Deb-Verhalten!) pdm-enterprise.sources
# (Der Installer ruft apt via apt_retry als `apt-get -o OPT install ...` auf –
#  deshalb generische Flag/Unterkommando-Erkennung statt cmd=$1.)
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
INNERBIN_DIR="$MK/bin-inner"
echo "apt-get $*" >> "$HS/calls.log"
is_update=false; is_install=false
for a in "$@"; do
    [[ "$a" == "update" ]] && is_update=true
    [[ "$a" == "install" ]] && is_install=true
done
if $is_update; then
    [[ -f "$HS/apt_update_fail" ]] && exit 100
    exit 0
fi
if $is_install; then
    if [[ -f "$HS/pdm_install_fail" ]]; then exit 100; fi
    prev=""
    for a in "$@"; do
        case "$a" in
            -*|"Acquire::Retries=3") prev="$a"; continue ;;   # Flags + -o-Wert überspringen
        esac
        if [[ "$prev" == "-o" ]]; then prev="$a"; continue; fi
        if [[ "$a" == "curl" && ! -e "$INNERBIN_DIR/curl" ]]; then
            ln -sf "$MK/mock-curl" "$INNERBIN_DIR/curl"
        fi
        if [[ "$a" == proxmox-datacenter-manager-container-meta ]]; then
            touch "$HS/pdm_installed"
            mkdir -p "$MK/usr/lib/systemd/system"
            cat > "$MK/usr/lib/systemd/system/proxmox-datacenter-api.service" <<'UNIT'
[Unit]
Description=Proxmox Datacenter Manager API daemon (mock)
[Service]
ExecStart=/bin/true
[Install]
WantedBy=multi-user.target
UNIT
            cat > "$MK/usr/lib/systemd/system/proxmox-datacenter-privileged-api.service" <<'UNIT'
[Unit]
Description=Proxmox Datacenter Manager privileged API daemon (mock)
[Service]
ExecStart=/bin/true
[Install]
WantedBy=multi-user.target
UNIT
            mkdir -p "$MK/etc/apt/sources.list.d"
            printf 'Types: deb\nURIs: https://enterprise.proxmox.com/debian/pdm/\nSuites: trixie\nComponents: pdm-enterprise\n' \
                > "$MK/etc/apt/sources.list.d/pdm-enterprise.sources"
        fi
    done
    exit 0
fi
exit 0
EOF

cat > "$MK/mock-systemctl" <<'EOF'
#!/usr/bin/env bash
# systemctl-Mock: Unit-Dateien müssen existieren (apt-Mock erzeugt sie);
# is-active verlangt gestartet-Marker
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
echo "systemctl $*" >> "$HS/calls.log"
MKDIR_MOCK="$MK"
unitdir="$MKDIR_MOCK/usr/lib/systemd/system"
sub="${1:-}"
case "$sub" in
    daemon-reload) exit 0 ;;
    enable)
        now=false
        shift
        for a in "$@"; do
            case "$a" in
                --now) now=true ;;
                -*) : ;;
                *)
                    mkdir -p "$unitdir"
                    [[ -f "$unitdir/$a.service" ]] || { echo "mock: Unit $a.service fehlt" >&2; exit 1; }
                    echo "$a" >> "$HS/enabled_units"
                    if $now; then touch "$HS/svc_active_$a"; fi ;;
            esac
        done
        exit 0 ;;
    start|restart)
        shift
        for a in "$@"; do
            [[ -f "$unitdir/$a.service" ]] || { echo "mock: Unit $a.service fehlt" >&2; exit 1; }
            touch "$HS/svc_active_$a"
        done
        exit 0 ;;
    stop)
        shift
        for a in "$@"; do rm -f "$HS/svc_active_$a"; done
        exit 0 ;;
    is-active)
        svc="${3:-${2:-}}"
        if [[ -f "$HS/svc_active_$svc" ]]; then exit 0; fi
        exit 3 ;;
    status) echo "mock: ${2:-} active-ish"; exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "$MK/mock-hostname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_hostname_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
if [[ "${1:-}" == "-I" ]]; then printf '%s 2601:db8::1 \n' "$IP"; exit 0; fi
echo "kvmoink"; exit 0
EOF

cat > "$MK/mock-getent" <<'EOF'
#!/usr/bin/env bash
# DNS-Mock: ok | fail | fail_then_ok (9x fail, dann ok → Fallback greift)
set -u
HS="${HARNESS_STATE:?}"
mode="ok"
[[ -f "$HS/getent_mode" ]] && mode=$(/bin/sed -n 's/^getent_mode=//p' "$HS/getent_mode")
case "$mode" in
    ok) exit 0 ;;
    fail) exit 2 ;;
    fail_then_ok)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        [[ "$n" -le 9 ]] && exit 2
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-dpkgq" <<'EOF'
#!/usr/bin/env bash
# dpkg-query-Mock: Version nur melden, wenn pdm "installiert" ist
set -u
HS="${HARNESS_STATE:?}"
echo "dpkg-query $*" >> "$HS/calls.log" 2>/dev/null || true
if [[ -f "$HS/pdm_installed" ]]; then
    echo "1.1.10-mock"
    exit 0
fi
exit 1
EOF

chmod +x "$MK"/mock-* "$MK"/bin-host/* "$MK"/bin-inner/* 2>/dev/null

# ── Runner ─────────────────────────────────────────────────────────────────
reset_state() {
    rm -rf "$HS"
    # WICHTIG: auch den MOCK-ROOT zurücksetzen – sonst bleibt z. B. der Keyring
    # eines früheren Cases liegen und der Download-Pfad (echter curl-Call +
    # SHA256-Check) würde in Folge-Cases nie wieder ausgeführt.
    rm -rf "${MK:?}/etc" "${MK:?}/usr" "${MK:?}/var" "${MK:?}/root" "${MK:?}/opt"
    mkdir -p "$HS" "$HS/templates" \
        "$MK/etc/apt/sources.list.d" "$MK/etc/dhcp" "$MK/usr/share/keyrings" \
        "$MK/usr/lib/systemd/system" "$MK/root" "$MK/var/log" "$MK/tmp"
    echo "$CT_IP" > "$HS/ct_ip"
    : > "$HS/ct_list"
    echo "getent_mode=ok" > "$HS/getent_mode"
    echo "x86_64" > "$HS/host_arch"
    printf 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nVERSION_CODENAME=trixie\nID=debian\n' > "$MK/etc/os-release"
}
run_installer() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_stdin() {
    local input="$1"; shift
    ( printf '%s' "$input" | unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_devnull() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" < /dev/null > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
seed_ct() { # laufender CT mit installiertem PDM
    reset_state
    echo "200 running kvmoink" > "$HS/ct_list"
    echo "running" > "$HS/ct_200.status"
    echo "kvmoink" > "$HS/ct_200.hostname"
    mkdir -p "$MK/etc/apt/sources.list.d" "$MK/usr/lib/systemd/system" "$MK/usr/share/keyrings" "$MK/var/log" "$MK/root"
    seed_inner_tools
    touch "$HS/pdm_installed"
    touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
    touch "$MK/usr/lib/systemd/system/proxmox-datacenter-api.service" \
          "$MK/usr/lib/systemd/system/proxmox-datacenter-privileged-api.service"
    touch "$HS/svc_active_proxmox-datacenter-api" "$HS/svc_active_proxmox-datacenter-privileged-api"
    printf 'proxmox-datacenter-api\nproxmox-datacenter-privileged-api\n' > "$HS/enabled_units"
    printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pdm/\nSuites: trixie\nComponents: pdm-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
        > "$MK/etc/apt/sources.list.d/pdm-installer.sources"
    printf 'Types: deb\nURIs: https://enterprise.proxmox.com/debian/pdm/\nSuites: trixie\nComponents: pdm-enterprise\n' \
        > "$MK/etc/apt/sources.list.d/pdm-enterprise.sources"   # Deb-Verhalten simulieren
    base64 -d "$MK/keyring.b64" > "$MK/usr/share/keyrings/proxmox-archive-keyring.gpg"
}

SOURCES_FILE="$MK/etc/apt/sources.list.d/pdm-installer.sources"
KEYRING_FILE="$MK/usr/share/keyrings/proxmox-archive-keyring.gpg"
UNITDIR="$MK/usr/lib/systemd/system"

echo "════════════════════════════════════════════════════════════"
echo " 🧪 Oink-ServerKVM Harness – $(date +%H:%M:%S)"
echo "════════════════════════════════════════════════════════════"

# ════════════════ A. Argumente & Grundlagen ════════════════
t "--help"
ec=$(run_installer --help); assert_exit 0 "$ec"
assert_out "Proxmox Datacenter Manager (PDM) – Proxmox-Installer"
assert_out "--update"

t "unbekannte Option"
ec=$(run_installer --schnulli); assert_exit 1 "$ec"
assert_out "Unbekannte Option: --schnulli"

t "--repo ungültig"
ec=$(run_installer --repo lederhosen); assert_exit 1 "$ec"
assert_out "Ungültiges Repo: 'lederhosen'"

t "\$0-Fallback (bash -c-Muster)"
ec=$( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
      bash -c "$(<"$SCRIPT")" --status > "$CUR_DIR/out.log" 2>&1; echo $? )
assert_exit 0 "$ec"
assert_out "Status PDM"

t "\$0-Fallback Copy-Paste-Falle: \" --status (überzähliges Anführungszeichen → \$0 mit Leerzeichen)"
ec=$( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
      bash -c "$(<"$SCRIPT")" " --status" > "$CUR_DIR/out.log" 2>&1; echo $? )
assert_exit 0 "$ec"
assert_out "Status PDM"

t "\$0-Fallback Copy-Paste-Falle: \" --id 210 → Option wird erkannt (Live-Bug 2026-11-19)"
reset_state
ec=$( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
      bash -c "$(<"$SCRIPT")" " --id 210" > "$CUR_DIR/out.log" 2>&1; echo $? )
assert_exit 0 "$ec"
assert_out "Erzeuge Container 210"
assert_calls 1 "pct create 210"

t "nächste freie CT-ID (200-202 belegt)"
reset_state
printf '200 running foo\n201 running bar\n202 running baz\n' > "$HS/ct_list"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Nächste freie CT-ID: 203"
assert_fcontains "$HS/ct_203.create" "hostname kvmoink"

t "pct list ohne Lock-Spalte (Name \$NF)"
reset_state
printf '200 running kvmoink\n' > "$HS/ct_list"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – kvmoink"

t "pct list mit doppeltem Leerzeichen (Lock leer)"
reset_state
printf '200 running  kvmoink\n' > "$HS/ct_list"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – kvmoink"

# ════════════════ B. Install Happy Path ════════════════
t "Install End-to-End (nacktes Debian: curl bootstrappen, Keyring, Repo, Paket, Services)"
reset_state
unseed_inner_tools
ec=$(run_installer); assert_exit 0 "$ec"

assert_out "Container-IP: $CT_IP"
assert_out "DNS im Container funktioniert (3x bestätigt)"
assert_out "Debian 13 (trixie) erkannt"
assert_out "debian-13-standard_13.2"
assert_calls 1 "pct create 200"
assert_fcontains "$HS/ct_200.create" "unprivileged"
assert_no_fcontains "$HS/ct_200.create" "nesting"          # PDM braucht kein Docker
assert_fcontains "$HS/ct_200.create" "onboot 1"
assert_fcontains "$HS/ct_200.create" "memory 2048"
assert_fregex "$HS/ct_200.create" "rootfs local-lvm:16"
assert_fcontains "$HS/ct_200.create" "firewall=0"
assert_calls 1 "install -y -qq"
assert_file "$KEYRING_FILE"
got_sha=$(sha256sum "$KEYRING_FILE" 2>/dev/null | awk '{print $1}')
if [[ "$got_sha" == "$KEY_SHA" ]]; then
    pass "Keyring-SHA256 == offizielle Prüfsumme"
else
    fail "Keyring-SHA256 falsch: ${got_sha:-unbekannt}"
fi
assert_fcontains "$SOURCES_FILE" "Types: deb"
assert_fcontains "$SOURCES_FILE" "URIs: http://download.proxmox.com/debian/pdm/"
assert_fcontains "$SOURCES_FILE" "Suites: trixie"
assert_fcontains "$SOURCES_FILE" "Components: pdm-no-subscription"
assert_fregex "$SOURCES_FILE" 'Signed-By: .*proxmox-archive-keyring\.gpg'   # Mock-Pfad-Umschreibung → regex
assert_no_file "$MK/etc/apt/sources.list.d/pdm-enterprise.sources"   # Deb brachte sie mit – Installer entfernt
assert_file "$UNITDIR/proxmox-datacenter-api.service"
assert_file "$UNITDIR/proxmox-datacenter-privileged-api.service"
assert_file "$MK/var/log/pdm-setup.log"
assert_calls 1 "systemctl enable proxmox-datacenter-privileged-api proxmox-datacenter-api"
assert_calls 1 "systemctl restart proxmox-datacenter-privileged-api proxmox-datacenter-api"
if [[ -f "$HS/svc_active_proxmox-datacenter-api" ]]; then
    pass "Service aktiv nach Install"
else
    fail "svc_active fehlt"
fi
assert_out "Web-GUI antwortet (HTTPS 200 auf Port 8443)"

# Zusammenfassung-Asserts (gleiches out.log)
assert_out "🖥️  Proxmox Datacenter Manager ist bereit!"
assert_out "https://$CT_IP:8443"
assert_out "root@pam – Passwort: das CT-Root-Passwort"
assert_out "Add Remote"
assert_out "https://<PVE-Host-IP>:8006"
assert_out "TLS-Fingerprint"
assert_out "Status:    bash -c"
assert_out "Update:    bash -c"
assert_out "Deinstall: bash -c"

t "Bootstrap-Reihenfolge: apt curl-Install VOR Keyring-Download"
# (State noch aus dem E2E-Case da – frisches calls.log pro Case, deshalb eigener Run)
reset_state
unseed_inner_tools
: > "$HS/calls.log"
ec=$(run_installer); assert_exit 0 "$ec"
first_apt=$(/bin/grep -n '^apt-get ' "$HS/calls.log" | head -1 | cut -d: -f1 || echo 99999)
first_keyring=$(/bin/grep -n '^curl .*enterprise.proxmox.com' "$HS/calls.log" | head -1 | cut -d: -f1 || echo 0)
if [[ "$first_apt" -lt "$first_keyring" ]]; then
    pass "apt-get (Zeile $first_apt) vor Keyring-Download (Zeile $first_keyring)"
else
    fail "Bootstrap-Reihenfolge: apt=$first_apt, keyring=$first_keyring"
fi

t "Install mit --repo test"
reset_state; unseed_inner_tools
ec=$(run_installer --repo test); assert_exit 0 "$ec"
assert_fcontains "$SOURCES_FILE" "Components: pdm-test"
assert_no_fcontains "$SOURCES_FILE" "Components: pdm-no-subscription"

t "Install mit statischer IP (--ip)"
reset_state; unseed_inner_tools
echo "192.168.178.77" > "$HS/ct_ip"   # hostname-Mock liefert die statische IP
ec=$(run_installer --ip 192.168.178.77/24 --gateway 192.168.178.1); assert_exit 0 "$ec"
cp "$HS/ct_200.create" "$CUR_DIR/create.snapshot" 2>/dev/null || true
assert_fcontains "$CUR_DIR/create.snapshot" "ip=192.168.178.77/24,gateway=192.168.178.1"
assert_out "https://192.168.178.77:8443"

t "Install mit --memory 4096 --rootfs 32"
reset_state; unseed_inner_tools
ec=$(run_installer --memory 4096 --rootfs 32); assert_exit 0 "$ec"
assert_fcontains "$HS/ct_200.create" "memory 4096"
assert_fregex "$HS/ct_200.create" "rootfs local-lvm:32"

t "sshkey-Install (--sshkey Datei)"
reset_state; unseed_inner_tools
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test@host\n' > "$MK/testkey.pub"
ec=$(run_installer --sshkey "$MK/testkey.pub"); assert_exit 0 "$ec"
assert_fcontains "$HS/ct_200.create" "ssh-public-keys"

t "sshkey-Datei fehlt → die"
reset_state
ec=$(run_installer --sshkey /nicht/da.pub); assert_exit 1 "$ec"
assert_out "SSH-Key-Datei nicht gefunden"

# ════════════════ C. Fehlerpfade Install ════════════════
t "Keyring manipuliert → SHA256-Check die"
reset_state; unseed_inner_tools
touch "$HS/keyring_bad"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Keyring-SHA256 stimmt NICHT"
assert_out "NICHT installieren"
rm -f "$HS/keyring_bad"

t "apt update tot → 4 Versuche, dann die (beim curl-Bootstrap, daher andere Debug-Zeile)"
reset_state; unseed_inner_tools
touch "$HS/apt_update_fail"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "apt-get update schlägt dauerhaft fehl"
assert_out "voll, ohne -qq"
rm -f "$HS/apt_update_fail"

t "PDM-Paket-Install tot → die"
reset_state; unseed_inner_tools
touch "$HS/pdm_install_fail"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Installationsfehler – Exit-Code 1"
assert_out "Fehlgeschlagener Befehl"
assert_out "Container 200 wurde NICHT gelöscht"
rm -f "$HS/pdm_install_fail"

t "Web-GUI Health tot → die mit Debug-Hinweis"
reset_state; unseed_inner_tools
touch "$HS/fail_ui"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Web-GUI antwortet nicht mit 200 auf Port 8443"
assert_out "journalctl -u proxmox-datacenter-api"
assert_out "ss -tlnp | grep 8443"
rm -f "$HS/fail_ui"

t "Debian 12 (bookworm) im CT → die (kein PDM-Keyring)"
reset_state; unseed_inner_tools
printf 'VERSION_CODENAME=bookworm\nID=debian\n' > "$MK/etc/os-release"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Debian 12 (bookworm) hat kein eigenes PDM-Keyring-Release"

t "unbekanntes Debian im CT → die"
reset_state; unseed_inner_tools
printf 'VERSION_CODENAME=winniehohl\nID=debian\n' > "$MK/etc/os-release"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Unbekanntes Debian ('winniehohl')"

t "keine Container-IP → Fehlerkette (on_error)"
reset_state
touch "$HS/no_hostname_ip"   # hostname -I bleibt leer → Poll läuft 60x leer → on_error
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Container hat nach 60 s keine IP bekommen"
assert_out "Installationsfehler – Exit-Code 1"
assert_out "Fehlgeschlagener Befehl"
assert_out "Container 200 wurde NICHT gelöscht"
assert_out "pct enter 200"
rm -f "$HS/no_hostname_ip"

t "pct exec Exit 255 (Grube 10) → Kette"
reset_state
touch "$HS/exec_fail"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Installationsfehler – Exit-Code 1"
rm -f "$HS/exec_fail"

t "DNS total defekt → die mit Fallback-Diagnose"
reset_state
echo "getent_mode=fail" > "$HS/getent_mode"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "DNS im Container weiterhin ohne Funktion"
assert_out "ausgehende DNS-Anfragen (Port 53)"
assert_file "$MK/etc/dhcp/dhclient-enter-hooks.d/no-dns"

t "DNS flaky → Fallback + dhclient-Hook, dann Erfolg"
reset_state
echo "getent_mode=fail_then_ok" > "$HS/getent_mode"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt"
assert_file "$MK/etc/dhcp/dhclient-enter-hooks.d/no-dns"

t "Template komplett fehlend → die"
reset_state
touch "$HS/pveam_empty"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Kein debian-13-standard-Template für amd64 gefunden"
assert_out "Debian 13 (trixie)"
rm -f "$HS/pveam_empty"

t "Template-Download-Pfad (list leer, available da)"
reset_state
unseed_inner_tools
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Kein Debian-13-amd64-Template vorhanden – lade es herunter"
assert_calls 1 "pveam download local"
assert_calls 1 "pct create 200"
assert_fcontains "$HS/ct_200.create" "amd64"

t "arm64-Host (ProxSmartHome-Klasse) → wählt arm64-Template (uname -m)"
reset_state
unseed_inner_tools
echo "aarch64" > "$HS/host_arch"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Host-Architektur: aarch64 → Template-Arch: arm64"
assert_fcontains "$HS/ct_200.create" "debian-13-standard_13.2-1_arm64.tar.zst"
assert_no_fcontains "$HS/ct_200.create" "amd64"

t "nur arm64-Template lokal + amd64-Host → lädt amd64 nach (Live-Fund CT 212)"
reset_state
unseed_inner_tools
mkdir -p "$HS/templates"
touch "$HS/templates/debian-13-standard_13.2-1_arm64.tar.zst"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Kein Debian-13-amd64-Template vorhanden – lade es herunter"
assert_fcontains "$HS/ct_200.create" "amd64"
assert_no_fcontains "$HS/ct_200.create" "arm64"

t "Spawn-Fail mit Exit-0-Täuschung → klare Fehlermeldung (CT 212, Live-Fund 2026-11-19)"
reset_state
touch "$HS/spawn_fail"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "startet NICHT (Status nach pct create: stopped)"
assert_out "falsches Template-Arch"
assert_out "pct start"
rm -f "$HS/spawn_fail"

t "existierender CT ohne --force → die mit Update-Hinweis"
seed_ct
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "existiert bereits"
assert_out "--update"

t "--force: destroy + recreate"
seed_ct
ec=$(run_installer --force); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_calls 1 "pct create 200"
assert_out "existiert – --force: lösche und lege neu an"

t "nicht-root (EUID-Check via env ohne unshare)"
ec=$( env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" HARNESS_STATE="$HS" HOME=/root TERM=dumb \
      bash "$SCRIPT" > "$CUR_DIR/out.log" 2>&1; echo $? )
assert_exit 1 "$ec"
assert_out "Bitte als root ausführen"

# ════════════════ D. Update / Idempotenz ════════════════
t "--update: apt-Upgrade, enterprise.sources entfernt, Keyring bleibt"
seed_ct
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_out "Keyring bereits vorhanden und korrekt (SHA256 stimmt)"
assert_fcontains "$SOURCES_FILE" "Components: pdm-no-subscription"
assert_no_file "$MK/etc/apt/sources.list.d/pdm-enterprise.sources"   # seed hatte sie – inner entfernt
assert_calls 1 "update -qq"
assert_calls 1 "install -y -qq"
assert_calls 1 "systemctl restart proxmox-datacenter-privileged-api proxmox-datacenter-api"
assert_no_calls "curl ca-certificates"               # curl war schon da (kein Bootstrap)
assert_out "Update abgeschlossen – PDM-Daten (/var/lib/proxmox-datacenter-manager) blieben erhalten."
assert_out "🖥️  Proxmox Datacenter Manager ist bereit!"

t "--update --repo test: Komponentenwechsel"
seed_ct
ec=$(run_installer --update --repo test); assert_exit 0 "$ec"
assert_fcontains "$SOURCES_FILE" "Components: pdm-test"

t "--update auf gestopptem CT → startet ihn selbst (Grube 10)"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i "s/^200 .*/200 stopped kvmoink/" "$HS/ct_list"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_calls 1 "pct start 200"
assert_out "läuft nicht (Status: stopped) – starte ihn"
assert_out "Update abgeschlossen"

t "--update ohne CT → die"
reset_state
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Kein Container mit Hostname 'kvmoink' gefunden"
assert_out "Erst installieren"

t "Host-Check tot → warn, update trotzdem exit 0"
seed_ct
touch "$HS/host_curl_fail"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_out "vom Proxmox-Host nicht erreichbar (HTTP 000"
rm -f "$HS/host_curl_fail"

# ════════════════ E. Uninstall ════════════════
t "--uninstall ohne CT"
reset_state
ec=$(run_installer --uninstall); assert_exit 0 "$ec"
assert_out "nichts zu tun"

t "--uninstall mit Bestätigung 'ja'"
seed_ct
ec=$(run_installer_stdin $'ja\n' --uninstall); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_no_file "$HS/ct_200.status"
assert_out "Container 200 entfernt."

t "--uninstall mit 'nein' → Abbruch"
seed_ct
ec=$(run_installer_stdin $'nein\n' --uninstall); assert_exit 0 "$ec"
assert_out "Abgebrochen – nichts gelöscht."
assert_file "$HS/ct_200.status"
assert_no_calls "pct destroy"

t "--uninstall nicht-interaktiv → die"
seed_ct
ec=$(run_installer_devnull --uninstall); assert_exit 1 "$ec"
assert_out "Keine Bestätigung erhalten"
assert_out "--uninstall --yes"
assert_file "$HS/ct_200.status"

t "--uninstall --yes (ohne Rückfrage)"
seed_ct
ec=$(run_installer --uninstall --yes); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_out "Container 200 entfernt."

# ════════════════ F. Status ════════════════
t "--status: laufender Stack mit Version + enterprise-warn (seed legt die Datei an)"
seed_ct
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Service:   proxmox-datacenter-api läuft"
assert_out "Service:   proxmox-datacenter-privileged-api läuft"
assert_out "PDM:       v1.1.10-mock"
assert_out "Web-UI:    https://$CT_IP:8443  (HTTPS 200)"
assert_out "pdm-enterprise.sources wieder vorhanden"
rm -f "$MK/etc/apt/sources.list.d/pdm-enterprise.sources"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_no_out "wieder vorhanden"

t "--status: gestoppter CT"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i "s/^200 .*/200 stopped kvmoink/" "$HS/ct_list"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "nicht gestartet (stopped)"
assert_out "pct start 200"

t "--status: CT fehlt"
reset_state
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Kein Container mit Hostname 'kvmoink' gefunden."
assert_out "Installieren:  bash -c"

t "--status: Service tot → err-Zeile"
seed_ct
rm -f "$HS/svc_active_proxmox-datacenter-api"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Service:   proxmox-datacenter-api läuft NICHT"

# ════════════════ Zusammenfassung ════════════════
echo "════════════════════════════════════════════════════════════"
echo " 📊 Ergebnis: $PASSED bestanden, $FAILED fehlgeschlagen"
echo "════════════════════════════════════════════════════════════"
if [[ $FAILED -gt 0 ]]; then
    echo "✘ Harness ROT"
    exit 1
fi
echo "✔ Harness GRÜN"
exit 0
