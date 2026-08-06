#!/usr/bin/env bash
set -Eeuo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APP_NAME="paineldtmod"
APP_DIR="/opt/paineldtmod"
INSTALLER_VERSION="2026.07.24.9"
BRAND="@nandoslayer"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
COMMAND_FILE="/usr/local/bin/${APP_NAME}"
NGINX_FILE="/etc/nginx/sites-available/${APP_NAME}.conf"
DOMAIN_FILE="/etc/paineldtmod.conf"
VERSION_FILE="${APP_DIR}/.paineldtmod-version"
PORT="${PORT:-3000}"

if [[ -t 1 && -t 2 ]]; then
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'
  BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'
else
  RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
fi

erro() { printf '%b\n' "${RED}${BOLD}✖ Erro${RESET} [${BRAND}] $*" >&2; exit 1; }
info() { printf '%b\n' "${CYAN}➜${RESET} $*"; }
ok() { printf '%b\n' "${GREEN}✔${RESET} $*"; }
aviso() { printf '%b\n' "${YELLOW}⚠${RESET} $*"; }
secao() { printf '\n%b\n' "${BLUE}${BOLD}━━ $* ━━${RESET}"; }
[[ "$(id -u)" -eq 0 ]] || erro "execute este instalador como root (sudo bash install.sh)."
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_SOURCE=""
if [[ ! -f "$SOURCE_DIR/package.json" && -f "$SOURCE_DIR/Painel DTunnelMod/package.json" ]]; then
  SOURCE_DIR="$SOURCE_DIR/Painel DTunnelMod"
fi

printf '\n%b\n' "${CYAN}${BOLD}╭────────────────────────────────────────────╮${RESET}"
printf '%b\n' "${CYAN}${BOLD}│  PAINEL DTMOD  •  ${BRAND}${RESET}"
printf '%b\n' "${CYAN}${BOLD}│  INSTALADOR HTTPS  •  Let's Encrypt${RESET}"
printf '%b\n' "${CYAN}${BOLD}╰────────────────────────────────────────────╯${RESET}"
printf '%b\n' "${DIM}Versão ${INSTALLER_VERSION}  •  produção limpa  •  PM2${RESET}"
secao "Configuração inicial"
CURRENT_DOMAIN=""
CURRENT_PORT=""
CURRENT_CERT_EMAIL=""
if [[ -r "$DOMAIN_FILE" ]]; then
  CURRENT_DOMAIN="$(sed -n -e 's/^PAINEL_DOMAIN=//p' -e 's/^DOMAIN=//p' "$DOMAIN_FILE" | head -n 1 | tr -d '"' | tr -d "'")"
  CURRENT_PORT="$(sed -n -e 's/^PAINEL_PORT=//p' -e 's/^PORT=//p' "$DOMAIN_FILE" | head -n 1 | tr -d '"' | tr -d "'")"
  CURRENT_CERT_EMAIL="$(sed -n 's/^PAINEL_CERT_EMAIL=//p' "$DOMAIN_FILE" | head -n 1 | tr -d '"' | tr -d "'")"
fi
if [[ "$CURRENT_PORT" =~ ^[0-9]+$ ]]; then
  PORT="$CURRENT_PORT"
fi
if [[ -n "$CURRENT_DOMAIN" ]]; then
  read -r -p "${CYAN}◆ Domínio do painel [${CURRENT_DOMAIN}]: ${RESET}" INPUT_DOMAIN
else
  read -r -p "${CYAN}◆ Domínio do painel (ex.: painel.exemplo.com): ${RESET}" INPUT_DOMAIN
fi
DOMAIN="${INPUT_DOMAIN:-$CURRENT_DOMAIN}"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || erro "domínio inválido."
read -r -p "${CYAN}◆ Porta interna do painel [${PORT}]: ${RESET}" INPUT_PORT
PORT="${INPUT_PORT:-$PORT}"
[[ "$PORT" =~ ^[0-9]+$ ]] || erro "porta inválida."
aviso "O domínio precisa apontar para esta VPS e ficar com a nuvem Cloudflare DESATIVADA (cinza/DNS only)."
read -r -p "${YELLOW}◆ Confirme digitando SIM para continuar: ${RESET}" CLOUDFLARE_DNS_ONLY
[[ "$CLOUDFLARE_DNS_ONLY" =~ ^[Ss][Ii][Mm]$ ]] || erro "ative o DNS only/nuvem cinza na Cloudflare antes de instalar."
if [[ -n "$CURRENT_CERT_EMAIL" ]]; then
  read -r -p "${CYAN}◆ E-mail do Let's Encrypt [${CURRENT_CERT_EMAIL}] (opcional): ${RESET}" INPUT_CERT_EMAIL
  CERT_EMAIL="${INPUT_CERT_EMAIL:-$CURRENT_CERT_EMAIL}"
else
  read -r -p "${CYAN}◆ E-mail do Let's Encrypt (opcional, ENTER sem e-mail): ${RESET}" CERT_EMAIL
fi

export DEBIAN_FRONTEND=noninteractive
secao "Instalação do ambiente"
info "Instalando dependências do sistema..."
apt-get update
apt-get install -y ca-certificates curl nginx openssl rsync build-essential unzip sqlite3 jq certbot python3-certbot-nginx
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
fi
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
npm install --global pm2
PM2_BIN="$(command -v pm2)"
[[ -x "$PM2_BIN" ]] || erro "PM2 não foi instalado corretamente."

ok "Dependências prontas."
validar_dns() {
  local dns_ipv4s public_ipv4 dns_ipv6s public_ipv6
  dns_ipv4s="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  [[ -n "${dns_ipv4s// /}" ]] || erro "não foi possível resolver o domínio ${DOMAIN}. Crie o registro DNS e aguarde a propagação."

  info "IPs IPv4 encontrados para ${DOMAIN}: ${dns_ipv4s}"
  public_ipv4="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$public_ipv4" ]]; then
    if ! printf '%s\n' "$dns_ipv4s" | tr ' ' '\n' | grep -Fxq "$public_ipv4"; then
      aviso "O domínio não aponta para o IP público desta VPS."
      printf '%b\n' "${YELLOW}IP público da VPS: ${public_ipv4}${RESET}"
      printf '%b\n' "${YELLOW}IPs atuais do domínio: ${dns_ipv4s}${RESET}"
      erro "corrija o registro A para ${public_ipv4}, remova CNAME/AAAA conflitantes e deixe a Cloudflare em DNS only/nuvem cinza."
    fi
  else
    aviso "Não foi possível consultar o IP público desta VPS; o Certbot fará a validação final."
  fi

  dns_ipv6s="$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  if [[ -n "${dns_ipv6s// /}" ]]; then
    public_ipv6="$(curl -6fsS --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
    if [[ -z "$public_ipv6" ]] || ! printf '%s\n' "$dns_ipv6s" | tr ' ' '\n' | grep -Fxq "$public_ipv6"; then
      aviso "Existe um registro AAAA para ${DOMAIN}, mas ele não aponta para esta VPS."
      printf '%b\n' "${YELLOW}AAAA atual: ${dns_ipv6s}${RESET}"
      erro "remova o registro AAAA conflitante ou aponte-o para o IPv6 correto desta VPS."
    fi
  fi
  ok "DNS do domínio corresponde à VPS."
}
validar_dns
validar_zip() {
  local arquivo_zip="$1"
  if unzip -Z1 "$arquivo_zip" | grep -q '\\'; then
    erro "ZIP incompatível: ele usa barras invertidas nos caminhos internos. Baixe o pacote atualizado."
  fi
}

if [[ ! -f "$SOURCE_DIR/package.json" ]]; then
  ARCHIVE="$(find "$(dirname "${BASH_SOURCE[0]}")" -maxdepth 1 -type f -iname 'paineldtmod.zip' | head -n 1)"
  if [[ -z "$ARCHIVE" ]]; then
    ARCHIVE="$(find "$(dirname "${BASH_SOURCE[0]}")" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ZIP' \) | head -n 1)"
  fi
  [[ -n "$ARCHIVE" ]] || erro "coloque install.sh e o ZIP do painel na mesma pasta."
  validar_zip "$ARCHIVE"
  TEMP_SOURCE="$(mktemp -d)"
  trap '[[ -n "${TEMP_SOURCE}" ]] && rm -rf "${TEMP_SOURCE}"' EXIT
  info "Extraindo $(basename "$ARCHIVE")..."
  unzip -q "$ARCHIVE" -d "$TEMP_SOURCE"
  PACKAGE_FILE="$(find "$TEMP_SOURCE" -type f -name package.json -print -quit)"
  if [[ -n "$PACKAGE_FILE" ]]; then
    SOURCE_DIR="$(dirname "$PACKAGE_FILE")"
  else
    NESTED_ARCHIVE="$(find "$TEMP_SOURCE" -type f -iname 'paineldtmod.zip' -print -quit)"
    [[ -n "$NESTED_ARCHIVE" ]] || erro "package.json não encontrado dentro do ZIP enviado."
    validar_zip "$NESTED_ARCHIVE"
    NESTED_SOURCE="${TEMP_SOURCE}/paineldtmod"
    mkdir -p "$NESTED_SOURCE"
    unzip -q "$NESTED_ARCHIVE" -d "$NESTED_SOURCE"
    PACKAGE_FILE="$(find "$NESTED_SOURCE" -type f -name package.json -print -quit)"
    [[ -n "$PACKAGE_FILE" ]] || erro "package.json não encontrado dentro do paineldtmod.zip."
    SOURCE_DIR="$(dirname "$PACKAGE_FILE")"
  fi
fi
[[ -f "$SOURCE_DIR/package.json" ]] || erro "package.json não encontrado dentro do ZIP do painel."
info "Parando qualquer versão anterior do painel..."
systemctl disable --now paineldtmod paineldtmod-telegram paineldtmod-backup.timer paineldtmod-backup.service 2>/dev/null || true
rm -f "$SERVICE_FILE"
systemctl daemon-reload
pm2 delete paineldtmod >/dev/null 2>&1 || true
while IFS= read -r LEGACY_PM2_APP; do
  [[ -n "$LEGACY_PM2_APP" ]] && pm2 delete "$LEGACY_PM2_APP" >/dev/null 2>&1 || true
done < <(pm2 jlist 2>/dev/null | jq -r '.[] | select((.pm2_env.pm_exec_path // "") | startswith("/opt/paineldtmod/")) | .name' 2>/dev/null || true)
pm2 save --force >/dev/null 2>&1 || true
info "Copiando o painel para ${APP_DIR}..."
install -d -m 0755 "$APP_DIR" "$APP_DIR/data"
rsync -a --delete --exclude node_modules --exclude build --exclude .env --exclude 'data/' --exclude 'telegram.conf' --exclude '*.db' "$SOURCE_DIR/" "$APP_DIR/"
cd "$APP_DIR"
find "$APP_DIR" -maxdepth 1 -type f \( -name 'ecosystem*.js' -o -name 'ecosystem*.cjs' -o -name 'ecosystem*.mjs' \) -delete
if [[ ! -f .env ]]; then
  cat > .env <<EOF
PORT=${PORT}
NODE_ENV=production
DATABASE_URL=file:${APP_DIR}/data/database.db
CSRF_SECRET=$(openssl rand -base64 48 | tr -d '\n')
JWT_SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')
JWT_SECRET_REFRESH=$(openssl rand -base64 48 | tr -d '\n')
EOF
else
  info "Configuração e banco existentes preservados."
  DATABASE_URL_VALUE="$(sed -n 's/^DATABASE_URL=//p' .env | head -n 1 | tr -d '\"' | tr -d "'")"
  DATABASE_SOURCE=""
  if [[ "$DATABASE_URL_VALUE" == file:./* ]]; then
    DATABASE_SOURCE="$APP_DIR/prisma/${DATABASE_URL_VALUE#file:./}"
  elif [[ "$DATABASE_URL_VALUE" == file:/* ]]; then
    DATABASE_SOURCE="${DATABASE_URL_VALUE#file:}"
  fi
  if [[ ! -s "$APP_DIR/data/database.db" && -n "$DATABASE_SOURCE" && -s "$DATABASE_SOURCE" ]]; then
    info "Migrando o banco existente para ${APP_DIR}/data/database.db..."
    sqlite3 "$DATABASE_SOURCE" ".backup '$APP_DIR/data/database.db'"
  fi
  if [[ ! -s "$APP_DIR/data/database.db" ]]; then
    for CANDIDATE in "$APP_DIR/prisma/database.db" "$APP_DIR/database.db"; do
      if [[ -s "$CANDIDATE" ]]; then
        DATABASE_SOURCE="$CANDIDATE"
        info "Migrando o banco existente para ${APP_DIR}/data/database.db..."
        sqlite3 "$CANDIDATE" ".backup '$APP_DIR/data/database.db'"
        break
      fi
    done
  fi
  if [[ -s "$APP_DIR/data/database.db" ]]; then
    if grep -q '^DATABASE_URL=' .env; then
      sed -i "s|^DATABASE_URL=.*|DATABASE_URL=file:${APP_DIR}/data/database.db|" .env
    else
      echo "DATABASE_URL=file:${APP_DIR}/data/database.db" >> .env
    fi
  fi
  if grep -q '^PORT=' .env; then
    sed -i "s/^PORT=.*/PORT=${PORT}/" .env
  else
    sed -i "1iPORT=${PORT}" .env
  fi
fi
chmod 600 .env
info "Instalando dependências do painel..."
npm install
ok "Dependências do painel prontas."
npx prisma generate
if [[ -s "$APP_DIR/data/database.db" ]]; then
  info "Banco existente encontrado; sincronizando sem apagar os dados..."
  npx prisma db push --skip-generate
else
  npx prisma migrate deploy
fi
rm -rf "$APP_DIR/build"
npm run build
info "Removendo arquivos e dependências de desenvolvimento..."
npm prune --omit=dev
if [[ "${DATABASE_SOURCE:-}" == "$APP_DIR/"* && "${DATABASE_SOURCE:-}" != "$APP_DIR/data/database.db" ]]; then
  rm -f "$DATABASE_SOURCE"
fi
rm -rf "$APP_DIR/src" "$APP_DIR/.git" "$APP_DIR/.github"
rm -rf "$APP_DIR/.cache" "$APP_DIR/coverage" "$APP_DIR/logs" "$APP_DIR/tmp"
find "$APP_DIR" -maxdepth 1 -type f \( -name 'ecosystem*.js' -o -name 'ecosystem*.cjs' -o -name 'ecosystem*.mjs' \) -delete
rm -f "$APP_DIR/README.md" "$APP_DIR/.env.example" "$APP_DIR/tsconfig.json" \
  "$APP_DIR/environment.d.ts" "$APP_DIR/.eslintrc.js" \
  "$APP_DIR/.prettierrc" "$APP_DIR/.prettierignore" "$APP_DIR/.editorconfig" \
  "$APP_DIR/install.sh"
ok "Arquivos de produção preparados."
[[ -f "$APP_DIR/build/index.js" ]] || erro "A compilação não gerou build/index.js."
LEGACY_PM2_CONFIG="$(find "$APP_DIR" -maxdepth 1 -type f -name 'ecosystem*.config.js' -print -quit)"
[[ -z "$LEGACY_PM2_CONFIG" ]] || erro "Configuração antiga do PM2 permaneceu em ${APP_DIR}."
cat > "$VERSION_FILE" <<EOF
instalador=${INSTALLER_VERSION}
marca=${BRAND}
instalado_em=$(date -u +%Y-%m-%dT%H:%M:%SZ)
entrada=${APP_DIR}/build/index.js
https=letsencrypt
EOF
chmod 600 "$VERSION_FILE"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Painel DTunnelMod - ${BRAND}
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=${APP_DIR}
ExecStart=${PM2_BIN} resurrect
ExecStop=-${PM2_BIN} stop paineldtmod
ExecReload=-${PM2_BIN} restart paineldtmod --update-env
EnvironmentFile=${APP_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF
grep -Fq "ExecStart=${PM2_BIN} resurrect" "$SERVICE_FILE" || erro "A unidade nova do painel não foi gravada corretamente."

cat > "$NGINX_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
cat > "$DOMAIN_FILE" <<EOF
PAINEL_DOMAIN='${DOMAIN}'
PAINEL_PORT='${PORT}'
PAINEL_CERT_EMAIL='${CERT_EMAIL}'
PAINEL_CERTBOT_MANAGED='true'
EOF
chmod 0644 "$DOMAIN_FILE"
ln -sfn "$NGINX_FILE" "/etc/nginx/sites-enabled/${APP_NAME}.conf"
nginx -t
systemctl enable nginx
systemctl reload nginx 2>/dev/null || systemctl restart nginx
validar_http_acme() {
  local cabecalhos localizacao
  cabecalhos="$(curl -sS -D - -o /dev/null --max-time 10 "http://${DOMAIN}/.well-known/acme-challenge/paineldtmod-check" 2>/dev/null || true)"
  localizacao="$(printf '%s\n' "$cabecalhos" | awk 'tolower($1) == "location:" { $1=""; sub(/^[[:space:]]+/, ""); print; exit }' | tr -d '\r')"
  if [[ "$localizacao" =~ ^https?:// ]]; then
    case "$localizacao" in
      "http://${DOMAIN}"*|"https://${DOMAIN}"*) ;;
      *)
        aviso "A porta 80 está redirecionando o desafio para outro endereço: ${localizacao}"
        erro "remova o redirecionamento antigo do Nginx/Cloudflare e deixe ${DOMAIN} responder diretamente nesta VPS."
        ;;
    esac
  fi
}
validar_http_acme
info "Emitindo certificado HTTPS do Let's Encrypt..."
CERTBOT_COMMAND=(certbot --nginx --non-interactive --agree-tos --keep-until-expiring --redirect --preferred-challenges http -d "$DOMAIN")
if [[ -n "$CERT_EMAIL" ]]; then
  CERTBOT_COMMAND+=(--email "$CERT_EMAIL")
else
  CERTBOT_COMMAND+=(--register-unsafely-without-email)
fi
if ! "${CERTBOT_COMMAND[@]}"; then
  erro "Let's Encrypt não conseguiu emitir o certificado. Confirme DNS apontando para esta VPS, portas 80/443 liberadas e Cloudflare em DNS only/nuvem cinza."
fi
systemctl enable --now certbot.timer 2>/dev/null || true
nginx -t
ok "Nginx e certificado HTTPS configurados."

cat > "$COMMAND_FILE" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -t 1 ]]; then
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  VERMELHO=$'\033[0;31m'
  VERDE=$'\033[0;32m'
  AMARELO=$'\033[1;33m'
  AZUL=$'\033[0;36m'
  CYAN=$'\033[0;36m'
  BRANCO=$'\033[0;37m'
else
  RESET=''; BOLD=''; DIM=''; VERMELHO=''; VERDE=''; AMARELO=''; AZUL=''; CYAN=''; BRANCO=''
fi
BRAND="@nandoslayer"

erro() { printf '%b\n' "${VERMELHO}${BOLD}✖ Erro${RESET} [${BRAND}] $*" >&2; return 1; }
info() { printf '%b\n' "${AZUL}➜${RESET} $*"; }
ok() { printf '%b\n' "${VERDE}✔${RESET} $*"; }
aviso() { printf '%b\n' "${AMARELO}⚠${RESET} $*"; }
secao() { printf '\n%b\n' "${AZUL}${BOLD}━━ $* ━━${RESET}"; }

estado_pm2() {
  local estado
  estado="$(pm2 jlist 2>/dev/null | jq -r '.[] | select(.name == "paineldtmod") | .pm2_env.status' | head -n 1 || true)"
  printf '%s\n' "${estado:-inativo}"
}
rotulo_estado() {
  case "$1" in
    online) echo "online" ;;
    stopped|stopping|stopped_waiting_restart) echo "parado" ;;
    *) echo "inativo" ;;
  esac
}
estado_visual() {
  case "$1" in
    online) printf '%b' "${VERDE}● online${RESET}" ;;
    stopped|stopping|stopped_waiting_restart) printf '%b' "${AMARELO}● parado${RESET}" ;;
    *) printf '%b' "${VERMELHO}● inativo${RESET}" ;;
  esac
}
linha_menu() { printf '%b\n' "${DIM}──────────────────────────────────────────────${RESET}"; }
resumo_painel() {
  local estado inicializacao estado_texto
  estado="$(estado_pm2)"
  inicializacao="$(systemctl is-enabled paineldtmod 2>/dev/null || true)"
  if [[ "$inicializacao" == "enabled" ]]; then
    inicializacao="${VERDE}● ativada${RESET}"
  else
    inicializacao="${AMARELO}● desativada${RESET}"
  fi
  estado_texto="$(estado_visual "$estado")"
  printf '%b\n' "  ${BRANCO}Painel:${RESET} ${estado_texto}"
  printf '%b\n' "  ${BRANCO}Inicialização automática:${RESET} ${inicializacao}"
}
status_painel() {
  linha_menu
  printf '%b\n' "${AZUL}${BOLD}Status detalhado${RESET}"
  resumo_painel
  linha_menu
  pm2 status paineldtmod || true
}
logs_painel() { pm2 logs paineldtmod --lines 100 --nostream || journalctl -u paineldtmod -n 100 --no-pager; }
iniciar_painel() {
  systemctl start paineldtmod >/dev/null 2>&1 || true
  if [[ "$(estado_pm2)" != "online" ]]; then
    if pm2 describe paineldtmod >/dev/null 2>&1; then
      pm2 start paineldtmod
    else
      pm2 start /opt/paineldtmod/build/index.js --name paineldtmod --cwd /opt/paineldtmod --time
    fi
  fi
  pm2 save >/dev/null
  echo -e "${VERDE}✔ Painel iniciado. Status: $(rotulo_estado "$(estado_pm2)")${RESET}"
}
parar_painel() {
  systemctl stop paineldtmod >/dev/null 2>&1 || true
  pm2 stop paineldtmod >/dev/null 2>&1 || true
  echo -e "${AMARELO}● Painel parado. Status: $(rotulo_estado "$(estado_pm2)")${RESET}"
}
alternar_painel() {
  if [[ "$(estado_pm2)" == "online" ]]; then
    parar_painel
  else
    iniciar_painel
  fi
}
reiniciar_painel() {
  systemctl restart paineldtmod >/dev/null 2>&1 || true
  if [[ "$(estado_pm2)" != "online" ]]; then
    pm2 restart paineldtmod >/dev/null 2>&1 || pm2 start /opt/paineldtmod/build/index.js --name paineldtmod --cwd /opt/paineldtmod --time
  fi
  pm2 save >/dev/null
  echo -e "${VERDE}↻ Painel reiniciado. Status: $(rotulo_estado "$(estado_pm2)")${RESET}"
}
contar_banco() { cd /opt/paineldtmod && node scripts/contar-tabelas.js; }
emitir_certificado() {
  local dominio="$1" email="${2:-}"
  local -a comando=(certbot --nginx --non-interactive --agree-tos --keep-until-expiring --redirect --preferred-challenges http -d "$dominio")
  if [[ -n "$email" ]]; then
    comando+=(--email "$email")
  else
    comando+=(--register-unsafely-without-email)
  fi
  "${comando[@]}"
}
dominio_trocar() {
  local dominio_atual porta novo backup_nginx backup_domain email confirmacao_cloudflare
  if [[ -r /etc/paineldtmod.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/paineldtmod.conf
  fi
  dominio_atual="${PAINEL_DOMAIN:-não configurado}"
  porta="${PAINEL_PORT:-3000}"
  email="${PAINEL_CERT_EMAIL:-}"
  echo "Domínio atual: ${dominio_atual}"
  read -r -p "Novo domínio: " novo
  [[ "$novo" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Domínio inválido."; return 1; }
  echo "O novo domínio precisa estar com a nuvem Cloudflare cinza/DNS only."
  read -r -p "Confirme digitando SIM para continuar: " confirmacao_cloudflare
  [[ "$confirmacao_cloudflare" =~ ^[Ss][Ii][Mm]$ ]] || { echo "Ative DNS only/nuvem cinza antes de emitir o certificado."; return 1; }
  if [[ -z "$email" ]]; then
    read -r -p "E-mail do Let's Encrypt (opcional, ENTER sem e-mail): " email
  fi
  backup_nginx="$(mktemp)"
  cp /etc/nginx/sites-available/paineldtmod.conf "$backup_nginx"
  backup_domain="$(mktemp)"
  [[ -f /etc/paineldtmod.conf ]] && cp /etc/paineldtmod.conf "$backup_domain" || true
  cat > /etc/nginx/sites-available/paineldtmod.conf <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${novo};

    location / {
        proxy_pass http://127.0.0.1:${porta};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
  if ! nginx -t || ! systemctl reload nginx; then
    cp "$backup_nginx" /etc/nginx/sites-available/paineldtmod.conf
    [[ -s "$backup_domain" ]] && cp "$backup_domain" /etc/paineldtmod.conf || rm -f /etc/paineldtmod.conf
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    rm -f "$backup_nginx" "$backup_domain"
    echo "Não foi possível aplicar o novo domínio; configuração anterior restaurada."
    return 1
  fi
  if ! emitir_certificado "$novo" "$email"; then
    cp "$backup_nginx" /etc/nginx/sites-available/paineldtmod.conf
    [[ -s "$backup_domain" ]] && cp "$backup_domain" /etc/paineldtmod.conf || rm -f /etc/paineldtmod.conf
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    rm -f "$backup_nginx" "$backup_domain"
    echo "Let's Encrypt não conseguiu emitir o certificado; configuração anterior restaurada."
    return 1
  fi
  rm -f "$backup_nginx"
  rm -f "$backup_domain"
  cat > /etc/paineldtmod.conf <<CFG
PAINEL_DOMAIN='${novo}'
PAINEL_PORT='${porta}'
PAINEL_CERT_EMAIL='${email}'
PAINEL_CERTBOT_MANAGED='true'
CFG
  echo -e "${VERDE}Domínio e certificado alterados para: ${novo}${RESET}"
}
telegram_configurar() {
  local token chat
  read -r -p "Token do bot Telegram: " token
  read -r -p "ID do chat autorizado: " chat
  [[ -n "$token" && -n "$chat" ]] || { echo "Token e chat são obrigatórios."; return 1; }
  cat > /opt/paineldtmod/telegram.conf <<CFG
TELEGRAM_BOT_TOKEN='$token'
TELEGRAM_CHAT_ID='$chat'
CFG
  chmod 600 /opt/paineldtmod/telegram.conf
  systemctl restart paineldtmod-telegram
  echo -e "${VERDE}Telegram configurado. Abra o bot e toque em Fazer backup para testar.${RESET}"
}
telegram_backup() { cd /opt/paineldtmod && bash scripts/telegram-backup.sh backup; }
restaurar_arquivo() {
  local arquivo
  read -r -p "Caminho do arquivo .tar.gz: " arquivo
  cd /opt/paineldtmod && bash scripts/telegram-backup.sh restaurar "$arquivo"
}
atualizar() {
  cd /opt/paineldtmod
  npm install --omit=dev
  npx prisma generate
  if [[ -s /opt/paineldtmod/data/database.db ]]; then
    npx prisma db push --skip-generate
  else
    npx prisma migrate deploy
  fi
  pm2 restart paineldtmod
  echo -e "${VERDE}Dependências e banco atualizados; painel reiniciado.${RESET}"
}
desinstalar() {
  local certificado_domain="" certificado_managed="" confirmacao pm2_dir
  local -a aplicativos_pm2=()
  if [[ -r /etc/paineldtmod.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/paineldtmod.conf
    certificado_domain="${PAINEL_DOMAIN:-${DOMAIN:-}}"
    certificado_managed="${PAINEL_CERTBOT_MANAGED:-}"
  fi
  printf '%b\n' "${AMARELO}${BOLD}⚠ Desinstalação do Painel DTunnelMod${RESET}"
  printf '%b\n' "${DIM}Serão removidos o painel, banco, backups, Telegram, serviços e o conf deste domínio no Nginx.${RESET}"
  printf '%b\n' "${VERDE}O Nginx, o Certbot e os demais sites do servidor serão preservados.${RESET}"
  read -r -p "${AMARELO}Digite REMOVER para confirmar: ${RESET}" confirmacao
  [[ "$confirmacao" == "REMOVER" ]] || { aviso "Desinstalação cancelada."; return; }

  secao "Removendo componentes do painel"
  systemctl disable --now paineldtmod paineldtmod-telegram paineldtmod-backup.timer paineldtmod-backup.service 2>/dev/null || true

  if command -v pm2 >/dev/null 2>&1; then
    if command -v jq >/dev/null 2>&1; then
      mapfile -t aplicativos_pm2 < <(pm2 jlist 2>/dev/null | jq -r '.[] | select((.name == "paineldtmod") or ((.pm2_env.pm_cwd // "") | startswith("/opt/paineldtmod")) or ((.pm2_env.pm_exec_path // "") | startswith("/opt/paineldtmod"))) | .name' 2>/dev/null || true)
    fi
    for aplicativo_pm2 in "${aplicativos_pm2[@]}"; do
      [[ -n "$aplicativo_pm2" ]] && pm2 delete "$aplicativo_pm2" >/dev/null 2>&1 || true
    done
    pm2 delete paineldtmod >/dev/null 2>&1 || true
    pm2 save --force >/dev/null 2>&1 || true
    pm2_dir="${PM2_HOME:-/root/.pm2}"
    if [[ -d "$pm2_dir/logs" ]]; then
      find "$pm2_dir/logs" -maxdepth 1 -type f -name 'paineldtmod-*.log' -delete 2>/dev/null || true
    fi
  fi

  if [[ "$certificado_managed" == "true" && -n "$certificado_domain" ]] && command -v certbot >/dev/null 2>&1; then
    certbot delete --cert-name "$certificado_domain" --non-interactive >/dev/null 2>&1 || true
  fi
  rm -f /etc/systemd/system/paineldtmod.service
  rm -f /etc/systemd/system/paineldtmod-telegram.service
  rm -f /etc/systemd/system/paineldtmod-backup.service /etc/systemd/system/paineldtmod-backup.timer
  rm -f /etc/paineldtmod-backup.conf
  rm -f /etc/nginx/sites-enabled/paineldtmod.conf /etc/nginx/sites-available/paineldtmod.conf
  rm -f /etc/paineldtmod.conf
  systemctl daemon-reload
  systemctl reset-failed paineldtmod paineldtmod-telegram paineldtmod-backup.timer paineldtmod-backup.service 2>/dev/null || true
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || true
  else
    aviso "O Nginx foi preservado, mas já havia outro erro de configuração; não foi recarregado."
  fi
  rm -rf /opt/paineldtmod
  rm -f /usr/local/bin/paineldtmod
  ok "Painel, dados, backups, serviços e configuração do domínio removidos."
  info "Nginx e demais configurações de sites preservados."
  exit 0
}
cabecalho_menu() {
  clear 2>/dev/null || true
  printf '\n%b\n' "${AZUL}${BOLD}╭──────────────────────────────────────────────╮${RESET}"
  printf '%b\n' "${AZUL}${BOLD}│  PAINEL DTMOD  •  ${BRAND}${RESET}"
  printf '%b\n' "${AZUL}${BOLD}╰──────────────────────────────────────────────╯${RESET}"
  resumo_painel
  linha_menu
}
menu() {
  while true; do
    cabecalho_menu
    printf '%b\n' "  ${CYAN}${BOLD}1${RESET}  ⚡ Ligar/desligar painel"
    printf '%b\n' "  ${CYAN}${BOLD}2${RESET}  ↻  Reiniciar painel"
    printf '%b\n' "  ${CYAN}${BOLD}3${RESET}  ◉  Ver status"
    printf '%b\n' "  ${CYAN}${BOLD}4${RESET}  ▤  Ver logs"
    printf '%b\n' "  ${CYAN}${BOLD}5${RESET}  ▦  Contar registros das tabelas"
    printf '%b\n' "  ${CYAN}${BOLD}6${RESET}  ⟳  Atualizar dependências e banco"
    printf '%b\n' "  ${CYAN}${BOLD}7${RESET}  ⌁  Trocar domínio do painel"
    printf '%b\n' "  ${CYAN}${BOLD}8${RESET}  ✈  Configurar Telegram"
    printf '%b\n' "  ${CYAN}${BOLD}9${RESET}  ⇧  Enviar backup pelo Telegram"
    printf '%b\n' "  ${CYAN}${BOLD}10${RESET} ⇩  Restaurar backup local"
    printf '%b\n' "  ${CYAN}${BOLD}11${RESET} ✓  Validar Nginx"
    printf '%b\n' "  ${VERMELHO}${BOLD}12${RESET} ⌫  Desinstalar painel"
    printf '%b\n' "  ${DIM}0  Sair${RESET}"
    printf '\n'
    read -r -p "${CYAN}◆ Escolha uma opção: ${RESET}" opcao
    case "$opcao" in
      1) alternar_painel ;;
      2) reiniciar_painel ;;
      3) status_painel ;;
      4) logs_painel ;;
      5) contar_banco ;;
      6) atualizar ;;
      7) dominio_trocar ;;
      8) telegram_configurar ;;
      9) telegram_backup ;;
      10) restaurar_arquivo ;;
      11) nginx -t ;;
      12) desinstalar ;;
      0) exit 0 ;;
      *) echo -e "${AMARELO}⚠ Opção inválida.${RESET}" ;;
    esac
    printf '\n'
    read -r -p "${DIM}Pressione ENTER para voltar ao menu...${RESET}" _
  done
}

case "${1:-menu}" in
  menu) menu ;;
  iniciar|start) iniciar_painel ;;
  parar|stop) parar_painel ;;
  alternar|toggle) alternar_painel ;;
  reiniciar|restart) reiniciar_painel ;;
  status|estado) status_painel ;;
  logs|log) logs_painel ;;
  banco|tabelas) contar_banco ;;
  dominio|dominio-trocar) dominio_trocar ;;
  telegram|telegram-configurar) telegram_configurar ;;
  backup) telegram_backup ;;
  restaurar) restaurar_arquivo ;;
  atualizar|update) atualizar ;;
  nginx) nginx -t ;;
  desinstalar|uninstall|remove) desinstalar ;;
  *) echo "Uso: paineldtmod [alternar|iniciar|parar|reiniciar|status|logs|banco|dominio|telegram|backup|restaurar|atualizar|nginx|desinstalar]"; exit 1 ;;
esac
EOF
chmod 0755 "$COMMAND_FILE"
chmod 0755 "$APP_DIR/scripts/telegram-backup.sh"
cat > /etc/systemd/system/paineldtmod-telegram.service <<EOF
[Unit]
Description=Bot Telegram de backup do Painel DTunnelMod - ${BRAND}
After=network-online.target paineldtmod.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=/bin/bash ${APP_DIR}/scripts/telegram-backup.sh bot
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/paineldtmod-backup.service <<EOF
[Unit]
Description=Backup automático do Painel DTunnelMod - ${BRAND}
After=network-online.target paineldtmod.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${APP_DIR}
ExecStart=/bin/bash ${APP_DIR}/scripts/telegram-backup.sh scheduled
EOF
systemctl daemon-reload
pm2 delete paineldtmod >/dev/null 2>&1 || true
pm2 start /opt/paineldtmod/build/index.js --name paineldtmod --cwd /opt/paineldtmod --time
pm2 save
PROCESS_PATH="$(pm2 jlist 2>/dev/null | jq -r '.[] | select(.name == "paineldtmod") | .pm2_env.pm_exec_path' | head -n 1 || true)"
[[ "$PROCESS_PATH" == "${APP_DIR}/build/index.js" ]] || erro "O PM2 não ficou apontado para ${APP_DIR}/build/index.js."
systemctl enable --now paineldtmod
if [[ -f "$APP_DIR/telegram.conf" ]]; then
  systemctl enable --now paineldtmod-telegram
else
  systemctl enable paineldtmod-telegram
fi
if [[ -f /etc/systemd/system/paineldtmod-backup.timer && -f "$APP_DIR/telegram.conf" ]]; then
  systemctl enable --now paineldtmod-backup.timer
fi
systemctl enable nginx
systemctl restart nginx

echo
ok "Serviço do painel ativado."
ok "Painel instalado com sucesso."
ok "Versão aplicada: ${INSTALLER_VERSION}"
ok "Marca aplicada: ${BRAND}"
echo "Acesse: https://${DOMAIN}"
echo "Let's Encrypt: renovação automática ativada."
echo "Cloudflare: mantenha a nuvem cinza/DNS only para este domínio."
echo "Menu: paineldtmod"
echo "Contagem do banco: paineldtmod banco"
