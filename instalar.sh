#!/usr/bin/env bash
# Instalador de um comando do portal Grupos ANATECH MG.
# Uso na VM Oracle (Ubuntu 22.04 ou 24.04, ARM ou x86):
#   curl -fsSL https://raw.githubusercontent.com/THEIMPORTS/grupos-anatechmg/main/instalar.sh | bash -s SEU-DOMINIO
set -euo pipefail

DOMINIO="${1:-}"
MODO_IP=0
if [ -z "$DOMINIO" ]; then
  DOMINIO=$(curl -fsS --max-time 10 https://api.ipify.org || curl -fsS --max-time 10 https://ifconfig.me || true)
  if [ -z "$DOMINIO" ]; then
    echo "Nao consegui detectar o IP publico. Rode passando o dominio:"
    echo "  bash instalar.sh grupos.anatechmg.com.br"
    exit 1
  fi
  MODO_IP=1
fi

echo "==> 1/6 preparando o sistema"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl unzip iptables-persistent >/dev/null

echo "==> 2/6 liberando portas 80 e 443 no firewall da VM"
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT || true
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT || true
sudo netfilter-persistent save >/dev/null 2>&1 || true

echo "==> 3/6 instalando Docker oficial"
if ! command -v docker >/dev/null 2>&1; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
sudo usermod -aG docker "$USER" || true

echo "==> 4/6 baixando o sistema"
mkdir -p "$HOME/grupos" && cd "$HOME/grupos"
curl -fsSL -o app.zip https://raw.githubusercontent.com/THEIMPORTS/grupos-anatechmg/main/pacote.zip
unzip -oq app.zip
cd grupos

echo "==> 5/6 configurando senhas e dominio"
SENHA_DB=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
SENHA_ROOT=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
cat > deploy/.env <<EOF
DOMAIN=$DOMINIO
DB_NAME=grupos
DB_USER=grupos
DB_PASSWORD=$SENHA_DB
DB_ROOT_PASSWORD=$SENHA_ROOT
EOF
chmod +x deploy/*.sh
mkdir -p data && sudo chown -R 33:33 data || true

echo "==> 6/6 subindo o sistema"
sudo docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build

echo
echo "======================================================"
if [ "$MODO_IP" = "1" ]; then
  echo "Sistema no ar. Abra agora: http://$DOMINIO/install.php"
  echo
  echo "Quando quiser o endereco com HTTPS e dominio:"
  echo "  1. crie o registro A do dominio apontando para $DOMINIO"
  echo "  2. rode: bash deploy/ativar-https.sh SEU-DOMINIO"
else
  echo "Sistema no ar. Abra: https://$DOMINIO/install.php"
fi
echo
echo "Dados do banco para preencher no instalador:"
echo "  Host: db      Porta: 3306"
echo "  Nome: grupos"
echo "  Usuario: grupos"
echo "  Senha: $SENHA_DB"
echo
echo "Guarde esta senha. Ela tambem esta em ~/grupos/grupos/deploy/.env"
echo "======================================================"
