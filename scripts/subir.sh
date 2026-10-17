#!/usr/bin/env bash
#
# Sobe o DriveGuard inteiro num Linux sem nada instalado (versão Linux do
# subir.cmd; também roda no WSL). Uso, na raiz do Infra:
#
#   ./subir.sh                 # sobe tudo
#   ./subir.sh --so-infra      # só a infraestrutura (sem Backend e sem site)
#   ./subir.sh --desligar      # apaga tudo da conta (pede confirmação)
#
# Faz o mesmo que o scripts/subir.ps1, na mesma ordem (ver o cabeçalho de
# lá): ferramentas em versões fixas com SHA-256 conferido, em
# ~/.local/share/driveguard/ferramentas (sem sudo); Backend e Site clonados
# ao lado do Infra (login do GitHub no navegador se faltar); credenciais do
# Learner Lab da área de transferência ou coladas no terminal; cofre de
# segredos; state no S3 da conta; terraform apply com novas tentativas.
#
# Precisa do sistema só: bash, git, curl (ou wget), tar, gzip e openssl
# (este para abrir o cofre). Rodar de novo é seguro.

set -uo pipefail

REGIAO="us-east-1"
ORG="Drive-Guard"
CHAVE_STATE="driveguard/dev/terraform.tfstate"

SO_INFRA=0; DESLIGAR=0; NAO_ABRIR=0
for arg in "$@"; do
  case "$arg" in
    --so-infra) SO_INFRA=1 ;;
    --desligar) DESLIGAR=1 ;;
    --nao-abrir) NAO_ABRIR=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Opção desconhecida: $arg (use --help)" >&2; exit 2 ;;
  esac
done

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$(dirname "$INFRA_DIR")"

RAIZ_LOCAL="${XDG_DATA_HOME:-$HOME/.local/share}/driveguard"
DIR_FERRAMENTAS="$RAIZ_LOCAL/ferramentas"
DIR_LOGS="$RAIZ_LOCAL/logs"
mkdir -p "$DIR_FERRAMENTAS" "$DIR_LOGS"
ARQUIVO_LOG="$DIR_LOGS/subir-$(date +%Y%m%d-%H%M%S).log"
# Tudo que aparece na tela vai também para o registro.
exec > >(tee -a "$ARQUIVO_LOG") 2>&1

# ============================================================================
# Saída e utilitários
# ============================================================================

if [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]; then
  C_CIANO=$'\e[36m'; C_VERDE=$'\e[32m'; C_AMARELO=$'\e[33m'; C_VERMELHO=$'\e[31m'; C_FIM=$'\e[0m'
else
  C_CIANO=""; C_VERDE=""; C_AMARELO=""; C_VERMELHO=""; C_FIM=""
fi
etapa() { echo; echo "${C_CIANO}==> $*${C_FIM}"; }
info()  { echo "    $*"; }
ok()    { echo "${C_VERDE}    $*${C_FIM}"; }
aviso() { echo "${C_AMARELO}    ATENCAO: $*${C_FIM}"; }
falhar() {  # na saída de erro: dentro de $(...) a mensagem não pode sumir
  {
    echo
    echo "${C_VERMELHO}==> NAO DEU CERTO: $*${C_FIM}"
    echo "    Rodar de novo é seguro: o que já foi feito é reaproveitado."
    echo "    Registro completo: $ARQUIVO_LOG"
  } >&2
  exit 1
}
tem() { command -v "$1" >/dev/null 2>&1; }

# Pergunta sempre no terminal, mesmo com a entrada redirecionada.
perguntar() {  # perguntar "texto" -> resposta em $RESPOSTA
  RESPOSTA=""
  if [ -r /dev/tty ] && [ -t 0 ]; then read -r -p "    $1 " RESPOSTA </dev/tty || true
  else read -r RESPOSTA || true; fi
}

sha256() { sha256sum "$1" | cut -d' ' -f1; }

baixar() {  # baixar URL DESTINO SHA256
  local url="$1" destino="$2" esperado="$3" parcial="$2.parcial" tentativa
  for tentativa in 1 2 3 4; do
    rm -f "$parcial"
    if tem curl; then
      curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 30 -o "$parcial" "$url"
    else
      wget -q --tries=3 --timeout=30 -O "$parcial" "$url"
    fi
    if [ $? -eq 0 ] && [ -s "$parcial" ]; then
      local hash; hash="$(sha256 "$parcial")"
      if [ "$hash" = "$esperado" ]; then mv -f "$parcial" "$destino"; return 0; fi
      aviso "o arquivo baixado não confere (SHA-256 $hash)"
    fi
    aviso "download falhou (tentativa $tentativa de 4): $url"
    sleep $((5 * tentativa))
  done
  falhar "não consegui baixar $url. Confira a internet (ou proxy) e rode de novo."
}

# ============================================================================
# Versões fixas (mesmas do subir.ps1; os hashes vêm dos SHA256SUMS de cada
# projeto ou foram calculados do arquivo oficial)
# ============================================================================

case "$(uname -s)" in
  Linux) ;;
  *) echo "Este script é para Linux (e WSL). No Windows, use o subir.cmd." >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARQ="x64" ;;
  aarch64|arm64) ARQ="arm64" ;;
  *) echo "Processador $(uname -m) não suportado (só x86_64 e arm64)." >&2; exit 1 ;;
esac

V_TERRAFORM="1.16.2"; V_NODE="24.20.0"; V_PYTHON="3.12.10"; V_PBS="20250409"; V_AWS="2.36.45"; V_GH="2.101.0"
if [ "$ARQ" = "x64" ]; then
  URL_TERRAFORM="https://releases.hashicorp.com/terraform/$V_TERRAFORM/terraform_${V_TERRAFORM}_linux_amd64.zip"
  SHA_TERRAFORM="0d17011f0c4664539b164b044903d04e296c86c13cb9f28040076c65cfb3985a"
  URL_NODE="https://nodejs.org/dist/v$V_NODE/node-v$V_NODE-linux-x64.tar.gz"
  SHA_NODE="855d581f8a4eb1a8117e3426de25fe02770592febcfb31369aee1ffbfee9e8ec"
  URL_PYTHON="https://github.com/astral-sh/python-build-standalone/releases/download/$V_PBS/cpython-$V_PYTHON%2B$V_PBS-x86_64-unknown-linux-gnu-install_only.tar.gz"
  SHA_PYTHON="e9cf6f7da499a4400ba30ae1da8f7ef25ce97827bd8c1084717aa05438035186"
  URL_AWS="https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$V_AWS.zip"
  SHA_AWS="0f02381483b0a5ca127a4cb379e656a73007b346561a5e41d3249d3bc1861226"
  URL_GH="https://github.com/cli/cli/releases/download/v$V_GH/gh_${V_GH}_linux_amd64.tar.gz"
  SHA_GH="9bca2d1c16825f109907a23307628a2f0698fbf99662b73a5cf0b020293072b8"
  PASTA_NODE="node-v$V_NODE-linux-x64"; PASTA_GH="gh_${V_GH}_linux_amd64"
else
  URL_TERRAFORM="https://releases.hashicorp.com/terraform/$V_TERRAFORM/terraform_${V_TERRAFORM}_linux_arm64.zip"
  SHA_TERRAFORM="c040bd1e3122b4290f70f74288d8c5a54ddd4254a3e52a29e7cc666653f50a0a"
  URL_NODE="https://nodejs.org/dist/v$V_NODE/node-v$V_NODE-linux-arm64.tar.gz"
  SHA_NODE="3515603e2487879a39bc75716f1a2affd027500c64ba50e845cf72cb33219013"
  URL_PYTHON="https://github.com/astral-sh/python-build-standalone/releases/download/$V_PBS/cpython-$V_PYTHON%2B$V_PBS-aarch64-unknown-linux-gnu-install_only.tar.gz"
  SHA_PYTHON="91557c4bc1f65c65c2bf1d0fc7a2816d21b1128f11d2d421af7bd5f6ce07232a"
  URL_AWS="https://awscli.amazonaws.com/awscli-exe-linux-aarch64-$V_AWS.zip"
  SHA_AWS="a10b80249b10c8fe9d433a42ee90d34c60cf50089b7e65d45c8d75e782c921ec"
  URL_GH="https://github.com/cli/cli/releases/download/v$V_GH/gh_${V_GH}_linux_arm64.tar.gz"
  SHA_GH="b57e8063f18862647c9d22727c32e9da1b963f8bf9db648fe123a6975695640f"
  PASTA_NODE="node-v$V_NODE-linux-arm64"; PASTA_GH="gh_${V_GH}_linux_arm64"
fi

# instalar NOME VERSAO URL SHA TIPO(tgz|zip) CAMINHO_DO_EXECUTAVEL(relativo)
# Ecoa o caminho absoluto do executável.
instalar() {
  local nome="$1" versao="$2" url="$3" sha="$4" tipo="$5" relativo="$6"
  local dir="$DIR_FERRAMENTAS/$nome-$versao"
  local exe="$dir/$relativo"
  if [ -f "$dir/.instalado" ] && [ -x "$exe" ]; then echo "$exe"; return 0; fi
  info "baixando $nome $versao..." >&2
  rm -rf "$dir"; mkdir -p "$dir"
  local pacote="$DIR_FERRAMENTAS/$nome-$versao.$tipo"
  if [ ! -f "$pacote" ] || [ "$(sha256 "$pacote")" != "$sha" ]; then baixar "$url" "$pacote" "$sha" >&2; fi
  if [ "$tipo" = "tgz" ]; then
    tar -xzf "$pacote" -C "$dir" || falhar "não consegui extrair o $nome."
  else
    # Sem depender do unzip (falta em muita instalação mínima): o Python
    # portátil extrai. O zipfile não guarda permissões; o chmod devolve.
    "$PY" -m zipfile -e "$pacote" "$dir" || falhar "não consegui extrair o $nome."
    chmod -R u+rwX,go+rX "$dir"
    chmod +x "$exe"
  fi
  [ -x "$exe" ] || falhar "o pacote do $nome não tem $relativo."
  echo "$versao" > "$dir/.instalado"
  rm -f "$pacote"
  echo "$exe"
}

no_path() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac; export PATH; }

# ============================================================================
# 0. Conferências básicas
# ============================================================================

echo
echo "  DriveGuard - subir o projeto"
echo "  Registro: $ARQUIVO_LOG"

etapa "Conferindo o computador"
faltam=()
for c in git tar gzip sha256sum; do tem "$c" || faltam+=("$c"); done
tem curl || tem wget || faltam+=("curl")
if [ ${#faltam[@]} -gt 0 ]; then
  falhar "faltam programas do sistema: ${faltam[*]}. No Ubuntu/Debian: sudo apt install -y ${faltam[*]/sha256sum/coreutils}"
fi
livre_kb="$(df -Pk "$RAIZ_LOCAL" | awk 'NR==2 {print $4}')"
[ "${livre_kb:-0}" -ge $((3 * 1024 * 1024)) ] || falhar "pouco espaço livre em $RAIZ_LOCAL (precisa de 3 GB)."
for site in https://github.com https://releases.hashicorp.com https://sts.us-east-1.amazonaws.com; do
  alcancou=0
  for i in 1 2 3; do
    if tem curl; then curl -sS -o /dev/null --connect-timeout 20 -I "$site" 2>/dev/null && { alcancou=1; break; }
    else wget -q --spider --timeout=20 "$site" 2>/dev/null; [ $? -le 8 ] && { alcancou=1; break; }; fi
    sleep 3
  done
  [ $alcancou -eq 1 ] || falhar "sem acesso a $site. Confira a internet e rode de novo."
done
case "$INFRA_DIR" in
  /mnt/[a-z]/*) aviso "a pasta está no disco do Windows ($INFRA_DIR). No WSL funciona, mas o npm fica bem mais lento; prefira clonar no Linux (~)." ;;
esac
ok "Linux $(uname -m), bash $BASH_VERSION, internet ok"

# ============================================================================
# 1. Ferramentas
# ============================================================================

etapa "Ferramentas (versões fixas, em $DIR_FERRAMENTAS)"
# O Python vem primeiro: ele extrai os .zip das outras.
PY="$(instalar python "$V_PYTHON" "$URL_PYTHON" "$SHA_PYTHON" tgz "python/bin/python3")" || exit 1
EXE_TERRAFORM="$(instalar terraform "$V_TERRAFORM" "$URL_TERRAFORM" "$SHA_TERRAFORM" zip "terraform")" || exit 1
EXE_NODE="$(instalar node "$V_NODE" "$URL_NODE" "$SHA_NODE" tgz "$PASTA_NODE/bin/node")" || exit 1
EXE_AWS="$(instalar aws "$V_AWS" "$URL_AWS" "$SHA_AWS" zip "aws/dist/aws")" || exit 1
for exe in "$PY" "$EXE_TERRAFORM" "$EXE_NODE" "$EXE_AWS"; do no_path "$(dirname "$exe")"; done
info "python     $PY"
info "terraform  $EXE_TERRAFORM"
info "node       $EXE_NODE"
info "aws        $EXE_AWS"
info "git        $(command -v git)"
"$PY" -m pip --version >/dev/null 2>&1 || "$PY" -m ensurepip --default-pip >/dev/null 2>&1 \
  || falhar "o pip do Python portátil não funcionou."
export PYTHON="$PY"               # o build_lambdas.sh usa este
export PIP_DISABLE_PIP_VERSION_CHECK=1
export GIT_TERMINAL_PROMPT=0      # git nunca fica parado pedindo usuário/senha
export CHECKPOINT_DISABLE=1
export NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false
ok "ferramentas prontas"

# ============================================================================
# 2. Repositórios
# ============================================================================

etapa "Repositórios"
info "pasta base: $BASE"

GH_PRONTO=0
garantir_login_github() {
  [ $GH_PRONTO -eq 1 ] && return 0
  EXE_GH="$(instalar gh "$V_GH" "$URL_GH" "$SHA_GH" tgz "$PASTA_GH/bin/gh")" || exit 1
  no_path "$(dirname "$EXE_GH")"
  if ! "$EXE_GH" auth status --hostname github.com >/dev/null 2>&1; then
    echo
    echo "    O repositório Site é privado. Vou abrir o login do GitHub:"
    echo "    copie o código que aparecer, cole na página do navegador e autorize."
    echo "    (Use a conta do GitHub que está na organização $ORG.)"
    echo
    "$EXE_GH" auth login --hostname github.com --git-protocol https --web </dev/tty \
      || falhar "o login do GitHub não foi concluído. Rode de novo e autorize no navegador."
  fi
  GH_PRONTO=1
}

atualizar_repo() {  # atualizar_repo NOME DIR PRIVADO(0|1)
  local nome="$1" dir="$2" privado="$3" url="https://github.com/$ORG/$1.git" tentativa saida
  if [ -d "$dir/.git" ]; then
    local ramo sujo
    ramo="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    sujo="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)"
    if [ "$ramo" != "main" ]; then aviso "$nome está no branch '$ramo': não atualizei (uso como está)."; return; fi
    if [ -n "$sujo" ]; then aviso "$nome tem alterações locais: não atualizei (uso como está)."; return; fi
    if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then ok "$nome atualizado (main)"; return; fi
    if [ "$privado" = 1 ]; then
      garantir_login_github
      if (cd "$dir" && "$EXE_GH" repo sync >/dev/null 2>&1); then ok "$nome atualizado (main)"; return; fi
    fi
    aviso "não consegui atualizar $nome; uso a cópia local."
    return
  fi
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then info "$nome já existe em $dir (sem git): uso como está."; return; fi
  rm -rf "$dir"
  info "clonando $nome..."
  for tentativa in 1 2 3; do
    if saida="$(git clone --quiet "$url" "$dir" 2>&1)"; then ok "$nome clonado"; return; fi
    rm -rf "$dir"
    [ "$privado" = 1 ] && break
    sleep $((5 * tentativa))
  done
  [ "$privado" = 1 ] || falhar "não consegui clonar $url : $saida"
  # Privado e sem login do GitHub neste computador: entra e clona com o gh.
  garantir_login_github
  for tentativa in 1 2 3; do
    if saida="$("$EXE_GH" repo clone "$ORG/$nome" "$dir" -- --quiet 2>&1)"; then ok "$nome clonado (login do GitHub)"; return; fi
    rm -rf "$dir"
    sleep $((5 * tentativa))
  done
  falhar "não consegui clonar $ORG/$nome. Confira se entrou no GitHub com a conta da organização $ORG : $saida"
}

atualizar_repo Infra "$INFRA_DIR" 0
atualizar_repo Backend "$BASE/Backend" 0
atualizar_repo Site "$BASE/Site" 1
cd "$INFRA_DIR" || falhar "não achei $INFRA_DIR"

# ============================================================================
# 3. Credenciais da AWS (Learner Lab)
# ============================================================================

etapa "Credenciais da AWS"

DIR_AWS="$HOME/.aws"
ARQ_CREDENCIAIS="$DIR_AWS/credentials"
ARQ_CONFIG="$DIR_AWS/config"
# Variáveis antigas teriam prioridade sobre o arquivo.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_DEFAULT_REGION="$REGIAO" AWS_REGION="$REGIAO" AWS_PAGER=""

# ler_bloco TEXTO -> CHAVE_ID / CHAVE_SECRETA / CHAVE_TOKEN (0 se achou as três)
ler_bloco() {
  local texto="$1"
  CHAVE_ID="$(printf '%s\n' "$texto" | tr -d '\r' | sed -n 's/^[[:space:]]*aws_access_key_id[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)"
  CHAVE_SECRETA="$(printf '%s\n' "$texto" | tr -d '\r' | sed -n 's/^[[:space:]]*aws_secret_access_key[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)"
  CHAVE_TOKEN="$(printf '%s\n' "$texto" | tr -d '\r' | sed -n 's/^[[:space:]]*aws_session_token[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)"
  [ -n "$CHAVE_ID" ] && [ -n "$CHAVE_SECRETA" ] && [ -n "$CHAVE_TOKEN" ]
}

area_de_transferencia() {
  if tem wl-paste; then wl-paste --no-newline 2>/dev/null && return; fi
  if tem xclip; then xclip -o -selection clipboard 2>/dev/null && return; fi
  if tem xsel; then xsel --clipboard --output 2>/dev/null && return; fi
  # WSL: a área de transferência é a do Windows.
  if tem powershell.exe; then powershell.exe -NoProfile -Command Get-Clipboard 2>/dev/null && return; fi
  return 1
}

IDENTIDADE_CONTA=""; IDENTIDADE_ARN=""
testar_credenciais() {  # usa o que estiver valendo (arquivo ou variáveis)
  local i saida
  for i in 1 2 3; do
    if saida="$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1)"; then
      IDENTIDADE_CONTA="$(echo "$saida" | awk '{print $1}')"
      IDENTIDADE_ARN="$(echo "$saida" | awk '{print $2}')"
      return 0
    fi
    case "$saida" in
      *RequestTimeTooSkewed*|*"Signature expired"*)
        falhar "o relógio do computador está errado. Acerte a hora (no WSL: wsl --shutdown no Windows e abra de novo) e rode de novo." ;;
    esac
    sleep 3
  done
  return 1
}

testar_bloco() {  # testa sem gravar: credencial velha não apaga a boa
  local r
  export AWS_ACCESS_KEY_ID="$CHAVE_ID" AWS_SECRET_ACCESS_KEY="$CHAVE_SECRETA" AWS_SESSION_TOKEN="$CHAVE_TOKEN"
  testar_credenciais; r=$?
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  return $r
}

gravar_credenciais() {
  mkdir -p "$DIR_AWS"; chmod 700 "$DIR_AWS"
  local outras=""
  # Troca só o [default]; os outros profiles ficam.
  [ -f "$ARQ_CREDENCIAIS" ] && outras="$(awk '
    /^[[:space:]]*\[.*\][[:space:]]*$/ { dentro = ($0 ~ /^[[:space:]]*\[default\][[:space:]]*$/) }
    !dentro { print }' "$ARQ_CREDENCIAIS")"
  umask 077
  {
    echo "[default]"
    echo "aws_access_key_id=$CHAVE_ID"
    echo "aws_secret_access_key=$CHAVE_SECRETA"
    echo "aws_session_token=$CHAVE_TOKEN"
    [ -n "$outras" ] && { echo; echo "$outras"; }
  } > "$ARQ_CREDENCIAIS"
  if ! grep -q '^\[default\]' "$ARQ_CONFIG" 2>/dev/null; then
    { printf '[default]\nregion = %s\noutput = json\n\n' "$REGIAO"; cat "$ARQ_CONFIG" 2>/dev/null; } > "$ARQ_CONFIG.novo"
    mv -f "$ARQ_CONFIG.novo" "$ARQ_CONFIG"
  fi
}

pedir_credenciais() {
  [ -n "${1:-}" ] && { echo; aviso "$1"; }
  echo "    No Learner Lab: Start Lab, espere a bolinha ficar verde, AWS Details > AWS CLI: Show."
  echo "    Copie o bloco inteiro ([default] ... aws_session_token=...)."
  local vez linha texto n
  for vez in 1 2 3 4 5 6 7 8 9 10; do
    perguntar "Com o bloco copiado, aperte Enter (ou cole aqui no terminal):"
    linha="$RESPOSTA"
    if [ -n "${linha// /}" ]; then
      # Colou no terminal: uma linha por leitura, até ter as três chaves.
      texto="$linha"
      for n in 1 2 3 4 5 6 7 8; do
        ler_bloco "$texto" && break
        if [ -r /dev/tty ] && [ -t 0 ]; then IFS= read -r linha </dev/tty || break; else IFS= read -r linha || break; fi
        texto="$texto"$'\n'"$linha"
      done
    else
      texto="$(area_de_transferencia || true)"
    fi
    ler_bloco "$texto" && return 0
    aviso "não achei aws_access_key_id, aws_secret_access_key e aws_session_token. Copie de novo."
  done
  falhar "não recebi as credenciais da AWS."
}

garantir_credenciais() {  # garantir_credenciais ACEITAR_ATUAIS(0|1)
  local texto tentativa motivo
  texto="$(area_de_transferencia || true)"
  if ler_bloco "$texto"; then
    info "credenciais encontradas na área de transferência"
    if testar_bloco; then gravar_credenciais; return 0; fi
    info "(as da área de transferência já não valem)"
  fi
  if [ "$1" = 1 ] && testar_credenciais; then info "uso as credenciais que já estavam em $ARQ_CREDENCIAIS"; return 0; fi
  motivo="preciso de credenciais válidas do Learner Lab."
  for tentativa in 1 2 3 4 5; do
    pedir_credenciais "$motivo"
    if testar_bloco; then gravar_credenciais; return 0; fi
    motivo="a AWS recusou essas credenciais. A sessão do lab pode ter acabado: clique em Start Lab e copie o bloco novo."
  done
  falhar "não consegui credenciais válidas da AWS."
}

garantir_credenciais 1
testar_credenciais || falhar "as credenciais gravadas não funcionaram."
CONTA="$IDENTIDADE_CONTA"
ok "conta $CONTA ($IDENTIDADE_ARN)"
case "$IDENTIDADE_ARN" in
  *voclabs*|*LabRole*) ;;
  *) aviso "isto não parece o AWS Academy Learner Lab. O projeto usa a LabRole (iam_mode = learner_lab)." ;;
esac

# ============================================================================
# 4. Segredos e variáveis
# ============================================================================

etapa "Segredos do grupo e variáveis"
ARQ_SEGREDOS="$INFRA_DIR/segredos.auto.tfvars"
if [ -f "$ARQ_SEGREDOS" ]; then
  ok "segredos.auto.tfvars já existe (não mexi)"
elif [ ! -f "$INFRA_DIR/segredos/segredos.tfvars.enc" ]; then
  aviso "sem cofre de segredos: sobe sem a chave da IA (insights por regras) e sem o usuário de teste."
else
  tem openssl || falhar "o cofre precisa do openssl. No Ubuntu/Debian: sudo apt install -y openssl"
  aberto=0
  for tentativa in 1 2 3; do
    if bash "$INFRA_DIR/scripts/segredos.sh" abrir </dev/tty; then aberto=1; break; fi
    unset DG_SEGREDOS_SENHA
  done
  if [ $aberto -eq 0 ]; then
    perguntar "Seguir sem os segredos (sem IA nos insights e sem usuário de teste)? [s/N]"
    case "$RESPOSTA" in [sS]*) ;; *) falhar "cofre não aberto. Peça a senha do cofre ao grupo e rode de novo." ;; esac
  fi
fi
if [ ! -f "$INFRA_DIR/terraform.tfvars" ]; then
  cp "$INFRA_DIR/terraform.tfvars.example" "$INFRA_DIR/terraform.tfvars"
  ok "terraform.tfvars criado a partir do exemplo"
else
  ok "terraform.tfvars já existe (não mexi)"
fi

# ============================================================================
# 5. State remoto no S3 da conta
# ============================================================================

etapa "State do Terraform (S3 da conta $CONTA)"
BUCKET_STATE="driveguard-tfstate-$CONTA"
if ! aws s3api head-bucket --bucket "$BUCKET_STATE" >/dev/null 2>&1; then
  info "criando o bucket $BUCKET_STATE"
  saida="$(aws s3api create-bucket --bucket "$BUCKET_STATE" --region "$REGIAO" 2>&1)" \
    || case "$saida" in *BucketAlreadyOwnedByYou*) ;; *) falhar "não consegui criar o bucket do state: $saida" ;; esac
  aws s3api wait bucket-exists --bucket "$BUCKET_STATE" >/dev/null 2>&1
fi
aws s3api put-bucket-versioning --bucket "$BUCKET_STATE" --versioning-configuration Status=Enabled >/dev/null 2>&1
aws s3api put-public-access-block --bucket "$BUCKET_STATE" --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null 2>&1

# Mesmo conteúdo que o subir.ps1 gera.
cat > "$INFRA_DIR/backend.tf.novo" <<EOF
# Gerado pelo scripts/subir.ps1 (não vai para o git). State no S3 da conta do
# Learner Lab, com trava por arquivo (use_lockfile), sem DynamoDB.
terraform {
  backend "s3" {
    bucket       = "$BUCKET_STATE"
    key          = "$CHAVE_STATE"
    region       = "$REGIAO"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
if cmp -s "$INFRA_DIR/backend.tf.novo" "$INFRA_DIR/backend.tf"; then rm -f "$INFRA_DIR/backend.tf.novo"
else mv -f "$INFRA_DIR/backend.tf.novo" "$INFRA_DIR/backend.tf"; fi

# Decide se o state local (de quem subia antes sem o S3) vai para o bucket.
STATE_LOCAL="$INFRA_DIR/terraform.tfstate"
REMOTO_TMP="$(mktemp)"
aws s3 cp "s3://$BUCKET_STATE/$CHAVE_STATE" "$REMOTO_TMP" --only-show-errors >/dev/null 2>&1 || : > "$REMOTO_TMP"
decisao="$("$PY" - "$STATE_LOCAL" "$REMOTO_TMP" "$CONTA" <<'EOF'
import json, os, sys
local_p, remoto_p, conta = sys.argv[1:4]
def ler(p):
    try:
        return json.load(open(p, encoding="utf-8")) if os.path.getsize(p) else None
    except Exception:
        return None
local = ler(local_p) if os.path.exists(local_p) else None
remoto = ler(remoto_p)
texto = open(local_p, encoding="utf-8", errors="ignore").read() if local else ""
desta_conta = bool(local and local.get("resources") and f":{conta}:" in texto)
if not desta_conta:
    print("reconfigurar" + (" remoto" if remoto else ""))
elif not remoto or not remoto.get("resources"):
    print("migrar")
elif remoto.get("lineage") == local.get("lineage") and int(local.get("serial", 0)) > int(remoto.get("serial", 0)):
    print("migrar")
else:
    print("reconfigurar remoto aviso")
EOF
)"
rm -f "$REMOTO_TMP"
args_init=(init -input=false -no-color)
case "$decisao" in
  migrar)
    info "levando o state local para o S3 (primeira vez neste computador)"
    rm -f "$INFRA_DIR/.terraform/terraform.tfstate"
    args_init+=(-migrate-state -force-copy) ;;
  *aviso*)
    aviso "este computador tinha um state local, mas o do S3 é o que vale (outro colega subiu depois)."
    args_init+=(-reconfigure) ;;
  *) args_init+=(-reconfigure) ;;
esac
init_ok=0
for tentativa in 1 2 3; do
  if saida_init="$(terraform "${args_init[@]}" 2>&1)"; then init_ok=1; break; fi
  aviso "terraform init falhou (tentativa $tentativa de 3)"
  sleep $((10 * tentativa))
done
[ $init_ok -eq 1 ] || { echo "$saida_init"; falhar "terraform init não funcionou."; }
if [ -f "$STATE_LOCAL" ]; then
  guardado="$STATE_LOCAL.antes-do-s3-$(date +%Y%m%d-%H%M%S)"
  mv -f "$STATE_LOCAL" "$guardado"
  info "state local antigo guardado em $(basename "$guardado")"
fi
case "$decisao" in
  migrar) ok "state em s3://$BUCKET_STATE/$CHAVE_STATE (migrado)" ;;
  *remoto*) ok "state em s3://$BUCKET_STATE/$CHAVE_STATE (já existia)" ;;
  *) ok "state em s3://$BUCKET_STATE/$CHAVE_STATE (novo)" ;;
esac

# Monta build/ sempre: um build/ velho daria pacotes diferentes dos colegas e
# Lambdas trocando a cada apply. Com o código igual, o pacote sai igual.
etapa "Empacotando as Lambdas"
bash "$INFRA_DIR/scripts/build_lambdas.sh" >/dev/null || falhar "o build das Lambdas falhou."
ok "pacotes em build/"

# ============================================================================
# 6a. Desligar (opcional)
# ============================================================================

if [ $DESLIGAR -eq 1 ]; then
  etapa "Desligar: destruir todo o DriveGuard da conta $CONTA"
  echo "${C_VERMELHO}    Isto APAGA banco, buckets, EC2, API e dados. Não tem volta.${C_FIM}"
  perguntar "Digite DESLIGAR para confirmar:"
  [ "$RESPOSTA" = "DESLIGAR" ] || { info "cancelado: nada foi apagado."; exit 0; }
  REGIAO="$REGIAO" bash "$INFRA_DIR/scripts/desligar.sh"
  exit $?
fi

# ============================================================================
# 6b. Apply
# ============================================================================

etapa "terraform apply (12 a 25 minutos na primeira vez; quase tudo é esperar o RDS)"
args_apply=(apply -input=false -auto-approve -no-color)
[ $SO_INFRA -eq 1 ] && args_apply+=(-var deploy_aplicacao=false)

SAIDA_APPLY="$(mktemp)"
sucesso=0
for tentativa in 1 2 3; do
  if [ $tentativa -gt 1 ]; then
    etapa "terraform apply: tentativa $tentativa de 3 (continua de onde parou)"
    testar_credenciais || garantir_credenciais 0
  fi
  terraform "${args_apply[@]}" 2>&1 | tee "$SAIDA_APPLY"
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then sucesso=1; break; fi

  if grep -q "Error acquiring the state lock" "$SAIDA_APPLY"; then
    id_trava="$(grep -oE 'ID:[[:space:]]+[0-9a-fA-F-]{8,}' "$SAIDA_APPLY" | head -1 | awk '{print $2}')"
    aviso "o state está travado. Ou alguém do grupo está rodando agora, ou uma execução anterior caiu no meio."
    perguntar "Ninguém mais está rodando? Destravar (ID $id_trava)? [s/N]"
    case "$RESPOSTA" in
      [sS]*) [ -n "$id_trava" ] && terraform force-unlock -force "$id_trava" >/dev/null 2>&1 ;;
      *) falhar "state travado. Espere o colega terminar e rode de novo." ;;
    esac
  elif grep -qE "ExpiredToken|InvalidClientTokenId|security token included in the request is (expired|invalid)|voc-cancel-cred" "$SAIDA_APPLY"; then
    garantir_credenciais 0
  else
    aviso "o apply falhou; erros passageiros da AWS são comuns aqui. Tento de novo em 30 s."
    sleep 30
  fi
done
rm -f "$SAIDA_APPLY"
[ $sucesso -eq 1 ] || falhar "o terraform apply falhou 3 vezes. O erro está logo acima e no registro."

# ============================================================================
# 7. Pronto
# ============================================================================

etapa "Conferindo o dashboard"
URL="$(terraform output -raw dashboard_url 2>/dev/null || true)"
API="$(terraform output -raw backend_api_url 2>/dev/null || true)"
NO_AR=0
if [[ "$URL" =~ ^https?:// ]]; then
  info "a EC2 copia o site do S3 a cada minuto; espero até 8 minutos"
  limite=$(( $(date +%s) + 480 ))
  while [ "$(date +%s)" -lt $limite ]; do
    if tem curl; then pagina="$(curl -fsS --max-time 15 "$URL" 2>/dev/null || true)"
    else pagina="$(wget -qO- --timeout=15 "$URL" 2>/dev/null || true)"; fi
    case "$pagina" in *'id="root"'*) NO_AR=1; break ;; esac
    sleep 15
  done
fi

EMAIL=""; SENHA=""
if [ -f "$ARQ_SEGREDOS" ]; then
  bloco="$(sed -n '/usuario_teste[[:space:]]*=[[:space:]]*{/,/}/p' "$ARQ_SEGREDOS")"
  EMAIL="$(printf '%s\n' "$bloco" | sed -n 's/^[[:space:]]*email[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  SENHA="$(printf '%s\n' "$bloco" | sed -n 's/^[[:space:]]*senha[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

echo
echo "${C_VERDE}  ============================================================${C_FIM}"
echo "${C_VERDE}   DriveGuard no ar${C_FIM}"
echo "${C_VERDE}  ============================================================${C_FIM}"
echo "   Dashboard:  $URL"
echo "   API:        $API"
[ -n "$EMAIL" ] && echo "   Login:      $EMAIL   senha: $SENHA"
[ $NO_AR -eq 1 ] || echo "${C_AMARELO}   (o dashboard ainda não respondeu; espere 1 ou 2 minutos e recarregue)${C_FIM}"
echo
echo "   O lab desliga RDS e EC2 quando a sessão acaba. Para voltar: Start Lab"
echo "   e rode o ./subir.sh de novo (credenciais novas, o resto é reaproveitado)."
echo "   Para apagar tudo da conta: ./subir.sh --desligar"
echo "   Registro: $ARQUIVO_LOG"
echo

if [ $NAO_ABRIR -eq 0 ] && [[ "$URL" =~ ^https?:// ]]; then
  if tem wslview; then wslview "$URL" >/dev/null 2>&1 &
  elif tem explorer.exe; then explorer.exe "$URL" >/dev/null 2>&1 &
  elif tem xdg-open; then xdg-open "$URL" >/dev/null 2>&1 &
  fi
fi
exit 0
