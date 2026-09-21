#!/usr/bin/env bash
#
# Cuicuit Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:     Cuicuit – Kitchen Companion (SvelteKit 5 + Node 24 + lokaler Supabase-Stack, Web UI :3000)
# Repo:    https://github.com/MadeInPierre/cuicuit
# Läuft:   vollständig lokal im LXC, keine Cloud nötig
# Host:    DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CuCuitCooking/main/install/cuicuit.sh)"
#   CT_ID=101 CORES=2 RAM=4096 DISK=16 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CuCuitCooking/main/install/cuicuit.sh)"
#   bash cuicuit.sh --ctid 101 --cores 2 --memory 4096 --disk 16 --bridge vmbr0 --debug
#
# Was passiert:
#   1. Host: LXC "cuicuit" mit naechster freier CT-ID, onboot=1, nesting=1 (fuer Docker)
#   2. LXC:  Docker + Node 24 + Repo-Clone nach /opt/cuicuit
#   3. LXC:  lokaler Supabase-Stack via "supabase start" (Migrationen + Seed aus dem Repo)
#   4. LXC:  .env aus Supabase-Keys fuellen, adapter-vercel -> adapter-node patchen, vite build
#   5. LXC:  systemd-Units cuicuit-supabase + cuicuit (Restart=always), enable --now
#   6. Host: Verifikation (is-active + HTTP-Check) und finale URL ausgeben
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="cuicuit"                                   # Container-Hostname + Service-Name
APP_PORT="3000"                                 # SvelteKit/adapter-node Port (Upstream: Vercel, self-host Default)
GITHUB_REPO="MadeInPierre/cuicuit"              # App-Quelle (Clone + Supabase-Migrationen)
INSTALLER_REPO="HatchetMan111/CuCuitCooking"    # Repo, das DIESES Script hostet (Einzeiler-URL)
BRANCH="main"                                   # Branch/Tag zum Auschecken
APP_DIR="/opt/cuicuit"                          # Installationsziel im Container
SERVICE_USER="cuicuit"                          # System-User fuer Checkout/Build/Service
SUPABASE_API_PORT="54321"                       # lokaler Supabase-API-Port (CLI-Default, Kong)

DEFAULT_CORES="2"                               # vCPU
DEFAULT_RAM="4096"                              # RAM in MB (Supabase-Docker-Stack + Node-Build brauchen >2GB)
DEFAULT_SWAP="1024"                             # Swap in MB
DEFAULT_DISK="16"                               # Disk in GB (Supabase-Images + node_modules + Build + 20MB Seed)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                  # Storage fuer CT-Templates
DEFAULT_OS="debian-12-standard"                 # Template-Familie (12 = stabil getestet)
UNPRIVILEGED="1"
FEATURES="nesting=1"                            # nesting: Docker im LXC noetig (Supabase-Stack)

# Umgebungs-Overrides erlauben: CT_ID=101 CORES=2 RAM=4096 DISK=16 ./cuicuit.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
BRANCH_ARG="${CUICUIT_BRANCH:-$BRANCH}"

# Optional: externe Supabase-Instanz statt lokalem Docker-Stack
# (wenn gesetzt, wird "supabase start" uebersprungen):
EXT_SUPABASE_URL="${CUICUIT_SUPABASE_URL:-${SUPABASE_URL:-}}"
EXT_ANON_KEY="${CUICUIT_SUPABASE_ANON_KEY:-${SUPABASE_ANON_KEY:-}}"
EXT_SERVICE_KEY="${CUICUIT_SUPABASE_SERVICE_KEY:-${SUPABASE_SERVICE_KEY:-}}"

# Optionale LLM-/Scraper-Keys werden 1:1 in die Container-.env uebernommen (leere bleiben leer):
FWD_ENV_KEYS="MISTRAL_API_KEY MISTRAL_MODEL GROQ_API_KEY GROQ_MODEL LLM_PRIORITY PYTHON_SCRAPER_URL PYTHON_SCRAPER_KEY"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe zusaetzlich ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash cuicuit.sh [OPTIONEN]
  CT_ID=101 bash cuicuit.sh
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/${INSTALLER_REPO}/main/install/cuicuit.sh)"

Optionen:
  --ctid ID               Container-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME         Hostname (Default: ${APP})
  --cores N               vCPU (Default: ${DEFAULT_CORES})
  --memory MB             RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB               Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME          RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N      Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME           Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --branch NAME           Git-Branch/Tag (Default: ${BRANCH})
  --password PW           Root-Passwort (Default: zufaellig generiert, wird angezeigt)
  --ssh-key PATH          SSH Public Key in den Container uebernehmen (optional)
  --supabase-url URL      externe Supabase-URL (optional; ohne = lokaler Docker-Stack)
  --supabase-anon-key K   Anon/Publishable Key zur --supabase-url
  --supabase-service-key K Service-Role Key zur --supabase-url
  --debug, -x             set -x + maximale Fehlermeldungskette
  --help, -h              diese Hilfe

Nach der Installation: http://<LXC-IP>:${APP_PORT}
EOF
}

# ---------------------------------------------------------------------------
# Debugging: komplette Fehlermeldungskette (Stacktrace, stderr/stdout, Exit-Code, Logs)
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +x
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $SCRIPT_ARGS"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Stacktrace (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  # Kontext: was gibt es her?
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]]; then
    msg_error "--- pct config ${CTID} ---"
    pct config "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- pct status ${CTID} ---"
    pct status "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- journalctl im Container (cuicuit, letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- journalctl -u "${APP}" --no-pager -n 100 2>&1 || true
    echo ""
    msg_error "--- journalctl im Container (cuicuit-supabase, letzte 50 Zeilen) ---"
    pct exec "${CTID}" -- journalctl -u "${APP}-supabase" --no-pager -n 50 2>&1 || true
    echo ""
    msg_error "--- systemctl status im Container ---"
    pct exec "${CTID}" -- systemctl status "${APP}" "${APP}-supabase" --no-pager --full 2>&1 || true
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  # shellcheck disable=SC2086
  msg_error "  bash -x cuicuit.sh $SCRIPT_ARGS"
  msg_error "  oder: DEBUG=1 bash cuicuit.sh $SCRIPT_ARGS"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CT_ID_ARG"
HOSTNAME_ARG="$APP"
CORES="$CORES_ARG"
RAM="$RAM_ARG"
DISK="$DISK_ARG"
BRANCH="$BRANCH_ARG"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
ROOT_PASSWORD=""
SSH_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)               CTID="${2:?--ctid braucht einen Wert}"; shift 2 ;;
    --hostname)           HOSTNAME_ARG="${2:?--hostname braucht einen Wert}"; shift 2 ;;
    --cores)              CORES="${2:?}"; shift 2 ;;
    --memory)             RAM="${2:?}"; shift 2 ;;
    --disk)               DISK="${2:?}"; shift 2 ;;
    --storage)            STORAGE_ARG="${2:?}"; shift 2 ;;
    --template-store)     TEMPLATE_STORE="${2:?}"; shift 2 ;;
    --bridge)             BRIDGE="${2:?}"; shift 2 ;;
    --branch)             BRANCH="${2:?}"; shift 2 ;;
    --password)           ROOT_PASSWORD="${2:?}"; shift 2 ;;
    --ssh-key)            SSH_KEY="${2:?}"; shift 2 ;;
    --supabase-url)       EXT_SUPABASE_URL="${2:?}"; shift 2 ;;
    --supabase-anon-key)  EXT_ANON_KEY="${2:?}"; shift 2 ;;
    --supabase-service-key) EXT_SERVICE_KEY="${2:?}"; shift 2 ;;
    --debug|-x)           DEBUG="1"; set -x; shift ;;
    --help|-h)            usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

# Trap NACH dem Parsen setzen, damit SCRIPT_ARGS die echten Args enthaelt
# shellcheck disable=SC2064
trap "on_error \$? \$LINENO \"\$BASH_COMMAND\"" ERR

# Externer Modus nur komplett (alle drei Werte) oder gar nicht
USE_EXTERNAL=0
if [[ -n "$EXT_SUPABASE_URL" ]]; then
  if [[ -z "$EXT_ANON_KEY" || -z "$EXT_SERVICE_KEY" ]]; then
    msg_error "--supabase-url braucht zusaetzlich --supabase-anon-key und --supabase-service-key (oder Env CUICUIT_SUPABASE_URL / CUICUIT_SUPABASE_ANON_KEY / CUICUIT_SUPABASE_SERVICE_KEY)."
    exit 1
  fi
  USE_EXTERNAL=1
  msg_info "Externer Supabase-Modus: lokaler Docker-Stack wird uebersprungen."
fi

# ---------------------------------------------------------------------------
# Pre-Checks (muss auf dem Proxmox-Host als root laufen)
# ---------------------------------------------------------------------------
msg_info "Pruefe Voraussetzungen (Proxmox-Host, root, Tools) ..."
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  msg_error "Bitte als root auf dem Proxmox-Host ausfuehren (sudo -i)."
  exit 1
fi
for bin in pct pveam pvesh pvesm wget curl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    msg_error "Benoetigtes Tool fehlt: $bin – laeuft das Skript wirklich auf einem Proxmox-VE-Host?"
    exit 1
  fi
done
msg_ok "Host-Checks bestanden."

# ---------------------------------------------------------------------------
# CT-ID: immer die naechste freie ID nehmen (ausser explizit gesetzt)
# ---------------------------------------------------------------------------
if [[ -z "$CTID" ]]; then
  msg_info "Ermittle naechste freie CT-ID ..."
  CTID="$(pvesh get /cluster/nextid)"
  msg_ok "Naechste freie CT-ID: $CTID"
else
  msg_info "CT-ID vorgegeben: $CTID"
fi

HOSTNAME_FINAL="$HOSTNAME_ARG"
if [[ ! "$HOSTNAME_FINAL" =~ ^[a-zA-Z0-9-]+$ ]]; then
  msg_error "Ungueltiger Hostname: $HOSTNAME_FINAL (nur Buchstaben, Zahlen, Bindestrich)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Storage-Erkennung (idempotent: vorhandene Storages nutzen)
# ---------------------------------------------------------------------------
detect_storage() {
  local s
  # pvesm status: Spalten "Name Type Status ..." – Status-Spalte enthaelt "active"
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | grep -x "local-lvm" || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | head -n1 || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  echo "local-lvm"
}
if [[ -z "$STORAGE_ARG" ]]; then
  STORAGE_ARG="$(detect_storage)"
  msg_info "RootFS-Storage (auto): $STORAGE_ARG"
else
  msg_info "RootFS-Storage (vorgegeben): $STORAGE_ARG"
fi

# ---------------------------------------------------------------------------
# Template sicherstellen
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Template-Liste (pveam update) ..."
pveam update

msg_info "Suche neuestes ${DEFAULT_OS}-Template auf ${TEMPLATE_STORE} ..."
TEMPLATE_FILE="$(pveam available --section system 2>/dev/null \
  | grep -o "${DEFAULT_OS}[^ ]*\\.tar\\.zst" | sort -V | tail -n1 || true)"
if [[ -z "$TEMPLATE_FILE" ]]; then
  msg_error "Kein Template fuer ${DEFAULT_OS} gefunden. Verfuegbare Debian-Templates:"
  pveam available --section system 2>&1 | grep -i debian || true
  exit 1
fi
TEMPLATE_REF="${TEMPLATE_STORE}:vztmpl/${TEMPLATE_FILE}"
msg_info "Template: $TEMPLATE_REF"
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE_FILE"; then
  msg_info "Lade Template herunter (kann dauern) ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_FILE"
else
  msg_ok "Template bereits vorhanden – Download uebersprungen (idempotent)."
fi

# ---------------------------------------------------------------------------
# Container erstellen (idempotent: existiert die CT-ID schon, wiederverwenden)
# ---------------------------------------------------------------------------
CREATED_NOW=0
GENERATED_PW=0
if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "Container $CTID existiert bereits – wird wiederverwendet (idempotent, kein Neu-Erstellen)."
  EXISTING_HOST="$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}' || true)"
  msg_info "Bestehender Hostname: ${EXISTING_HOST:-unbekannt}"
else
  if [[ -z "$ROOT_PASSWORD" ]]; then
    ROOT_PASSWORD="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    GENERATED_PW=1
  fi
  msg_info "Erstelle LXC $CTID (hostname=${HOSTNAME_FINAL}, cores=${CORES}, ram=${RAM}MB, disk=${DISK}G) ..."
  CREATE_ARGS=(
    "$CTID" "$TEMPLATE_REF"
    --hostname "$HOSTNAME_FINAL"
    --cores "$CORES"
    --memory "$RAM"
    --swap "$DEFAULT_SWAP"
    --rootfs "${STORAGE_ARG}:${DISK}"
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
    --ostype debian
    --unprivileged "$UNPRIVILEGED"
    --features "$FEATURES"
    --onboot 1
    --start 0
    --password "$ROOT_PASSWORD"
  )
  if [[ -n "$SSH_KEY" ]]; then
    if [[ ! -f "$SSH_KEY" ]]; then msg_error "SSH-Key nicht gefunden: $SSH_KEY"; exit 1; fi
    CREATE_ARGS+=(--ssh-public-keys "$SSH_KEY")
  fi
  pct create "${CREATE_ARGS[@]}"
  # onboot explizit sicherstellen (Reboot-sicher)
  pct set "$CTID" --onboot 1
  CREATED_NOW=1
  msg_ok "Container $CTID erstellt (Name: $HOSTNAME_FINAL, onboot=1)."
fi

msg_info "Starte Container $CTID ..."
if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
  pct start "$CTID"
fi
# Warten bis pct exec geht
for i in $(seq 1 30); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
  if [[ "$i" -eq 30 ]]; then msg_error "Container $CTID reagiert nicht auf 'pct exec'."; exit 1; fi
done
msg_ok "Container $CTID laeuft."

# Debian-Template braucht nach Start kurz Netzwerk/DNS
sleep 5

# ---------------------------------------------------------------------------
# Installation IM Container (idempotentes Setup-Skript via pct push + exec)
# ---------------------------------------------------------------------------
msg_info "Installiere ${APP} im Container (Node 24 + Supabase-Stack + SvelteKit-Build, systemd) ..."

# systemd-Unit: App (identisch zu systemd/cuicuit.service im Repo)
read -r -d '' UNIT_APP <<'UNIT_EOF' || true
[Unit]
Description=Cuicuit - Kitchen Companion (SvelteKit, self-hosted)
Documentation=https://github.com/MadeInPierre/cuicuit
After=network-online.target cuicuit-supabase.service
Wants=network-online.target cuicuit-supabase.service

[Service]
Type=simple
User=cuicuit
Group=cuicuit
WorkingDirectory=/opt/cuicuit
EnvironmentFile=/opt/cuicuit/.env
Environment=NODE_ENV=production
Environment=HOST=0.0.0.0
Environment=PORT=3000
ExecStart=/usr/bin/node /opt/cuicuit/build
Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
UNIT_EOF

# systemd-Unit: lokaler Supabase-Stack (identisch zu systemd/cuicuit-supabase.service;
# no-op bei externer Supabase-URL – siehe Helper /usr/local/bin/cuicuit-supabase-start)
read -r -d '' UNIT_SUPABASE <<'UNIT_EOF' || true
[Unit]
Description=Cuicuit Supabase stack (lokal, via Supabase CLI)
Documentation=https://github.com/MadeInPierre/cuicuit
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/cuicuit
ExecStart=/usr/local/bin/cuicuit-supabase-start
ExecStop=/usr/bin/npx --yes supabase stop
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
UNIT_EOF

# Setup-Skript lokal bauen (Host-Variablen werden HIER expandiert,
# Container-Variablen sind mit \$ escaped und werden ERST im LXC expandiert).
TMP_SETUP="$(mktemp /tmp/cuicuit-setup.XXXXXX.sh)"
cat > "$TMP_SETUP" <<SETUP_EOF
#!/usr/bin/env bash
set -euo pipefail
APP="${APP}"
APP_PORT="${APP_PORT}"
APP_DIR="${APP_DIR}"
SERVICE_USER="${SERVICE_USER}"
GITHUB_REPO="${GITHUB_REPO}"
BRANCH="${BRANCH}"
SUPABASE_API_PORT="${SUPABASE_API_PORT}"
USE_EXTERNAL="${USE_EXTERNAL}"
EXT_SUPABASE_URL="${EXT_SUPABASE_URL}"
EXT_ANON_KEY="${EXT_ANON_KEY}"
EXT_SERVICE_KEY="${EXT_SERVICE_KEY}"
FWD_ENV_KEYS="${FWD_ENV_KEYS}"
# Optionale Keys aus der Host-Umgebung (falls exportiert) in den Container durchreichen:
$(for k in $FWD_ENV_KEYS; do v="${!k:-}"; printf 'FWD_%s=%q\n' "$k" "$v"; done)

echo "[LXC] apt update + Basis-Pakete ..."
export DEBIAN_FRONTEND=noninteractive
# Locale-Warnungen ("Cannot set LC_ALL") in minimalen Debian-Templates unterdruecken
export LC_ALL=C LANG=C
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates git iproute2 procps python3 jq docker.io

echo "[LXC] Docker sicherstellen ..."
systemctl enable --now docker
for i in \$(seq 1 30); do
  if docker info >/dev/null 2>&1; then break; fi
  sleep 2
  if [[ "\$i" -eq 30 ]]; then echo "[LXC][ERROR] Docker-Daemon startet nicht (nesting=1 am Container gesetzt?)." >&2; exit 1; fi
done

echo "[LXC] Node 24 sicherstellen (Upstream engines: node 24.x) ..."
NEED_NODE=1
if command -v node >/dev/null 2>&1; then
  MAJOR="\$(node -v | sed 's/^v//' | cut -d. -f1)"
  if [[ "\$MAJOR" == "24" ]]; then NEED_NODE=0; echo "[LXC] Node \$(node -v) bereits vorhanden."; fi
fi
if [[ "\$NEED_NODE" == "1" ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y --no-install-recommends nodejs
fi
node -v
npm -v

echo "[LXC] User '\$SERVICE_USER' sicherstellen (idempotent) ..."
if ! id "\$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home "\$APP_DIR" --create-home --shell /bin/bash "\$SERVICE_USER"
fi
mkdir -p "\$APP_DIR"
chown "\$SERVICE_USER:\$SERVICE_USER" "\$APP_DIR"

echo "[LXC] Repo-Stand sichern (idempotent: fetch + reset auf origin/\$BRANCH) ..."
fresh_clone() {
  if [[ -d "\$APP_DIR" && -n "\$(ls -A "\$APP_DIR")" ]]; then
    # \$APP_DIR ist das Home von \$SERVICE_USER und enthaelt Skelett-Dateien
    # (.bashrc, .profile) – git clone braucht ein leeres Ziel: Umweg via Temp-Dir.
    TMP_CLONE="\$(mktemp -d)"
    chown "\$SERVICE_USER:\$SERVICE_USER" "\$TMP_CLONE"
    runuser -u "\$SERVICE_USER" -- git clone --branch "\$BRANCH" --depth 1 "https://github.com/\$GITHUB_REPO.git" "\$TMP_CLONE"
    cp -a "\$TMP_CLONE/." "\$APP_DIR/"
    rm -rf "\$TMP_CLONE"
  else
    runuser -u "\$SERVICE_USER" -- git clone --branch "\$BRANCH" --depth 1 "https://github.com/\$GITHUB_REPO.git" "\$APP_DIR"
  fi
}
# Das Repo gehoert \$SERVICE_USER – alle git-Ops laufen als er (sonst
# "fatal: detected dubious ownership" fuer root). safe.directory zusaetzlich
# als Gurt fuer direkte root-Zugriffe (z. B. Debugging per pct exec).
runuser -u "\$SERVICE_USER" -- git config --global --add safe.directory "\$APP_DIR" 2>/dev/null || true
git config --global --add safe.directory "\$APP_DIR" 2>/dev/null || true
if [[ -d "\$APP_DIR/.git" ]]; then
  if runuser -u "\$SERVICE_USER" -- git -C "\$APP_DIR" fetch origin --prune \
  && runuser -u "\$SERVICE_USER" -- git -C "\$APP_DIR" reset --hard "origin/\$BRANCH"; then
    echo "[LXC] Repo aktualisiert."
  else
    echo "[LXC][WARN] Repo-Update schlug fehl – frischer Clone (.env/Marker bleiben erhalten)."
    rm -rf "\$APP_DIR/.git"
    fresh_clone
  fi
else
  fresh_clone
fi
# Hinweis: bewusst KEIN "git clean -fdx" – das wuerde .env, .use-local-supabase
# und .proxmox-build-rev loeschen. reset --hard revertiert den Adapter-Patch
# (svelte.config.js ist tracked), der Patch weiter unten laeuft erneut.
NEW_REV="\$(runuser -u "\$SERVICE_USER" -- git -C "\$APP_DIR" rev-parse HEAD)"
echo "[LXC] Repo-Rev: \$NEW_REV"
chown -R "\$SERVICE_USER:\$SERVICE_USER" "\$APP_DIR"

# --- IP-DETECT-START ---
# Die Browser der Nutzer laden die App via http://<LXC-IP>:3000 – PUBLIC_SUPABASE_URL
# wird zur Build-Zeit eingebettet und muss daher die erreichbare Container-IP
# enthalten (127.0.0.1 wuerde im BROWSER auf den Client zeigen, nicht auf den LXC).
echo "[LXC] Container-IP ermitteln (fuer PUBLIC_SUPABASE_URL + Ausgabe) ..."
LXC_IP="\$(ip -4 -o addr show eth0 2>/dev/null | awk '\$4 !~ /^127\\./ {print \$4}' | cut -d/ -f1 | head -n1 || true)"
if [[ -z "\$LXC_IP" ]]; then
  LXC_IP="\$(ip -4 -o addr show 2>/dev/null | awk '\$2 != "lo" && \$4 !~ /^127\\./ {print \$4}' | cut -d/ -f1 | head -n1 || true)"
fi
if [[ -z "\$LXC_IP" ]]; then
  echo "[LXC][ERROR] Keine IPv4-Adresse gefunden." >&2
  ip -4 -o addr show >&2 || true
  exit 1
fi
echo "[LXC] Container-IP: \$LXC_IP"
# --- IP-DETECT-END ---

# --- SUPABASE-START ---
if [[ "\$USE_EXTERNAL" == "1" ]]; then
  echo "[LXC] Externer Supabase-Modus – lokaler Stack wird uebersprungen."
  rm -f "\$APP_DIR/.use-local-supabase"
  SUPA_URL="\$EXT_SUPABASE_URL"
  SUPA_ANON="\$EXT_ANON_KEY"
  SUPA_SERVICE="\$EXT_SERVICE_KEY"
else
  echo "[LXC] Lokaler Supabase-Stack via 'supabase start' (Migrationen + Seed aus dem Repo; Erstlauf zieht Docker-Images, dauert mehrere Minuten) ..."
  touch "\$APP_DIR/.use-local-supabase"
  chown "\$SERVICE_USER:\$SERVICE_USER" "\$APP_DIR/.use-local-supabase"
  cd "\$APP_DIR"
  # idempotent: laeuft der Stack schon, meldet die CLI "started" und exit 0
  npx --yes supabase start
  echo "[LXC] Supabase-Status + Keys auslesen ..."
  STATUS_JSON="\$(npx --yes supabase status -o json)"
  echo "\$STATUS_JSON" | jq . >/dev/null || { echo "[LXC][ERROR] 'supabase status -o json' lieferte kein valides JSON:" >&2; echo "\$STATUS_JSON" >&2; exit 1; }
  CLI_API_URL="\$(echo "\$STATUS_JSON" | jq -r '.API_URL // empty')"
  SUPA_ANON="\$(echo "\$STATUS_JSON" | jq -r '.ANON_KEY // empty')"
  SUPA_SERVICE="\$(echo "\$STATUS_JSON" | jq -r '.SERVICE_ROLE_KEY // empty')"
  if [[ -z "\$SUPA_ANON" || -z "\$SUPA_SERVICE" ]]; then
    echo "[LXC][ERROR] Keine Keys in 'supabase status' gefunden. Vollstaendige Ausgabe:" >&2
    echo "\$STATUS_JSON" >&2
    exit 1
  fi
  echo "[LXC] Supabase-CLI meldet API: \${CLI_API_URL:-unbekannt}"
  # Browser-erreichbare URL (siehe IP-DETECT-Kommentar oben); Kong lauscht auf 0.0.0.0
  SUPA_URL="http://\$LXC_IP:\$SUPABASE_API_PORT"
fi
# --- SUPABASE-END ---

echo "[LXC] .env sicherstellen (nur leere Werte fuellen, gesetzte bleiben – idempotent) ..."
ENV_FILE="\$APP_DIR/.env"
if [[ ! -f "\$ENV_FILE" ]]; then
  cp "\$APP_DIR/.env.example" "\$ENV_FILE"
  chown "\$SERVICE_USER:\$SERVICE_USER" "\$ENV_FILE"
fi
python3 - "\$ENV_FILE" "\$SUPA_URL" "\$SUPA_ANON" "\$SUPA_SERVICE" <<'PYEOF'
import sys
path, url, anon, service = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
wanted = {
    "PUBLIC_SUPABASE_URL": url,
    "PUBLIC_SUPABASE_PUBLISHABLE_KEY": anon,
    "SUPABASE_SERVICE_ROLE_KEY": service,
}
lines, seen = [], set()
with open(path) as f:
    for raw in f:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key, _, val = stripped.partition("=")
            key = key.strip()
            if key in wanted and (val.strip() == "" or val.strip() in ("...", "your_posthog_project_token_here")):
                lines.append(f"{key}={wanted[key]}")
                seen.add(key)
                continue
            if key in wanted:
                seen.add(key)
        lines.append(line)
for key, val in wanted.items():
    if key not in seen:
        lines.append(f"{key}={val}")
with open(path, "w") as f:
    f.write("\n".join(lines).rstrip("\n") + "\n")
print("env aktualisiert:", ", ".join(f"{k}={'gesetzt' if k in wanted else k}" for k in wanted))
PYEOF
# Optionale LLM-/Scraper-Keys aus Host-Env uebernehmen (nur wenn im Container leer):
for k in \$FWD_ENV_KEYS; do
  var="FWD_\$k"
  val="\${!var:-}"
  if [[ -n "\$val" ]]; then
    if grep -qE "^\$k=$" "\$ENV_FILE" || ! grep -qE "^\$k=" "\$ENV_FILE"; then
      grep -vE "^\$k=" "\$ENV_FILE" > "\$ENV_FILE.tmp" || true
      echo "\$k=\$val" >> "\$ENV_FILE.tmp"
      mv "\$ENV_FILE.tmp" "\$ENV_FILE"
      echo "[LXC] \$k aus Host-Umgebung uebernommen."
    else
      echo "[LXC] \$k bereits gesetzt – Host-Wert ignoriert."
    fi
  fi
done
chown "\$SERVICE_USER:\$SERVICE_USER" "\$ENV_FILE"
chmod 0600 "\$ENV_FILE"

echo "[LXC] npm-Abhaengigkeiten (idempotent) ..."
cd "\$APP_DIR"
if [[ -f package-lock.json ]]; then
  runuser -u "\$SERVICE_USER" -- npm ci --no-audit --no-fund || runuser -u "\$SERVICE_USER" -- npm install --no-audit --no-fund
else
  runuser -u "\$SERVICE_USER" -- npm install --no-audit --no-fund
fi

echo "[LXC] adapter-vercel -> adapter-node patchen (Upstream nutzt Vercel; self-host braucht Node) ..."
if ! grep -q '"@sveltejs/adapter-node"' package.json; then
  runuser -u "\$SERVICE_USER" -- npm install --no-audit --no-fund -D "@sveltejs/adapter-node@^3"
fi
if grep -q "adapter-vercel" svelte.config.js; then
  cp svelte.config.js "svelte.config.js.proxmox-bak"
  python3 - <<'PYEOF'
import re
p = "svelte.config.js"
s = open(p).read()
s = s.replace("@sveltejs/adapter-vercel", "@sveltejs/adapter-node")
s = re.sub(r"adapter\(\{\s*runtime:\s*'nodejs[^']*'\s*\}\)", "adapter()", s)
open(p, "w").write(s)
PYEOF
  grep -q "adapter-node" svelte.config.js || { echo "[LXC][ERROR] Adapter-Patch fehlgeschlagen." >&2; exit 1; }
  echo "[LXC] svelte.config.js gepatcht (Backup: svelte.config.js.proxmox-bak)."
else
  echo "[LXC] svelte.config.js bereits auf adapter-node (idempotent)."
fi

echo "[LXC] Build entscheiden (nur bei neuer Rev / fehlendem build/ – idempotent) ..."
OLD_REV="\$(cat "\$APP_DIR/.proxmox-build-rev" 2>/dev/null || true)"
NEED_BUILD=0
if [[ ! -d "\$APP_DIR/build" ]]; then NEED_BUILD=1; echo "[LXC] build/ fehlt."; fi
if [[ "\$OLD_REV" != "\$NEW_REV" ]]; then NEED_BUILD=1; echo "[LXC] Neue Rev \$NEW_REV (war: \${OLD_REV:-keine})."; fi
if [[ "\${BUILD_FORCE:-0}" == "1" ]]; then NEED_BUILD=1; echo "[LXC] BUILD_FORCE=1."; fi
if [[ "\$NEED_BUILD" == "1" ]]; then
  echo "[LXC] vite build (braucht RAM, dauert mehrere Minuten) ..."
  runuser -u "\$SERVICE_USER" -- env NODE_OPTIONS="--max-old-space-size=3072" npm run build
  echo -n "\$NEW_REV" > "\$APP_DIR/.proxmox-build-rev"
  chown "\$SERVICE_USER:\$SERVICE_USER" "\$APP_DIR/.proxmox-build-rev"
else
  echo "[LXC] Build aktuell – uebersprungen (idempotent)."
fi
chown -R "\$SERVICE_USER:\$SERVICE_USER" "\$APP_DIR"

echo "[LXC] Helper + systemd-Units schreiben ..."
cat > /usr/local/bin/cuicuit-supabase-start <<HELPER_EOF
#!/usr/bin/env bash
set -euo pipefail
# Reboot-sicherer Start des lokalen Supabase-Stacks. No-op bei externer URL.
if [[ -f "${APP_DIR}/.use-local-supabase" ]]; then
  cd "${APP_DIR}"
  /usr/bin/npx --yes supabase start
else
  echo "Externe Supabase-URL konfiguriert – lokaler Stack wird nicht gestartet."
fi
HELPER_EOF
chmod 0755 /usr/local/bin/cuicuit-supabase-start

cat > /etc/systemd/system/cuicuit.service <<UNIT_INNER_EOF
${UNIT_APP}
UNIT_INNER_EOF
cat > /etc/systemd/system/cuicuit-supabase.service <<UNIT_INNER_EOF
${UNIT_SUPABASE}
UNIT_INNER_EOF

systemctl daemon-reload
systemctl enable cuicuit-supabase.service
systemctl enable cuicuit.service
# Firewall: Port offen lassen, falls ufw aktiv ist (Debian-Default: keine Firewall)
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow ${APP_PORT}/tcp || true
  echo "[LXC] ufw: Port ${APP_PORT}/tcp freigegeben."
fi

echo "[LXC] Dienste starten (supabase zuerst, dann App) ..."
if [[ -f "\$APP_DIR/.use-local-supabase" ]]; then
  systemctl restart cuicuit-supabase.service
  systemctl is-active --quiet cuicuit-supabase.service
fi
if systemctl is-active --quiet cuicuit.service; then
  systemctl restart cuicuit.service
else
  systemctl start cuicuit.service
fi

echo "[LXC] Warte auf Web UI (http://127.0.0.1:\$APP_PORT/api/v1/openapi.json, max ~120s) ..."
OK=0
for i in \$(seq 1 60); do
  if curl -fsS --max-time 5 "http://127.0.0.1:\$APP_PORT/api/v1/openapi.json" >/dev/null 2>&1; then OK=1; break; fi
  if curl -fsS --max-time 5 "http://127.0.0.1:\$APP_PORT/" -o /dev/null 2>&1; then OK=1; break; fi
  sleep 2
done
if [[ "\$OK" != "1" ]]; then
  echo "[LXC][ERROR] Web UI antwortet nicht auf 127.0.0.1:\$APP_PORT" >&2
  echo "--- systemctl status cuicuit ---" >&2
  systemctl status cuicuit.service --no-pager --full >&2 || true
  echo "--- journalctl -u cuicuit (letzte 100 Zeilen) ---" >&2
  journalctl -u cuicuit.service --no-pager -n 100 >&2 || true
  echo "--- journalctl -u cuicuit-supabase (letzte 50 Zeilen) ---" >&2
  journalctl -u cuicuit-supabase.service --no-pager -n 50 >&2 || true
  exit 1
fi
echo "[LXC] Web UI antwortet."
echo "[LXC] Service aktiv: \$(systemctl is-active cuicuit.service)"
echo "[LXC] Container-IP: \$LXC_IP -> http://\$LXC_IP:\$APP_PORT"
SETUP_EOF

chmod 0644 "$TMP_SETUP"
msg_info "Setup-Skript lokal: $TMP_SETUP (Kopie bleibt zur Fehlersuche erhalten)"
pct push "$CTID" "$TMP_SETUP" /tmp/cuicuit-setup.sh
pct exec "$CTID" -- bash /tmp/cuicuit-setup.sh
msg_ok "Installation im Container abgeschlossen."

# ---------------------------------------------------------------------------
# Verifikation vom Host aus (Service + HTTP + IP)
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."

SERVICE_STATE="$(pct exec "$CTID" -- systemctl is-active "$APP" 2>&1 || true)"
if [[ "$SERVICE_STATE" != "active" ]]; then
  msg_error "Service-Check fehlgeschlagen: 'systemctl is-active $APP' = '$SERVICE_STATE' (erwartet: active)"
  pct exec "$CTID" -- systemctl status "$APP" --no-pager --full || true
  pct exec "$CTID" -- journalctl -u "$APP" --no-pager -n 100 || true
  exit 1
fi
msg_ok "Service laeuft (systemctl is-active $APP = active)."

if ! pct exec "$CTID" -- curl -fsS --max-time 10 "http://127.0.0.1:${APP_PORT}/api/v1/openapi.json" -o /dev/null \
  && ! pct exec "$CTID" -- curl -fsS --max-time 10 "http://127.0.0.1:${APP_PORT}/" -o /dev/null; then
  msg_error "HTTP-Check fehlgeschlagen: http://127.0.0.1:${APP_PORT} antwortet nicht."
  pct exec "$CTID" -- journalctl -u "$APP" --no-pager -n 100 || true
  exit 1
fi
msg_ok "Web UI antwortet (HTTP-Check auf localhost:${APP_PORT})."

CT_IP="$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
[[ -z "$CT_IP" ]] && CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

echo ""
echo -e "${C_GREEN}${C_BOLD}════════════════ INSTALLATION ERFOLGREICH ════════════════${C_RESET}"
echo -e "  App          : ${C_BOLD}Cuicuit – Kitchen Companion (self-hosted, Alpha)${C_RESET}"
echo -e "  Container    : CT ${C_BOLD}${CTID}${C_RESET} (Hostname: ${C_BOLD}${HOSTNAME_FINAL}${C_RESET}, onboot=1)"
echo -e "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
if [[ -n "${CT_IP:-}" ]]; then
echo -e "  Web UI       : ${C_BOLD}http://${CT_IP}:${APP_PORT}${C_RESET}"
else
echo -e "  Web UI       : ${C_BOLD}http://<LXC-IP>:${APP_PORT}${C_RESET} (IP konnte nicht auto-ermittelt werden: pct exec $CTID -- ip a)"
fi
if [[ "$USE_EXTERNAL" == "1" ]]; then
echo -e "  Datenbank    : extern (${EXT_SUPABASE_URL})"
else
echo -e "  Datenbank    : lokal im LXC (Supabase-Stack, Studio: http://${CT_IP:-<LXC-IP>}:54323)"
fi
if [[ "$CREATED_NOW" == "1" && "$GENERATED_PW" == "1" ]]; then
echo -e "  Root-Passwort: ${C_BOLD}${ROOT_PASSWORD}${C_RESET} (nur jetzt angezeigt – sicher ablegen!)"
fi
echo -e "  Service      : systemctl status ${APP}  (im Container via: pct enter ${CTID})"
echo -e "  Update       : Skript erneut laufen lassen (idempotent) – pullt Branch '${BRANCH}', baut bei Aenderung neu"
echo -e "  Deinstall    : pct stop ${CTID} && pct destroy ${CTID}"
echo -e "  Reboot-Test  : pct reboot ${CTID} && sleep 60 && curl -fs http://${CT_IP:-<LXC-IP>}:${APP_PORT}/api/v1/openapi.json"
echo -e "  Log          : ${LOG_FILE}"
echo -e "  Setup-Kopie  : ${TMP_SETUP}"
if [[ "$DEBUG" != "1" ]]; then
echo -e "  Debug bei Fehlern: ${C_CYAN}bash -x cuicuit.sh --ctid ${CTID}${C_RESET}"
fi
echo -e "${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
