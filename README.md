# Grupos ANATECH MG — instalador

Painel de divulgação agendada em grupos de WhatsApp (base Grupos Evogo 1.3.13), com a marca ANATECH MG.

## Instalação em um comando (Ubuntu 22.04/24.04, ARM ou x86)

    curl -fsSL https://raw.githubusercontent.com/THEIMPORTS/grupos-anatechmg/main/instalar.sh | bash -s grupos.anatechmg.com.br

Depois abra https://grupos.anatechmg.com.br/install.php e preencha com os dados que o instalador imprime.

## Antes de rodar

1. Crie a VM na Oracle Cloud (Ubuntu 22.04, Ampere A1 ARM, IP publico).
2. Libere TCP 80 e 443 na Default Security List da subnet.
3. Crie no Registro.br um registro tipo A: nome grupos, valor o IP da VM.

O instalador cuida do resto: firewall interno, Docker, banco, HTTPS automatico pelo Caddy.

## Estrutura

- `instalar.sh` — instalador de um comando
- `pacote.zip` — sistema com a marca, Dockerfile, compose, Caddyfile, backup e README completo em deploy/README-DEPLOY.md
