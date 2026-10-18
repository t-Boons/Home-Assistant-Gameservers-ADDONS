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
echo " Minecraft Dedicated Server (Home Assistant Add-on)"
echo "-----------------------------------------------------------"

# -----------------------------------------------------------
# Optionen
# -----------------------------------------------------------
DATA_DIR="$(jq -r '.data_dir' /data/options.json)"
XMS_MB="$(jq -r '.xms_mb' /data/options.json)"
XMX_MB="$(jq -r '.xmx_mb' /data/options.json)"
MC_VERSION="$(jq -r '.mc_version' /data/options.json)"
SERVER_JAR_URL="$(jq -r '.server_jar_url' /data/options.json)"
MODPACK_URL="$(jq -r '.modpack_url // ""' /data/options.json)"
JAVA_VERSION="$(jq -r '.java_version // "25"' /data/options.json)"

[[ "${DATA_DIR}" == "null" || -z "${DATA_DIR}" ]] && DATA_DIR="/share/minecraft-vanilla"
[[ "${MC_VERSION}" == "null" || -z "${MC_VERSION}" ]] && MC_VERSION="latest"
[[ "${SERVER_JAR_URL}" == "null" ]] && SERVER_JAR_URL=""
[[ "${MODPACK_URL}" == "null" ]] && MODPACK_URL=""
[[ "${JAVA_VERSION}" == "null" || -z "${JAVA_VERSION}" ]] && JAVA_VERSION="25"

CONTAINER_PORT="25565"

mkdir -p "${DATA_DIR}"
cd "${DATA_DIR}"

LOG_DIR="${DATA_DIR}/logs"
LOG_FILE="${LOG_DIR}/ha_console.log"
mkdir -p "${LOG_DIR}"

# -----------------------------------------------------------
# Java automatisch installieren (Temurin)
# -----------------------------------------------------------
JRE_DIR="${DATA_DIR}/.jre/${JAVA_VERSION}"
JAVA_HOME="${JRE_DIR}"
JAVA_BIN="${JAVA_HOME}/bin/java"

install_java() {
  if [[ -x "${JAVA_BIN}" ]]; then
    return 0
  fi

  log_info "Java ${JAVA_VERSION} nicht gefunden – installiere Temurin JRE"

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
  TMP="/tmp/jre.tar.gz"
  URL="https://api.adoptium.net/v3/binary/latest/${JAVA_VERSION}/ga/linux/${adoptium_arch}/jre/hotspot/normal/eclipse?project=jdk"

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
# unzip sicherstellen (für Modpacks)
# -----------------------------------------------------------
ensure_unzip() {
  if command -v unzip >/dev/null 2>&1; then
    return 0
  fi
  log_info "unzip nicht gefunden – versuche Installation"
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache unzip
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y unzip
  else
    log_error "unzip fehlt und konnte nicht installiert werden"
    exit 1
  fi
}

# -----------------------------------------------------------
# Modpack installieren (CurseForge Server Pack ZIP)
# -----------------------------------------------------------
install_modpack() {
  local marker=".modpack_url.txt"
  if [[ -f "${marker}" && "$(cat "${marker}")" == "${MODPACK_URL}" ]]; then
    log_info "Modpack unverändert – überspringe Installation"
    return 0
  fi

  

  ensure_unzip

  log_info "Lade Modpack herunter"
  rm -rf /tmp/modpack /tmp/modpack.zip
  curl -fL --retry 3 --retry-delay 2 \
  -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" \
  "${MODPACK_URL}" -o /tmp/modpack.zip
  if ! unzip -tq /tmp/modpack.zip >/dev/null 2>&1; then
  log_error "Download ist kein gültiges ZIP. Anfang der Datei:"
  head -c 300 /tmp/modpack.zip
  echo
  rm -f /tmp/modpack.zip
  exit 1
fi
  mkdir -p /tmp/modpack
  unzip -q /tmp/modpack.zip -d /tmp/modpack

  # Alte Mods/Configs entfernen (Welt & server.properties bleiben erhalten)
  log_info "Entferne alte Mods und Configs"
  rm -rf mods config defaultconfigs kubejs libraries

  # Falls die ZIP nur einen Unterordner enthält, diesen verwenden
  local entries=(/tmp/modpack/*)
  if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
    cp -a "${entries[0]}"/. .
  else
    cp -a /tmp/modpack/. .
  fi
  rm -rf /tmp/modpack /tmp/modpack.zip

  # Forge/NeoForge Installer ausführen, falls vorhanden
  local installer
  installer="$(ls *installer*.jar 2>/dev/null | head -n1 || true)"
  if [[ -n "${installer}" && ! -f run.sh ]]; then
    log_info "Führe Installer aus: ${installer}"
    java -jar "${installer}" --installServer
  fi

  echo "${MODPACK_URL}" > "${marker}"
  log_info "Modpack installiert"
}

# -----------------------------------------------------------
# Server-JAR ermitteln (Mojang piston-meta) – nur Vanilla
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

install_vanilla() {
  local jar_url
  if [[ -n "${SERVER_JAR_URL}" ]]; then
    jar_url="${SERVER_JAR_URL}"
    log_info "Nutze benutzerdefinierte Server-JAR URL"
  else
    if [[ "${MC_VERSION}" == "latest" ]]; then
      jar_url="$(get_latest_jar)"
      log_info "Nutze neueste Minecraft-Version"
    else
      jar_url="$(get_version_jar "${MC_VERSION}")"
      log_info "Nutze Minecraft-Version ${MC_VERSION}"
    fi
  fi

  local url_marker=".server_jar_url.txt"
  if [[ ! -f "${SERVER_JAR}" || ! -f "${url_marker}" || "$(cat "${url_marker}")" != "${jar_url}" ]]; then
    log_info "Lade Server-JAR herunter"
    curl -fL --retry 3 --retry-delay 2 "${jar_url}" -o "${SERVER_JAR}"
    echo "${jar_url}" > "${url_marker}"
  fi
}

if [[ -n "${MODPACK_URL}" ]]; then
  install_modpack
else
  install_vanilla
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

if [[ -n "${MODPACK_URL}" ]]; then
  MODE="Modpack"
else
  MODE="Vanilla"
fi

log_info "Starte Minecraft Server (${MODE})"
log_info "Port (Container): ${CONTAINER_PORT}"
log_info "RAM             : Xms=${XMS_MB}M / Xmx=${XMX_MB}M"
log_info "Datenverzeichnis: ${DATA_DIR}"
log_info "Logdatei        : ${LOG_FILE}"
echo "-----------------------------------------------------------"

{
  echo ""
  echo "==================== $(date -Iseconds) ===================="
  echo "Minecraft ${MODE} | Port ${CONTAINER_PORT} | Xms/Xmx ${XMS_MB}/${XMX_MB} MB"
  echo "==========================================================="
} >> "${LOG_FILE}"

if [[ -n "${MODPACK_URL}" ]]; then
  if [[ -f run.sh ]]; then                       # neues Forge / NeoForge
    exec bash run.sh nogui 2>&1 | tee -a "${LOG_FILE}"
  elif [[ -f fabric-server-launch.jar ]]; then   # Fabric
    exec java -jar fabric-server-launch.jar nogui 2>&1 | tee -a "${LOG_FILE}"
  else
    log_error "Kein Startskript im Modpack gefunden (run.sh / fabric-server-launch.jar)"
    exit 1
  fi
else
  exec java -jar "${SERVER_JAR}" nogui 2>&1 | tee -a "${LOG_FILE}"
fi
