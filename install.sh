#!/bin/bash

# Цвета для вывода (определяем ДО set -euo pipefail)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

set -euo pipefail

# Заголовок
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════════════════════╗"
echo "  ║     Установка и настройка Certbot с токеном Cloudflare        ║"
echo "  ╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Функции для вывода
step() {
    step_progress "$1"
}

step_done() {
    step_progress_stop
}

STEP_PROGRESS_MSG=""

step_progress() {
    local msg="$1"
    STEP_PROGRESS_MSG="$msg"
    local pid_file="/tmp/certbot_install_progress_$$.pid"
    local spinner_chars="|/-\\"
    local spinner_idx=0
    
    (
        while [ -f "$pid_file" ]; do
            local spinner_char="${spinner_chars:$spinner_idx:1}"
            echo -ne "\r\033[K${spinner_char} ${BOLD}${msg}${NC}"
            spinner_idx=$(( (spinner_idx + 1) % 4 ))
            sleep 0.1
        done
    ) &
    echo $! > "$pid_file"
}

step_progress_stop() {
    local pid_file="/tmp/certbot_install_progress_$$.pid"
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f "$pid_file"
        sleep 0.15
        local msg="${STEP_PROGRESS_MSG}"
        echo -ne "\r\033[K${GREEN}✓${NC} ${BOLD}${msg}${NC}\n"
        STEP_PROGRESS_MSG=""
    fi
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} ${BOLD}Ошибка:${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

info() {
    echo -e "  ${GREEN}→${NC} $1"
}

# ============================================================================
# ПРОВЕРКИ
# ============================================================================

# Проверка запуска через sudo
if [ "$EUID" -ne 0 ]; then
    error "Скрипт должен быть запущен через sudo"
    exit 1
fi

# Определение пользователя, от имени которого запущен sudo
if [ -z "${SUDO_USER:-}" ]; then
    error "Не удалось определить пользователя. Запустите: sudo -u USER $0"
    exit 1
fi

REAL_USER="$SUDO_USER"
REAL_HOME=$(eval echo ~$REAL_USER)

info "Пользователь: $REAL_USER"
info "Домашняя директория: $REAL_HOME"

success "Проверки пройдены"

# ============================================================================
# ПРОВЕРКА И ЗАПРОС ТОКЕНА CLOUDFLARE
# ============================================================================

exec 3<&0

CLOUDFLARE_DIR="/etc/letsencrypt/cloudflare"
CLOUDFLARE_INI="$CLOUDFLARE_DIR/cloudflare.ini"

echo ""
# Проверяем наличие файла с токеном
if [ -f "$CLOUDFLARE_INI" ]; then
    echo -e "${BOLD}${GREEN}Найден существующий файл с токеном: $CLOUDFLARE_INI${NC}"
    echo -e "${BOLD}${YELLOW}Нажмите Enter чтобы использовать существующий токен, или введите новый токен:${NC}" >&2
    read -rs CLOUDFLARE_TOKEN <&3
    echo ""
    
    if [ -z "$CLOUDFLARE_TOKEN" ]; then
        # Используем существующий токен
        info "Используется существующий токен из файла"
        USE_EXISTING_TOKEN=true
    else
        # Пользователь ввел новый токен
        USE_EXISTING_TOKEN=false
        info "Будет использован новый токен"
    fi
else
    # Файла нет - обязательно запрашиваем токен
    echo -e "${BOLD}${YELLOW}Введите токен Cloudflare API (для DNS-валидации):${NC}" >&2
    echo -e "${YELLOW}  (токен должен иметь права: Zone DNS:Edit и Zone:Read)${NC}" >&2
    read -rs CLOUDFLARE_TOKEN <&3
    echo ""
    
    if [ -z "$CLOUDFLARE_TOKEN" ]; then
        error "Токен не может быть пустым"
        exit 1
    fi
    USE_EXISTING_TOKEN=false
fi

# ============================================================================
# ЗАПРОС ДОМЕНА
# ============================================================================

echo ""
echo -e "${BOLD}${YELLOW}Введите домен (или домены через пробел, например: example.com www.example.com):${NC}" >&2
read -r DOMAINS <&3

if [ -z "$DOMAINS" ]; then
    error "Домен не может быть пустым"
    exit 1
fi

# Запрос email для Let's Encrypt
echo ""
echo -e "${BOLD}${YELLOW}Введите email для уведомлений Let's Encrypt (или Enter для пропуска):${NC}" >&2
read -r CERT_EMAIL <&3

if [ -z "$CERT_EMAIL" ]; then
    CERT_EMAIL_ARG="--register-unsafely-without-email"
    warn "Email не указан, используется --register-unsafely-without-email"
else
    CERT_EMAIL_ARG="--email $CERT_EMAIL"
fi

# ============================================================================
# УСТАНОВКА CERTBOT И ПЛАГИНОВ
# ============================================================================

step "Обновление списка пакетов"
apt-get update -qq > /dev/null 2>&1
step_done

step "Проверка установки certbot"
if command -v certbot &> /dev/null; then
    step_progress_stop
    CERTBOT_VERSION=$(certbot --version | head -n1)
    info "Certbot уже установлен: $CERTBOT_VERSION"
else
    step_progress_stop
    step "Установка certbot"
    if ! apt-get install -y certbot > /dev/null 2>&1; then
        step_progress_stop
        error "Не удалось установить certbot"
        exit 1
    fi
    step_done
fi

step "Проверка установки плагина python3-certbot-dns-cloudflare"
if dpkg -l | grep -q "^ii.*python3-certbot-dns-cloudflare"; then
    step_progress_stop
    info "Плагин python3-certbot-dns-cloudflare уже установлен"
else
    step_progress_stop
    step "Установка плагина python3-certbot-dns-cloudflare"
    if ! apt-get install -y python3-certbot-dns-cloudflare > /dev/null 2>&1; then
        step_progress_stop
        error "Не удалось установить python3-certbot-dns-cloudflare"
        exit 1
    fi
    step_done
fi

step "Проверка установки плагина python3-certbot-nginx"
if dpkg -l | grep -q "^ii.*python3-certbot-nginx"; then
    step_progress_stop
    info "Плагин python3-certbot-nginx уже установлен"
else
    step_progress_stop
    step "Установка плагина python3-certbot-nginx"
    if ! apt-get install -y python3-certbot-nginx > /dev/null 2>&1; then
        step_progress_stop
        error "Не удалось установить python3-certbot-nginx"
        exit 1
    fi
    step_done
fi

# ============================================================================
# СОЗДАНИЕ ДИРЕКТОРИИ И СОХРАНЕНИЕ ТОКЕНА
# ============================================================================

step "Создание директории для токена Cloudflare"
if [ ! -d "$CLOUDFLARE_DIR" ]; then
    mkdir -p "$CLOUDFLARE_DIR"
    chmod 700 "$CLOUDFLARE_DIR"
    step_done
    info "Создана директория: $CLOUDFLARE_DIR"
else
    step_progress_stop
    info "Директория уже существует: $CLOUDFLARE_DIR"
fi

# Сохраняем токен только если он новый
if [ "$USE_EXISTING_TOKEN" = false ]; then
    step "Сохранение токена Cloudflare"
    
    # Создаем файл с токеном
    cat > "$CLOUDFLARE_INI" <<EOF
# Cloudflare API token
dns_cloudflare_api_token = $CLOUDFLARE_TOKEN
EOF
    
    # Устанавливаем правильные права доступа
    chmod 600 "$CLOUDFLARE_INI"
    chown root:root "$CLOUDFLARE_INI"
    
    step_done
    info "Токен сохранен в: $CLOUDFLARE_INI"
    info "Права доступа: 600 (только root может читать/писать)"
fi

# ============================================================================
# ПОЛУЧЕНИЕ СЕРТИФИКАТА ЧЕРЕЗ DNS
# ============================================================================

# Нормализация доменов (убираем лишние пробелы и невидимые символы)
step "Нормализация доменов"
VALIDATED_DOMAINS=""
for domain in $DOMAINS; do
    # Убираем все пробелы и невидимые символы, оставляем только печатные ASCII
    domain=$(echo "$domain" | tr -d '[:space:]' | tr -cd '[:print:]')
    
    if [ -z "$domain" ]; then
        continue
    fi
    
    # Проверяем что домен содержит только допустимые символы
    if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+$'; then
        warn "Домен содержит недопустимые символы: $domain"
        # Пытаемся конвертировать в punycode если есть python3
        if command -v python3 &> /dev/null; then
            domain=$(python3 -c "import encodings.idna; print(encodings.idna.ToASCII('$domain').decode('ascii'))" 2>/dev/null || echo "$domain")
        fi
    fi
    
    if [ -n "$VALIDATED_DOMAINS" ]; then
        VALIDATED_DOMAINS="$VALIDATED_DOMAINS $domain"
    else
        VALIDATED_DOMAINS="$domain"
    fi
done

if [ -z "$VALIDATED_DOMAINS" ]; then
    step_progress_stop
    error "Не удалось нормализовать домены"
    exit 1
fi

step_done
info "Домены для сертификата: $VALIDATED_DOMAINS"

# Обновляем DOMAINS для использования в дальнейшем
DOMAINS="$VALIDATED_DOMAINS"

# Формируем список доменов для certbot
DOMAIN_ARGS=""
for domain in $DOMAINS; do
    DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
done

step "Получение сертификата через DNS-валидацию Cloudflare"
info "Домены: $DOMAINS"
CERTBOT_OUTPUT=$(mktemp)
set +e
certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
    --non-interactive \
    --agree-tos \
    $CERT_EMAIL_ARG \
    $DOMAIN_ARGS > "$CERTBOT_OUTPUT" 2>&1
CERTBOT_EXIT_CODE=$?
set -e

if [ $CERTBOT_EXIT_CODE -eq 0 ]; then
    step_done
    success "Сертификат успешно получен"
    rm -f "$CERTBOT_OUTPUT"
else
    step_progress_stop
    error "Не удалось получить сертификат"
    echo ""
    echo -e "${BOLD}${RED}Детали ошибки:${NC}"
    cat "$CERTBOT_OUTPUT" | grep -v "^Saving debug log" | tail -20
    rm -f "$CERTBOT_OUTPUT"
    echo ""
    warn "Проверьте токен Cloudflare и домены"
    exit 1
fi

# ============================================================================
# АВТОМАТИЧЕСКАЯ НАСТРОЙКА NGINX
# ============================================================================

# Проверяем наличие nginx
if ! command -v nginx &> /dev/null; then
    warn "Nginx не установлен, пропускаем автоматическую настройку"
    info "Установите nginx и выполните: sudo certbot --nginx $DOMAIN_ARGS"
else
    step "Автоматическая настройка nginx"
    
    # Формируем команду certbot --nginx с доменами
    NGINX_CMD="certbot --nginx --non-interactive --agree-tos $CERT_EMAIL_ARG"
    for domain in $DOMAINS; do
        NGINX_CMD="$NGINX_CMD -d $domain"
    done
    
    if eval $NGINX_CMD 2>&1; then
        step_done
        success "Nginx настроен автоматически"
        
        # Перезагрузка nginx
        step "Перезагрузка nginx"
        if systemctl reload nginx > /dev/null 2>&1; then
            step_done
        else
            step_progress_stop
            warn "Не удалось перезагрузить nginx автоматически"
            info "Выполните вручную: sudo systemctl reload nginx"
        fi
    else
        step_progress_stop
        warn "Не удалось автоматически настроить nginx"
        FIRST_DOMAIN=$(echo $DOMAINS | awk '{print $1}')
        info "Настройте nginx вручную, используя сертификаты из: /etc/letsencrypt/live/$FIRST_DOMAIN/"
    fi
fi

# ============================================================================
# ПРОВЕРКА ТАЙМЕРА АВТООБНОВЛЕНИЯ
# ============================================================================

step "Проверка таймера автообновления сертификатов"
if systemctl list-unit-files | grep -q "certbot.timer"; then
    if systemctl is-enabled certbot.timer &> /dev/null; then
        step_progress_stop
        info "Таймер certbot.timer уже включен"
    else
        step_progress_stop
        step "Включение таймера certbot.timer"
        systemctl enable certbot.timer > /dev/null 2>&1
        step_done
    fi
    
    if systemctl is-active certbot.timer &> /dev/null; then
        step_progress_stop
        info "Таймер certbot.timer уже активен"
    else
        step_progress_stop
        step "Запуск таймера certbot.timer"
        systemctl start certbot.timer > /dev/null 2>&1
        step_done
    fi
else
    step_progress_stop
    warn "Таймер certbot.timer не найден (это нормально, если certbot установлен без systemd)"
fi

# ============================================================================
# ЗАВЕРШЕНИЕ
# ============================================================================

echo ""
echo -e "${BOLD}${GREEN}✓ Установка и настройка завершены успешно!${NC}"
echo ""
echo -e "  ${BOLD}Домены:${NC} $DOMAINS"
echo -e "  ${BOLD}Токен Cloudflare:${NC} $CLOUDFLARE_INI"
FIRST_DOMAIN=$(echo $DOMAINS | awk '{print $1}')
echo -e "  ${BOLD}Сертификаты:${NC} /etc/letsencrypt/live/$FIRST_DOMAIN/"
echo ""
echo -e "  ${BOLD}Проверка статуса автообновления:${NC}"
echo -e "    ${CYAN}sudo systemctl status certbot.timer${NC}"
echo ""
echo -e "  ${BOLD}Проверка статуса nginx:${NC}"
echo -e "    ${CYAN}sudo systemctl status nginx${NC}"
echo ""
