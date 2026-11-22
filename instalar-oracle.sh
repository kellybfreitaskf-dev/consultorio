#!/bin/bash
# Instala o sistema do consultório numa máquina Ubuntu 24.04 da Oracle Cloud.
# Roda sozinho na primeira vez que a máquina liga. Registro: /var/log/instalar-consultorio.log
exec > /var/log/instalar-consultorio.log 2>&1
set -eux
export DEBIAN_FRONTEND=noninteractive
APP=/opt/consultorio
DADOS=/opt/consultorio-dados

# memória extra (swap) para máquinas pequenas
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

apt-get update
apt-get install -y git python3-venv sqlite3 unzip rsync curl gpg debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

# libera as portas do site (80 e 443) no firewall interno do Ubuntu da Oracle
iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
netfilter-persistent save || true

# Comando que baixa a versão mais nova do GitHub e instala. Serve também para
# atualizar no futuro:  sudo atualizar-consultorio
# Aceita o código solto no repositório ou um consultorio.zip enviado para lá.
cat > /usr/local/bin/atualizar-consultorio <<'FIM'
#!/bin/bash
set -e
REPO=https://github.com/kellybfreitaskf-dev/consultorio.git
FONTE=/opt/consultorio-github
APP=/opt/consultorio
if [ -d "$FONTE/.git" ]; then git -C "$FONTE" pull --ff-only; else git clone "$REPO" "$FONTE"; fi
TMP=$(mktemp -d)
# usa o .zip enviado mais recentemente ao GitHub (qualquer nome: consultorio (2).zip etc.)
ZIP=$(git -c core.quotePath=false -C "$FONTE" log --diff-filter=AM --name-only --format= -- '*.zip' | grep -v '^$' | head -1)
if [ -n "$ZIP" ] && [ -f "$FONTE/$ZIP" ]; then
  echo "Usando: $ZIP"
  unzip -q "$FONTE/$ZIP" -d "$TMP"
  ORIGEM=$(dirname "$(find "$TMP" -name app.py -print -quit)")
else
  ORIGEM="$FONTE"
fi
if [ ! -f "$ORIGEM/app.py" ]; then echo "app.py não encontrado no repositório"; exit 1; fi
mkdir -p "$APP"
rsync -a --delete --exclude .venv --exclude .git --exclude dados "$ORIGEM/" "$APP/"
rm -rf -- "$TMP"
[ -d "$APP/.venv" ] || python3 -m venv "$APP/.venv"
"$APP/.venv/bin/pip" install -q -r "$APP/requirements.txt"
chown -R consultorio:consultorio "$APP"
systemctl restart consultorio 2>/dev/null || true
echo "Sistema atualizado."
FIM
chmod +x /usr/local/bin/atualizar-consultorio

id consultorio || useradd --system --home-dir "$APP" --shell /usr/sbin/nologin consultorio
/usr/local/bin/atualizar-consultorio
mkdir -p "$DADOS/backups"
chown -R consultorio:consultorio "$DADOS"
chmod 700 "$DADOS"

cat > /etc/systemd/system/consultorio.service <<FIM
[Unit]
Description=Sistema do consultorio
After=network-online.target

[Service]
User=consultorio
WorkingDirectory=$APP
Environment=DATA_DIR=$DADOS
Environment=TZ_CONSULTORIO=America/Sao_Paulo
ExecStart=$APP/.venv/bin/gunicorn -w 1 --threads 8 --timeout 300 -b 127.0.0.1:8000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
FIM
systemctl daemon-reload
systemctl enable --now consultorio

# endereço com HTTPS gratuito (cadeado): IP-com-tracos.sslip.io
IP=$(curl -s https://api.ipify.org)
DOMINIO="$(echo "$IP" | tr . -).sslip.io"
cat > /etc/caddy/Caddyfile <<FIM
$DOMINIO {
    encode gzip
    reverse_proxy 127.0.0.1:8000
}
FIM
systemctl restart caddy
echo "https://$DOMINIO" > /opt/ENDERECO.txt

# cópia de segurança automática todo dia (guarda 30 dias)
cat > /etc/cron.daily/backup-consultorio <<'FIM'
#!/bin/bash
D=/opt/consultorio-dados
[ -f "$D/consultorio.db" ] && sqlite3 "$D/consultorio.db" ".backup '$D/backups/consultorio-$(date +%F).db'"
find "$D/backups" -name '*.db' -mtime +30 -delete
FIM
chmod +x /etc/cron.daily/backup-consultorio

echo "INSTALACAO CONCLUIDA: https://$DOMINIO"
