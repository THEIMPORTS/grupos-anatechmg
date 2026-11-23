#!/usr/bin/env bash
# Cria a VM na Oracle Cloud e instala o portal Grupos ANATECH MG.
# Rode dentro do Cloud Shell da Oracle (ja vem autenticado).
# Uso: bash provisionar-oracle.sh
set -euo pipefail

NOME_INSTANCIA="grupos-anatechmg"
REPO_RAW="https://raw.githubusercontent.com/THEIMPORTS/grupos-anatechmg/main"

echo "==> 1/8 conferindo a CLI da Oracle"
command -v oci >/dev/null 2>&1 || { echo "CLI oci nao encontrada. Use o Cloud Shell da Oracle."; exit 1; }

echo "==> 2/8 descobrindo tenancy, dominio de disponibilidade e rede"
TENANCY=$(oci iam user list --query 'data[0]."compartment-id"' --raw-output 2>/dev/null | head -1)
if [ -z "$TENANCY" ] || [ "$TENANCY" = "null" ]; then
  echo "Nao consegui identificar o compartimento. Rode 'oci setup config' ou use o Cloud Shell."
  exit 1
fi
AD=$(oci iam availability-domain list --compartment-id "$TENANCY" --query 'data[0].name' --raw-output)
REGIAO=$(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output)
echo "    compartimento: $TENANCY"
echo "    regiao: $REGIAO | AD: $AD"

VCN=$(oci network vcn list --compartment-id "$TENANCY" --query 'data[0].id' --raw-output 2>/dev/null | head -1)
if [ -z "$VCN" ] || [ "$VCN" = "null" ]; then
  echo "==> criando rede (VCN, gateway, rota, security list e subnet publica)"
  VCN=$(oci network vcn create --compartment-id "$TENANCY" --cidr-block 10.0.0.0/16 \
        --display-name "vcn-anatechmg" --wait-for-state AVAILABLE \
        --query 'data.id' --raw-output)
  IGW=$(oci network internet-gateway create --compartment-id "$TENANCY" --vcn-id "$VCN" \
        --is-enabled true --display-name "igw-anatechmg" --wait-for-state AVAILABLE \
        --query 'data.id' --raw-output)
  RT=$(oci network route-table create --compartment-id "$TENANCY" --vcn-id "$VCN" \
        --display-name "rt-anatechmg" \
        --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]" \
        --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  SL=$(oci network security-list create --compartment-id "$TENANCY" --vcn-id "$VCN" \
        --display-name "sl-anatechmg" \
        --ingress-security-rules "[{\"protocol\":\"6\",\"source\":\"0.0.0.0/0\",\"isStateless\":false,\"tcpOptions\":{\"destinationPortRange\":{\"min\":80,\"max\":80}}},{\"protocol\":\"6\",\"source\":\"0.0.0.0/0\",\"isStateless\":false,\"tcpOptions\":{\"destinationPortRange\":{\"min\":443,\"max\":443}}},{\"protocol\":\"6\",\"source\":\"0.0.0.0/0\",\"isStateless\":false,\"tcpOptions\":{\"destinationPortRange\":{\"min\":22,\"max\":22}}}]" \
        --egress-security-rules "[{\"protocol\":\"all\",\"destination\":\"0.0.0.0/0\",\"isStateless\":false}]" \
        --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  SUBNET=$(oci network subnet create --compartment-id "$TENANCY" --vcn-id "$VCN" --cidr-block 10.0.1.0/24 \
        --display-name "subnet-anatechmg" --availability-domain "$AD" \
        --route-table-id "$RT" --security-list-ids "[\"$SL\"]" \
        --wait-for-state AVAILABLE --query 'data.id' --raw-output)
else
  SUBNET=$(oci network subnet list --compartment-id "$TENANCY" --vcn-id "$VCN" \
        --query 'data[?"prohibit-public-ip-on-vnic"==`false`] | [0].id' --raw-output)
  if [ -z "$SUBNET" ] || [ "$SUBNET" = "null" ]; then
    echo "A VCN existente nao tem subnet publica. Crie uma subnet publica e rode de novo."
    exit 1
  fi
fi
echo "    subnet: $SUBNET"

echo "==> 3/8 liberando as portas 80 e 443 na security list"
SL_ID=$(oci network subnet get --subnet-id "$SUBNET" --query 'data."security-list-ids"[0]' --raw-output)
REGRAS=$(oci network security-list get --security-list-id "$SL_ID" --query 'data."ingress-security-rules"' --raw-output)
REGRAS_NOVAS=$(REGRAS="$REGRAS" python3 - <<'PY'
import json, os
regras = json.loads(os.environ["REGRAS"] or "[]")
def porta80(regra):
    try:
        return regra["tcpOptions"]["destinationPortRange"]["min"] == 80
    except Exception:
        return False
def porta443(regra):
    try:
        return regra["tcpOptions"]["destinationPortRange"]["min"] == 443
    except Exception:
        return False
if not any(porta80(r) for r in regras):
    regras.append({"protocol":"6","source":"0.0.0.0/0","isStateless":False,
                   "tcpOptions":{"destinationPortRange":{"min":80,"max":80}}})
if not any(porta443(r) for r in regras):
    regras.append({"protocol":"6","source":"0.0.0.0/0","isStateless":False,
                   "tcpOptions":{"destinationPortRange":{"min":443,"max":443}}})
print(json.dumps(regras))
PY
)
oci network security-list update --security-list-id "$SL_ID" \
  --ingress-security-rules "$REGRAS_NOVAS" --force >/dev/null
echo "    portas 80 e 443 liberadas"

echo "==> 4/8 localizando a imagem Ubuntu 22.04"
IMAGEM=$(oci compute image list --compartment-id "$TENANCY" --operating-system "Canonical Ubuntu" \
  --operating-system-version "22.04" --shape VM.Standard.A1.Flex \
  --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output)
echo "    imagem: $IMAGEM"

echo "==> 5/8 montando o script de inicializacao da VM"
CLOUD_INIT=$(cat <<EOF
#cloud-config
package_update: true
packages:
  - curl
  - unzip
runcmd:
  - curl -fsSL $REPO_RAW/instalar.sh -o /root/instalar.sh
  - bash /root/instalar.sh > /root/instalacao.log 2>&1
  - echo "FIM" >> /root/instalacao.log
EOF
)
echo "$CLOUD_INIT" > /tmp/cloud-init.yaml

echo "==> 6/8 criando a VM (Ampere ARM 2 OCPU / 12 GB, camada gratuita)"
CRIAR_VM() {
  local SHAPE="$1" CONFIG="$2"
  oci compute instance launch \
    --compartment-id "$TENANCY" --availability-domain "$AD" \
    --display-name "$NOME_INSTANCIA" --shape "$SHAPE" --shape-config "$CONFIG" \
    --image-id "$IMAGEM" --subnet-id "$SUBNET" \
    --assign-public-ip true --metadata "{\"user_data\":\"$(echo "$CLOUD_INIT" | base64 -w0)\"}" \
    --wait-for-state RUNNING --query 'data.id' --raw-output 2>/tmp/erro-vm.txt
}

if ! ID_VM=$(CRIAR_VM "VM.Standard.A1.Flex" '{"ocpus":2,"memoryInGBs":12}'); then
  echo "    ARM sem capacidade nesta regiao. Tentando a instancia x86 gratuita..."
  ID_VM=$(CRIAR_VM "VM.Standard.E2.1.Micro" '{"ocpus":1,"memoryInGBs":1}') || {
    echo "Nao consegui criar a VM. Erro:"; tail -5 /tmp/erro-vm.txt; exit 1; }
fi
echo "    VM criada: $ID_VM"

echo "==> 7/8 esperando a rede ficar pronta"
sleep 20
IP_PUBLICO=$(oci compute instance list-vnics --instance-id "$ID_VM" --query 'data[0]."public-ip"' --raw-output)
echo "    IP publico: $IP_PUBLICO"

echo "==> 8/8 aguardando a instalacao terminar (pode levar de 3 a 6 minutos)"
for _ in $(seq 1 40); do
  sleep 15
  if curl -fsS -o /dev/null --max-time 5 "http://$IP_PUBLICO/install.php" 2>/dev/null; then
    echo
    echo "======================================================"
    echo "SISTEMA NO AR"
    echo "Abra: http://$IP_PUBLICO/install.php"
    echo
    echo "Se pedir o codigo de instalacao e voce nao tiver, entre por SSH e rode:"
    echo "  ssh ubuntu@$IP_PUBLICO"
    echo "  cd ~/grupos/grupos && bash deploy/definir-codigo.sh SEU-CODIGO-FORTE"
    echo
    echo "Para o endereco com HTTPS: crie o registro A do dominio"
    echo "apontando para $IP_PUBLICO e rode dentro da VM:"
    echo "  bash deploy/ativar-https.sh SEU-DOMINIO"
    echo "======================================================"
    exit 0
  fi
  echo "    ...ainda instalando (${_}0s)"
done

echo "A VM esta criada (IP $IP_PUBLICO), mas o site ainda nao respondeu."
echo "Entre na VM e veja o log: ssh ubuntu@$IP_PUBLICO 'sudo tail -40 /root/instalacao.log'"
