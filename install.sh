#!/usr/bin/env bash
#
# Pelican Panel & Wings installer (unofficial)
# Based on: https://pelican.dev/docs/panel/getting-started
# Not affiliated with the Pelican project.
#
# Usage (as root):
#   bash install.sh
#   curl -fsSL ... | bash
#

set -euo pipefail

[[ ${BASH_VERSINFO[0]} -ge 4 ]] || { echo "Bash 4+ required." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
PELICAN_ROOT="${PELICAN_ROOT:-/var/www/pelican}"
readonly PELICAN_RELEASE_URL="https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz"
readonly SCRIPT_VERSION="1.0.0"

# Runtime (filled by detect_environment)
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY=""
SUPPORTED_OS=0
PHP_VERSION=""          # e.g. 8.5
PHP_PKG_PREFIX=""       # e.g. php8.5
WEB_USER="www-data"
INSTALL_MODE=""         # express | manual
INSTALL_COMPONENTS=""   # panel | wings | both

# Credentials & config (summary at end)
declare -A SUMMARY=()

# ---------------------------------------------------------------------------
# Terminal UI
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  C_HEAD=$'\033[38;5;39m'   # bright blue
  C_ACCENT=$'\033[38;5;214m'
  C_OK=$'\033[38;5;42m'
  C_WARN=$'\033[38;5;214m'
  C_ERR=$'\033[38;5;196m'
  C_MUTED=$'\033[38;5;245m'
  C_STEP=$'\033[38;5;141m'
else
  BOLD=''; DIM=''; RESET=''
  C_HEAD=''; C_ACCENT=''; C_OK=''; C_WARN=''; C_ERR=''; C_MUTED=''; C_STEP=''
fi

# 1 = fewer logs (express); composer/tar/apt/docker redirect or -q
QUIET_INSTALL="${QUIET_INSTALL:-0}"
EXPRESS_LOG="${EXPRESS_LOG:-/tmp/pelican-install.log}"

# Express: hide apt/dpkg/systemctl noise; full output is in EXPRESS_LOG on failure.
run_apt_quiet() {
  if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
    {
      echo "---- apt: $* ----"
      date -Iseconds 2>/dev/null || date
    } >>"$EXPRESS_LOG"
    if ! env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none "$@" >>"$EXPRESS_LOG" 2>&1; then
      error "Package step failed: $*"
      tail -n 60 "$EXPRESS_LOG" >&2
      exit 1
    fi
  else
    env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none "$@"
  fi
}

run_cmd_quiet() {
  if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
    echo "---- cmd: $* ----" >>"$EXPRESS_LOG"
    if ! "$@" >>"$EXPRESS_LOG" 2>&1; then
      error "Command failed: $*"
      tail -n 40 "$EXPRESS_LOG" >&2
      exit 1
    fi
  else
    "$@"
  fi
}

ui_width() { echo "${COLUMNS:-80}"; }

# Fixed width so the banner stays aligned (full $COLUMNS caused huge empty rails).
readonly BANNER_BOX_WIDTH=68

hr() {
  local w; w=$(ui_width)
  # Ultra-wide terminals make section rules unreadably long
  [[ "$w" -gt 78 ]] && w=78
  printf '%*s\n' "$w" '' | tr ' ' '-'
}

# Banner frame: plain text only inside rows — ANSI in the string breaks padding (${#text}).
banner_rule() {
  local w=$(( BANNER_BOX_WIDTH - 2 ))
  printf '%s+' "$C_ACCENT"
  printf '%*s' "$w" '' | tr ' ' '='
  printf '+%s\n' "$RESET"
}

banner_row() {
  local text="$1"
  local inner=$(( BANNER_BOX_WIDTH - 4 ))
  local len=${#text}
  if [[ $len -gt $inner ]]; then
    text="${text:0:$inner}"
    len=$inner
  fi
  local pad=$(( inner - len ))
  printf '%s| %s%*s%s |%s\n' "$C_ACCENT" "$BOLD$text$RESET" "$pad" '' '' "$RESET"
}

# Plain-language context before the framed header (so the UI is not abrupt).
intro_before_ui() {
  echo
  printf '%sPelican Panel & Wings installer%s  %s%s%s\n' "$BOLD" "$RESET" "$DIM" "v${SCRIPT_VERSION}" "$RESET"
  muted "Unofficial install helper (not affiliated with the Pelican project)."
  muted "You will confirm, then pick express or manual mode. Root is required."
  muted "Docs: https://pelican.dev/docs/panel/getting-started"
  echo
}

banner() {
  # Do not clear screen — keeps scrollback for troubleshooting
  banner_rule
  banner_row "  ___      _ _            ___          _ _       _"
  banner_row " | _ \\___ | (_)__ _ _ _  | _ \\_ _ ___ (_) |_ ___| |_"
  banner_row " |  _/ _ \\| | / _\` | '_| |  _/ _\` / -_)|  _/ -_)  _|"
  banner_row " |_| \\___/|_|_\\__,_|_|   |_| \\__,_\\___| \\__\\___|\\__|"
  banner_row ""
  banner_row "  Panel & Wings  ·  v${SCRIPT_VERSION}  ·  unofficial helper"
  banner_rule
  echo
}

# Express: announce step (live bar runs during express_run on stderr).
express_step() {
  local cur="${1:-1}" total="${2:-1}" msg="${3:-}"
  [[ "$total" =~ ^[0-9]+$ ]] || total=1
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=1
  [[ "$total" -lt 1 ]] && total=1
  [[ "$cur" -lt 1 ]] && cur=1
  [[ "$cur" -gt "$total" ]] && cur="$total"
  export EXPRESS_STEP_NUM="$cur"
  export EXPRESS_STEP_TOTAL="$total"
  printf '%s[%sexpress%s]%s %s/%s — %s%s\n' \
    "$C_STEP" "$BOLD" "$RESET" "$RESET" "$cur" "$total" "$msg" "$RESET"
}

# Express only: animated overall % + bar on stderr while a slow command runs (updates ~10×/s).
EXPRESS_PROGRESS_PID=""

_express_progress_pct_bounds() {
  local cur="${1:-1}" total="${2:-1}"
  [[ "$total" -lt 1 ]] && total=1
  EXPRESS_PCT_LO=$(( (cur - 1) * 100 / total ))
  EXPRESS_PCT_HI=$(( cur * 100 / total ))
  [[ "$cur" -eq "$total" ]] && EXPRESS_PCT_HI=100
  [[ "$EXPRESS_PCT_HI" -le "$EXPRESS_PCT_LO" ]] && EXPRESS_PCT_HI=$(( EXPRESS_PCT_LO + 1 ))
}

express_progress_start() {
  local label="${1:-Working}"
  [[ "${QUIET_INSTALL:-0}" != "1" ]] && return 0
  local cur="${EXPRESS_STEP_NUM:-1}" total="${EXPRESS_STEP_TOTAL:-1}"
  printf '\n' >&2
  (
    local pct_lo pct_hi pct tick inner span start_sec bar_w=22 filled i b pos
    pct_lo=$(( (cur - 1) * 100 / total ))
    pct_hi=$(( cur * 100 / total ))
    [[ "$cur" -eq "$total" ]] && pct_hi=100
    [[ "$pct_hi" -le "$pct_lo" ]] && pct_hi=$(( pct_lo + 1 ))
    span=$(( pct_hi - pct_lo ))
    [[ "$span" -lt 1 ]] && span=1
    start_sec=$(date +%s)
    pct=$pct_lo
    while true; do
      tick=$(($(date +%s) - start_sec))
      # Crawl from pct_lo toward pct_hi-1 over ~35s in this step (keeps moving on long apt/docker runs).
      inner=$(( tick * span / 35 ))
      pct=$(( pct_lo + inner ))
      [[ "$pct" -ge "$pct_hi" ]] && pct=$(( pct_hi - 1 ))
      [[ "$cur" -eq "$total" ]] && [[ "$pct" -ge 99 ]] && pct=99
      filled=$(( pct * bar_w / 100 ))
      [[ "$filled" -gt "$bar_w" ]] && filled=$bar_w
      [[ "$filled" -lt 1 ]] && filled=1
      pos=0
      [[ "$filled" -gt 1 ]] && pos=$(( (tick / 2) % filled ))
      b=""
      for ((i = 0; i < bar_w; i++)); do
        if [[ "$i" -lt "$filled" ]]; then
          if [[ "$filled" -gt 1 && "$i" -eq "$pos" ]]; then
            b+="${BOLD}#${RESET}"
          else
            b+='='
          fi
        else
          b+='·'
        fi
      done
      printf '\r  %s[express %s/%s]%s [%b] %3d%%  %s%s%s…%s' \
        "$C_STEP" "$cur" "$total" "$RESET" "$b" "$pct" "$BOLD" "$label" "$RESET" "$C_STEP" "$RESET" >&2
      sleep 0.1
    done
  ) &
  EXPRESS_PROGRESS_PID=$!
}

express_progress_stop() {
  [[ "${QUIET_INSTALL:-0}" != "1" ]] && return 0
  if [[ -n "${EXPRESS_PROGRESS_PID:-}" ]] && kill -0 "$EXPRESS_PROGRESS_PID" 2>/dev/null; then
    kill "$EXPRESS_PROGRESS_PID" 2>/dev/null || true
    wait "$EXPRESS_PROGRESS_PID" 2>/dev/null || true
  fi
  EXPRESS_PROGRESS_PID=""
  local cur="${EXPRESS_STEP_NUM:-1}" total="${EXPRESS_STEP_TOTAL:-1}" pct_hi bar_w=22 filled empty i b
  _express_progress_pct_bounds "$cur" "$total"
  pct_hi=$EXPRESS_PCT_HI
  filled=$(( pct_hi * bar_w / 100 ))
  [[ "$filled" -gt "$bar_w" ]] && filled=$bar_w
  empty=$(( bar_w - filled ))
  b=""
  for ((i = 0; i < filled; i++)); do b+='='; done
  for ((i = 0; i < empty; i++)); do b+='·'; done
  printf '\r  %s[express %s/%s]%s [%s] %3d%%  %s%s%s\n' \
    "$C_STEP" "$cur" "$total" "$RESET" "$b" "$pct_hi" "$C_OK" "✓" "$RESET" >&2
}

# Express: run a command/function with live progress on stderr (stdout unchanged for captures).
express_run() {
  local label="$1"
  shift
  if [[ "${QUIET_INSTALL:-0}" != "1" ]]; then
    "$@"
    return $?
  fi
  express_progress_start "$label"
  set +e
  "$@"
  local ec=$?
  set -e
  express_progress_stop
  return "$ec"
}

section() {
  echo
  printf '%s-- %s%s%s\n' "$C_HEAD" "$BOLD" "$1" "$RESET"
  hr
}

info()    { printf '%s>%s %s\n' "$C_OK" "$RESET" "$*"; }
warn()    { printf '%s!%s %s\n' "$C_WARN" "$RESET" "$*" >&2; }
error()   { printf '%sX%s %s\n' "$C_ERR" "$RESET" "$*" >&2; }
muted()   { printf '%s%s%s\n' "$C_MUTED" "$*" "$RESET"; }

read_tty() {
  read "$@" < /dev/tty 2>/dev/null || read "$@"
}

prompt() {
  local def="$2"
  local r
  if [[ -n "$def" ]]; then
    printf '%s>%s %s %s[%s]%s: ' "$C_ACCENT" "$RESET" "$1" "$DIM" "$def" "$RESET" >&2
  else
    printf '%s>%s %s: ' "$C_ACCENT" "$RESET" "$1" >&2
  fi
  read_tty -r r
  if [[ -z "$r" && -n "$def" ]]; then
    echo "$def"
  else
    echo "$r"
  fi
}

prompt_secret() {
  local r
  printf '%s>%s %s: ' "$C_ACCENT" "$RESET" "$1" >&2
  read_tty -r -s r
  echo >&2
  echo "$r"
}

confirm() {
  local prompt="$1"
  local def="${2:-y}"
  local r
  while true; do
    if [[ "$def" == "y" ]]; then
      printf '%s[%sY%s/%sn%s]%s ' "$DIM" "$C_OK" "$RESET" "$DIM" "$RESET" "$RESET" >&2
    else
      printf '%s[%sy%s/%sY%s]%s ' "$DIM" "$RESET" "$C_OK" "$DIM" "$RESET" "$RESET" >&2
    fi
    printf '%s' "$prompt" >&2
    read_tty -r r
    r="${r:-$def}"
    case "${r,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
  done
}

menu_two() {
  echo
  printf '  %s1)%s %sExpress install%s  — minimal questions, smart defaults for Ubuntu/Debian-style hosts\n' "$C_OK" "$RESET" "$BOLD" "$RESET"
  printf '  %s2)%s %sManual install%s    — choose webserver, PHP, DB, SSL, paths, and every option step by step\n' "$C_OK" "$RESET" "$BOLD" "$RESET"
  echo
  local c
  while true; do
    c=$(prompt "Select mode (1 or 2)" "1")
    case "$c" in
      1) INSTALL_MODE="express"; return 0 ;;
      2) INSTALL_MODE="manual"; return 0 ;;
      *) warn "Please enter 1 or 2." ;;
    esac
  done
}

menu_components() {
  echo
  printf '  %s1)%s Panel only\n' "$C_OK" "$RESET"
  printf '  %s2)%s Wings only  %s(Docker + wings binary; configure node in Panel)%s\n' "$C_OK" "$RESET" "$DIM" "$RESET"
  printf '  %s3)%s Panel + Wings (this machine)\n' "$C_OK" "$RESET"
  echo
  local c
  while true; do
    c=$(prompt "What should we install?" "3")
    case "$c" in
      1) INSTALL_COMPONENTS="panel"; return 0 ;;
      2) INSTALL_COMPONENTS="wings"; return 0 ;;
      3) INSTALL_COMPONENTS="both"; return 0 ;;
      *) warn "Please enter 1, 2, or 3." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
detect_environment() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY="${PRETTY_NAME:-$NAME $VERSION}"
  else
    OS_ID="unknown"
    OS_VERSION_ID=""
    OS_PRETTY="Unknown"
  fi

  SUPPORTED_OS=0
  case "$OS_ID" in
    ubuntu)
      case "${OS_VERSION_ID:-}" in
        22.04|24.04) SUPPORTED_OS=1 ;;
        *) SUPPORTED_OS=1 ;; # allow with warning
      esac
      WEB_USER="www-data"
      ;;
    debian)
      SUPPORTED_OS=1
      WEB_USER="www-data"
      ;;
    rocky|almalinux|centos|rhel)
      SUPPORTED_OS=1
      WEB_USER="nginx"
      ;;
    *)
      SUPPORTED_OS=0
      ;;
  esac
}

os_warning_block() {
  section "Detected environment"
  printf '  %sOS:%s %s\n' "$BOLD" "$RESET" "$OS_PRETTY"
  printf '  %sID:%s %s  %sVersion:%s %s  %sCodename:%s %s\n' \
    "$BOLD" "$RESET" "$OS_ID" "$BOLD" "$RESET" "${OS_VERSION_ID:-n/a}" "$BOLD" "$RESET" "${OS_CODENAME:-n/a}"
  echo
  if [[ "$OS_ID" == "ubuntu" ]]; then
    SUMMARY[ubuntu_version]="${OS_VERSION_ID:-}"
    case "${OS_VERSION_ID:-}" in
      24.04) info "Ubuntu 24.04 LTS — Pelican documentation assumes this baseline (PHP 8.5 recommended)." ;;
      22.04) info "Ubuntu 22.04 LTS — supported; PHP 8.5 may require the ondrej/php PPA (this script adds it if needed)." ;;
      *) warn "Ubuntu ${OS_VERSION_ID:-unknown}: package names may differ; verify PHP 8.2–8.5 per Pelican docs." ;;
    esac
  fi
  if [[ "$SUPPORTED_OS" -eq 0 ]]; then
    warn "Primary testing target is Ubuntu 22.04/24.04. Other distros may need manual package names."
  else
    info "See supported OS matrix: https://pelican.dev/docs/panel/getting-started"
  fi
  echo
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "Run as root (e.g. sudo bash $0)"
    exit 1
  fi
}

# Pick PHP version: prefer 8.5 per docs, fall back per distro
select_php_version() {
  PHP_VERSION="8.5"
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    if apt-cache show "php8.5-fpm" &>/dev/null; then
      PHP_VERSION="8.5"
    elif apt-cache show "php8.4-fpm" &>/dev/null; then
      PHP_VERSION="8.4"
      [[ "${QUIET_INSTALL:-0}" != "1" ]] && warn "php8.5 not in repos yet; using PHP 8.4 (supported by Pelican)."
    elif apt-cache show "php8.3-fpm" &>/dev/null; then
      PHP_VERSION="8.3"
      [[ "${QUIET_INSTALL:-0}" != "1" ]] && warn "Using PHP 8.3 from repositories (Pelican supports 8.2–8.5)."
    else
      PHP_VERSION="8.3"
      [[ "${QUIET_INSTALL:-0}" != "1" ]] && warn "Could not probe packages; defaulting to PHP 8.3 — ensure Pelican-supported PHP is installed."
    fi
  else
    PHP_VERSION="8.3"
    [[ "${QUIET_INSTALL:-0}" != "1" ]] && warn "Non-Debian family: defaulting PHP version label to 8.3 — verify php-fpm package names."
  fi
  PHP_PKG_PREFIX="php${PHP_VERSION}"
  SUMMARY[php_version]="$PHP_VERSION"
}

ensure_php_repo_debian() {
  [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]] || return 0
  if apt-cache show "php8.5-fpm" &>/dev/null; then
    return 0
  fi
  [[ "${QUIET_INSTALL:-0}" != "1" ]] && info "Adding ondrej/php PPA (or sury for Debian) for recent PHP versions…"
  run_apt_quiet apt-get update -qq
  local spq=()
  [[ "${QUIET_INSTALL:-0}" == "1" ]] && spq=(-qq)
  run_apt_quiet apt-get install -y "${spq[@]}" software-properties-common curl gnupg lsb-release
  if [[ "$OS_ID" == "ubuntu" ]]; then
    if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
      echo "---- add-apt-repository ondrej/php ----" >>"$EXPRESS_LOG"
      add-apt-repository -y ppa:ondrej/php >>"$EXPRESS_LOG" 2>&1 || {
        error "add-apt-repository failed; tail of $EXPRESS_LOG:"
        tail -n 40 "$EXPRESS_LOG" >&2
        exit 1
      }
    else
      add-apt-repository -y ppa:ondrej/php
    fi
  else
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/php.gpg 2>/dev/null || true
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
  fi
  run_apt_quiet apt-get update -qq
}

apt_install_panel_deps() {
  ensure_php_repo_debian
  run_apt_quiet apt-get update -qq
  local apt_q=()
  [[ "${QUIET_INSTALL:-0}" == "1" ]] && apt_q=(-qq)
  run_apt_quiet apt-get install -y "${apt_q[@]}" \
    "nginx" \
    "mariadb-server" "mariadb-client" \
    "${PHP_PKG_PREFIX}-fpm" "${PHP_PKG_PREFIX}-cli" "${PHP_PKG_PREFIX}-common" \
    "${PHP_PKG_PREFIX}-mysql" "${PHP_PKG_PREFIX}-gd" "${PHP_PKG_PREFIX}-mbstring" \
    "${PHP_PKG_PREFIX}-bcmath" "${PHP_PKG_PREFIX}-xml" "${PHP_PKG_PREFIX}-curl" \
    "${PHP_PKG_PREFIX}-zip" "${PHP_PKG_PREFIX}-intl" "${PHP_PKG_PREFIX}-sqlite3" \
    curl tar unzip git ca-certificates
  run_cmd_quiet systemctl enable --now "${PHP_PKG_PREFIX}-fpm"
  run_cmd_quiet systemctl restart "${PHP_PKG_PREFIX}-fpm"
}

# ---------------------------------------------------------------------------
# MariaDB helpers
# ---------------------------------------------------------------------------
mysql_exec() {
  if mysql -u root --protocol=socket -e "SELECT 1" &>/dev/null; then
    mysql -u root --protocol=socket -e "$1"
  elif mysql -u root -e "SELECT 1" &>/dev/null; then
    mysql -u root -e "$1"
  else
    error "Could not connect to MariaDB/MySQL as root. Set root access or install mariadb-server."
    exit 1
  fi
}

# DB password for express: mixes admin password + epoch + subsecond + urandom (not only pure openssl rand).
generate_db_password_from_seed() {
  local seed="$1"
  local s ns r out
  s=$(date +%s)
  ns=$(date +%N 2>/dev/null || echo "${RANDOM}${RANDOM}")
  r=$(head -c 64 /dev/urandom 2>/dev/null | base64 | tr -d '\n')
  out=""
  if command -v openssl &>/dev/null; then
    out=$(printf '%s|%s|%s|%s' "$seed" "$s" "$ns" "$r" | openssl dgst -sha256 -binary 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | head -c 28)
  fi
  [[ -n "$out" ]] || out=$(printf '%s|%s|%s|%s' "$seed" "$s" "$ns" "$r" | sha256sum | awk '{print $1}' | head -c 28)
  [[ -n "$out" ]] || out=$(openssl rand -hex 16 2>/dev/null)
  printf '%s' "$out"
}

apply_app_url_to_dotenv() {
  local url="$1"
  local env_file="$PELICAN_ROOT/.env"
  [[ -f "$env_file" ]] || return 0
  if grep -q '^APP_URL=' "$env_file"; then
    sed -i.bak "s#^APP_URL=.*#APP_URL=${url}#" "$env_file" 2>/dev/null || true
  else
    echo "APP_URL=${url}" >> "$env_file"
  fi
}

# Pelican hides /installer when APP_INSTALLED=true (see App\Livewire\Installer\PanelInstaller).
apply_app_installed_true() {
  local env_file="$PELICAN_ROOT/.env"
  [[ -f "$env_file" ]] || return 0
  if grep -q '^APP_INSTALLED=' "$env_file"; then
    sed -i.bak 's/^APP_INSTALLED=.*/APP_INSTALLED=true/' "$env_file" 2>/dev/null || true
  else
    echo 'APP_INSTALLED=true' >> "$env_file"
  fi
}

ensure_queue_connection_in_dotenv() {
  local f="$PELICAN_ROOT/.env"
  [[ -f "$f" ]] || return 0
  grep -q '^QUEUE_CONNECTION=' "$f" && return 0
  echo 'QUEUE_CONNECTION=database' >> "$f"
}

# Replaces browser installer finish: mark installed, database queue driver, systemd queue worker (p:environment:queue-service).
panel_finalize_cli() {
  apply_app_installed_true
  ensure_queue_connection_in_dotenv
  pushd "$PELICAN_ROOT" >/dev/null
  if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
    php artisan config:clear --no-interaction -q 2>/dev/null || php artisan config:clear --no-interaction
    if ! php artisan p:environment:queue-service --no-interaction --service-name=pelican-queue \
      --user="$WEB_USER" --group="$WEB_USER" --overwrite >>"$EXPRESS_LOG" 2>&1; then
      warn "Queue worker systemd step failed (see log or run: cd ${PELICAN_ROOT} && php artisan p:environment:queue-service)"
    fi
    php artisan config:clear --no-interaction -q 2>/dev/null || true
  else
    php artisan config:clear --no-interaction
    if ! php artisan p:environment:queue-service --no-interaction --service-name=pelican-queue \
      --user="$WEB_USER" --group="$WEB_USER" --overwrite; then
      warn "Queue worker systemd step failed; from ${PELICAN_ROOT} run: php artisan p:environment:queue-service"
    fi
    php artisan config:clear --no-interaction
  fi
  popd >/dev/null
}

# Panel + Wings on same host: p:node:make + p:node:configuration → /etc/pelican/config.yml, then start wings.
# $1 = panel base URL (APP_URL), $2 = Nginx server_name (must be a host your *browser* resolves to this server).
pelican_autoconfigure_wings_local() {
  local panel_base="$1" server_name="$2"
  local wings_host scheme="http"

  # "Reachable" in the Panel UI checks from *your browser*: FQDN must resolve to this machine on the
  # client PC. Names like wings.localhost only resolve to 127.0.0.1 on each computer — so the browser
  # talks to itself, not the server. Prefer the same host you use in the address bar (LAN IP or DNS).
  if [[ "$server_name" == "127.0.0.1" || "${server_name,,}" == "localhost" ]]; then
    wings_host="wings.localhost"
    warn "server_name is ${server_name}: using ${wings_host}. From another PC the node will show not \"Reachable\" unless you add on *that* PC: <server-ip> wings.localhost — or edit the node FQDN in the Panel to your server's LAN IP/hostname and re-export YAML."
  else
    wings_host="$server_name"
    if [[ "$panel_base" == https://* ]] && ! [[ "$server_name" =~ ^[0-9.]+$ ]]; then
      scheme="https"
    else
      scheme="http"
    fi
  fi

  if [[ "$wings_host" == "wings.localhost" ]] && ! grep -qE "[[:space:]]wings\.localhost([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1   wings.localhost" >> /etc/hosts
    info "Added wings.localhost to this server's /etc/hosts (Panel→Wings on loopback). Other PCs still need the same name in *their* hosts file or a different node FQDN."
  fi

  pushd "$PELICAN_ROOT" >/dev/null
  local node_count
  node_count=$(php artisan p:node:list --format=json --no-interaction 2>/dev/null | php -r '$a=json_decode(stream_get_contents(STDIN),true); echo is_array($a) ? count($a) : 0;' 2>/dev/null || echo "0")
  node_count=$(printf '%s' "$node_count" | tr -d '\r\n')

  if [[ "${node_count:-0}" -eq 0 ]]; then
    if ! php artisan p:node:make --no-interaction \
      --name="This server" \
      --description="Created by Pelican install.sh" \
      --fqdn="$wings_host" \
      --scheme="$scheme" \
      --public=1 \
      --proxy=0 \
      --maintenance=0 \
      --maxMemory=0 \
      --overallocateMemory=-1 \
      --maxDisk=0 \
      --overallocateDisk=-1 \
      --maxCpu=0 \
      --overallocateCpu=-1 \
      --uploadSize=256 \
      --daemonListeningPort=8080 \
      --daemonConnectingPort=8080 \
      --daemonSFTPPort=2022 \
      --daemonSFTPAlias= \
      --daemonBase=/var/lib/pelican/volumes; then
      popd >/dev/null
      warn "p:node:make failed — create the node in the Panel, then: cd ${PELICAN_ROOT} && php artisan p:node:configuration <id> --format=yaml > /etc/pelican/config.yml"
      return 1
    fi
  else
    info "Panel already has ${node_count} node(s); skipping p:node:make (writing YAML for latest node id)."
  fi

  local nid
  nid=$(php artisan p:node:list --format=json --no-interaction 2>/dev/null | php -r '$a=json_decode(stream_get_contents(STDIN),true); if(!is_array($a)||!$a){exit(1);}$m=0;foreach($a as $n){if(!empty($n["id"])&&(int)$n["id"]>$m)$m=(int)$n["id"];}if($m<1)exit(1);echo $m;' 2>/dev/null) || nid=""
  nid=$(printf '%s' "$nid" | tr -d '\r\n ')
  popd >/dev/null

  if [[ -z "$nid" || "$nid" == "0" ]]; then
    warn "Could not determine node id from the Panel database."
    return 1
  fi

  mkdir -p /etc/pelican
  if ! ( cd "$PELICAN_ROOT" && php artisan p:node:configuration "$nid" --format=yaml --no-interaction > /etc/pelican/config.yml ); then
    warn "Failed to write /etc/pelican/config.yml"
    return 1
  fi

  SUMMARY[wings_config_written]="yes"
  SUMMARY[node_id]="$nid"
  info "Wrote /etc/pelican/config.yml for node id ${nid} (daemon FQDN ${wings_host}, scheme ${scheme})."
  if [[ "$scheme" == "https" ]]; then
    muted "If Wings fails to bind TLS, add certificates under /etc/letsencrypt/live/${wings_host}/ or switch the node to HTTP in the Panel."
  fi
  if systemctl start wings 2>/dev/null; then
    info "wings.service started."
  else
    warn "systemctl start wings failed — check: journalctl -u wings -n 50"
  fi
}

create_database_and_user() {
  local db_name="$1" db_user="$2" db_pass="$3"
  local ep eu
  ep=$(printf '%s' "$db_pass" | sed "s/'/''/g")
  eu=$(printf '%s' "$db_user" | sed "s/'/''/g")
  en=$(printf '%s' "$db_name" | sed "s/'/''/g")
  mysql_exec "CREATE DATABASE IF NOT EXISTS \`${en}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql_exec "CREATE USER IF NOT EXISTS '${eu}'@'127.0.0.1' IDENTIFIED BY '${ep}';"
  mysql_exec "GRANT ALL PRIVILEGES ON \`${en}\`.* TO '${eu}'@'127.0.0.1';"
  mysql_exec "FLUSH PRIVILEGES;"
}

# Pelican's `p:environment:database` always runs confirm("Do you want to continue?") with default NO.
# With --no-interaction that aborts immediately; interactively it blocks on the prompt (red warnings).
# We set MySQL credentials in .env instead, then migrate (see pelican-dev/panel DatabaseSettingsCommand.php).
wait_for_mysql_user() {
  local db_user="$1" db_pass="$2"
  local tries=0
  [[ "${QUIET_INSTALL:-0}" != "1" ]] && info "Waiting for MySQL to accept TCP logins for ${db_user}@127.0.0.1…"
  while [[ $tries -lt 45 ]]; do
    if mysql -h 127.0.0.1 -u "$db_user" -p"$db_pass" -e "SELECT 1" &>/dev/null; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  error "MySQL did not accept credentials at 127.0.0.1:3306 within 45s (check mariadb bind-address / firewall)."
  exit 1
}

escape_dotenv_double() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

apply_mysql_to_dotenv() {
  local db_name="$1" db_user="$2" db_pass="$3"
  local env_file="$PELICAN_ROOT/.env"
  [[ -f "$env_file" ]] || { error "Missing $env_file (p:environment:setup failed?)"; exit 1; }
  local tmp
  tmp=$(mktemp)
  grep -vE '^DB_(CONNECTION|HOST|PORT|DATABASE|USERNAME|PASSWORD|SOCKET)=' "$env_file" > "$tmp" 2>/dev/null || cp "$env_file" "$tmp"
  {
    echo "DB_CONNECTION=mysql"
    echo "DB_HOST=127.0.0.1"
    echo "DB_PORT=3306"
    echo "DB_DATABASE=${db_name}"
    echo "DB_USERNAME=${db_user}"
    echo "DB_PASSWORD=\"$(escape_dotenv_double "$db_pass")\""
  } >> "$tmp"
  mv "$tmp" "$env_file"
}

apply_pgsql_to_dotenv() {
  local db_name="$1" db_user="$2" db_pass="$3"
  local env_file="$PELICAN_ROOT/.env"
  [[ -f "$env_file" ]] || { error "Missing $env_file (p:environment:setup failed?)"; exit 1; }
  local tmp
  tmp=$(mktemp)
  grep -vE '^DB_(CONNECTION|HOST|PORT|DATABASE|USERNAME|PASSWORD|SOCKET)=' "$env_file" > "$tmp" 2>/dev/null || cp "$env_file" "$tmp"
  {
    echo "DB_CONNECTION=pgsql"
    echo "DB_HOST=127.0.0.1"
    echo "DB_PORT=5432"
    echo "DB_DATABASE=${db_name}"
    echo "DB_USERNAME=${db_user}"
    echo "DB_PASSWORD=\"$(escape_dotenv_double "$db_pass")\""
  } >> "$tmp"
  mv "$tmp" "$env_file"
}

# ---------------------------------------------------------------------------
# Panel: download & composer
# ---------------------------------------------------------------------------
install_panel_files() {
  mkdir -p "$PELICAN_ROOT"
  [[ "${QUIET_INSTALL:-0}" != "1" ]] && info "Downloading Pelican Panel release…"
  # Never use tar -v: it lists thousands of files and floods the console
  curl -fsSL "$PELICAN_RELEASE_URL" | tar -xz -C "$PELICAN_ROOT" --strip-components=0 2>/dev/null || {
    curl -fsSL "$PELICAN_RELEASE_URL" | tar -xz -C "$PELICAN_ROOT"
  }

  if [[ ! -f "$PELICAN_ROOT/artisan" ]]; then
    # Some archives may have a top-level folder
    local sub
    sub=$(find "$PELICAN_ROOT" -maxdepth 2 -name artisan -type f | head -1 | xargs dirname 2>/dev/null || true)
    if [[ -n "$sub" && "$sub" != "$PELICAN_ROOT" ]]; then
      shopt -s dotglob
      mv "$sub"/* "$PELICAN_ROOT"/
      shopt -u dotglob
      rmdir "$sub" 2>/dev/null || true
    fi
  fi

  if [[ ! -f "$PELICAN_ROOT/artisan" ]]; then
    error "Could not find artisan after extract. Check release layout."
    exit 1
  fi

  if ! command -v composer &>/dev/null; then
    if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
      curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer &>/dev/null
    else
      curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    fi
  fi
  pushd "$PELICAN_ROOT" >/dev/null
  if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction --quiet >>"$EXPRESS_LOG" 2>&1 || {
      error "composer install failed; tail of $EXPRESS_LOG:"
      tail -n 40 "$EXPRESS_LOG" >&2
      exit 1
    }
  else
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  fi
  popd >/dev/null
}

configure_panel_env() {
  local db_name="$1" db_user="$2" db_pass="$3"
  pushd "$PELICAN_ROOT" >/dev/null
  if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
    php artisan p:environment:setup --no-interaction >>"$EXPRESS_LOG" 2>&1
  else
    php artisan p:environment:setup --no-interaction
  fi

  wait_for_mysql_user "$db_user" "$db_pass"
  [[ "${QUIET_INSTALL:-0}" != "1" ]] && info "Writing MySQL settings to .env (skipping interactive p:environment:database)…"
  apply_mysql_to_dotenv "$db_name" "$db_user" "$db_pass"
  if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
    php artisan config:clear --no-interaction -q 2>/dev/null || php artisan config:clear --no-interaction
  else
    php artisan config:clear --no-interaction
  fi

  if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
    if ! php artisan migrate --force --no-interaction >>"$EXPRESS_LOG" 2>&1; then
      error "migrate failed; last lines of $EXPRESS_LOG:"
      tail -n 30 "$EXPRESS_LOG" >&2
      exit 1
    fi
  else
    php artisan migrate --force --no-interaction
  fi
  popd >/dev/null
}

panel_permissions() {
  chmod -R 755 "$PELICAN_ROOT/storage" "$PELICAN_ROOT/bootstrap/cache" 2>/dev/null || \
    chmod -R 755 "$PELICAN_ROOT/storage/" "$PELICAN_ROOT/bootstrap/cache/" 2>/dev/null || true
  chown -R "$WEB_USER:$WEB_USER" "$PELICAN_ROOT"
}

create_admin_user() {
  local email="$1" username="$2" password="$3"
  pushd "$PELICAN_ROOT" >/dev/null
  if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
    php artisan p:user:make --no-interaction --no-ansi \
      --email="$email" --username="$username" --password="$password" --admin=1 >>"$EXPRESS_LOG" 2>&1 || {
      error "Could not create admin user; see $EXPRESS_LOG"
      exit 1
    }
  else
    php artisan p:user:make --no-interaction \
      --email="$email" --username="$username" --password="$password" --admin=1
  fi
  popd >/dev/null
}

setup_cron() {
  local cron_line="* * * * * cd $PELICAN_ROOT && php artisan schedule:run >> /dev/null 2>&1"
  (crontab -l -u "$WEB_USER" 2>/dev/null | grep -v "pelican.*schedule:run" || true; echo "$cron_line") | crontab -u "$WEB_USER" -
}

# ---------------------------------------------------------------------------
# Nginx (HTTP or HTTPS template from Pelican docs)
# ---------------------------------------------------------------------------
nginx_write_site() {
  local server_name="$1"
  local use_ssl="$2" # 0 or 1
  local conf="/etc/nginx/sites-available/pelican.conf"
  local sock=""
  for s in "/run/php/php${PHP_VERSION}-fpm.sock" "/var/run/php/php${PHP_VERSION}-fpm.sock"; do
    if [[ -S "$s" ]]; then
      sock="$s"
      break
    fi
  done
  [[ -n "$sock" ]] || sock="/run/php/php${PHP_VERSION}-fpm.sock"

  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  if [[ "$use_ssl" -eq 1 ]]; then
    cat > "$conf" <<NGX
server_tokens off;

server {
    listen 80;
    server_name ${server_name};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${server_name};

    root ${PELICAN_ROOT}/public;
    index index.php;

    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/letsencrypt/live/${server_name}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${server_name}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php\$ {
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:${sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \\n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\\.ht {
        deny all;
    }
}
NGX
  else
    cat > "$conf" <<NGX
server {
    listen 80;
    server_name ${server_name};

    root ${PELICAN_ROOT}/public;
    index index.html index.htm index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/pelican.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \\.php\$ {
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:${sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \\n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\\.ht {
        deny all;
    }
}
NGX
  fi

  ln -sf "$conf" /etc/nginx/sites-enabled/pelican.conf
  run_cmd_quiet nginx -t
  run_cmd_quiet systemctl reload nginx
}

# ---------------------------------------------------------------------------
# Wings
# ---------------------------------------------------------------------------
install_docker() {
  if command -v docker &>/dev/null; then
    [[ "${QUIET_INSTALL:-0}" != "1" ]] && info "Docker already installed."
    if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
      systemctl enable --now docker >>"$EXPRESS_LOG" 2>&1 || true
    else
      systemctl enable --now docker 2>/dev/null || true
    fi
    return 0
  fi
  [[ "${QUIET_INSTALL:-0}" != "1" ]] && info "Installing Docker CE (get.docker.com)…"
  if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
    local dlog="/tmp/pelican-docker-install.log"
    if ! curl -fsSL https://get.docker.com/ | CHANNEL=stable sh >"$dlog" 2>&1; then
      error "Docker install script failed; tail of $dlog:"
      tail -n 50 "$dlog" >&2
      exit 1
    fi
    run_cmd_quiet systemctl enable --now docker
  else
    curl -fsSL https://get.docker.com/ | CHANNEL=stable sh
    systemctl enable --now docker
  fi
}

install_wings_binary() {
  local arch
  arch=$(uname -m)
  [[ "$arch" == "x86_64" ]] && arch="amd64" || arch="arm64"
  mkdir -p /etc/pelican /var/run/wings /var/lib/pelican/volumes
  [[ "${QUIET_INSTALL:-0}" != "1" ]] && info "Downloading Wings (${arch})…"
  curl -fsSL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${arch}"
  chmod u+x /usr/local/bin/wings
}

wings_systemd() {
  # RuntimeDirectory creates /run/wings before start (fixes systemd PIDFile warnings).
  cat > /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
RuntimeDirectory=wings
LimitNOFILE=4096
PIDFile=/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  run_cmd_quiet systemctl daemon-reload
  run_cmd_quiet systemctl enable wings
}

# ---------------------------------------------------------------------------
# Manual: extra prompts & branches
# ---------------------------------------------------------------------------
manual_select_components() {
  echo
  printf '  %s1)%s Panel only\n' "$C_OK" "$RESET"
  printf '  %s2)%s Wings only\n' "$C_OK" "$RESET"
  printf '  %s3)%s Panel + Wings\n' "$C_OK" "$RESET"
  local c
  while true; do
    c=$(prompt "Component(s) to install" "3")
    case "$c" in
      1) INSTALL_COMPONENTS="panel"; return 0 ;;
      2) INSTALL_COMPONENTS="wings"; return 0 ;;
      3) INSTALL_COMPONENTS="both"; return 0 ;;
      *) warn "Enter 1–3." ;;
    esac
  done
}

WEBSERVER_CHOICE=""
manual_select_webserver() {
  local c
  echo >&2
  printf '  %s1)%s NGINX (recommended)\n' "$C_OK" "$RESET" >&2
  printf '  %s2)%s Apache\n' "$C_OK" "$RESET" >&2
  printf '  %s3)%s Caddy\n' "$C_OK" "$RESET" >&2
  while true; do
    c=$(prompt "Webserver for Panel" "1")
    case "$c" in
      1) WEBSERVER_CHOICE="nginx"; return 0 ;;
      2) WEBSERVER_CHOICE="apache"; return 0 ;;
      3) WEBSERVER_CHOICE="caddy"; return 0 ;;
      *) warn "Enter 1–3." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  section "Installation summary"
  echo
  printf '  %s%-22s%s %s\n' "$BOLD" "Operating system" "$RESET" "${SUMMARY[os]:-}"
  if [[ -n "${SUMMARY[ubuntu_version]:-}" ]]; then
    printf '  %s%-22s%s %s\n' "$BOLD" "Ubuntu release" "$RESET" "${SUMMARY[ubuntu_version]}"
  fi
  printf '  %s%-22s%s %s\n' "$BOLD" "Install mode" "$RESET" "${SUMMARY[mode]:-}"
  printf '  %s%-22s%s %s\n' "$BOLD" "Components" "$RESET" "${SUMMARY[components]:-}"
  if [[ -n "${SUMMARY[php_version]:-}" ]]; then
    printf '  %s%-22s%s PHP %s (php-fpm socket in nginx config)\n' "$BOLD" "PHP" "$RESET" "${SUMMARY[php_version]}"
  fi
  if [[ -n "${SUMMARY[panel_path]:-}" ]]; then
    printf '  %s%-22s%s %s\n' "$BOLD" "Panel path" "$RESET" "${SUMMARY[panel_path]}"
  fi

  if [[ -n "${SUMMARY[panel_url]:-}" && ( "${SUMMARY[components]:-}" == "panel" || "${SUMMARY[components]:-}" == "both" ) ]]; then
    echo
    printf '  %s%s%s\n' "$C_HEAD" "  Log in to the Panel" "$RESET"
    printf '  %s%-22s%s %s\n' "$BOLD" "  Panel URL" "$RESET" "${SUMMARY[panel_url]}"
    if [[ -n "${SUMMARY[admin_email]:-}" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Admin email" "$RESET" "${SUMMARY[admin_email]}"
      printf '  %s%-22s%s %s\n' "$BOLD" "  Admin username" "$RESET" "${SUMMARY[admin_username]}"
      printf '  %s%-22s%s %s\n' "$BOLD" "  Admin password" "$RESET" "${SUMMARY[admin_password]}"
    fi
    echo
  fi

  if [[ -n "${SUMMARY[db_name]:-}" ]]; then
    printf '  %s%s%s\n' "$C_HEAD" "  Database (.env)" "$RESET"
    if [[ -n "${SUMMARY[db_ui_driver]:-}" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Driver (dropdown)" "$RESET" "${SUMMARY[db_ui_driver]}"
    fi
    if [[ -n "${SUMMARY[db_engine]:-}" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Engine / .env" "$RESET" "${SUMMARY[db_engine]}"
    fi
    if [[ -n "${SUMMARY[db_host]:-}" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Host" "$RESET" "${SUMMARY[db_host]}"
    fi
    if [[ -n "${SUMMARY[db_port]:-}" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Port" "$RESET" "${SUMMARY[db_port]}"
    fi
    printf '  %s%-22s%s %s\n' "$BOLD" "  Database name" "$RESET" "${SUMMARY[db_name]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "  Username" "$RESET" "${SUMMARY[db_user]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "  Password" "$RESET" "${SUMMARY[db_password]}"
    echo
  fi
  if [[ -n "${SUMMARY[admin_email]:-}" && ! ( "${SUMMARY[components]:-}" == "panel" || "${SUMMARY[components]:-}" == "both" ) ]]; then
    printf '  %s%-22s%s %s\n' "$BOLD" "Admin email" "$RESET" "${SUMMARY[admin_email]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "Admin username" "$RESET" "${SUMMARY[admin_username]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "Admin password" "$RESET" "${SUMMARY[admin_password]}"
  fi
  if [[ -n "${SUMMARY[app_key]:-}" ]]; then
    printf '  %s%-22s%s %s\n' "$BOLD" "APP_KEY (backup!)" "$RESET" "${SUMMARY[app_key]}"
  fi
  if [[ "${SUMMARY[wings_skipped]:-}" == "yes" ]]; then
    echo
    printf '  %s%s%s\n' "$C_HEAD" "  Docker + Wings" "$RESET"
    muted "  Skipped at your prompt. Install later: https://pelican.dev/docs/wings/install"
    echo
  fi
  if [[ "${SUMMARY[wings_installed]:-}" == "yes" ]]; then
    echo
    printf '  %s%s%s\n' "$C_HEAD" "  Wings" "$RESET"
    printf '  %s%-22s%s %s\n' "$BOLD" "  Installed on disk" "$RESET" "Docker, /usr/local/bin/wings, systemd unit wings.service (enabled)"
    if [[ "${SUMMARY[wings_config_written]:-}" == "yes" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Config" "$RESET" "/etc/pelican/config.yml (from p:node:configuration)"
      [[ -n "${SUMMARY[node_id]:-}" ]] && printf '  %s%-22s%s %s\n' "$BOLD" "  Panel node id" "$RESET" "${SUMMARY[node_id]}"
    else
      printf '  %s%-22s%s %s\n' "$BOLD" "  Config" "$RESET" "/etc/pelican/config.yml — create a node in the Panel, then: php artisan p:node:configuration <id> --format=yaml > /etc/pelican/config.yml"
      echo
      printf '  %s  Next steps:%s\n' "$BOLD" "$RESET"
      printf '    %s1.%s In the Panel: %sAdmin → Nodes → Create New%s (FQDN cannot be 127.0.0.1).\n' "$DIM" "$RESET" "$BOLD" "$RESET"
      printf '    %s2.%s %sphp artisan p:node:configuration <id> --format=yaml > /etc/pelican/config.yml%s\n' "$DIM" "$RESET" "$BOLD" "$RESET"
      printf '    %s3.%s %ssudo systemctl start wings%s\n' "$DIM" "$RESET" "$BOLD" "$RESET"
    fi
    echo
    muted "  Docs: https://pelican.dev/docs/wings/install"
  fi
  echo
  muted "Official docs: https://pelican.dev/docs/panel/getting-started · https://pelican.dev/docs/wings/install"
  echo
}

extract_app_key() {
  local f="$PELICAN_ROOT/.env"
  [[ -f "$f" ]] || return 0
  grep -E '^APP_KEY=' "$f" | head -1 | cut -d= -f2- | tr -d '\r' || true
}

# Database values written to .env (same as a manual Pelican DB setup).
set_summary_db_web_installer_info() {
  local d="${1:-mysql}"
  case "$d" in
    mysql)
      SUMMARY[db_ui_driver]="MySQL"
      SUMMARY[db_engine]="MariaDB (apt); .env DB_CONNECTION=mysql"
      SUMMARY[db_host]="127.0.0.1"
      SUMMARY[db_port]="3306"
      ;;
    pgsql)
      SUMMARY[db_ui_driver]="PostgreSQL"
      SUMMARY[db_engine]="PostgreSQL; .env DB_CONNECTION=pgsql"
      SUMMARY[db_host]="127.0.0.1"
      SUMMARY[db_port]="5432"
      ;;
    sqlite)
      SUMMARY[db_ui_driver]="SQLite"
      SUMMARY[db_engine]="SQLite file; .env DB_CONNECTION=sqlite"
      SUMMARY[db_host]="(not used for SQLite)"
      SUMMARY[db_port]="(not used for SQLite)"
      ;;
    *)
      SUMMARY[db_ui_driver]="(see .env)"
      SUMMARY[db_engine]=""
      SUMMARY[db_host]=""
      SUMMARY[db_port]=""
      ;;
  esac
}

# Shown after CLI finalization: no /installer wizard — APP_INSTALLED=true, queue worker, cron already set.
print_panel_ready_banner() {
  local panel_url="${SUMMARY[panel_url]:-}"
  section "Panel is ready — CLI setup complete"
  echo
  printf '  %s%-22s%s %s\n' "$BOLD" "Panel URL" "$RESET" "$panel_url"
  muted "The web installer at /installer is disabled (APP_INSTALLED=true). Log in with the admin account below."
  echo

  if [[ -n "${SUMMARY[db_name]:-}" ]]; then
    printf '  %s%s%s\n' "$C_HEAD" "  Database (.env)" "$RESET"
    if [[ -n "${SUMMARY[db_ui_driver]:-}" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Driver (dropdown)" "$RESET" "${SUMMARY[db_ui_driver]}"
    fi
    if [[ -n "${SUMMARY[db_engine]:-}" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Engine / .env" "$RESET" "${SUMMARY[db_engine]}"
    fi
    if [[ -n "${SUMMARY[db_host]:-}" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Host" "$RESET" "${SUMMARY[db_host]}"
    fi
    if [[ -n "${SUMMARY[db_port]:-}" ]]; then
      printf '  %s%-22s%s %s\n' "$BOLD" "  Port" "$RESET" "${SUMMARY[db_port]}"
    fi
    printf '  %s%-22s%s %s\n' "$BOLD" "  Database name" "$RESET" "${SUMMARY[db_name]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "  Username" "$RESET" "${SUMMARY[db_user]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "  Password" "$RESET" "${SUMMARY[db_password]}"
    echo
  fi

  printf '  %s%s%s\n' "$C_HEAD" "  Admin account (first login)" "$RESET"
  printf '  %s%-22s%s %s\n' "$BOLD" "  Email" "$RESET" "${SUMMARY[admin_email]:-}"
  printf '  %s%-22s%s %s\n' "$BOLD" "  Username" "$RESET" "${SUMMARY[admin_username]:-}"
  printf '  %s%-22s%s %s\n' "$BOLD" "  Password" "$RESET" "${SUMMARY[admin_password]:-}"
  if [[ -n "${SUMMARY[app_key]:-}" ]]; then
    echo
    printf '  %s%-22s%s %s\n' "$BOLD" "APP_KEY (backup)" "$RESET" "${SUMMARY[app_key]}"
  fi
  echo
  muted "Queue worker: systemd unit pelican-queue (if enabled). Cron: www-data schedule:run every minute."
  echo
}

# Returns 0 if user wants Wings install to proceed, 1 if they skip (Panel + Wings only).
pause_before_wings_install() {
  echo
  printf '%s%s%s\n' "$C_HEAD" "Docker + Wings on this server" "$RESET"
  muted "For Panel + Wings, the script can create a local node and write /etc/pelican/config.yml after Docker is installed."
  echo
  if confirm "Continue and install Docker + Wings on this machine now?" "y"; then
    return 0
  fi
  SUMMARY[wings_skipped]="yes"
  warn "Skipping Docker/Wings. Install them later: https://pelican.dev/docs/wings/install"
  return 1
}

# ---------------------------------------------------------------------------
# Express flow
# ---------------------------------------------------------------------------
run_express() {
  QUIET_INSTALL=1
  : >"$EXPRESS_LOG"
  {
    echo "--- pelican express $(date -Iseconds 2>/dev/null || date) ---"
  } >>"$EXPRESS_LOG"

  SUMMARY[mode]="express"
  menu_components

  local admin_email admin_user admin_pass db_name db_user db_pass fqdn

  db_name="pelican"
  db_user="pelican"
  admin_email=$(prompt "Admin email (first user)" "admin@localhost")
  admin_user=$(prompt "Admin username" "admin")
  admin_pass=$(prompt_secret "Admin password (hidden)")
  if [[ "$INSTALL_COMPONENTS" == "panel" || "$INSTALL_COMPONENTS" == "both" ]]; then
    db_pass=$(generate_db_password_from_seed "$admin_pass")
  else
    db_pass=""
  fi

  if [[ "$INSTALL_COMPONENTS" != "wings" ]]; then
    local auto_ip
    auto_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fqdn=$(prompt "Panel domain or IP for Nginx server_name" "${auto_ip:-127.0.0.1}")
    SUMMARY[panel_url]="http://${fqdn}"
  fi

  SUMMARY[components]="$INSTALL_COMPONENTS"
  SUMMARY[os]="$OS_PRETTY"
  SUMMARY[admin_email]="$admin_email"
  SUMMARY[admin_username]="$admin_user"
  SUMMARY[admin_password]="$admin_pass"

  _express_wings_bin_systemd() {
    install_wings_binary
    wings_systemd
  }

  _express_wings_autoconfig() {
    pelican_autoconfigure_wings_local "${SUMMARY[panel_url]}" "$fqdn"
  }

  if [[ "$INSTALL_COMPONENTS" == "panel" || "$INSTALL_COMPONENTS" == "both" ]]; then
    section "Step 1 — Pelican Panel"
    local etotal=4

    _express_panel_step4() {
      configure_panel_env "$db_name" "$db_user" "$db_pass"
      create_admin_user "$admin_email" "$admin_user" "$admin_pass"
      panel_permissions
      setup_cron
      nginx_write_site "$fqdn" 0
      apply_app_url_to_dotenv "http://${fqdn}"
      if [[ "${QUIET_INSTALL:-0}" == "1" ]]; then
        ( cd "$PELICAN_ROOT" && php artisan config:clear --no-interaction -q 2>/dev/null ) || \
          ( cd "$PELICAN_ROOT" && php artisan config:clear --no-interaction )
      else
        ( cd "$PELICAN_ROOT" && php artisan config:clear --no-interaction )
      fi
    }

    express_step 1 "$etotal" "System packages (nginx, MariaDB, PHP)…"
    select_php_version
    express_run "APT: nginx, MariaDB, PHP (may take a few minutes)…" apt_install_panel_deps

    express_step 2 "$etotal" "Creating database and MySQL user…"
    express_run "MariaDB: creating database & user…" create_database_and_user "$db_name" "$db_user" "$db_pass"

    express_step 3 "$etotal" "Panel release + Composer (this can take several minutes)…"
    express_run "Download, extract & composer install…" install_panel_files

    express_step 4 "$etotal" "Environment, migrations, admin, Nginx, APP_URL…"
    express_run "Artisan, migrations, admin, nginx, APP_URL…" _express_panel_step4

    panel_finalize_cli

    SUMMARY[panel_path]="$PELICAN_ROOT"
    SUMMARY[app_key]="$(extract_app_key)"
    SUMMARY[db_name]="$db_name"
    SUMMARY[db_user]="$db_user"
    SUMMARY[db_password]="$db_pass"
    set_summary_db_web_installer_info "mysql"
  fi

  if [[ "$INSTALL_COMPONENTS" == "panel" ]]; then
    print_panel_ready_banner
  fi

  if [[ "$INSTALL_COMPONENTS" == "both" ]]; then
    print_panel_ready_banner
    if pause_before_wings_install; then
      section "Step 2 — Docker + Wings"
      express_step 1 3 "Docker Engine…"
      express_run "Docker CE (get.docker.com, may take a few minutes)…" install_docker
      express_step 2 3 "Wings binary + systemd unit…"
      express_run "Wings binary & systemd unit…" _express_wings_bin_systemd
      express_step 3 3 "Panel node + Wings config + start…"
      if ! express_run "p:node:make, config.yml, wings.service…" _express_wings_autoconfig; then
        warn "Wings auto-config failed — create the node in the Panel and write /etc/pelican/config.yml manually (see summary)."
      fi
      SUMMARY[wings_installed]="yes"
    fi
  fi

  if [[ "$INSTALL_COMPONENTS" == "wings" ]]; then
    section "Wings only — Docker + Wings"
    express_step 1 2 "Docker Engine…"
    express_run "Docker CE (get.docker.com, may take a few minutes)…" install_docker
    express_step 2 2 "Wings binary + systemd unit…"
    express_run "Wings binary & systemd unit…" _express_wings_bin_systemd
    SUMMARY[wings_installed]="yes"
    info "Wings only: create a node on your Panel host, then run there: php artisan p:node:configuration <id> --format=yaml > /etc/pelican/config.yml && systemctl start wings"
  fi

  print_summary
}

# ---------------------------------------------------------------------------
# Manual flow
# ---------------------------------------------------------------------------
run_manual() {
  SUMMARY[mode]="manual"
  manual_select_components

  local webserver php_ver_choice
  local admin_email admin_user admin_pass db_name db_user db_pass fqdn
  local use_ssl=0
  local db_driver="mysql"

  manual_select_webserver
  webserver="$WEBSERVER_CHOICE"

  echo
  PELICAN_ROOT=$(prompt "Panel installation directory" "${PELICAN_ROOT:-/var/www/pelican}")
  SUMMARY[panel_path]="$PELICAN_ROOT"

  echo
  printf '%sAdmin account (panel)%s\n' "$BOLD" "$RESET"
  admin_email=$(prompt "Admin email" "admin@localhost")
  admin_user=$(prompt "Admin username" "admin")
  admin_pass=$(prompt_secret "Admin password")

  echo
  printf '%sDatabase%s\n' "$BOLD" "$RESET"
  db_driver=$(prompt "DB driver (mysql, sqlite, pgsql)" "mysql")
  db_name=$(prompt "Database name" "pelican")
  db_user=$(prompt "Database user" "pelican")
  if [[ "$db_driver" == "mysql" ]]; then
    if confirm "Generate database password from admin password + time + entropy (recommended)?" "y"; then
      db_pass=$(generate_db_password_from_seed "$admin_pass")
    else
      db_pass=$(prompt_secret "Database password")
    fi
  else
    db_pass=$(prompt_secret "Database password")
  fi

  if [[ "$INSTALL_COMPONENTS" != "wings" ]]; then
    local auto_ip
    auto_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fqdn=$(prompt "server_name / domain or IP" "${auto_ip:-127.0.0.1}")
    if confirm "Use HTTPS with Let's Encrypt? (domain must resolve; not for raw IP)" "n"; then
      use_ssl=1
    fi
  fi

  echo
  printf '%sPHP version%s\n' "$BOLD" "$RESET"
  php_ver_choice=$(prompt "PHP version to install (8.2–8.5 per Pelican docs)" "8.5")
  PHP_VERSION="$php_ver_choice"
  PHP_PKG_PREFIX="php${PHP_VERSION}"
  SUMMARY[php_version]="$PHP_VERSION"

  SUMMARY[components]="$INSTALL_COMPONENTS"
  SUMMARY[os]="$OS_PRETTY"
  SUMMARY[db_name]="$db_name"
  SUMMARY[db_user]="$db_user"
  SUMMARY[db_password]="$db_pass"
  SUMMARY[admin_email]="$admin_email"
  SUMMARY[admin_username]="$admin_user"
  SUMMARY[admin_password]="$admin_pass"
  set_summary_db_web_installer_info "$db_driver"

  if [[ "$INSTALL_COMPONENTS" == "panel" || "$INSTALL_COMPONENTS" == "both" ]]; then
    section "Step 1 — Pelican Panel"
    if [[ "$webserver" != "nginx" ]]; then
      warn "Apache/Caddy vhost generation is not fully automated in this script."
      warn "Install deps, then copy examples from: https://pelican.dev/docs/panel/webserver-config"
    fi

    info "Installing base packages…"
    apt_install_panel_deps

    if [[ "$db_driver" == "mysql" ]]; then
      create_database_and_user "$db_name" "$db_user" "$db_pass"
    elif [[ "$db_driver" == "pgsql" ]]; then
      warn "PostgreSQL: create the database and role in psql before migrations if they do not exist yet."
    else
      warn "SQLite: after panel files are installed, run php artisan p:environment:database (sqlite) and migrate manually."
    fi

    install_panel_files

    pushd "$PELICAN_ROOT" >/dev/null
    php artisan p:environment:setup --no-interaction
    if [[ "$db_driver" == "mysql" ]]; then
      wait_for_mysql_user "$db_user" "$db_pass"
      info "Writing MySQL settings to .env…"
      apply_mysql_to_dotenv "$db_name" "$db_user" "$db_pass"
      php artisan config:clear --no-interaction
    elif [[ "$db_driver" == "pgsql" ]]; then
      info "Writing PostgreSQL settings to .env…"
      apply_pgsql_to_dotenv "$db_name" "$db_user" "$db_pass"
      php artisan config:clear --no-interaction
    fi
    if [[ "$db_driver" != "sqlite" ]]; then
      php artisan migrate --force --no-interaction
    else
      warn "Skipping migrate for sqlite — run php artisan migrate --force after configuring the database."
    fi
    popd >/dev/null

    create_admin_user "$admin_email" "$admin_user" "$admin_pass"
    panel_permissions
    setup_cron

    if [[ "$webserver" == "nginx" ]]; then
      nginx_write_site "$fqdn" 0
      if [[ "$use_ssl" -eq 1 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
        certbot certonly --nginx -d "$fqdn" --non-interactive --agree-tos -m "$admin_email" || {
          warn "Certbot failed; falling back to HTTP only."
          use_ssl=0
        }
      fi
      nginx_write_site "$fqdn" "$use_ssl"
      if [[ "$use_ssl" -eq 1 ]]; then
        SUMMARY[panel_url]="https://${fqdn}"
      else
        SUMMARY[panel_url]="http://${fqdn}"
      fi
    else
      SUMMARY[panel_url]="(configure ${webserver} manually)"
    fi

    {
      local pub="${SUMMARY[panel_url]}"
      if [[ "$pub" == http://* || "$pub" == https://* ]]; then
        apply_app_url_to_dotenv "$pub"
      else
        apply_app_url_to_dotenv "http://${fqdn}"
      fi
    }
    ( cd "$PELICAN_ROOT" && php artisan config:clear --no-interaction )

    panel_finalize_cli

    SUMMARY[app_key]="$(extract_app_key)"
  fi

  if [[ "$INSTALL_COMPONENTS" == "panel" ]]; then
    print_panel_ready_banner
  fi

  if [[ "$INSTALL_COMPONENTS" == "both" ]]; then
    local gurl="${SUMMARY[panel_url]}"
    if [[ ! "$gurl" == http://* && ! "$gurl" == https://* ]]; then
      gurl="http://${fqdn}"
    fi
    print_panel_ready_banner
    if pause_before_wings_install; then
      section "Step 2 — Docker + Wings"
      install_docker
      install_wings_binary
      wings_systemd
      pelican_autoconfigure_wings_local "$gurl" "$fqdn" || true
      SUMMARY[wings_installed]="yes"
    fi
  fi

  if [[ "$INSTALL_COMPONENTS" == "wings" ]]; then
    section "Wings only — Docker + Wings"
    install_docker
    install_wings_binary
    wings_systemd
    SUMMARY[wings_installed]="yes"
    info "Wings only: create a node on your Panel host, then run there: php artisan p:node:configuration <id> --format=yaml > /etc/pelican/config.yml && systemctl start wings"
  fi

  print_summary
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  detect_environment
  # Clean slate for the installer UI (MOTD / scrollback stays above if you scroll up).
  [[ -t 1 ]] && clear
  intro_before_ui
  banner
  os_warning_block

  if ! confirm "Continue with installation?" "y"; then
    muted "Aborted."
    exit 0
  fi

  menu_two

  SUMMARY[os]="$OS_PRETTY"

  case "$INSTALL_MODE" in
    express) run_express ;;
    manual) run_manual ;;
    *) error "Invalid mode"; exit 1 ;;
  esac

  info "Done."
}

main "$@"
