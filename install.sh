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
# ИНТЕРАКТИВНЫЙ ВВОД
# ============================================================================

exec 3<&0

# Запрос токена Cloudflare
echo ""
echo -e "${BOLD}${YELLOW}Введите токен Cloudflare API (для DNS-валидации):${NC}" >&2
echo -e "${YELLOW}  (токен должен иметь права: Zone DNS:Edit и Zone:Read)${NC}" >&2
read -rs CLOUDFLARE_TOKEN <&3
echo ""

if [ -z "$CLOUDFLARE_TOKEN" ]; then
    error "Токен не может быть пустым"
    exit 1
fi

# ============================================================================
# УСТАНОВКА CERTBOT И ПЛАГИНА CLOUDFLARE
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

# ============================================================================
# СОЗДАНИЕ ДИРЕКТОРИИ ДЛЯ ТОКЕНА
# ============================================================================

step "Создание директории для токена Cloudflare"
CLOUDFLARE_DIR="/etc/letsencrypt/cloudflare"

if [ ! -d "$CLOUDFLARE_DIR" ]; then
    mkdir -p "$CLOUDFLARE_DIR"
    chmod 700 "$CLOUDFLARE_DIR"
    step_done
    info "Создана директория: $CLOUDFLARE_DIR"
else
    step_progress_stop
    info "Директория уже существует: $CLOUDFLARE_DIR"
fi

# ============================================================================
# СОХРАНЕНИЕ ТОКЕНА
# ============================================================================

step "Сохранение токена Cloudflare"
CLOUDFLARE_INI="$CLOUDFLARE_DIR/cloudflare.ini"

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
echo -e "  ${BOLD}Токен Cloudflare сохранен в:${NC} $CLOUDFLARE_INI"
echo ""
echo -e "  ${BOLD}Для получения сертификата используйте:${NC}"
echo -e "    ${CYAN}sudo certbot certonly \\${NC}"
echo -e "    ${CYAN}  --dns-cloudflare \\${NC}"
echo -e "    ${CYAN}  --dns-cloudflare-credentials $CLOUDFLARE_INI \\${NC}"
echo -e "    ${CYAN}  -d your-domain.com \\${NC}"
echo -e "    ${CYAN}  -d www.your-domain.com${NC}"
echo ""
echo -e "  ${BOLD}Или для автоматической настройки nginx:${NC}"
echo -e "    ${CYAN}sudo certbot --nginx -d your-domain.com${NC}"
echo ""
echo -e "  ${BOLD}Проверка статуса автообновления:${NC}"
echo -e "    ${CYAN}sudo systemctl status certbot.timer${NC}"
echo ""
