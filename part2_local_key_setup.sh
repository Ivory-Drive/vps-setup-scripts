#!/bin/bash

# --- part2_local_key_setup.sh ---
# Создание и копирование SSH-ключа на сервер
# Выполняется на ЛОКАЛЬНОМ компьютере
# ---

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

clear
echo "========================================="
echo "  НАСТРОЙКА SSH-КЛЮЧЕЙ (Часть 2)"
echo "========================================="
echo ""

read -p "Введите имя пользователя на сервере: " USERNAME
read -p "Введите IP-адрес сервера: " SERVER_IP
read -p "Введите SSH-порт сервера: " SSH_PORT
read -p "Создать новый ключ (new) или использовать существующий (existing)? " KEY_CHOICE

if [[ "$KEY_CHOICE" == "new" ]]; then
    read -p "Имя ключа (Enter для id_ed25519): " KEY_NAME
    [ -z "$KEY_NAME" ] && KEY_NAME="id_ed25519"
    ssh-keygen -t ed25519 -f ~/.ssh/$KEY_NAME
    PUB_KEY="$HOME/.ssh/$KEY_NAME.pub"
    ok "Новый ключ создан"
else
    info "Доступные публичные ключи:"
    ls -1 ~/.ssh/*.pub 2>/dev/null || echo "  (нет файлов .pub)"
    read -p "Путь к публичному ключу: " PUB_KEY
    PUB_KEY=$(eval echo $PUB_KEY)
fi

# --- Проверка, что файл ключа существует ---
if [ ! -f "$PUB_KEY" ]; then
    error "Файл ключа не найден: $PUB_KEY"
    exit 1
fi

info "Копирование ключа на сервер..."
ssh-copy-id -i "$PUB_KEY" -p "$SSH_PORT" "$USERNAME@$SERVER_IP"

if [ $? -eq 0 ]; then
    ok "✅ Ключ скопирован!"
    echo ""
    info "ПРОВЕРЬТЕ ПОДКЛЮЧЕНИЕ:"
    echo "  ssh -p $SSH_PORT $USERNAME@$SERVER_IP"

    # --- Проверка подключения по ключу (опционально) ---
    echo ""
    read -p "Проверить подключение по ключу сейчас? (y/n): " TEST
    if [[ "$TEST" =~ ^[Yy]$ ]]; then
        info "Проверка подключения..."
        if ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$SSH_PORT" "$USERNAME@$SERVER_IP" "echo 'Подключение успешно'" 2>/dev/null; then
            ok "✅ Подключение по ключу работает!"
        else
            warn "⚠️  Подключение по ключу не удалось. Проверьте настройки SSH на сервере."
            warn "Не закрывайте root-сессию, пока не разберётесь!"
        fi
    fi
else
    error "Не удалось скопировать ключ."
    echo ""
    warn "Проверьте:"
    echo "  - Правильно ли указан IP-адрес сервера"
    echo "  - Запущен ли SSH на сервере (порт $SSH_PORT)"
    echo "  - Доступен ли сервер по сети (ping $SERVER_IP)"
fi
