# DriveGuard — Infraestrutura AWS (Terraform)

Infraestrutura como código do **DriveGuard**, sistema de detecção de sonolência em
motoristas de caminhões e ônibus (TCC 2026).

Um `terraform apply` provisiona a nuvem inteira: rede, ingestão, armazenamento,
banco com o schema já criado e populado, pipeline de ETL agendado, dashboard e
monitoramento.

![Arquitetura AWS do DriveGuard](docs/arquitetura-aws.png)

---

## Subir com um clique

Mesmo num computador sem nada instalado:

1. No AWS Academy, clique em **Start Lab** e espere a bolinha ficar verde.
   Abra **AWS Details → AWS CLI: Show** e copie o bloco inteiro.
2. Rode o script do seu sistema, na raiz deste repositório:

| Sistema | Subir | Apagar tudo |
|---|---|---|
| Windows 10/11 | duplo clique em **`subir.cmd`** | `desligar.cmd` |
| Linux e WSL (x86_64 ou arm64) | **`./subir.sh`** | `./desligar.sh` |

No Linux, o sistema só precisa ter `git`, `curl` (ou `wget`), `tar` e
`openssl`, que já vêm no Ubuntu/Debian. Não precisa de `sudo`, e as
ferramentas ficam em `~/.local/share/driveguard`. No terminal, o script lê o
bloco da área de transferência (`wl-paste`, `xclip`, `xsel` ou a do Windows,
no WSL) ou pede para colar.

Ele faz o resto sozinho, e rodar de novo é seguro:

| Etapa | O que acontece |
|---|---|
| Ferramentas | baixa Terraform, Node.js, Python e AWS CLI em versões fixas, conferindo o SHA-256, para `%LOCALAPPDATA%\DriveGuard\ferramentas` (Linux: `~/.local/share/driveguard`). Também baixa Git (só no Windows) e GitHub CLI se faltarem. Não instala nada no sistema e não pede administrador. |
| Repositórios | clona (ou atualiza com `pull --ff-only`) o Backend e o Site ao lado do Infra. O Site é privado: se o computador ainda não tem login do GitHub, o script abre o login no navegador uma vez. |
| Credenciais AWS | lê o bloco da área de transferência (ou pede para colar) e grava o `[default]` de `~/.aws/credentials`. Se a sessão do lab acabar no meio, ele pede o bloco novo e continua. |
| Segredos | abre o cofre do grupo (`segredos/segredos.tfvars.enc`) e pede a senha. |
| State | guarda o state no bucket `driveguard-tfstate-<conta>`, criado na conta do lab. Assim qualquer colega continua de onde o outro parou. Na primeira vez, leva o state local para lá. |
| Apply | roda `terraform apply`, tenta de novo em erros passageiros e destrava o state se uma execução anterior caiu. No fim, abre o dashboard e mostra o login de teste. |

**`desligar.cmd`** (ou `./desligar.sh`) apaga tudo da conta e pede
confirmação. O bucket do state fica, para o próximo `subir`. O registro de
cada execução vai para `%LOCALAPPDATA%\DriveGuard\logs` (Linux:
`~/.local/share/driveguard/logs`). Para subir só a infraestrutura, sem Backend e
sem dashboard: `scripts\subir.ps1 -SoInfra` ou `./subir.sh --so-infra`.

Windows e Linux podem se revezar na mesma conta. Os dois geram pacotes
idênticos: finais de linha LF no git, zip das Lambdas com modo fixo e o mesmo
Python 3.12.10. Assim, o apply de um colega não refaz o que outro subiu.

As seções abaixo explicam o mesmo passo a passo, feito à mão.

---

## Índice

0. [Subir com um clique](#subir-com-um-clique)
1. [O que este repositório provisiona](#1-o-que-este-repositório-provisiona)
2. [Fluxo de dados](#2-fluxo-de-dados)
3. [Decisões de arquitetura](#3-decisões-de-arquitetura)
4. [Estrutura do repositório](#4-estrutura-do-repositório)
5. [Pré-requisitos](#5-pré-requisitos)
6. [Como rodar no AWS Academy Learner Lab](#6-como-rodar-no-aws-academy-learner-lab)
7. [Validando a esteira ponta a ponta](#7-validando-a-esteira-ponta-a-ponta)
8. [Modelo de dados](#8-modelo-de-dados)
9. [Custo](#9-custo)
10. [Ligar e desligar](#10-ligar-e-desligar)
11. [Operação do dia a dia](#11-operação-do-dia-a-dia)
12. [Segurança e LGPD](#12-segurança-e-lgpd)
13. [Solução de problemas](#13-solução-de-problemas)
14. [Destruindo o ambiente](#14-destruindo-o-ambiente)
15. [Limitações conhecidas](#15-limitações-conhecidas)

---

## 1. O que este repositório provisiona

| Camada | Recurso AWS | Papel na solução |
|---|---|---|
| Rede | VPC `10.0.0.0/16`, IGW, 2 subnets públicas, 2 privadas, VPC Endpoints | Isola o banco e as Lambdas da internet |
| Ingestão | API Gateway REST + API Key + Usage Plan | Recebe os lotes HTTPS enviados pelo veículo |
| Ingestão | Lambda `ingest` | Grava o JSON cru no S3 Bronze |
| Bronze | S3 versionado, cifrado, com lifecycle | Evento imutável e auditável |
| Silver | Lambda `etl-silver` (gatilho S3) | Normaliza e carrega no PostgreSQL |
| Silver/Gold | RDS PostgreSQL `db.t3.micro` | Tabelas da frota, cadastros e PRF + 11 MATERIALIZED VIEWs |
| Gold | Lambda `etl-gold` + EventBridge (5 min) | `REFRESH MATERIALIZED VIEW CONCURRENTLY` |
| Schema | Lambda `db-migrate` | Aplica o DDL e o seed no `apply` |
| Base PRF | Lambda `prf-download` (fora da VPC) + EventBridge semanal | Baixa os acidentes da PRF e o IPCA para o Bronze |
| Base PRF | Lambda `prf-carga` (VPC, gatilho S3) | Carrega a PRF no banco e atualiza as views `mv_prf_*` |
| Login | Cognito (grupos admin, gestor, operador) | Autenticação da dashboard, empresa no token |
| Backend | API HTTP + autorizador JWT + parâmetros no SSM | Recebe as rotas e Lambdas do repositório Backend |
| Apresentação | EC2 `t3.micro` + Elastic IP + nginx | Serve o build estático do dashboard (sincronizado do S3) |
| Demonstração | Lambda `simulador` + EventBridge (1 min) *(opcional)* | Faz o papel das câmeras do seed |
| ML | SageMaker Notebook `ml.t3.medium` *(opcional)* | Treino dos modelos (XGBoost / YOLO) |
| Observabilidade | CloudWatch (alarmes + dashboard), SNS, SQS DLQ | Monitora a cadeia inteira |

O processamento de visão computacional **não** está aqui: ele roda no dispositivo
embarcado no veículo (MediaPipe Face Mesh → extração de features → classificador →
alerta local). Esta infraestrutura começa no ponto em que o veículo já decidiu o
estado do motorista e envia apenas métricas numéricas anonimizadas.

---

## 2. Fluxo de dados

```
┌──────────────────────── VEÍCULO (edge, fora da AWS) ─────────────────────────┐
│  Câmera IR/RGB 30fps → MediaPipe Face Mesh (468 landmarks)                   │
│  → EAR, MAR, PERCLOS, blink rate, head pose (solvePnP)                       │
│  → classificador (XGBoost) → alerta / fadiga / sonolento                     │
│  → ALERTA LOCAL sonoro+visual (funciona offline)                             │
│  → buffer local; envia lote HTTPS quando há rede                             │
└────────────────────────────────────┬─────────────────────────────────────────┘
                                     │ POST /v1/eventos  (x-api-key)
                                     ▼
                         ┌───────────────────────┐
                         │  API Gateway (REST)   │  throttling + quota
                         └───────────┬───────────┘
                                     ▼
                         ┌───────────────────────┐
                         │  Lambda ingest        │  fora da VPC (só fala com S3)
                         │  valida + envelopa    │
                         └───────────┬───────────┘
                                     ▼
                  ┌──────────────────────────────────────┐
                  │  S3 BRONZE                           │
                  │  eventos/dt=YYYY-MM-DD/hr=HH/…json   │  imutável, versionado
                  └──────────────────┬───────────────────┘
                                     │ s3:ObjectCreated:*
                                     ▼
                         ┌───────────────────────┐
                         │  Lambda etl-silver    │  subnet PRIVADA
                         │  resolve FKs, dedup   │
                         └───────────┬───────────┘
                                     ▼
                  ┌──────────────────────────────────────┐
                  │  RDS PostgreSQL                      │
                  │  schema silver  (12 tabelas OLTP)    │
                  │  schema gold    (7 MATERIALIZED VIEWs)│
                  └───────┬──────────────────────┬───────┘
                          │                      ▲
        EventBridge 5 min │                      │ REFRESH CONCURRENTLY
                          ▼                      │
                    ┌───────────────────────┐    │
                    │  Lambda etl-gold      │────┘
                    └───────────────────────┘
                                     │
                                     ▼
                         ┌───────────────────────┐
                         │  EC2 t3.small + nginx │  subnet PÚBLICA
                         │  Dashboard DriveGuard │  ← gestor de frota (browser)
                         └───────────────────────┘
```

**Dados ao vivo não passam pelo Gold.** Os painéis "Alertas em Tempo Real",
"Ações Rápidas" e "Insights" leem a Silver diretamente; só as agregações
históricas vêm das MVs, que têm até 5 minutos de atraso.

---

## 3. Decisões de arquitetura

Estas são as escolhas que exigiram justificativa — cada uma resolve uma restrição
concreta do projeto.

### 3.1 PostgreSQL, não MySQL

A dissertação (versão inicial) menciona "Amazon RDS com MySQL". Aqui foi usado
**PostgreSQL**, e essa mudança é deliberada:

- a camada Gold é feita de `MATERIALIZED VIEW` com `REFRESH CONCURRENTLY`, que
  **não existe no MySQL** — no MySQL seria preciso recriar tabelas agregadas a
  cada ciclo, com janela de indisponibilidade a cada refresh;
- o modelo usa `UUID`, `JSONB`, `TIMESTAMPTZ`, `ENUM` via `CREATE TYPE` e
  índices parciais — todos nativos no PostgreSQL;
- o time do dashboard já definiu o schema em PostgreSQL.

O documento de contexto do TCC (`CONTEXTO_TCC.md`, seção 9) registra essa decisão.
**O diagrama `docs/arquitetura-aws.png` ainda diz "RDS MySQL" e está desatualizado
nesse ponto** — vale corrigir antes da entrega final.

### 3.2 Sem NAT Gateway

As Lambdas de ETL rodam em subnet privada e precisam alcançar S3 e CloudWatch
Logs. O caminho óbvio seria um NAT Gateway, mas ele custa **~US$32/mês + tráfego**:
um terço do orçamento de US$100 do Learner Lab, gasto em encanamento.

A solução usa VPC Endpoints:

| Serviço | Tipo de endpoint | Custo |
|---|---|---|
| S3 | Gateway | **grátis** |
| CloudWatch Logs | Interface (1 ENI por subnet privada) | ~US$0,01/h por ENI |

Sem o endpoint de Logs, uma Lambda em subnet privada sem NAT **trava no envio do
log e só aparece o timeout, sem stack trace** — um dos erros mais difíceis de
diagnosticar nessa topologia. Se quiser o NAT mesmo assim:
`enable_nat_gateway = true`.

### 3.3 A Lambda de ingestão fica fora da VPC

Ela só fala com o S3. Colocá-la na VPC custaria uma ENI e cold start de rede
sem nenhum ganho. As outras três Lambdas ficam na VPC porque precisam do RDS.

### 3.4 `iam_mode`: Learner Lab ou conta própria

O Learner Lab **nega `iam:CreateRole`**. Qualquer Terraform que tente criar roles
falha no primeiro apply. Por isso:

- `iam_mode = "learner_lab"` *(padrão)* — reutiliza a `LabRole` e o
  `LabInstanceProfile` já existentes;
- `iam_mode = "self_managed"` — o Terraform cria roles e policies dedicadas por
  serviço, com permissões mínimas (veja [`iam.tf`](iam.tf)).

O segundo modo não é enfeite: ele documenta, em código, exatamente quais
permissões a solução exige — material direto para o capítulo de segurança do TCC.

### 3.5 pg8000 no lugar de psycopg2

`psycopg2` tem extensão em C e precisaria ser compilado no Amazon Linux para
virar uma layer. `pg8000` é **100% Python puro**: `pip install --target` funciona
em Windows, macOS e Linux, e o build do repositório é reprodutível em qualquer
máquina do grupo.

### 3.6 SSM Parameter Store, não Secrets Manager

A senha do RDS é gerada pelo Terraform e guardada como `SecureString` no
Parameter Store. Parâmetros Standard são **gratuitos**; cada segredo no Secrets
Manager custa US$0,40/mês, e o acesso a partir de subnet privada exigiria mais um
VPC Endpoint de interface.

As Lambdas recebem a senha por variável de ambiente (cifrada em repouso pela
chave gerenciada da AWS para Lambda). A EC2 do dashboard, que tem saída para a
internet, lê a URI direto do Parameter Store no boot.

> Em produção o correto seria Secrets Manager com rotação automática. A troca
> está documentada aqui como decisão de custo, não como boa prática geral.

### 3.7 O refresh do Gold acontece em Python, não no banco

`REFRESH MATERIALIZED VIEW CONCURRENTLY` chama `PreventInTransactionBlock` no
PostgreSQL: ele **recusa rodar dentro de um bloco de transação** — e todo corpo de
função plpgsql é um. Uma função `fn_refresh_todas()` que fizesse o laço no banco
falharia em tempo de execução.

Por isso a Lambda `etl-gold` lê `gold.vw_materialized_views` e dispara um
`REFRESH` por statement, com a conexão em **autocommit**, medindo cada view
separadamente e publicando a duração como métrica no CloudWatch.

### 3.8 Toda MV tem índice UNIQUE sobre colunas sem NULL

`REFRESH CONCURRENTLY` exige um índice UNIQUE. Menos óbvio: um índice UNIQUE
**não desduplica linhas com NULL**, e o refresh aborta com
`contains duplicate rows`. Por isso as colunas de dimensão das views são
normalizadas com `COALESCE(...,'ND')` em vez de aceitar NULL.

### 3.9 Idempotência em duas camadas

O S3 pode reentregar o mesmo evento e o Lambda pode reprocessar depois de uma
falha parcial. A proteção é dupla:

1. `silver.ingestao_controle` registra cada objeto Bronze já processado;
2. constraints `UNIQUE (device_id, registrado_em)` em `leituras_fadiga` e
   `UNIQUE (motorista_id, disparado_em, tipo)` em `alertas`, com
   `ON CONFLICT DO NOTHING`.

Assim, reprocessar o bucket inteiro de propósito é seguro.

### 3.10 Elastic IP no dashboard

O Learner Lab **para as instâncias ao fim de cada sessão**. Sem EIP, o IP público
mudaria a cada retomada e o link entregue à banca deixaria de funcionar.

### 3.11 Buckets S3 criados via Cloud Control (`awscc`), não `aws_s3_bucket`

Descoberto aplicando de verdade no Learner Lab. A Service Control Policy da
conta **nega explicitamente `s3:GetBucketObjectLockConfiguration`**, e o recurso
`aws_s3_bucket` chama essa API em **todo refresh**:

```
Error: reading S3 Bucket (...) object lock configuration:
AccessDenied ... with an explicit deny in a service control policy
```

Não há como desligar essa leitura, e o comportamento é o mesmo no provider 5.x
e no 6.x — ou seja, `aws_s3_bucket` é inutilizável nesta conta. O
`awscc_s3_bucket` usa a Cloud Control API, que não faz essa chamada.

Testando bucket a bucket, **só aquela chamada é negada**: versionamento,
criptografia, lifecycle, policy, bloqueio público e notificação passam todas.
Por isso a divisão ficou assim:

| O quê | Provider | Recurso |
|---|---|---|
| Criar o bucket | `awscc` | `awscc_s3_bucket` |
| Todo o resto da configuração | `aws` | `aws_s3_bucket_versioning`, `_server_side_encryption_configuration`, `_lifecycle_configuration`, `_public_access_block`, `_policy`, `_notification` |

Efeito colateral: `awscc_s3_bucket` não tem `force_destroy`, e a Cloud Control
recusa apagar bucket com objetos. Dois `null_resource` com provisioner de
destroy esvaziam os buckets antes — como eles dependem do bucket, o Terraform
os destrói primeiro, na ordem certa.

### 3.12 O pacote das Lambdas preserva os `*.dist-info`

Parece detalhe de empacotamento, mas derruba a função. O `scramp`, dependência
do `pg8000`, chama `importlib.metadata.version()` **no próprio import**. Um
build que limpa metadados para reduzir o zip produz:

```
Runtime.ImportModuleError: No package metadata was found for scramp
```

Os scripts de build removem só `__pycache__`.

---

## 4. Estrutura do repositório

```
Infra/
├── main.tf                  # orquestração dos módulos
├── variables.tf             # todas as variáveis, com o porquê de cada default
├── locals.tf                # tags, AZs, resolução de IAM
├── iam.tf                   # roles (apenas em iam_mode = self_managed)
├── outputs.tf               # endpoints, credenciais, comandos de teste
├── providers.tf / versions.tf
├── terraform.tfvars.example # copie para terraform.tfvars
├── subir.cmd / desligar.cmd # um clique no Windows: sobe ou apaga tudo (scripts/subir.ps1)
├── subir.sh / desligar.sh   # o mesmo no Linux e no WSL (scripts/subir.sh)
├── backend.tf.example       # backend S3 à mão (o subir.cmd gera o backend.tf sozinho)
├── Makefile                 # atalhos de operação
│
├── modules/
│   ├── network/             # VPC, subnets, IGW, SGs, VPC Endpoints
│   ├── storage/             # S3 Bronze + artefatos, lifecycle, upload do SQL
│   ├── database/            # RDS PostgreSQL, parameter group, SSM
│   ├── ingest/              # API Gateway + Lambda ingest
│   ├── etl/                 # Lambdas silver/gold/migrate, EventBridge, DLQ
│   ├── dashboard/           # EC2 + EIP + user_data (Node/nginx)
│   ├── ml/                  # SageMaker Notebook + autostop por ociosidade
│   └── observability/       # alarmes, SNS, dashboard do CloudWatch
│
├── lambdas/
│   ├── common/db.py         # conexão pg8000 com TLS validado e retry
│   ├── ingest/handler.py    # valida o lote e grava no Bronze
│   ├── etl_silver/handler.py# Bronze → schema silver
│   ├── etl_gold/handler.py  # REFRESH das MVs
│   └── db_migrate/handler.py# aplica os .sql do bucket de artefatos
│
├── sql/
│   ├── 01_schema_silver.sql # 12 tabelas, ENUMs, índices, triggers
│   ├── 02_views_gold.sql    # 7 MATERIALIZED VIEWs + catálogo
│   ├── 03_seed_demo.sql     # dados sintéticos de demonstração
│   └── 04_refresh_gold.sql  # primeira carga das MVs
│
├── scripts/
│   ├── build_lambdas.ps1    # empacotamento (Windows)
│   └── build_lambdas.sh     # empacotamento (Linux/macOS)
│
├── examples/evento.json     # payload de exemplo da API
└── docs/arquitetura-aws.png
```

---

## 5. Pré-requisitos

| Ferramenta | Versão | Para quê |
|---|---|---|
| Terraform | ≥ 1.6 | provisionar |
| Python | ≥ 3.11 | empacotar as Lambdas (`pip install --target`) |
| AWS CLI | v2 | credenciais e comandos operacionais |
| Git | qualquer | clonar o dashboard na EC2 |

No Windows:

```bash
winget install Hashicorp.Terraform Amazon.AWSCLI Python.Python.3.12
```

---

## 6. Como rodar no AWS Academy Learner Lab

### 6.1 Pegue as credenciais da sessão

No Learner Lab, clique em **AWS Details → AWS CLI → Show**. Copie o bloco e cole
em `~/.aws/credentials`:

```ini
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

> As credenciais **expiram quando a sessão do lab termina**. Se o `apply` falhar
> com `ExpiredToken`, é só copiar o bloco novo e rodar de novo. O state continua
> válido (o `subir.cmd` já faz isso sozinho).

Confirme:

```bash
aws sts get-caller-identity
```

### 6.2 Configure as variáveis

```bash
cp terraform.tfvars.example terraform.tfvars
```

Ajuste o que interessa. O mínimo recomendado é liberar o seu IP:

```bash
curl -s https://checkip.amazonaws.com
```

e colocar em `admin_cidrs = ["SEU.IP.AQUI/32"]`.

### 6.3 Provisione

```bash
terraform init
terraform plan
terraform apply
```

O `apply` executa, nesta ordem:

1. `null_resource.build_lambdas` roda `scripts/build_lambdas.ps1` (ou `.sh`):
   instala `pg8000` em `build/`, baixa o bundle de CAs do RDS e monta os pacotes;
2. cria VPC, subnets, security groups e VPC Endpoints;
3. cria os buckets e publica os `.sql` no bucket de artefatos;
4. cria o RDS **(esta etapa leva 8–12 minutos)**;
5. cria as Lambdas e o API Gateway;
6. invoca `db-migrate`, que aplica `01` → `06`: schema, views, seed e primeira
   carga das MVs;
7. sobe a EC2, que clona e builda o dashboard no `user_data`.

Tempo total típico: **12 a 18 minutos**, quase tudo esperando o RDS.

### 6.4 Pegue os endereços

```bash
terraform output resumo
terraform output -raw api_key_value
terraform output -raw db_connection_uri
terraform output -json usuarios_demo     # login e senha dos usuários de demonstração
```

### 6.5 Backend e dashboard: no mesmo `apply`

Com `deploy_aplicacao = true` (padrão), o `apply` também publica a aplicação
(`app.tf`), então **um `terraform apply` deixa o TCC pronto para usar**:

- `null_resource.deploy_backend` roda `scripts/deploy_backend.ps1` (ou `.sh`):
  `npm ci`, build e `osls deploy` do repositório
  [Drive-Guard/Backend](https://github.com/Drive-Guard/Backend) (Lambdas e rotas na API);
- `null_resource.publicar_site` builda o dashboard (repositório Site) e publica no S3;
  a EC2 pega a versão nova em até 1 minuto.

Pré-requisitos: os repositórios clonados lado a lado (`../Backend` e
`../Site/driveguard-codigo`, ajustáveis em `backend_dir` e `site_dir`) e Node.js 22+
no `PATH`. Só a infraestrutura: `terraform apply -var deploy_aplicacao=false`.
No `destroy`, o stack do backend é apagado antes da API.

O simulador de frota (`enable_simulador = true`, padrão) mantém os turnos de agora
recebendo leituras a cada minuto (ver "Dados de demonstração", na seção 8).

### 6.6 Entrar no dashboard

```bash
terraform output -raw dashboard_url
terraform output -json usuarios_demo     # admin, gestor e operador, com senha gerada
```

### Cofre de segredos do grupo

A chave da IA (Gemini) e o usuário de teste ficam **versionados e cifrados** em
`segredos/segredos.tfvars.enc` (AES-256, chave derivada da senha do grupo por
PBKDF2-SHA256 com 200 mil iterações; mesmo formato do `openssl`). Quem tem a senha:

```bash
./scripts/segredos.ps1 -Abrir     # (ou ./scripts/segredos.sh abrir) cria segredos.auto.tfvars
terraform apply                   # o Terraform lê o segredos.auto.tfvars sozinho
```

Para mudar um segredo: edite o `segredos.auto.tfvars`, rode `-Fechar` (ou `fechar`) e
faça o commit do `.enc`. A senha pode vir em `DG_SEGREDOS_SENHA` (sem digitar). O
arquivo aberto (`*.auto.tfvars`) nunca vai para o git. A senha do cofre não fica em
lugar nenhum do repositório: combinem entre vocês.

Sem o cofre, dá para definir os mesmos valores à mão no `terraform.tfvars` local:

```hcl
usuario_teste = {
  email = "teste@driveguard.dev"
  nome  = "Usuário de Teste"
  papel = "admin"
  senha = "a-senha-que-voce-quiser"
}
senha_tamanho_minimo  = 8      # política do Cognito (padrão 10)
senha_exige_maiuscula = false  # padrão true
```

### 6.7 Credenciais novas do Learner Lab: subir tudo e injetar meses de dados

O Learner Lab troca as credenciais a cada sessão e pode acabar os créditos. Para
recomeçar numa conta nova (ou no dia da apresentação):

```bash
# 1. credenciais novas em ~/.aws/credentials
terraform apply                       # sobe tudo, inclusive backend e dashboard
./scripts/injetar_dados.ps1           # (ou .sh) um ano de operação simulada
./scripts/injetar_dados.ps1 -Dias 180 # 6 meses
```

`injetar_dados` apaga a frota de demonstração e roda a simulação de novo,
ancorada na data de hoje (os turnos "de agora" ficam atuais), atualiza as views Gold e
pede uma rodada nova de insights. A base da PRF fica como está. Rode no dia da
apresentação.

---

## 7. Testes locais

Os testes do ETL rodam contra um PostgreSQL 16 de verdade (o mesmo motor do RDS):

```bash
cd ../Backend && npm run db:local        # outro terminal: localhost:54329
cd ../Infra && python -m pytest tests    # migrações, ETL Silver, PRF, simulador
```

## 7b. Validando a esteira ponta a ponta

> Esta infraestrutura já foi aplicada de verdade num AWS Academy Learner Lab
> (`us-east-1`, 92 recursos). O que foi confirmado rodando:
>
> | Etapa | Resultado |
> |---|---|
> | `terraform apply` | `Apply complete!` sem erro |
> | Migração do schema | 4 scripts SQL aplicados, 0 erros, seed incluído |
> | `GET /v1/health` | `{"status": "ok", "servico": "driveguard-ingest"}` |
> | `POST /v1/eventos` | HTTP 202, 3 leituras e 1 alerta aceitos, gravados no Bronze |
>
> O DDL completo (12 tabelas Silver + 7 MATERIALIZED VIEWs) roda em PostgreSQL
> real — não só no parser.


### 7.1 A API responde?

```bash
curl "$(terraform output -raw api_invoke_url)/health"
```

Esperado: `{"status": "ok", "servico": "driveguard-ingest"}`

### 7.2 Enviar um lote de eventos

```bash
curl -X POST "$(terraform output -raw api_eventos_endpoint)" \
  -H "x-api-key: $(terraform output -raw api_key_value)" \
  -H "Content-Type: application/json" \
  -d @examples/evento.json
```

Esperado: HTTP 202 com `ingest_id` e `bronze_key`.

### 7.3 O objeto chegou ao Bronze?

```bash
aws s3 ls "s3://$(terraform output -raw bronze_bucket)/eventos/" --recursive
```

### 7.4 O ETL Silver processou?

```bash
aws logs tail "/aws/lambda/$(terraform output -json lambdas | jq -r .etl_silver)" --since 5m
```

Procure por `Silver atualizada: key=... leituras=3 alertas=1`.

### 7.5 Os dados estão no banco?

Com `db_publicly_accessible = true` e o seu IP em `admin_cidrs`:

```bash
psql "$(terraform output -raw db_connection_uri)" \
  -c "SELECT estado, COUNT(*) FROM silver.leituras_fadiga GROUP BY estado;"
```

### 7.6 O Gold atualizou?

O EventBridge dispara a cada 5 minutos. Para não esperar:

```bash
aws lambda invoke \
  --function-name "$(terraform output -json lambdas | jq -r .etl_gold)" \
  --payload '{}' --cli-binary-format raw-in-base64-out /dev/stdout
```

Esperado: `{"views_atualizadas": 7, ...}` com a duração de cada view.

### 7.7 O dashboard está no ar?

```bash
curl -I "$(terraform output -raw dashboard_url)"
```

Enquanto o site não for publicado (`scripts/publicar_site.*`), a EC2 mostra uma
página de espera. Para acompanhar o bootstrap:

```bash
aws ssm start-session --target "$(terraform output -raw dashboard_instance_id)"
sudo tail -f /var/log/driveguard-bootstrap.log
```

---

## 8. Modelo de dados

Arquitetura **Medallion** em três camadas.

### Bronze — S3

JSON cru, imutável, versionado, particionado por data e hora:

```
s3://driveguard-dev-bronze-<sufixo>/eventos/dt=2026-03-14/hr=03/dg-edge-0001/<ts>-<uuid>.json
```

Cada objeto é um envelope com `ingest_id`, `ingest_timestamp`, IP de origem e o
`payload` original intacto. A Silver pode ser reconstruída do zero a partir daqui.

### Silver — `schema silver`

| Grupo | Tabelas |
|---|---|
| Frota | `empresas`, `usuarios`, `veiculos`, `motoristas`, `turnos`, `leituras_fadiga`, `alertas`, `acoes_motorista` |
| Cadastros | `dispositivos` (câmeras), `vinculos_dispositivo_veiculo` (histórico câmera ↔ caminhão), `rotas`, `viagens`, `dim_uf` |
| ROI | `parametros_roi_padrao` (valor + fonte de cada número), `parametros_roi` (valores da empresa) |
| IA e relatórios | `insights_frota`, `insights_motorista`, `insights_execucoes`, `relatorios_gerados`, `agendamentos_relatorio` |
| PRF | `incidentes` (`origem='prf'` ou interna), `incidentes_veiculos`, `prf_veiculos_staging`, `prf_cargas` |
| Controle | `ingestao_controle`, `previsoes_fadiga` |

O ETL Silver resolve a câmera pelo `device_id` e, pelo vínculo vigente na hora da
leitura, o caminhão e a empresa. Câmera nunca vista entra como **pendente** para o
gestor associar. O turno é casado com a viagem cadastrada para o caminhão, de onde
vêm origem, destino e distância.

### Gold — `schema gold` (11 MATERIALIZED VIEWs)

Guardam **somas e contagens** (a API recompõe as médias), têm `empresa_id` e usam o
fuso de Brasília.

| View | Uso |
|---|---|
| `mv_kpis_diarios` | KPIs, evolução da fadiga, relatórios |
| `mv_alertas_agregados` | Horário crítico, sinais detectados, alertas atendidos |
| `mv_fadiga_por_tempo_direcao` | Tendência no turno, heatmap, fadiga × tempo de direção |
| `mv_curva_fadiga_turno` | Curva do turno de cada motorista |
| `mv_ranking_motoristas` | Lista e indicadores de 30 dias dos motoristas |
| `mv_rotas_desempenho` | Rotas com maior incidência |
| `mv_prf_faixa_horaria`, `mv_prf_causas_mes`, `mv_prf_hotspots`, `mv_prf_trechos`, `mv_prf_perfil_sono` | Base comparativa da PRF e parâmetros do ROI |

As views da frota são atualizadas pela `etl-gold` a cada 5 minutos; as da PRF pela
`prf-carga`, quando chega arquivo novo. `gold.vw_frota_agora` é uma view comum,
lida na hora, para o estado ao vivo.

### Dados de demonstração

Com `seed_demo_data = true` (padrão), o banco nasce com 1 empresa (UUID fixo, o mesmo
dos usuários do Cognito), 16 motoristas (`DRV-1000`…), 16 veículos com câmera (uma
delas com histórico de troca), 8 rotas com as BRs e **meses de operação simulada**
(`seed_dias_historico`, padrão 365 dias). Não são números soltos: o seed simula a
frota dia a dia e cada tabela é consequência da anterior.

- **Perfis**: suscetibilidade à fadiga por motorista, saída de madrugada (4
  caminhoneiros de rota longa), à tarde (ônibus) ou de manhã, escala 5x2.
- **Fadiga** = horas sem pausa × suscetibilidade + horas de turno + ritmo circadiano
  (pico às 4h, queda depois do almoço) + dívida de sono + ruído com memória.
  Estados em três níveis, como o modelo do repositório ML: alerta (< 40), fadiga
  (40–70), sonolento (≥ 70); as features (EAR, PERCLOS, piscadas, bocejo, cabeça)
  saem do score.
- **Alertas** quando entra em sonolento (tipo pelo sinal dominante), mais distração e
  perda de face.
- **Três fases**, como uma implantação de verdade:
  - **piloto** (primeiro quarto do ano): só o alarme na cabine;
  - **central** (segundo quarto): a central atende os graves com pausa obrigatória,
    liga nos médios, encerra o turno no segundo crítico; parada a cada 4h30;
  - **programa** (metade recente): programa de gestão da fadiga depois dos acidentes:
    madrugada limitada a 8 h com parada a cada 3h30, parada a cada 4 h para todos,
    escala revisada e **treinamento individual** dos mais suscetíveis (a fadiga
    deles cai nas semanas seguintes; a ação fica registrada e marcada como eficaz
    quando a média dos 30 dias seguintes cai).

  A pausa zera as horas sem pausa, então a fadiga cai de verdade fase a fase (na
  simulação padrão, a média mensal sai de ~35 para ~25 e as leituras sonolentas de
  ~7% para menos de 0,5%).
- **Acidentes da frota** pelo risco acumulado (cresce ao cubo acima de score 75):
  acontecem onde houve detecção forte sem intervenção, quase sempre no piloto, e
  interrompem o turno no ponto da rota onde o veículo está. Há também acidentes sem
  relação com sono (risco de base, maior com distração).
- **Quase-acidentes** (ocorrência sem gravidade: saída de faixa, quase colisão) com
  fadiga muito alta: bem mais comuns que os acidentes; na operação a central manda
  parar em seguida.
- **ROI**: `acidentes_ano_frota` é a taxa anual da fase piloto calculada pela própria
  simulação.

A escala (saída, duração, folgas, paradas) é determinística pela data, e a Lambda
simulador usa a mesma conta, nas regras da fase atual: o turno que o seed deixa
aberto agora é o mesmo que o simulador continua, e as leituras param quando o turno
acaba.

**Dados ao vivo (simulador):** a Lambda `simulador` é disparada pelo EventBridge a cada
minuto e envia as leituras dos motoristas em turno para a API de ingestão real (daí
em diante é o caminho de produção). Para ligar ou desligar sem Terraform:

```bash
./scripts/dados_ao_vivo.ps1             # (ou .sh status) estado atual
./scripts/dados_ao_vivo.ps1 -Desligar   # (ou .sh desligar) só o histórico
./scripts/dados_ao_vivo.ps1 -Ligar      # (ou .sh ligar)
```

O estado inicial vem de `dados_ao_vivo` (padrão `true`); o `apply` seguinte não desfaz
a escolha feita pelo script. Desligado, o dashboard mostra o histórico e nada
"dirigindo agora" (os turnos da hora da injeção somem do "ao vivo" em 30 minutos).

**Fontes do ROI:** os custos por acidente são os do IPEA/PRF (2015, base dez/2014),
os mais recentes publicados por gravidade para rodovias federais, corrigidos pelo
IPCA até o último mês disponível (Banco Central, SGS 433), o mesmo método da
atualização simplificada do próprio IPEA (2020). As proporções de gravidade e as
mortes por acidente vêm da PRF (5 anos carregados, `prf_anos`). Acidentes da PRF não
são inventados: vêm da base real, carregada no próprio `apply`.

Para conferir os números: `cd ../Backend && npx tsx scripts/estatisticas-seed.ts`
(banco local) ou com `DATABASE_URL` apontando para outro banco.

---

## 9. Custo

Estimativa para `us-east-1`, com os defaults deste repositório.

| Recurso | Configuração | ~US$/mês |
|---|---|---|
| RDS PostgreSQL | db.t3.micro, 20 GB gp3, single-AZ | ~15 |
| EC2 dashboard | t3.small ligada 24/7 | ~15 |
| VPC Endpoint (Logs) | 2 ENIs | ~15 |
| Elastic IP | associado a instância ligada | 0 |
| S3 | poucos GB | < 1 |
| Lambda | dentro do free tier | ~0 |
| API Gateway | < 1M requisições | ~0 |
| CloudWatch | logs + alarmes + dashboard | ~2 |
| **Total com tudo ligado** | | **~48** |
| SageMaker *(opcional)* | ml.t3.medium, só quando ligado | ~0,05/h |
| NAT Gateway *(desligado)* | se habilitado | ~32 |

Com o orçamento de **US$100** do Learner Lab, o ambiente completo dura cerca de
dois meses ligado direto. Como reduzir:

- **desligue (destrua) ao fim de cada sessão de trabalho** — parar EC2 e
  RDS não basta, ver [seção 10](#10-ligar-e-desligar);
- `enable_vpc_interface_endpoints = false` economiza ~US$15/mês, mas as Lambdas
  privadas param de emitir log — só faça isso depois que o pipeline estiver
  estável;
- mantenha `enable_sagemaker = false` fora dos dias de treino.

---

## 10. Ligar e desligar

**O liga/desliga deste projeto é o próprio Terraform.** Não existe "pausar".

| Ação | Windows | Linux/macOS/Git Bash | Tempo |
|---|---|---|---|
| **Ligar** | `subir.cmd` (ou `terraform apply`) | `./subir.sh` (ou `make up`) | ~15 min |
| **Desligar** | `desligar.cmd` (ou `./scripts/desligar.ps1`) | `./desligar.sh` (ou `make down`) | ~15 min |
| Conferir o que existe | — | `make custos` | segundos |

Desligar **apaga tudo, inclusive o banco e os buckets**. Ao ligar de novo, o
schema é recriado e o seed de demonstração repovoa o banco — então o dashboard
volta com dados, só não os mesmos.

O `desligar` não confia só no `destroy`: depois dele, consulta a conta e lista
qualquer EC2, RDS, VPC Endpoint, Elastic IP, NAT, notebook SageMaker, bucket ou
VPC do projeto que ainda exista. Sai com erro se encontrar algo.

### Por que não "parar"

Uma versão anterior deste repositório tinha `make stop`, que parava EC2 e RDS
e removia os VPC Endpoints, preservando os dados. **Ela deixou o ambiente
ligado e consumiu US$30 do lab**, por três motivos que nenhum script de stop
contorna:

- **o RDS religa sozinho depois de 7 dias parado** — é regra da AWS, não
  configurável;
- **o Start Lab religa a EC2** a cada nova sessão do Academy;
- **VPC Endpoint, Elastic IP e discos cobram mesmo com tudo parado**.

Por isso foi removido. Desligar = destruir.

### E quando houver dados que precisam sobreviver

Hoje o banco só tem dados sintéticos do seed, então perder tudo no destroy é
aceitável. Quando houver dados reais, a saída é separar o que persiste do que
é computação:

- exportar a Silver para um bucket fora deste Terraform antes do destroy, e
  reimportar no apply;
- ou mover a persistência para um serviço sem custo ocioso no plano do
  estudante.

Isso fica para quando existir o dado.

---

## 11. Operação do dia a dia

Com `make` (Git Bash ou WSL):

```bash
make help          # lista os alvos
make output        # resumo da infra
make creds         # API Key, usuário e senha do banco
make test-api      # envia examples/evento.json
make refresh-gold  # força o refresh das MVs agora
make logs-silver   # acompanha o ETL Silver
make migrate       # reaplica o DDL (sem seed)
make seed          # reaplica o DDL com seed
make db-shell      # abre o psql
```

Sem `make`, os equivalentes em AWS CLI estão no próprio
[`Makefile`](Makefile) e na seção 7.

### Reprocessar um objeto do Bronze

O trigger é `s3:ObjectCreated:*`. Para reprocessar, basta copiar o objeto sobre
si mesmo:

```bash
BUCKET=$(terraform output -raw bronze_bucket)
KEY=eventos/dt=2026-03-14/hr=03/dg-edge-0001/arquivo.json
aws s3 cp "s3://$BUCKET/$KEY" "s3://$BUCKET/$KEY" --metadata-directive REPLACE
```

O ETL vai reprocessar e, graças às constraints UNIQUE, **não duplicar nada**.

### Atualizar o schema

Edite os arquivos em `sql/` e rode `terraform apply`. O hash do diretório muda,
`aws_lambda_invocation` reexecuta a migração e o DDL é reaplicado — todos os
scripts são idempotentes.

---

## 12. Segurança e LGPD

O ponto de partida é **privacy by design**: o vídeo é processado e descartado no
veículo. Nenhuma imagem facial trafega pela rede nem chega à AWS — só métricas
numéricas.

O que a infraestrutura garante:

| Controle | Onde |
|---|---|
| Identificadores irreversíveis (`motorista_hash`, `placa_hash`, `cnpj_hash`) | schema silver |
| S3 cifrado em repouso (SSE-S3) + bucket policy negando tráfego sem TLS | `modules/storage` |
| RDS cifrado em repouso + `rds.force_ssl = 1` no parameter group | `modules/database` |
| TLS do RDS **validado contra o bundle oficial de CAs**, sem downgrade | `lambdas/common/db.py` |
| Banco e Lambdas de ETL em subnet privada, sem rota para a internet | `modules/network` |
| RDS só aceita 5432 vindo dos Security Groups das Lambdas e do dashboard | `modules/network` |
| API protegida por API Key com throttling e quota | `modules/ingest` |
| Senha gerada pelo Terraform, guardada como `SecureString` no SSM | `modules/database` |
| IMDSv2 obrigatório na EC2 | `modules/dashboard` |
| Acesso público bloqueado nos dois buckets | `modules/storage` |
| Permissões mínimas por serviço documentadas em código | `iam.tf` |

**Atenção ao `terraform.tfstate`:** ele guarda a senha do RDS e a API Key em texto
claro. O `.gitignore` já o exclui, então não versione. O `subir.cmd` guarda o
state no S3 da conta do lab, com `encrypt = true`, versionamento e acesso
público bloqueado.

---

## 13. Solução de problemas

| Sintoma | Causa | Solução |
|---|---|---|
| `ExpiredToken` / `InvalidClientTokenId` | Sessão do Learner Lab expirou | Copie as credenciais novas em **AWS Details → AWS CLI** |
| `explicit deny in an identity-based policy: voc-cancel-cred` | A **sessão do lab foi encerrada** — o Academy anexa essa policy e bloqueia quase tudo | Reinicie o lab (**Start Lab**) e atualize as credenciais |
| `AccessDenied` em `iam:CreateRole` | `iam_mode = "self_managed"` no Learner Lab | Volte para `iam_mode = "learner_lab"` |
| `NoSuchEntity: LabRole` | Conta AWS própria, sem a role do Academy | Use `iam_mode = "self_managed"` |
| `InvalidParameterValueException: ReservedConcurrentExecutions` | Cota de concorrência baixa na conta | `lambda_reserve_concurrency = false` |
| `No package metadata was found for scramp` | O build removeu os `*.dist-info` | Refaça o build com os scripts atuais (ver 3.12) |
| `reading S3 Bucket ... object lock configuration: AccessDenied` | Usou `aws_s3_bucket` numa conta com o SCP do Academy | Use `awscc_s3_bucket` (ver 3.11) |
| `Cannot find version 16.4 for postgres` | A conta não oferece essa minor version | `aws rds describe-db-engine-versions --engine postgres` e ajuste `db_engine_version` |
| `rds-ca-bundle.pem nao encontrado` | O build não rodou | `./scripts/build_lambdas.ps1` (ou `.sh`) |
| Lambda de ETL dá timeout sem log | Sem NAT e sem VPC Endpoint de Logs | `enable_vpc_interface_endpoints = true` |
| `db-migrate` falha ao conectar | ENI da Lambda ainda subindo | O handler já faz 6 tentativas com backoff; se persistir, `terraform apply` de novo |
| `REFRESH ... contains duplicate rows` | Alguma MV com dimensão NULL | Verifique os `COALESCE` em `sql/02_views_gold.sql` |
| Dashboard mostra a página de status | O `git clone` falhou (repo privado) | Use um repo público, ou faça o deploy manual via SSM |
| Dashboard não abre | Build do Node ainda rodando | `sudo tail -f /var/log/driveguard-bootstrap.log` |
| MVs vazias após o apply | Seed desligado | `make seed` |

Onde olhar primeiro:

```bash
aws logs tail /aws/lambda/driveguard-dev-db-migrate --since 30m
aws logs tail /aws/lambda/driveguard-dev-etl-silver --since 30m
aws logs tail /aws/lambda/driveguard-dev-etl-gold   --since 30m
```

---

## 14. Destruindo o ambiente

```bash
terraform destroy
```

Com os defaults (`force_destroy_buckets = true`, `skip_final_snapshot = true`,
`db_deletion_protection = false`), o destroy remove tudo, inclusive buckets com
objetos dentro. Leva cerca de 10 minutos, quase tudo apagando o RDS.

> Prefira `desligar.cmd` (ou `./scripts/desligar.ps1`, `make down`): além do destroy, ele
> confere que nada do projeto ficou cobrando na conta. Ver [seção 10](#10-ligar-e-desligar).

---

## 15. Limitações conhecidas

Coisas que este repositório **não** faz, e por quê:

- **Sem HTTPS no dashboard.** A EC2 serve HTTP na porta 80. Um certificado exigiria
  domínio próprio (ACM + Route 53) ou um ALB, e nenhum dos dois cabe no orçamento
  do lab. Para a banca, HTTP no Elastic IP resolve.
- **Sem alta disponibilidade.** RDS single-AZ, uma EC2, sem Auto Scaling. A VPC
  tem duas AZs e o subnet group está pronto para Multi-AZ (`db_multi_az = true`),
  mas ligar isso dobra o custo do banco.
- **Sem rotação de credenciais.** A senha do RDS é gerada uma vez no `apply`.
- **Sem CI/CD.** Não há pipeline rodando `terraform plan` em pull request.
- **O dashboard é buildado no boot da EC2.** Para produção, o correto seria um
  artefato versionado no S3 ou uma imagem de container, não `git clone` + `npm
  build` em cada boot.
- **O modelo de ML não é treinado aqui.** O módulo `ml` provisiona o notebook; o
  treino e o registro do modelo ficam nos repositórios `Drive-Guard/ML` e
  `Drive-Guard/ETL`.
- **`enable_apigw_access_logs` vem desligado.** Ligar exige configurar
  `aws_api_gateway_account`, que é um ajuste **global da conta** — em um lab
  compartilhado, isso afeta outros alunos.

---

## Repositórios relacionados

| Repositório | Conteúdo |
|---|---|
| [`Drive-Guard/Infra`](https://github.com/Drive-Guard/Infra) | Este repositório |
| [`Drive-Guard/Backend`](https://github.com/Drive-Guard/Backend) | API da dashboard e trabalhos agendados (TypeScript + osls) |
| [`Drive-Guard/Site`](https://github.com/Drive-Guard/Site) | Dashboard (React, SPA estática) |
| [`Drive-Guard/ML`](https://github.com/Drive-Guard/ML) | Detecção de sonolência e acidentes |
| [`Drive-Guard/ETL`](https://github.com/Drive-Guard/ETL) | Tratamento dos dados abertos da PRF |

---

## Equipe

Vinicius Cirello · Caetano Domingues · Raphael Klein · Amanda Cupola ·
Emily Ferreira · Danilo Marques — TCC 2026.
