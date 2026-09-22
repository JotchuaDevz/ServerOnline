#!/usr/bin/env bash
set -euo pipefail

BINARY_URL_AMD64="https://raw.githubusercontent.com/JotchuaDevz/ServerOnline/refs/heads/main/presence-server-linux-amd64"
BINARY_URL_ARM64="https://raw.githubusercontent.com/JotchuaDevz/ServerOnline/refs/heads/main/presence-server-linux-arm64"
INSTALL_DIR="/opt/presence-server"
BIN_PATH="$INSTALL_DIR/presence-server"
SERVICE_PATH="/etc/systemd/system/presence-server.service"
PORT="${PRESENCE_PORT:-8090}"
API_KEY="${PRESENCE_API_KEY:-}"

log() { echo ">> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "corre este script como root (sudo ./install.sh)"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)
        BINARY_URL="$BINARY_URL_AMD64"
        ARCH_LABEL="amd64"
        ;;
    aarch64|arm64)
        BINARY_URL="$BINARY_URL_ARM64"
        ARCH_LABEL="arm64"
        ;;
    *)
        die "arquitectura no soportada: $ARCH (compílalo tú con GOOS=linux GOARCH=... y edita este script)"
        ;;
esac

[ -n "$BINARY_URL" ] || die "falta BINARY_URL_${ARCH_LABEL^^} en la parte de arriba del script (detecté $ARCH_LABEL)"

log "arquitectura detectada: $ARCH_LABEL"

GENERATED_KEY=false
if [ -z "$API_KEY" ]; then
    if command -v openssl >/dev/null 2>&1; then
        API_KEY="$(openssl rand -hex 24)"
    else
        API_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    GENERATED_KEY=true
    log "no se pasó PRESENCE_API_KEY, se generó una nueva"
fi

if ! command -v wget >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        log "wget no está instalado, instalando..."
        apt-get update -qq && apt-get install -y wget
    else
        die "wget no está instalado y no hay apt-get para instalarlo automáticamente"
    fi
fi
log "creando $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

TMP_BIN="$BIN_PATH.new"
log "descargando binario ($ARCH_LABEL) ..."
wget -q --show-progress -O "$TMP_BIN" "$BINARY_URL" || die "falló la descarga desde $BINARY_URL"

[ -s "$TMP_BIN" ] || die "el archivo descargado está vacío, revisa el link de BINARY_URL_${ARCH_LABEL^^}"

chmod +x "$TMP_BIN"

if systemctl is-active --quiet presence-server 2>/dev/null; then
    log "deteniendo servicio anterior antes de reemplazar el binario"
    systemctl stop presence-server
fi
mv -f "$TMP_BIN" "$BIN_PATH"
log "binario instalado en $BIN_PATH"

log "escribiendo $SERVICE_PATH"
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=HexVPN presence server (contador de usuarios por servidor)
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH -addr :$PORT -apikey $API_KEY
Restart=always
RestartSec=3
User=nobody
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now presence-server
log "servicio habilitado e iniciado"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    log "abriendo puerto $PORT/tcp en ufw"
    ufw allow "$PORT/tcp" >/dev/null
fi
log "verificando que el servidor responde..."
OK=false
for i in $(seq 1 10); do
    if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        OK=true
        break
    fi
    sleep 1
done

echo
echo "================================================================"
if [ "$OK" = true ]; then
    echo "OK: presence-server responde en el puerto $PORT"
else
    echo "AVISO: el servicio está activo pero /health no respondió en 10s."
    echo "Revisa los logs: journalctl -u presence-server -n 50 --no-pager"
fi

if [ "$GENERATED_KEY" = true ]; then
    echo
    echo "API key generada (guárdala, la necesitas en la app Android):"
    echo "  $API_KEY"
fi

echo
echo "Pega esto en AppConfig.kt (app Android):"
echo "  fun presenceServerUrl(): String { return \"http://$(curl -s ifconfig.me 2>/dev/null || echo TU_IP):$PORT\" }"
echo "  fun presenceApiKey(): String { return \"$API_KEY\" }"
echo
echo "Ver logs en vivo:   journalctl -u presence-server -f"
echo "Reiniciar:          systemctl restart presence-server"
echo "Probar desde fuera: curl -H \"X-Api-Key: $API_KEY\" http://TU_IP:$PORT/counts"
echo "================================================================"

