#!/bin/bash

# --- server_full_setup.sh ---
# Полная настройка сервера: часть 1 (root) + часть 3 (пользователь)
# Выполняется на сервере от root
# Поддерживает Ubuntu 22.04 / 24.04
# ---

set -e

# --- Trap для обработки ошибок ---
trap 'error "Ошибка на строке $LINENO. Скрипт прерван."; exit 1' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then error "Запустите от root!"; exit 1; fi

# --- Проверка версии ОС ---
if ! lsb_release -d 2>/dev/null | grep -qE "Ubuntu (22|24)\.04"; then
    error "Скрипт поддерживает только Ubuntu 22.04 или 24.04"
    exit 1
fi

clear
echo "========================================="
echo "  ПОЛНАЯ НАСТРОЙКА СЕРВЕРА"
echo "========================================="
echo ""

# --- Запрос параметров ---
while true; do
    read -p "Введите имя нового пользователя: " USERNAME
    if [[ "$USERNAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && [ ${#USERNAME} -ge 3 ]; then break; fi
    warn "Некорректное имя (буквы/цифры/_, мин. 3 символа)"
done

while true; do
    read -p "Введите новый порт для SSH (1024-65535): " SSH_PORT
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ]; then
        if ! ss -tuln | grep -q ":$SSH_PORT "; then break; fi
        warn "Порт $SSH_PORT занят."
    fi
done

read -p "Имя хоста (Enter для 'server'): " HOSTNAME
[ -z "$HOSTNAME" ] && HOSTNAME="server"

read -p "Запретить ответ на ping? (y/n): " DISABLE_PING
[[ "$DISABLE_PING" =~ ^[Yy]$ ]] && DISABLE_PING=true || DISABLE_PING=false

echo ""
info "Начинаю настройку..."

# --- 1. Создание пользователя ---
if ! id "$USERNAME" &>/dev/null; then
    info "Создаю пользователя $USERNAME"
    adduser $USERNAME
    usermod -aG sudo $USERNAME
    ok "Пользователь создан"
else
    warn "Пользователь $USERNAME уже существует"
fi

# --- 2. Установка часового пояса (без вопроса) ---
info "Установка часового пояса Europe/Moscow..."
timedatectl set-timezone Europe/Moscow
ok "Часовой пояс установлен"

# --- 3. Создание swap-файла (только если отсутствует) ---
info "Проверка swap..."
if [ $(swapon --show | wc -l) -eq 0 ]; then
    # Определяем размер по объёму RAM (не более 4 ГБ)
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$RAM_MB" -le 4096 ]; then
        SWAP_SIZE="${RAM_MB}M"
    else
        SWAP_SIZE="4G"
    fi
    info "Создаю swap-файл размером $SWAP_SIZE..."
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q "^/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    ok "Swap-файл создан: $SWAP_SIZE"
else
    ok "Swap уже существует"
fi

# --- 4. Обновление системы ---
info "Обновление системы..."
apt update && apt upgrade -y
ok "Система обновлена"

# --- 5. Установка утилит ---
info "Установка утилит..."
# Предварительная настройка debconf для iptables-persistent (без запросов)
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt install -y mc iptables-persistent fail2ban unattended-upgrades
ok "Утилиты установлены"

# --- 6. ОТКЛЮЧЕНИЕ СОКЕТ-АКТИВАЦИИ SSH ---
if systemctl is-active --quiet ssh.socket; then
    warn "Обнаружена сокет-активация. Отключаю..."
    systemctl stop ssh.socket
    systemctl disable ssh.socket
    systemctl mask ssh.socket
    rm -f /etc/systemd/system/ssh.socket.d/addresses.conf
    rm -f /etc/systemd/system/ssh.service.d/00-socket.conf
    systemctl daemon-reload
    ok "Сокет-активация отключена и замаскирована"
fi

# --- 7. Настройка SSH ---
info "Настройка SSH..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
cat > /etc/ssh/sshd_config <<EOF
Port $SSH_PORT
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers $USERNAME
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

if sshd -t; then
    ok "Конфигурация SSH корректна"
else
    error "Ошибка в конфигурации SSH! Восстанавливаю..."
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    exit 1
fi

systemctl enable ssh
systemctl restart ssh
ok "SSH настроен на порт $SSH_PORT"

# --- 8. Отключение IPv6 ---
cat >> /etc/sysctl.conf <<EOF

# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl --system >/dev/null
ok "IPv6 отключён"

# --- 9. Настройка iptables ---
info "Настройка iptables..."
iptables -F && iptables -t nat -F && iptables -t mangle -F
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT

# --- Обработка ICMP (пинг) ---
if [ "$DISABLE_PING" = true ]; then
    iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
    echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
    sysctl --system >/dev/null
    ok "Пинг заблокирован"
else
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    ok "Пинг разрешён"
fi

# --- Блокировка SMTP (защита от спама) ---
iptables -A OUTPUT -p tcp -m multiport --dports 25,465,587,2525 -j DROP
ok "Исходящие SMTP-порты заблокированы"

netfilter-persistent save
ok "Правила iptables сохранены"

# --- 10. Настройка sysctl для VPN-сервера (3x-ui) ---
info "Настройка параметров ядра для VPN..."

cat >> /etc/sysctl.conf <<EOF

# ============================================
# НАСТРОЙКА SYSCTL ДЛЯ VPN-СЕРВЕРА (3x-ui)
# ============================================

# --- ОБЯЗАТЕЛЬНО: IP-форвардинг ---
net.ipv4.ip_forward=1

# --- Защита от сетевых атак ---
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.tcp_syncookies=1

# --- Оптимизация для высоких скоростей VPN ---
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# --- Алгоритм BBR ---
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

EOF

sysctl --system >/dev/null
ok "Параметры ядра для VPN настроены"

# --- 11. Настройка Fail2ban ---
info "Настройка Fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 3
bantime = 3600
findtime = 600
EOF
systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2ban настроен для SSH"

# --- 12. Автоматические обновления ---
info "Настройка автоматических обновлений..."
dpkg-reconfigure --priority=low unattended-upgrades -f noninteractive
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}:\${distro_codename}-updates";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
ok "Автообновления настроены (без авторебута)"

# --- 13. ФИНАЛЬНЫЕ НАСТРОЙКИ (от имени пользователя) ---
info "Переключаюсь на пользователя $USERNAME для финальных настроек..."

cat > /tmp/user_finalize.sh <<'EOF'
#!/bin/bash
# --- Финальные настройки от пользователя ---

# Установка fastfetch
sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
sudo apt update
sudo apt install -y fastfetch

# --- КАСТОМИЗАЦИЯ BASHRC ---
cat >> ~/.bashrc <<'EOR'
# Настройка истории
HISTSIZE=1000
HISTFILESIZE=2000
HISTTIMEFORMAT="%d-%m-%Y %T "
HISTCONTROL=ignoreboth
shopt -s histappend

# Алиасы
alias rm='rm -vi'
alias speedtest="curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -"
EOR

# Кастомный промпт
cat > ~/.bash_prompt <<'EOP'
BRACKET_COLOR="\[\033[38;5;35m\]"
CLOCK_COLOR="\[\033[38;5;33m\]"
JOB_COLOR="\[\033[38;5;35m\]"
PATH_COLOR="\[\033[38;5;33m\]"
LINE_BOTTOM="\342\224\200"
LINE_BOTTOM_CORNER="\342\224\224"
LINE_COLOR="\[\033[38;5;248m\]"
LINE_STRAIGHT="\342\224\200"
LINE_UPPER_CORNER="\342\224\214"
END_CHARACTER="|"

tty -s && export PS1="$LINE_COLOR$LINE_UPPER_CORNER$LINE_STRAIGHT$LINE_STRAIGHT$BRACKET_COLOR[$CLOCK_COLOR\t$BRACKET_COLOR]$LINE_COLOR$LINE_STRAIGHT$BRACKET_COLOR[$JOB_COLOR\j$BRACKET_COLOR]$LINE_COLOR$LINE_STRAIGHT$BRACKET_COLOR[\H:\]$PATH_COLOR\w$BRACKET_COLOR]\n$LINE_COLOR$LINE_BOTTOM_CORNER$LINE_STRAIGHT$LINE_BOTTOM$END_CHARACTER\[$(tput sgr0)\] "
EOP

# Подключаем кастомный промпт (с проверкой)
if [ -f ~/.bash_prompt ]; then
    echo "source ~/.bash_prompt" >> ~/.bashrc
fi

# Запуск fastfetch только в интерактивных сессиях
echo 'if [ -t 1 ]; then fastfetch; fi' >> ~/.bashrc

echo "✅ Финальные настройки завершены!"
EOF

chmod +x /tmp/user_finalize.sh
su - $USERNAME -c "/tmp/user_finalize.sh"
rm -f /tmp/user_finalize.sh

# --- Завершение ---
echo ""
ok "✅ ПОЛНАЯ НАСТРОЙКА СЕРВЕРА ЗАВЕРШЕНА!"
echo ""
info "ДАЛЬНЕЙШИЕ ШАГИ:"
echo "1. Выйдите из сессии: exit"
echo "2. На ЛОКАЛЬНОМ компьютере запустите скрипт для копирования ключа:"
echo "   ./part2_local_key_setup.sh"
echo "3. Подключитесь к серверу: ssh -p $SSH_PORT $USERNAME@<IP_сервера>"
echo ""
info "🔐 Не закрывайте эту сессию, пока не проверите подключение!"
