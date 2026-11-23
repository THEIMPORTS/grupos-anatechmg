#!/usr/bin/env bash
# Ativa o HTTPS definitivo depois que o DNS estiver apontando para a VM.
# Uso: bash deploy/ativar-https.sh grupos.anatechmg.com.br
set -euo pipefail
cd "$(dirname "$0")/.."

DOMINIO="${1:-}"
if [ -z "$DOMINIO" ]; then
  echo "Uso: bash deploy/ativar-https.sh SEU-DOMINIO"
  exit 1
fi

IP_PUBLICO=$(curl -fsS --max-time 10 https://api.ipify.org || echo "")
IP_DNS=$(getent hosts "$DOMINIO" | awk '{print $1}' | head -1 || echo "")

echo "IP desta VM : ${IP_PUBLICO:-desconhecido}"
echo "IP do dominio: ${IP_DNS:-nao resolveu}"

if [ -n "$IP_DNS" ] && [ "$IP_DNS" != "$IP_PUBLICO" ]; then
  echo "ATENCAO: o dominio ainda nao aponta para esta VM. Ajuste o registro A e rode de novo."
  exit 1
fi

if [ -z "$IP_DNS" ]; then
  echo "ATENCAO: o dominio ainda nao resolve na internet. Aguarde a propagacao do DNS."
  exit 1
fi

echo "==> atualizando o dominio no .env"
sed -i "s|^DOMAIN=.*|DOMAIN=$DOMINIO|" deploy/.env

echo "==> recriando o proxy para emitir o certificado"
sudo docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --force-recreate web

echo "Aguardando o certificado (ate 60s)..."
for _ in $(seq 1 20); do
  sleep 3
  if curl -fsS -o /dev/null --max-time 5 "https://$DOMINIO" 2>/dev/null; then
    echo "HTTPS ativo: https://$DOMINIO"
    exit 0
  fi
done

echo "O certificado ainda nao respondeu. Veja os logs com:"
echo "  sudo docker compose -f deploy/docker-compose.yml logs --tail=40 web"
