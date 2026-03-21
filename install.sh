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
else
  BOLD=''; DIM=''; RESET=''
  C_HEAD=''; C_ACCENT=''; C_OK=''; C_WARN=''; C_ERR=''; C_MUTED=''
fi

ui_width() { echo "${COLUMNS:-80}"; }

hr() {
  local w; w=$(ui_width)
  printf '%*s\n' "$w" '' | tr ' ' '─'
}

box_top() {
  printf '%s╔' "$C_ACCENT"
  local w=$(( $(ui_width) - 2 ))
  printf '%*s' "$w" '' | tr ' ' '═'
  printf '╗%s\n' "$RESET"
}

box_bottom() {
  printf '%s╚' "$C_ACCENT"
  local w=$(( $(ui_width) - 2 ))
  printf '%*s' "$w" '' | tr ' ' '═'
  printf '╝%s\n' "$RESET"
}

box_line() {
  local text="$1"
  local pad=$(( $(ui_width) - 4 - ${#text} ))
  printf '%s║ %s%*s%s ║%s\n' "$C_ACCENT" "$BOLD$text$RESET" "$pad" '' '' "$RESET"
}

banner() {
  clear 2>/dev/null || true
  box_top
  box_line "  ___      _ _            ___          _ _       _   "
  box_line " | _ \___ | (_)__ _ _ _  | _ \_ _ ___ (_) |_ ___| |_ "
  box_line " |  _/ _ \| | / _\` | '_| |  _/ _\` / -_)|  _/ -_)  _|"
  box_line " |_| \___/|_|_\__,_|_|   |_| \__,_\___| \__\___|\__|"
  box_line ""
  box_line "  Panel & Wings installer  ${DIM}v${SCRIPT_VERSION}${RESET}${BOLD}  ·  ${C_MUTED}unofficial helper${RESET}"
  box_bottom
  echo
}

section() {
  echo
  printf '%s━━ %s%s%s\n' "$C_HEAD" "$BOLD" "$1" "$RESET"
  hr
}

info()    { printf '%s▸%s %s\n' "$C_OK" "$RESET" "$*"; }
warn()    { printf '%s!%s %s\n' "$C_WARN" "$RESET" "$*" >&2; }
error()   { printf '%s✖%s %s\n' "$C_ERR" "$RESET" "$*" >&2; }
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
      warn "php8.5 not in repos yet; using PHP 8.4 (supported by Pelican)."
    elif apt-cache show "php8.3-fpm" &>/dev/null; then
      PHP_VERSION="8.3"
      warn "Using PHP 8.3 from repositories (Pelican supports 8.2–8.5)."
    else
      PHP_VERSION="8.3"
      warn "Could not probe packages; defaulting to PHP 8.3 — ensure Pelican-supported PHP is installed."
    fi
  else
    PHP_VERSION="8.3"
    warn "Non-Debian family: defaulting PHP version label to 8.3 — verify php-fpm package names."
  fi
  PHP_PKG_PREFIX="php${PHP_VERSION}"
  SUMMARY[php_version]="$PHP_VERSION"
}

ensure_php_repo_debian() {
  [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]] || return 0
  if apt-cache show "php8.5-fpm" &>/dev/null; then
    return 0
  fi
  info "Adding ondrej/php PPA (or sury for Debian) for recent PHP versions…"
  apt-get update -qq
  apt-get install -y software-properties-common curl gnupg lsb-release
  if [[ "$OS_ID" == "ubuntu" ]]; then
    add-apt-repository -y ppa:ondrej/php
  else
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/php.gpg 2>/dev/null || true
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
  fi
  apt-get update -qq
}

apt_install_panel_deps() {
  ensure_php_repo_debian
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "nginx" \
    "mariadb-server" "mariadb-client" \
    "${PHP_PKG_PREFIX}-fpm" "${PHP_PKG_PREFIX}-cli" "${PHP_PKG_PREFIX}-common" \
    "${PHP_PKG_PREFIX}-mysql" "${PHP_PKG_PREFIX}-gd" "${PHP_PKG_PREFIX}-mbstring" \
    "${PHP_PKG_PREFIX}-bcmath" "${PHP_PKG_PREFIX}-xml" "${PHP_PKG_PREFIX}-curl" \
    "${PHP_PKG_PREFIX}-zip" "${PHP_PKG_PREFIX}-intl" "${PHP_PKG_PREFIX}-sqlite3" \
    curl tar unzip git ca-certificates
  systemctl enable --now "${PHP_PKG_PREFIX}-fpm"
  systemctl restart "${PHP_PKG_PREFIX}-fpm"
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

# ---------------------------------------------------------------------------
# Panel: download & composer
# ---------------------------------------------------------------------------
install_panel_files() {
  mkdir -p "$PELICAN_ROOT"
  info "Downloading Pelican Panel release…"
  curl -fsSL "$PELICAN_RELEASE_URL" | tar -xzv -C "$PELICAN_ROOT" --strip-components=0 2>/dev/null || {
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
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi
  pushd "$PELICAN_ROOT" >/dev/null
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  popd >/dev/null
}

configure_panel_env() {
  local db_name="$1" db_user="$2" db_pass="$3"
  pushd "$PELICAN_ROOT" >/dev/null
  php artisan p:environment:setup --no-interaction

  php artisan p:environment:database --no-interaction \
    --driver=mysql \
    --database="$db_name" \
    --host=127.0.0.1 \
    --port=3306 \
    --username="$db_user" \
    --password="$db_pass"

  php artisan migrate --force --no-interaction
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
  php artisan p:user:make --no-interaction \
    --email="$email" --username="$username" --password="$password" --admin=1
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
  nginx -t
  systemctl reload nginx
}

# ---------------------------------------------------------------------------
# Wings
# ---------------------------------------------------------------------------
install_docker() {
  if command -v docker &>/dev/null; then
    info "Docker already installed."
    systemctl enable --now docker 2>/dev/null || true
    return 0
  fi
  info "Installing Docker CE (get.docker.com)…"
  curl -fsSL https://get.docker.com/ | CHANNEL=stable sh
  systemctl enable --now docker
}

install_wings_binary() {
  local arch
  arch=$(uname -m)
  [[ "$arch" == "x86_64" ]] && arch="amd64" || arch="arm64"
  mkdir -p /etc/pelican /var/run/wings
  info "Downloading Wings (${arch})…"
  curl -fsSL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${arch}"
  chmod u+x /usr/local/bin/wings
}

wings_systemd() {
  cat > /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable wings
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
  if [[ -n "${SUMMARY[panel_url]:-}" ]]; then
    printf '  %s%-22s%s %s\n' "$BOLD" "Panel URL" "$RESET" "${SUMMARY[panel_url]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "Web installer" "$RESET" "${SUMMARY[panel_url]}/installer (if needed)"
  fi
  if [[ -n "${SUMMARY[db_name]:-}" ]]; then
    printf '  %s%-22s%s %s\n' "$BOLD" "Database name" "$RESET" "${SUMMARY[db_name]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "Database user" "$RESET" "${SUMMARY[db_user]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "Database password" "$RESET" "${SUMMARY[db_password]}"
  fi
  if [[ -n "${SUMMARY[admin_email]:-}" ]]; then
    printf '  %s%-22s%s %s\n' "$BOLD" "Admin email" "$RESET" "${SUMMARY[admin_email]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "Admin username" "$RESET" "${SUMMARY[admin_username]}"
    printf '  %s%-22s%s %s\n' "$BOLD" "Admin password" "$RESET" "${SUMMARY[admin_password]}"
  fi
  if [[ -n "${SUMMARY[app_key]:-}" ]]; then
    printf '  %s%-22s%s %s\n' "$BOLD" "APP_KEY (backup!)" "$RESET" "${SUMMARY[app_key]}"
  fi
  if [[ "${SUMMARY[wings_installed]:-}" == "yes" ]]; then
    printf '  %s%-22s%s %s\n' "$BOLD" "Wings binary" "$RESET" "/usr/local/bin/wings"
    printf '  %s%-22s%s %s\n' "$BOLD" "Wings config" "$RESET" "/etc/pelican/config.yml (from Panel → Nodes → Configuration)"
    printf '  %s%-22s%s %s\n' "$BOLD" "Wings service" "$RESET" "systemctl start wings (after valid config)"
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

# ---------------------------------------------------------------------------
# Express flow
# ---------------------------------------------------------------------------
run_express() {
  SUMMARY[mode]="express"
  menu_components

  local admin_email admin_user admin_pass db_name db_user db_pass fqdn

  db_name="pelican"
  db_user="pelican"
  db_pass=$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24)
  [[ -n "$db_pass" ]] || db_pass=$(head -c 32 /dev/urandom 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  admin_email=$(prompt "Admin email (first user)" "admin@localhost")
  admin_user=$(prompt "Admin username" "admin")
  admin_pass=$(prompt_secret "Admin password (hidden)")

  if [[ "$INSTALL_COMPONENTS" != "wings" ]]; then
    local auto_ip
    auto_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fqdn=$(prompt "Panel domain or IP for Nginx server_name" "${auto_ip:-127.0.0.1}")
    SUMMARY[panel_url]="http://${fqdn}"
  fi

  SUMMARY[components]="$INSTALL_COMPONENTS"
  SUMMARY[os]="$OS_PRETTY"
  SUMMARY[db_name]="$db_name"
  SUMMARY[db_user]="$db_user"
  SUMMARY[db_password]="$db_pass"
  SUMMARY[admin_email]="$admin_email"
  SUMMARY[admin_username]="$admin_user"
  SUMMARY[admin_password]="$admin_pass"

  if [[ "$INSTALL_COMPONENTS" == "panel" || "$INSTALL_COMPONENTS" == "both" ]]; then
    select_php_version
    info "Installing packages (nginx, MariaDB, PHP ${PHP_VERSION})…"
    apt_install_panel_deps
    info "Creating database…"
    create_database_and_user "$db_name" "$db_user" "$db_pass"
    info "Installing panel files…"
    install_panel_files
    info "Configuring environment & migrations…"
    configure_panel_env "$db_name" "$db_user" "$db_pass"
    info "Creating administrator…"
    create_admin_user "$admin_email" "$admin_user" "$admin_pass"
    panel_permissions
    setup_cron
    nginx_write_site "$fqdn" 0
    SUMMARY[panel_path]="$PELICAN_ROOT"
    SUMMARY[app_key]="$(extract_app_key)"
  fi

  if [[ "$INSTALL_COMPONENTS" == "wings" || "$INSTALL_COMPONENTS" == "both" ]]; then
    install_docker
    install_wings_binary
    wings_systemd
    SUMMARY[wings_installed]="yes"
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
  printf '%sDatabase%s\n' "$BOLD" "$RESET"
  db_driver=$(prompt "DB driver (mysql, sqlite, pgsql)" "mysql")
  db_name=$(prompt "Database name" "pelican")
  db_user=$(prompt "Database user" "pelican")
  db_pass=$(prompt_secret "Database password")

  echo
  printf '%sAdmin account (panel)%s\n' "$BOLD" "$RESET"
  admin_email=$(prompt "Admin email" "admin@localhost")
  admin_user=$(prompt "Admin username" "admin")
  admin_pass=$(prompt_secret "Admin password")

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

  if [[ "$INSTALL_COMPONENTS" == "panel" || "$INSTALL_COMPONENTS" == "both" ]]; then
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
      php artisan p:environment:database --no-interaction \
        --driver=mysql \
        --database="$db_name" \
        --host=127.0.0.1 \
        --port=3306 \
        --username="$db_user" \
        --password="$db_pass"
    elif [[ "$db_driver" == "pgsql" ]]; then
      php artisan p:environment:database --no-interaction \
        --driver=pgsql \
        --database="$db_name" \
        --host=127.0.0.1 \
        --port=5432 \
        --username="$db_user" \
        --password="$db_pass"
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

    SUMMARY[app_key]="$(extract_app_key)"
  fi

  if [[ "$INSTALL_COMPONENTS" == "wings" || "$INSTALL_COMPONENTS" == "both" ]]; then
    install_docker
    install_wings_binary
    wings_systemd
    SUMMARY[wings_installed]="yes"
  fi

  print_summary
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  detect_environment
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
