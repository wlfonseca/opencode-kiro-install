#!/usr/bin/env bash
set -Eeuo pipefail

# Installs the OpenCode host together with the native Kiro provider.
# The defaults are pinned so that a fresh install is reproducible.

readonly OPENCODE_VERSION="${OPENCODE_VERSION:-2.0.26}"
readonly KIRO_NATIVE_REPO="${KIRO_NATIVE_REPO:-https://github.com/wlfonseca/kiro-native.git}"
readonly KIRO_NATIVE_REF="${KIRO_NATIVE_REF:-11bced129fe2dcb45a9ec2ba0ee2fbdedf7e08d4}"
readonly NPM_PREFIX="${NPM_PREFIX:-${HOME}/.local}"
readonly OPENCODE_HOME="${OPENCODE_HOME:-${HOME}/.local/share/opencode-kiro}"
readonly PROVIDER_DIR="${OPENCODE_HOME}/kiro-native"
readonly CONFIG_FILE="${OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/opencode/opencode.json}"
TEMP_DIR=""

log() {
  printf '[opencode-kiro] %s\n' "$*"
}

die() {
  printf '[opencode-kiro] erro: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

version_at_least_20() {
  local major
  major="${1%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 20 ))
}

require_dependencies() {
  local missing=()
  local command

  for command in git node npm; do
    command_exists "$command" || missing+=("$command")
  done

  ((${#missing[@]} == 0)) || die "dependências ausentes: ${missing[*]}"

  local node_version
  node_version="$(node --version)"
  version_at_least_20 "${node_version#v}" || die "Node.js >= 20 é necessário (encontrado: ${node_version})"

  case "$(uname -s)" in
    Linux|Darwin) ;;
    *) die "sistema operacional não suportado: $(uname -s)" ;;
  esac
}

install_opencode() {
  local installed_version=""
  if command_exists opencode; then
    installed_version="$(opencode --version 2>/dev/null || true)"
  fi

  if [[ "$installed_version" == *"v${OPENCODE_VERSION}"* ]]; then
    log "OpenCode ${OPENCODE_VERSION} já está instalado"
    return
  fi

  log "instalando @opencode/cli@${OPENCODE_VERSION} em ${NPM_PREFIX}"
  mkdir -p "$NPM_PREFIX"
  npm install --global --prefix "$NPM_PREFIX" "@opencode/cli@${OPENCODE_VERSION}"
  export PATH="${NPM_PREFIX}/bin:${PATH}"
}

persist_path() {
  local path_entry="${NPM_PREFIX}/bin"
  local export_line="export PATH=\"${path_entry}:\$PATH\""
  local profile
  local profiles=()

  case "${SHELL##*/}" in
    zsh) profiles+=("${ZDOTDIR:-${HOME}}/.zshrc") ;;
    bash) profiles+=("${HOME}/.bashrc") ;;
  esac
  profiles+=("${HOME}/.profile")

  if [[ ":${PATH}:" != *":${path_entry}:"* ]]; then
    for profile in "${profiles[@]}"; do
      [[ -f "$profile" ]] || continue
      if ! grep -Fqx "$export_line" "$profile"; then
        printf '\n# OpenCode installed by opencode-kiro\n%s\n' "$export_line" >> "$profile"
        log "PATH persistido em ${profile}"
      fi
      break
    done
  fi

  export PATH="${path_entry}:${PATH}"
}

clone_or_update_provider() {
  local had_provider=0

  mkdir -p "$OPENCODE_HOME"
  TEMP_DIR="${OPENCODE_HOME}/.kiro-native.tmp.$$"
  trap 'if [[ -n "${TEMP_DIR:-}" ]]; then rm -rf -- "$TEMP_DIR"; fi' EXIT

  if [[ -e "$PROVIDER_DIR" && ! -d "$PROVIDER_DIR/.git" ]]; then
    die "${PROVIDER_DIR} já existe e não é um checkout Git; remova-o ou defina OPENCODE_HOME"
  fi

  if [[ -d "$PROVIDER_DIR/.git" ]]; then
    had_provider=1
    if [[ -n "$(git -C "$PROVIDER_DIR" status --porcelain)" ]]; then
      die "${PROVIDER_DIR} tem alterações locais; preserve-as ou use outro OPENCODE_HOME"
    fi
    log "atualizando provider Kiro para ${KIRO_NATIVE_REF:0:12}"
    git -C "$PROVIDER_DIR" fetch --depth 1 origin "$KIRO_NATIVE_REF"
    git -C "$PROVIDER_DIR" checkout --detach --quiet "$KIRO_NATIVE_REF"
  else
    log "baixando provider Kiro (${KIRO_NATIVE_REF:0:12})"
    git clone --quiet --filter=blob:none "$KIRO_NATIVE_REPO" "$TEMP_DIR"
    git -C "$TEMP_DIR" fetch --depth 1 origin "$KIRO_NATIVE_REF"
    git -C "$TEMP_DIR" checkout --detach --quiet "$KIRO_NATIVE_REF"
    mv -- "$TEMP_DIR" "$PROVIDER_DIR"
  fi

  log "instalando dependências e compilando provider"
  npm --prefix "$PROVIDER_DIR" ci
  npm --prefix "$PROVIDER_DIR" run build

  if ((had_provider)); then
    log "provider Kiro atualizado"
  else
    log "provider Kiro instalado"
  fi
}

configure_opencode() {
  mkdir -p "$(dirname "$CONFIG_FILE")"

  node - "$CONFIG_FILE" "$PROVIDER_DIR" "$OPENCODE_VERSION" <<'NODE'
const fs = require("node:fs")
const path = require("node:path")

const [configPath, providerPath, opencodeVersion] = process.argv.slice(2)

function stripJsonComments(source) {
  let output = ""
  let quoted = false
  let escaped = false
  let lineComment = false
  let blockComment = false

  for (let i = 0; i < source.length; i += 1) {
    const char = source[i]
    const next = source[i + 1]

    if (lineComment) {
      if (char === "\n") {
        lineComment = false
        output += char
      }
      continue
    }

    if (blockComment) {
      if (char === "*" && next === "/") {
        blockComment = false
        i += 1
      } else if (char === "\n") {
        output += char
      }
      continue
    }

    if (quoted) {
      output += char
      if (escaped) escaped = false
      else if (char === "\\") escaped = true
      else if (char === '"') quoted = false
      continue
    }

    if (char === '"') {
      quoted = true
      output += char
    } else if (char === "/" && next === "/") {
      lineComment = true
      i += 1
    } else if (char === "/" && next === "*") {
      blockComment = true
      i += 1
    } else {
      output += char
    }
  }

  return output
}

function removeTrailingCommas(source) {
  let output = ""
  let quoted = false
  let escaped = false

  for (let i = 0; i < source.length; i += 1) {
    const char = source[i]
    if (quoted) {
      output += char
      if (escaped) escaped = false
      else if (char === "\\") escaped = true
      else if (char === '"') quoted = false
      continue
    }
    if (char === '"') {
      quoted = true
      output += char
      continue
    }
    if (char === ",") {
      let next = i + 1
      while (/\s/.test(source[next] || "")) next += 1
      if (source[next] === "}" || source[next] === "]") continue
    }
    output += char
  }

  return output
}

let config = {}
let originalMode = 0o600
if (fs.existsSync(configPath)) {
  const source = fs.readFileSync(configPath, "utf8")
  try {
    const normalized = removeTrailingCommas(stripJsonComments(source.replace(/^\uFEFF/, "")))
    config = JSON.parse(normalized)
    if (!config || Array.isArray(config) || typeof config !== "object") {
      throw new Error("a raiz precisa ser um objeto")
    }
  } catch (error) {
    console.error(`não foi possível ler ${configPath}: ${error.message}`)
    process.exit(1)
  }

  originalMode = fs.statSync(configPath).mode & 0o777
  const backupPath = `${configPath}.bak.${new Date().toISOString().replace(/[.:]/g, "-")}`
  fs.copyFileSync(configPath, backupPath)
  console.log(`backup da configuração: ${backupPath}`)
}

const modelsPath = path.join(providerPath, "models.json")
const models = JSON.parse(fs.readFileSync(modelsPath, "utf8"))
config.provider = config.provider && typeof config.provider === "object" && !Array.isArray(config.provider)
  ? config.provider
  : {}
config.provider["kiro-native"] = {
  npm: providerPath,
  name: "Kiro Native",
  models,
}

const tempPath = `${configPath}.tmp.${process.pid}`
fs.writeFileSync(tempPath, `${JSON.stringify(config, null, 2)}\n`, { mode: originalMode })
fs.renameSync(tempPath, configPath)
console.log(`provider configurado em ${configPath}`)
console.log(`OpenCode alvo: ${opencodeVersion}`)
NODE
}

validate_installation() {
  export PATH="${NPM_PREFIX}/bin:${PATH}"
  command_exists opencode || die "OpenCode não ficou disponível em PATH; adicione ${NPM_PREFIX}/bin ao PATH"
  local actual_version
  actual_version="$(opencode --version 2>/dev/null || true)"
  [[ "$actual_version" == *"v${OPENCODE_VERSION}"* ]] || die "versão inesperada do OpenCode: ${actual_version:-desconhecida}"
  [[ -f "${PROVIDER_DIR}/dist/index.js" ]] || die "build do provider não produziu ${PROVIDER_DIR}/dist/index.js"
  log "OpenCode validado: ${actual_version}"
  log "provider validado: ${PROVIDER_DIR}"
  if command_exists kiro-cli; then
    log "kiro-cli encontrado: $(kiro-cli --version 2>/dev/null || echo instalado)"
  else
    log "aviso: kiro-cli não está no PATH; instale-o e execute 'kiro-cli login' antes de usar o provider"
  fi
}

main() {
  log "instalando OpenCode + Kiro Native"
  require_dependencies
  install_opencode
  persist_path
  clone_or_update_provider
  configure_opencode
  validate_installation
  log "concluído; execute 'kiro-cli login' e depois 'opencode'"
}

main "$@"
