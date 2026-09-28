#!/usr/bin/env bash
set -euo pipefail

RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "-----------------------------------------------------------"
echo " Minecraft Vanilla Dedicated Server (Home Assistant Add-on)"
echo "-----------------------------------------------------------"

# -----------------------------------------------------------
# Optionen
# -----------------------------------------------------------
DATA_DIR="$(jq -r '.data_dir' /data/options.json)"
XMS_MB="$(jq -r '.xms_mb' /data/options.json)"
XMX_MB="$(jq -r '.xmx_mb' /data/options.json)"
MC_VERSION="$(jq -r '.mc_version' /data/options.json)"
SERVER_JAR_URL="$(jq -r '.server_jar_url' /data/options.json)"

[[ "${DATA_DIR}" == "null" || -z "${DATA_DIR}" ]] && DATA_DIR="/share/minecraft-vanilla"
[[ "${MC_VERSION}" == "null" || -z "${MC_VERSION}" ]] && MC_VERSION="latest"
[[ "${SERVER_JAR_URL}" == "null" ]] && SERVER_JAR_URL=""

CONTAINER_PORT="25565"

mkdir -p "${DATA_DIR}"
cd "${DATA_DIR}"

LOG_DIR="${DATA_DIR}/logs"
LOG_FILE="${LOG_DIR}/ha_console.log"
mkdir -p "${LOG_DIR}"

# -----------------------------------------------------------
# Java 21 automatisch installieren (Temurin)
# -----------------------------------------------------------
JRE_DIR="${DATA_DIR}/.jre/25"
JAVA_HOME="${JRE_DIR}"
JAVA_BIN="${JAVA_HOME}/bin/java"

install_java() {
  if [[ -x "${JAVA_BIN}" ]]; then
    return 0
  fi

  log_info "Java 25 nicht gefunden – installiere Temurin JRE"

  local arch adoptium_arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  adoptium_arch="x64" ;;
    aarch64|arm64) adoptium_arch="aarch64" ;;
    *)
      log_error "Nicht unterstützte Architektur: ${arch}"
      exit 1
      ;;
  esac

  mkdir -p "${JRE_DIR}"
  TMP="/tmp/jre21.tar.gz"
  URL="https://api.adoptium.net/v3/binary/latest/25/ga/linux/${adoptium_arch}/jre/hotspot/normal/eclipse?project=jdk"

  curl -fL --retry 3 --retry-delay 2 "${URL}" -o "${TMP}"
  rm -rf "${JRE_DIR:?}/"*
  tar -xzf "${TMP}" -C "${JRE_DIR}" --strip-components=1
  rm -f "${TMP}"

  [[ -x "${JAVA_BIN}" ]] || { log_error "Java Installation fehlgeschlagen"; exit 1; }
}

install_java
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"
log_info "Java Version: $(java -version 2>&1 | head -n1)"

# -----------------------------------------------------------
# Server-JAR ermitteln (Mojang piston-meta)
# -----------------------------------------------------------
SERVER_JAR="server.jar"

get_latest_jar() {
  local manifest latest version_url vjson
  manifest="$(curl -fsSL https://piston-meta.mojang.com/mc/game/version_manifest_v2.json)"
  latest="$(echo "$manifest" | jq -r '.latest.release')"
  version_url="$(echo "$manifest" | jq -r --arg id "$latest" '.versions[] | select(.id==$id) | .url')"
  vjson="$(curl -fsSL "$version_url")"
  echo "$vjson" | jq -r '.downloads.server.url'
}

get_version_jar() {
  local ver="$1"
  local manifest version_url vjson
  manifest="$(curl -fsSL https://piston-meta.mojang.com/mc/game/version_manifest_v2.json)"
  version_url="$(echo "$manifest" | jq -r --arg id "$ver" '.versions[] | select(.id==$id) | .url')"
  [[ -z "$version_url" || "$version_url" == "null" ]] && {
    log_error "Unbekannte Minecraft-Version: ${ver}"
    exit 1
  }
  vjson="$(curl -fsSL "$version_url")"
  echo "$vjson" | jq -r '.downloads.server.url'
}

if [[ -n "${SERVER_JAR_URL}" ]]; then
  JAR_URL="${SERVER_JAR_URL}"
  log_info "Nutze benutzerdefinierte Server-JAR URL"
else
  if [[ "${MC_VERSION}" == "latest" ]]; then
    JAR_URL="$(get_latest_jar)"
    log_info "Nutze neueste Minecraft-Version"
  else
    JAR_URL="$(get_version_jar "${MC_VERSION}")"
    log_info "Nutze Minecraft-Version ${MC_VERSION}"
  fi
fi

URL_MARKER=".server_jar_url.txt"
if [[ ! -f "${SERVER_JAR}" || ! -f "${URL_MARKER}" || "$(cat "${URL_MARKER}")" != "${JAR_URL}" ]]; then
  log_info "Lade Server-JAR herunter"
  curl -fL --retry 3 --retry-delay 2 "${JAR_URL}" -o "${SERVER_JAR}"
  echo "${JAR_URL}" > "${URL_MARKER}"
fi

# -----------------------------------------------------------
# EULA IMMER akzeptieren
# -----------------------------------------------------------
cat > ./eula.txt <<'EOF'
#By changing the setting below to TRUE you are indicating your agreement to the Minecraft EULA (https://aka.ms/MinecraftEULA).
eula=true
EOF
log_info "EULA automatisch akzeptiert"

# -----------------------------------------------------------
# server.properties – Port fest setzen
# -----------------------------------------------------------
if [[ -f "./server.properties" ]]; then
  sed -i "s/^server-port=.*/server-port=${CONTAINER_PORT}/" ./server.properties || true
else
  echo "server-port=${CONTAINER_PORT}" > ./server.properties
fi

# -----------------------------------------------------------
# Start
# -----------------------------------------------------------
export JAVA_TOOL_OPTIONS="-Xms${XMS_MB}M -Xmx${XMX_MB}M"

log_info "Starte Minecraft Vanilla Server"
log_info "Port (Container): ${CONTAINER_PORT}"
log_info "RAM             : Xms=${XMS_MB}M / Xmx=${XMX_MB}M"
log_info "Datenverzeichnis: ${DATA_DIR}"
log_info "Logdatei        : ${LOG_FILE}"
echo "-----------------------------------------------------------"

{
  echo ""
  echo "==================== $(date -Iseconds) ===================="
  echo "Minecraft Vanilla | Port ${CONTAINER_PORT} | Xms/Xmx ${XMS_MB}/${XMX_MB} MB"
  echo "==========================================================="
} >> "${LOG_FILE}"

exec java -jar "${SERVER_JAR}" nogui 2>&1 | tee -a "${LOG_FILE}"
