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
# Options
# -----------------------------------------------------------
DATA_DIR="$(jq -r '.data_dir' /data/options.json)"
XMS_MB="$(jq -r '.xms_mb' /data/options.json)"
XMX_MB="$(jq -r '.xmx_mb' /data/options.json)"
MC_VERSION="$(jq -r '.mc_version' /data/options.json)"
SERVER_JAR_URL="$(jq -r '.server_jar_url' /data/options.json)"
MODPACK_URL="$(jq -r '.modpack_url // ""' /data/options.json)"
JAVA_VERSION="$(jq -r '.java_version // "25"' /data/options.json)"
CF_API_KEY="$(jq -r '.curseforge_api_key // ""' /data/options.json)"

[[ "${DATA_DIR}" == "null" || -z "${DATA_DIR}" ]] && DATA_DIR="/share/minecraft-vanilla"
[[ "${MC_VERSION}" == "null" || -z "${MC_VERSION}" ]] && MC_VERSION="latest"
[[ "${SERVER_JAR_URL}" == "null" ]] && SERVER_JAR_URL=""
[[ "${MODPACK_URL}" == "null" ]] && MODPACK_URL=""
[[ "${JAVA_VERSION}" == "null" || -z "${JAVA_VERSION}" ]] && JAVA_VERSION="25"
[[ "${CF_API_KEY}" == "null" ]] && CF_API_KEY=""

CONTAINER_PORT="25565"

mkdir -p "${DATA_DIR}"
cd "${DATA_DIR}"

LOG_DIR="${DATA_DIR}/logs"
LOG_FILE="${LOG_DIR}/ha_console.log"
mkdir -p "${LOG_DIR}"

# -----------------------------------------------------------
# Install Java automatically (Temurin)
# -----------------------------------------------------------
JRE_DIR="${DATA_DIR}/.jre/${JAVA_VERSION}"
JAVA_HOME="${JRE_DIR}"
JAVA_BIN="${JAVA_HOME}/bin/java"

install_java() {
  if [[ -x "${JAVA_BIN}" ]]; then
    return 0
  fi

  log_info "Java ${JAVA_VERSION} not found - installing Temurin JRE"

  local arch adoptium_arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  adoptium_arch="x64" ;;
    aarch64|arm64) adoptium_arch="aarch64" ;;
    *)
      log_error "Unsupported architecture: ${arch}"
      exit 1
      ;;
  esac

  mkdir -p "${JRE_DIR}"
  local tmp="/tmp/jre.tar.gz"
  local url="https://api.adoptium.net/v3/binary/latest/${JAVA_VERSION}/ga/linux/${adoptium_arch}/jre/hotspot/normal/eclipse?project=jdk"

  curl -fL --retry 3 --retry-delay 2 "${url}" -o "${tmp}"
  rm -rf "${JRE_DIR:?}/"*
  tar -xzf "${tmp}" -C "${JRE_DIR}" --strip-components=1
  rm -f "${tmp}"

  [[ -x "${JAVA_BIN}" ]] || { log_error "Java installation failed"; exit 1; }
}

install_java
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"
log_info "Java version: $(java -version 2>&1 | head -n1)"

# -----------------------------------------------------------
# Make sure unzip is available (needed for modpacks)
# -----------------------------------------------------------
ensure_unzip() {
  if command -v unzip >/dev/null 2>&1; then
    return 0
  fi
  log_info "unzip not found - trying to install it"
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache unzip
  elif command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y unzip
  else
    log_error "unzip is missing and could not be installed"
    exit 1
  fi
}

# -----------------------------------------------------------
# Detect mod loader (Fabric / Forge / NeoForge)
# -----------------------------------------------------------
LOADER=""
LOADER_VER=""
PACK_MC=""

detect_loader() {
  LOADER=""; LOADER_VER=""; PACK_MC=""

  # 1) manifest.json (if the pack has one)
  if [[ -f manifest.json ]]; then
    PACK_MC="$(jq -r '.minecraft.version // empty' manifest.json)"
    local id
    id="$(jq -r '.minecraft.modLoaders[0].id // empty' manifest.json)"
    if [[ -n "${id}" ]]; then
      LOADER="${id%%-*}"
      LOADER_VER="${id#*-}"
    fi
  fi

  # 2) Otherwise detect from the mod jars
  if [[ -z "${LOADER}" ]]; then
    local f=0 n=0 g=0 jar list
    for jar in mods/*.jar; do
      [[ -e "${jar}" ]] || continue
      list="$(unzip -l "${jar}" 2>/dev/null || true)"
      grep -q 'fabric.mod.json' <<<"${list}" && f=$((f+1))
      grep -q 'META-INF/neoforge.mods.toml' <<<"${list}" && n=$((n+1))
      grep -q 'META-INF/mods.toml' <<<"${list}" && g=$((g+1))
    done
    if (( f > 0 && f >= n && f >= g )); then LOADER="fabric"
    elif (( n > 0 && n >= g )); then LOADER="neoforge"
    elif (( g > 0 )); then LOADER="forge"
    fi
  fi

  # 3) Minecraft version from the add-on config if not in the manifest
  if [[ -z "${PACK_MC}" && "${MC_VERSION}" != "latest" ]]; then
    PACK_MC="${MC_VERSION}"
  fi

  if [[ -z "${LOADER}" ]]; then
    log_error "Could not detect the mod loader (no manifest.json and no mods found)"
    exit 1
  fi
  if [[ -z "${PACK_MC}" ]]; then
    log_error "Minecraft version unknown - please set 'mc_version' in the add-on configuration"
    exit 1
  fi
  log_info "Detected: ${LOADER} ${LOADER_VER:-(latest)} for Minecraft ${PACK_MC}"
}

install_loader() {
  local mc="${PACK_MC}"
  case "${LOADER}" in
    fabric)
      local inst lv="${LOADER_VER}"
      inst="$(curl -fsSL https://meta.fabricmc.net/v2/versions/installer | jq -r '[.[]|select(.stable)][0].version')"
      if [[ -z "${lv}" ]]; then
        lv="$(curl -fsSL "https://meta.fabricmc.net/v2/versions/loader/${mc}" | jq -r '[.[]|select(.loader.stable)][0].loader.version')"
      fi
      curl -fL "https://meta.fabricmc.net/v2/versions/loader/${mc}/${lv}/${inst}/server/jar" -o fabric-server-launch.jar
      ;;
    forge)
      local fv="${LOADER_VER}"
      if [[ -z "${fv}" ]]; then
        fv="$(curl -fsSL https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json | jq -r --arg k "${mc}-latest" '.promos[$k] // empty')"
      fi
      [[ -z "${fv}" ]] && { log_error "No Forge version found for ${mc}"; exit 1; }
      curl -fL "https://maven.minecraftforge.net/net/minecraftforge/forge/${mc}-${fv}/forge-${mc}-${fv}-installer.jar" -o loader-installer.jar
      java -jar loader-installer.jar --installServer
      rm -f loader-installer.jar
      ;;
    neoforge)
      local nv="${LOADER_VER}"
      if [[ -z "${nv}" ]]; then
        local prefix="${mc#1.}"
        [[ "${prefix}" != *.* ]] && prefix="${prefix}.0"
        nv="$(curl -fsSL https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge | jq -r --arg p "${prefix}." '[.versions[]|select(startswith($p))|select(contains("-")|not)]|last // empty')"
      fi
      [[ -z "${nv}" ]] && { log_error "No NeoForge version found for ${mc}"; exit 1; }
      curl -fL "https://maven.neoforged.net/releases/net/neoforged/neoforge/${nv}/neoforge-${nv}-installer.jar" -o loader-installer.jar
      java -jar loader-installer.jar --installServer
      rm -f loader-installer.jar
      ;;
    *)
      log_error "Unsupported loader: ${LOADER}"
      exit 1
      ;;
  esac
}

# -----------------------------------------------------------
# Client pack: download all mods listed in manifest.json
# (needs a free CurseForge API key)
# -----------------------------------------------------------
install_client_pack() {
  if [[ -z "${CF_API_KEY}" ]]; then
    log_error "This is a client pack (manifest.json + overrides/). Downloading its mods needs a CurseForge API key."
    log_error "Get a free key at https://console.curseforge.com and enter it as 'curseforge_api_key' in the add-on configuration."
    exit 1
  fi

  log_info "Client pack detected - downloading mods from CurseForge"
  mkdir -p mods

  local total i=0 failed=0 pid fid info name url
  total="$(jq '.files | length' manifest.json)"

  while IFS=$'\t' read -r pid fid; do
    i=$((i+1))
    info="$(curl -fsSL --retry 3 \
      -H "x-api-key: ${CF_API_KEY}" -H "Accept: application/json" \
      "https://api.curseforge.com/v1/mods/${pid}/files/${fid}" || true)"
    name="$(jq -r '.data.fileName // empty' <<<"${info}" 2>/dev/null || true)"
    url="$(jq -r '.data.downloadUrl // empty' <<<"${info}" 2>/dev/null || true)"

    if [[ -z "${name}" ]]; then
      log_warn "[${i}/${total}] Could not look up mod ${pid} / file ${fid}"
      failed=$((failed+1))
      continue
    fi

    # Some mods hide their download URL - build the CDN URL manually
    if [[ -z "${url}" ]]; then
      url="https://edge.forgecdn.net/files/$((fid/1000))/$((fid%1000))/${name}"
    fi
    url="${url// /%20}"

    if curl -fsSL --retry 3 "${url}" -o "mods/${name}"; then
      log_info "[${i}/${total}] ${name}"
    else
      log_warn "[${i}/${total}] Download failed: ${name}"
      rm -f "mods/${name}"
      failed=$((failed+1))
    fi
  done < <(jq -r '.files[] | [.projectID, .fileID] | @tsv' manifest.json)

  if (( failed > 0 )); then
    log_warn "${failed} of ${total} mods could not be downloaded"
  fi

  # Copy the pack's configs and other files into the server folder
  if [[ -d overrides ]]; then
    cp -a overrides/. .
    rm -rf overrides
  fi

  log_warn "Client packs can contain client-only mods (shaders, minimaps, etc.)."
  log_warn "If the server crashes on startup, remove the mod named in the crash log from ${DATA_DIR}/mods."
}

# -----------------------------------------------------------
# Install modpack (server pack or client pack ZIP)
# -----------------------------------------------------------
pack_has_launcher() {
  [[ -f run.sh || -f fabric-server-launch.jar ]] \
    || ls start*.sh >/dev/null 2>&1 \
    || ls forge-*.jar neoforge-*.jar >/dev/null 2>&1
}

install_modpack() {
  local marker=".modpack_url.txt"
  if [[ -f "${marker}" && "$(cat "${marker}")" == "${MODPACK_URL}" ]] && pack_has_launcher; then
    log_info "Modpack unchanged - skipping installation"
    return 0
  fi

  ensure_unzip

  log_info "Downloading modpack"
  rm -rf /tmp/modpack /tmp/modpack.zip
  curl -fL --retry 3 --retry-delay 2 \
    -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" \
    "${MODPACK_URL}" -o /tmp/modpack.zip

  if ! unzip -tq /tmp/modpack.zip >/dev/null 2>&1; then
    log_error "Download is not a valid ZIP. Start of the file:"
    head -c 300 /tmp/modpack.zip || true
    echo
    rm -f /tmp/modpack.zip
    exit 1
  fi

  mkdir -p /tmp/modpack
  unzip -q /tmp/modpack.zip -d /tmp/modpack

  # Remove old loader, mods and configs (world & server.properties are kept)
  log_info "Removing old mods, configs and loader"
  rm -rf mods config defaultconfigs kubejs libraries versions .fabric overrides
  rm -f run.sh user_jvm_args.txt fabric-server-launch.jar server.jar manifest.json

  # If the ZIP only contains one subfolder, use its contents
  local entries=(/tmp/modpack/*)
  if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
    cp -a "${entries[0]}"/. .
  else
    cp -a /tmp/modpack/. .
  fi
  rm -rf /tmp/modpack /tmp/modpack.zip

  # Client pack: fetch the mods listed in manifest.json
  if [[ ! -d mods && -f manifest.json ]]; then
    install_client_pack
  elif [[ ! -d mods && -d overrides ]]; then
    log_error "This looks like a client pack but has no manifest.json, so the mods cannot be downloaded."
    exit 1
  fi

  # Install a loader if the pack does not ship its own launcher
  if [[ ! -f run.sh && ! -f fabric-server-launch.jar ]]; then
    local installer
    installer="$(ls *installer*.jar 2>/dev/null | head -n1 || true)"
    if [[ -n "${installer}" ]]; then
      log_info "Running installer: ${installer}"
      java -jar "${installer}" --installServer
    elif ls start*.sh >/dev/null 2>&1; then
      log_info "Pack ships its own start script"
    else
      detect_loader
      install_loader
    fi
  fi

  echo "${MODPACK_URL}" > "${marker}"
  log_info "Modpack installed"
}

# -----------------------------------------------------------
# Get the server JAR (Mojang piston-meta) - vanilla only
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
    log_error "Unknown Minecraft version: ${ver}"
    exit 1
  }
  vjson="$(curl -fsSL "$version_url")"
  echo "$vjson" | jq -r '.downloads.server.url'
}

install_vanilla() {
  local jar_url
  if [[ -n "${SERVER_JAR_URL}" ]]; then
    jar_url="${SERVER_JAR_URL}"
    log_info "Using custom server JAR URL"
  else
    if [[ "${MC_VERSION}" == "latest" ]]; then
      jar_url="$(get_latest_jar)"
      log_info "Using latest Minecraft version"
    else
      jar_url="$(get_version_jar "${MC_VERSION}")"
      log_info "Using Minecraft version ${MC_VERSION}"
    fi
  fi

  local url_marker=".server_jar_url.txt"
  if [[ ! -f "${SERVER_JAR}" || ! -f "${url_marker}" || "$(cat "${url_marker}")" != "${jar_url}" ]]; then
    log_info "Downloading server JAR"
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
# ALWAYS accept the EULA
# -----------------------------------------------------------
cat > ./eula.txt <<'EOF'
#By changing the setting below to TRUE you are indicating your agreement to the Minecraft EULA (https://aka.ms/MinecraftEULA).
eula=true
EOF
log_info "EULA accepted automatically"

# -----------------------------------------------------------
# server.properties - force the port
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

log_info "Starting Minecraft server (${MODE})"
log_info "Port (container): ${CONTAINER_PORT}"
log_info "RAM             : Xms=${XMS_MB}M / Xmx=${XMX_MB}M"
log_info "Data directory  : ${DATA_DIR}"
log_info "Log file        : ${LOG_FILE}"
echo "-----------------------------------------------------------"

{
  echo ""
  echo "==================== $(date -Iseconds) ===================="
  echo "Minecraft ${MODE} | Port ${CONTAINER_PORT} | Xms/Xmx ${XMS_MB}/${XMX_MB} MB"
  echo "==========================================================="
} >> "${LOG_FILE}"

if [[ -n "${MODPACK_URL}" ]]; then
  if [[ -f run.sh ]]; then                       # new Forge / NeoForge
    exec bash run.sh nogui 2>&1 | tee -a "${LOG_FILE}"
  elif [[ -f fabric-server-launch.jar ]]; then   # Fabric
    exec java -jar fabric-server-launch.jar nogui 2>&1 | tee -a "${LOG_FILE}"
  else
    START_SH="$(ls start*.sh 2>/dev/null | head -n1 || true)"
    FORGE_JAR="$(ls forge-*.jar neoforge-*.jar 2>/dev/null | grep -vi installer | head -n1 || true)"
    if [[ -n "${START_SH}" ]]; then
      log_info "Using ${START_SH}"
      exec bash "${START_SH}" 2>&1 | tee -a "${LOG_FILE}"
    elif [[ -n "${FORGE_JAR}" ]]; then
      log_info "Using ${FORGE_JAR}"
      exec java -jar "${FORGE_JAR}" nogui 2>&1 | tee -a "${LOG_FILE}"
    else
      log_error "No start script found. Contents of ${DATA_DIR}:"
      ls -la
      exit 1
    fi
  fi
else
  exec java -jar "${SERVER_JAR}" nogui 2>&1 | tee -a "${LOG_FILE}"
fi
