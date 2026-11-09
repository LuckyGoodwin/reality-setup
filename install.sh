#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
trap 'printf "Установка остановилась на строке %s. Проверьте вывод выше.\n" "$LINENO" >&2' ERR

[[ $EUID == 0 ]] || die 'Запустите через sudo bash install.sh.'
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(uname -m) == x86_64 ]] ||
    die 'Нужна Ubuntu 24.04 x64.'
[[ ! -e /etc/x-ui && ! -e /usr/local/x-ui && ! -e /etc/caddy && ! -e /srv/www ]] ||
    die 'Нужен чистый VPS. Найдены файлы Caddy, 3x-ui или сайта.'
[[ -z $(ss -H -ltn '( sport = :80 or sport = :443 or sport = :2053 or sport = :8444 )') ]] ||
    die 'Один из портов 80, 443, 2053, 8444 уже занят.'

domain=${1:-}
if [[ -z $domain ]]; then
    read -rp 'Домен сайта, без https://: ' domain
fi
domain=${domain,,}
server_ip=$(python3 - "$domain" <<'PY'
import ipaddress
import json
import re
import socket
import subprocess
import sys

domain = sys.argv[1]
label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
if (len(domain) > 253 or not re.fullmatch(rf"(?:{label}\.)+[a-z]{{2,63}}", domain)
        or domain.endswith((".example", ".test", ".invalid", ".localhost"))
        or any(domain == x or domain.endswith("." + x)
               for x in ("example.com", "example.net", "example.org"))):
    sys.exit("Укажите реальный домен, например поддомен своего сайта.")

def addresses(family):
    try:
        return {entry[4][0] for entry in socket.getaddrinfo(domain, None, family)}
    except socket.gaierror as error:
        if error.errno in (socket.EAI_NONAME, getattr(socket, "EAI_NODATA", -5)):
            return set()
        raise

local = json.loads(subprocess.check_output(["ip", "-j", "-4", "addr", "show", "scope", "global"]))
local_ips = {a["local"] for iface in local for a in iface.get("addr_info", [])}
ipv4 = addresses(socket.AF_INET)
if len(ipv4) != 1 or not ipv4 <= local_ips or not all(ipaddress.ip_address(ip).is_global for ip in ipv4):
    sys.exit("A-запись должна указывать на один публичный IPv4 этого VPS. Проверьте DNS и отключите проксирование CDN.")
if addresses(socket.AF_INET6):
    sys.exit("Для этой схемы удалите AAAA-запись домена и дождитесь обновления DNS.")
print(ipv4.pop())
PY
)

# Установщик рассчитан на один SSH-порт. При запуске по SSH берём порт текущего подключения.
ssh_port=${SSH_CONNECTION:-}
ssh_port=${ssh_port##* }
ssh_port=${ssh_port:-22}
[[ $ssh_port =~ ^[1-9][0-9]{0,4}$ && $ssh_port -le 65535 ]] || die 'Не удалось определить порт SSH.'

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export DEBIAN_FRONTEND=noninteractive

printf 'Настраиваем %s на %s\n' "$domain" "$server_ip"
apt-get update
apt-get install -y ca-certificates curl git gpg openssl rsync ufw
ufw allow "$ssh_port/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw default deny incoming
ufw --force enable

curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$work/caddy.key"
gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$work/caddy.key"
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    -o /etc/apt/sources.list.d/caddy-stable.list
chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy
install -d -m 755 /srv/www

prepare_random_site() {
    local repo="$work/templates" template
    timeout 60s git clone --quiet --depth 1 --filter=blob:none --sparse \
        https://github.com/GFW4Fun/randomfakehtml.git "$repo" || return 1
    template=$(git -C "$repo" ls-tree -r --name-only HEAD |
        awk -F/ 'NF == 2 && $2 == "index.html" {print $1}' | shuf -n 1) || return 1
    [[ -n $template ]] || return 1
    timeout 60s git -C "$repo" sparse-checkout set -- "$template" || return 1
    # Ссылки из шаблона не копируем, чтобы сайт не мог читать файлы за пределами своего каталога.
    rsync -rp --chmod=D755,F644 -- "$repo/$template/" "$work/site/" || return 1
    [[ -s $work/site/index.html ]] || return 1
    printf 'Выбран шаблон сайта: %s\n' "$template"
}

if prepare_random_site; then
    cp -a "$work/site/." /srv/www/
else
    printf 'Не удалось загрузить шаблон. Устанавливаем страницу «Мой сайт».\n' >&2
    cat > /srv/www/index.html <<'HTML'
<!doctype html>
<html lang="ru">
<head><meta charset="utf-8"><title>Мой сайт</title></head>
<body><h1>Мой сайт</h1><p>Добро пожаловать!</p></body>
</html>
HTML
fi

cat > /etc/caddy/Caddyfile <<CADDY
{
	https_port 8444
	auto_https disable_redirects
	servers {
		protocols h1 h2
	}
}

http://$domain {
	bind 0.0.0.0
	redir https://$domain{uri} permanent
}

https://$domain {
	bind 127.0.0.1
	root * /srv/www
	file_server
	tls {
		issuer acme {
			dir https://acme-v02.api.letsencrypt.org/directory
			disable_tlsalpn_challenge
		}
	}
}
CADDY
caddy validate --config /etc/caddy/Caddyfile
systemctl enable caddy
systemctl restart caddy

printf 'Ждём сертификат Let’s Encrypt для %s.\n' "$domain"
for attempt in {1..24}; do
    if curl --noproxy '*' -fsS --connect-timeout 3 --max-time 5 \
        --resolve "$domain:8444:127.0.0.1" "https://$domain:8444/" -o /dev/null 2>/dev/null; then
        break
    fi
    [[ $attempt != 24 ]] || die 'Caddy не предъявил доверенный сертификат. Проверьте DNS, публичный TCP 80 и journalctl -u caddy.'
    sleep 5
done

# Установщик закреплён за коммитом релиза 3x-ui v3.11.0.
curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/install.sh \
    -o "$work/install-x-ui.sh"
printf 'Устанавливаем 3x-ui. Журнал: /root/reality-setup-x-ui.log\n'
install -m 600 /dev/null /root/reality-setup-x-ui.log
XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_DB_TYPE=sqlite \
XUI_PANEL_PORT=2053 XUI_USERNAME=admin XUI_PASSWORD="$(openssl rand -hex 16)" \
XUI_WEB_BASE_PATH="$(openssl rand -hex 12)" \
    bash "$work/install-x-ui.sh" v3.11.0 > /root/reality-setup-x-ui.log 2>&1
[[ -s /etc/x-ui/install-result.env ]] || die '3x-ui не записала результат установки.'
. /etc/x-ui/install-result.env
[[ -n ${XUI_API_TOKEN:-} && -n ${XUI_WEB_BASE_PATH:-} ]] || die 'Не получены параметры панели.'

/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
systemctl enable x-ui
systemctl restart x-ui

XUI_API_TOKEN="$XUI_API_TOKEN" python3 - "$domain" \
    "http://127.0.0.1:$XUI_PANEL_PORT/${XUI_WEB_BASE_PATH#/}" \
    /usr/local/x-ui/bin/xray-linux-amd64 <<'PY'
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request

domain, base, xray = sys.argv[1:]
api = base.rstrip("/") + "/panel/api/inbounds/"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
headers = {"Authorization": "Bearer " + os.environ["XUI_API_TOKEN"], "Content-Type": "application/json"}

def request(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    with opener.open(urllib.request.Request(api + path, data=data, headers=headers), timeout=5) as response:
        result = json.load(response)
    if not result.get("success"):
        sys.exit("3x-ui отклонила запрос: " + str(result.get("msg", "")))
    return result.get("obj")

for attempt in range(20):
    try:
        inbounds = request("list")
        break
    except urllib.error.HTTPError:
        raise
    except (urllib.error.URLError, TimeoutError):
        if attempt == 19:
            raise
        time.sleep(1)

if any(i["port"] == 443 for i in inbounds or []):
    sys.exit("Входящее на 443 уже есть. Проверьте панель.")

keys = subprocess.check_output([xray, "x25519"], text=True)
private = re.search(r"(?m)^Private[Kk]ey:\s*(\S+)$", keys)
public = re.search(r"(?m)^(?:Password(?: \(PublicKey\))?|Public[Kk]ey):\s*(\S+)$", keys)
if not private or not public:
    sys.exit("Не удалось прочитать ключи из вывода xray x25519.")

request("add", {
    "remark": "VLESS REALITY",
    "enable": True,
    "port": 443,
    "protocol": "vless",
    "shareAddrStrategy": "custom",
    "shareAddr": domain,
    "settings": json.dumps({"clients": [], "decryption": "none", "encryption": "none"}),
    "streamSettings": json.dumps({
        "network": "tcp",
        "tcpSettings": {"header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False,
            "xver": 0,
            "target": "127.0.0.1:8444",
            "serverNames": [domain],
            "privateKey": private[1],
            "shortIds": [secrets.token_hex(8)],
            "settings": {"publicKey": public[1], "fingerprint": "firefox", "spiderX": "/"},
        },
    }),
    "sniffing": json.dumps({"enabled": False, "destOverride": []}),
})
PY

systemctl restart x-ui
for attempt in {1..15}; do
    if curl --noproxy '*' -fsS --connect-timeout 2 --max-time 4 \
        --resolve "$domain:443:127.0.0.1" "https://$domain/" -o /dev/null 2>/dev/null; then
        break
    fi
    [[ $attempt != 15 ]] || die 'HTTPS через Xray не ответил. Проверьте journalctl -u x-ui.'
    sleep 2
done

printf '\nСайт: https://%s/\n' "$domain"
printf 'На компьютере запустите: ssh -N -p %s -L 127.0.0.1:18080:127.0.0.1:%s %s@%s\n' "$ssh_port" "$XUI_PANEL_PORT" "${SUDO_USER:-root}" "$server_ip"
printf 'Панель: http://127.0.0.1:18080/%s/\n' "${XUI_WEB_BASE_PATH#/}"
printf 'Логин: %s\nПароль: %s\n' "$XUI_USERNAME" "$XUI_PASSWORD"
printf 'В панели добавьте клиента к входящему VLESS REALITY и выберите Flow xtls-rprx-vision.\n'
