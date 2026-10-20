"""
Gera docs/arquitetura-aws.svg, o diagrama de arquitetura do README.

O desenho é código para continuar fiel ao Terraform: quando um recurso mudar,
ajuste aqui e rode de novo. Só usa a biblioteca padrão.

    python docs/gerar_diagrama.py

O PNG do README sai do SVG, em resolução dobrada (Inkscape, ou abra o SVG no
navegador e exporte):

    inkscape docs/arquitetura-aws.svg -o docs/arquitetura-aws.png -d 192
"""

from html import escape
from pathlib import Path

L, A = 1800, 1130  # largura e altura do desenho

# Cores das categorias dos ícones oficiais da AWS.
COR = {
    "compute": "#ED7100",
    "storage": "#7AA116",
    "database": "#C925D1",
    "network": "#8C4FFF",
    "integration": "#E7157B",
    "security": "#DD344C",
    "externo": "#5F6B7A",
}
FLUXO = {
    "ingestao": "#E8590C",
    "gestor": "#1C7ED6",
    "prf": "#2F9E44",
    "ia": "#9C36B5",
    "evento": "#6B7280",
}

partes: list[str] = []


def add(s: str) -> None:
    partes.append(s)


def texto(x, y, conteudo, tam=13, peso=400, cor="#1F2933", ancora="start", italico=False):
    estilo = ' font-style="italic"' if italico else ""
    add(f'<text x="{x}" y="{y}" font-size="{tam}" font-weight="{peso}" fill="{cor}" '
        f'text-anchor="{ancora}"{estilo}>{escape(conteudo)}</text>')


def caixa(x, y, w, h, titulo, borda, fundo, tracejado=False, cor_titulo=None):
    traco = ' stroke-dasharray="6 5"' if tracejado else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{fundo}" '
        f'stroke="{borda}" stroke-width="1.6"{traco}/>')
    if titulo:
        texto(x + 14, y + 22, titulo, 13, 700, cor_titulo or borda)


def card(x, y, w, h, cat, glifo, titulo, linhas=(), destaque=False):
    cor = COR[cat]
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="#FFFFFF" '
        f'stroke="{cor if destaque else "#CBD2D9"}" stroke-width="{2 if destaque else 1.2}"/>')
    add(f'<rect x="{x + 10}" y="{y + 10}" width="34" height="34" rx="7" fill="{cor}"/>')
    tam = 18 if len(glifo) == 1 else (12 if len(glifo) <= 3 else 10)
    texto(x + 27, y + 27 + tam * 0.35, glifo, tam, 700, "#FFFFFF", "middle")
    texto(x + 54, y + 24, titulo, 13.5, 700)
    for i, linha in enumerate(linhas):
        texto(x + 54, y + 42 + i * 16, linha, 11.5, 400, "#52606D")


def chip(x, y, w, cat, glifo, rotulo):
    cor = COR[cat]
    add(f'<rect x="{x}" y="{y}" width="{w}" height="34" rx="17" fill="#FFFFFF" stroke="#CBD2D9"/>')
    add(f'<circle cx="{x + 17}" cy="{y + 17}" r="11" fill="{cor}"/>')
    texto(x + 17, y + 21, glifo, 9 if len(glifo) > 2 else 11, 700, "#FFFFFF", "middle")
    texto(x + 34, y + 22, rotulo, 11.5, 600, "#323F4B")


def seta(pontos, fluxo, tracejado=False, rotulo=None, pos_rotulo=None, ancora="middle", duas_pontas=False):
    cor = FLUXO[fluxo]
    d = "M " + " L ".join(f"{px} {py}" for px, py in pontos)
    traco = ' stroke-dasharray="7 5"' if tracejado else ""
    inicio = f' marker-start="url(#ini-{fluxo})"' if duas_pontas else ""
    add(f'<path d="{d}" fill="none" stroke="{cor}" stroke-width="2.2"{traco} '
        f'stroke-linejoin="round" marker-end="url(#fim-{fluxo})"{inicio}/>')
    if rotulo:
        rx, ry = pos_rotulo
        largura = 6.3 * len(rotulo) + 12
        bx = rx - largura / 2 if ancora == "middle" else (rx if ancora == "start" else rx - largura)
        add(f'<rect x="{bx}" y="{ry - 13}" width="{largura}" height="18" rx="9" fill="#FFFFFF" '
            f'stroke="{cor}" stroke-width="1"/>')
        texto(bx + largura / 2, ry, rotulo, 11, 600, cor, "middle")


def numero(x, y, n, fluxo):
    add(f'<circle cx="{x}" cy="{y}" r="11" fill="{FLUXO[fluxo]}"/>')
    texto(x, y + 4, str(n), 12, 700, "#FFFFFF", "middle")


# --------------------------------------------------------------------------
# Cabeçalho, marcadores de seta e fundo
# --------------------------------------------------------------------------
add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{L}" height="{A}" viewBox="0 0 {L} {A}" '
    'font-family="Segoe UI, Helvetica Neue, Arial, sans-serif">')
add("<defs>")
for nome, cor in FLUXO.items():
    add(f'<marker id="fim-{nome}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        f'orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="{cor}"/></marker>')
    add(f'<marker id="ini-{nome}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        f'orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="{cor}"/></marker>')
add("</defs>")
add(f'<rect width="{L}" height="{A}" fill="#FFFFFF"/>')
texto(20, 42, "DriveGuard — Arquitetura AWS", 26, 700, "#102A43")
texto(20, 66, "Detecção de sonolência em motoristas de caminhão e ônibus · us-east-1 · AWS Academy "
      "Learner Lab · tudo provisionado por Terraform (repositório Infra)", 13.5, 400, "#52606D")

# --------------------------------------------------------------------------
# Fora da AWS: veículo e gestor (esquerda), internet (direita)
# --------------------------------------------------------------------------
caixa(20, 100, 275, 306, "VEÍCULO (edge, fora da AWS)", "#829AB1", "#F5F7FA", tracejado=True, cor_titulo="#486581")
card(34, 134, 247, 62, "externo", "CAM", "Câmera IR/RGB · 30 fps", ["webcam no protótipo"])
card(34, 204, 247, 108, "externo", "ML", "Modelo (repositório ML)",
     ["MediaPipe Face Mesh (468 pts)", "EAR, MAR, PERCLOS, pose", "classificador de 3 estados:", "alerta · fadiga · sonolento"])
card(34, 320, 247, 72, "externo", "!", "Alerta na cabine",
     ["funciona sem rede", "buffer local; envia lotes HTTPS"])

caixa(20, 430, 275, 140, "GESTOR DE FROTA", "#829AB1", "#F5F7FA", tracejado=True, cor_titulo="#486581")
card(34, 464, 247, 92, "externo", "WEB", "Navegador",
     ["dashboard (React, build estático)", "login no Cognito", "chama a API com o token JWT"])

caixa(1585, 100, 195, 290, "INTERNET", "#829AB1", "#F5F7FA", tracejado=True, cor_titulo="#486581")
card(1597, 134, 171, 92, "externo", "PRF", "Dados abertos",
     ["PRF: acidentes", "(Google Drive)", "Banco Central: IPCA"])
card(1597, 290, 171, 76, "externo", "AI", "Google Gemini", ["insights da IA", "(camada gratuita)"])

# --------------------------------------------------------------------------
# AWS
# --------------------------------------------------------------------------
caixa(320, 100, 1240, 940, "AWS CLOUD · us-east-1", "#232F3E", "#FFFFFF", cor_titulo="#232F3E")
texto(1544, 122, "conta do AWS Academy Learner Lab (só a LabRole)", 11.5, 400, "#52606D", "end")

# Serviços regionais (fora da VPC)
caixa(340, 138, 1200, 262, "SERVIÇOS REGIONAIS (fora da VPC)", "#9FB3C8", "#F8FAFC", cor_titulo="#486581")
COL = {"A": 360, "B": 600, "C": 840, "D": 1080, "E": 1320}
W = 200
card(COL["A"], 172, W, 76, "integration", "API", "API Gateway REST",
     ["POST /v1/eventos", "API Key + usage plan"], destaque=True)
card(COL["B"], 172, W, 76, "compute", "λ", "Lambda ingest", ["valida o lote", "grava o JSON cru"])
card(COL["C"], 172, W, 76, "storage", "S3", "S3 Bronze", ["JSON imutável por dia", "versionado e cifrado"], destaque=True)
card(COL["D"], 172, W, 76, "compute", "λ", "Lambda prf-download", ["semanal (EventBridge)", "baixa PRF e IPCA"])
card(COL["E"], 172, W, 76, "storage", "S3", "S3 artefatos",
     ["build do site, SQL, deploy", "troca de insights/relatórios"])

card(COL["A"], 296, W, 76, "compute", "λ", "Lambda simulador", ["a cada 1 min (demo)", "faz o papel das câmeras"])
card(COL["B"], 296, W, 76, "security", "ID", "Cognito", ["User Pool", "admin / gestor / operador"])
card(COL["D"], 296, W, 76, "integration", "API", "API Gateway HTTP",
     ["rotas do Backend", "autorizador JWT (Cognito)"], destaque=True)
card(COL["E"], 296, W, 76, "compute", "λ", "Backend fora da VPC",
     ["insightsIa (Gemini)", "usuarios · relatorioEnviar"])

# VPC
caixa(340, 425, 1200, 520, "VPC 10.0.0.0/16 · 2 AZs · sem NAT Gateway", COR["network"], "#FBF8FF")
caixa(360, 458, 1160, 108, "Subnets públicas · 10.0.1.0/24, 10.0.3.0/24", "#7AA116", "#F6FBEF")
card(380, 492, 270, 64, "compute", "EC2", "EC2 dashboard · t3.micro",
     ["nginx + Elastic IP", "copia o site do S3 a cada minuto"], destaque=True)

caixa(360, 582, 1160, 350, "Subnets privadas · 10.0.2.0/24, 10.0.4.0/24", "#1C7ED6", "#F3F8FE")
caixa(376, 626, 400, 236, "ETL · Python 3.12", "#9FB3C8", "#FFFFFF", cor_titulo="#486581")
card(388, 660, 182, 72, "compute", "λ", "prf-carga", ["evento S3 (prf/)", "carrega a PRF"])
card(582, 660, 182, 72, "compute", "λ", "etl-silver", ["evento S3 (eventos/)", "normaliza no Silver"], destaque=True)
card(388, 742, 182, 72, "compute", "λ", "db-migrate", ["no terraform apply", "schema + seed"])
card(582, 742, 182, 72, "compute", "λ", "etl-gold", ["a cada 5 min", "REFRESH das MVs"])
texto(390, 840, "Falhas do ETL → fila SQS (DLQ) + alarme no CloudWatch", 11.5, 400, "#52606D")

card(816, 672, 248, 132, "database", "RDS", "RDS PostgreSQL 16",
     ["db.t3.micro · TLS obrigatório", "silver: frota, cadastros, PRF", "gold: 11 materialized views",
      "advisory locks entre cargas"], destaque=True)

caixa(1104, 626, 400, 236, "Backend · Node.js 22", "#9FB3C8", "#FFFFFF", cor_titulo="#486581")
card(1116, 660, 376, 80, "compute", "λ", "API: dashboard · motoristas · alertas",
     ["relatórios (PDF, Excel, CSV) · cadastros", "uma Lambda por domínio, atrás do", "autorizador JWT"])
card(1116, 750, 376, 104, "compute", "λ", "Workers",
     ["insightsContexto (1 h) e insightsGravar", "agendamentos de relatório (15 min)",
      "relatorioStatus · trocam arquivos com o", "S3 artefatos (evento → EventBridge)"])

chip(388, 880, 210, "network", "S3", "Gateway Endpoint · S3")
chip(612, 880, 290, "network", "EP", "Interface Endpoint · CloudWatch Logs")
chip(916, 880, 300, "network", "SG", "Security groups: Lambdas → RDS 5432")

# Serviços de apoio
texto(340, 978, "SERVIÇOS DE APOIO", 12, 700, "#486581")
apoio = [
    (476, 150, "security", "IAM", "LabRole (todas)"),
    (636, 200, "integration", "EB", "EventBridge (agendas)"),
    (846, 210, "integration", "SSM", "SSM (config e segredos)"),
    (1066, 230, "integration", "CW", "CloudWatch (logs, alarmes)"),
    (1306, 100, "integration", "SNS", "SNS"),
    (1416, 124, "storage", "S3", "S3 tfstate"),
]
for x, w, cat, g, r in apoio:
    chip(x, 959, w, cat, g, r)
texto(340, 1022, "S3 tfstate: state compartilhado do Terraform, criado pelo subir.cmd / subir.sh "
      "(fica no desligar). SageMaker Notebook: opcional, desligado por padrão.", 11.5, 400, "#52606D")

# --------------------------------------------------------------------------
# Fluxos
# --------------------------------------------------------------------------
# 1. Ingestão: câmera -> API REST -> ingest -> Bronze -> etl-silver -> RDS
seta([(281, 165), (330, 165), (330, 210), (COL["A"], 210)], "ingestao", rotulo="HTTPS", pos_rotulo=(306, 158))
seta([(COL["A"] + W, 210), (COL["B"], 210)], "ingestao")
seta([(COL["B"] + W, 210), (COL["C"], 210)], "ingestao")
seta([(COL["A"] + 100, 296), (COL["A"] + 100, 248)], "ingestao")
seta([(870, 248), (870, 616), (700, 616), (700, 660)], "evento", tracejado=True,
     rotulo="evento S3", pos_rotulo=(870, 285))
seta([(700, 616), (540, 616), (540, 660)], "evento", tracejado=True)
seta([(764, 700), (816, 700)], "ingestao")
seta([(764, 778), (816, 778)], "ingestao")
numero(306, 130, 1, "ingestao")

# 2. Base PRF: prf-download -> internet; -> Bronze
seta([(COL["D"] + 150, 172), (COL["D"] + 150, 150), (1597, 150)], "prf", rotulo="HTTPS", pos_rotulo=(1480, 155))
seta([(COL["D"], 236), (COL["C"] + W, 236)], "prf", rotulo="prf/", pos_rotulo=(1060, 254))
numero(COL["D"] + 150, 150, 2, "prf")

# 3. Gestor: navegador -> EC2 (site), Cognito (login), API HTTP -> Backend -> RDS
seta([(281, 524), (380, 524)], "gestor", rotulo="HTTP", pos_rotulo=(306, 552))
seta([(281, 480), (332, 480), (332, 412), (700, 412), (700, 372)], "gestor")
seta([(700, 412), (1150, 412), (1150, 372)], "gestor", rotulo="JWT", pos_rotulo=(1000, 416))
seta([(1270, 372), (1270, 660)], "gestor")
seta([(1116, 700), (1064, 700)], "gestor")
seta([(1116, 778), (1064, 778)], "gestor")
numero(306, 452, 3, "gestor")
# Internet Gateway por cima da seta que entra na VPC.
add(f'<rect x="327" y="513" width="36" height="22" rx="5" fill="{COR["network"]}"/>')
texto(345, 528, "IGW", 10.5, 700, "#FFFFFF", "middle")


# 4. Insights com IA: Backend fora da VPC <-> S3 artefatos; -> Gemini
seta([(COL["E"] + W, 334), (1597, 334)], "ia", rotulo="HTTPS", pos_rotulo=(1560, 328))
seta([(COL["E"] + 100, 296), (COL["E"] + 100, 248)], "ia", tracejado=True, duas_pontas=True)
numero(COL["E"] + 120, 272, 4, "ia")

# --------------------------------------------------------------------------
# Legenda
# --------------------------------------------------------------------------
ly = 1086
add(f'<rect x="20" y="{ly - 22}" width="{L - 40}" height="52" rx="8" fill="#F5F7FA" stroke="#D9E2EC"/>')
itens = [
    ("ingestao", "1  Ingestão: câmera → Bronze → Silver"),
    ("prf", "2  Base aberta da PRF (semanal)"),
    ("gestor", "3  Gestor: site, login e API"),
    ("ia", "4  Insights com IA (via S3)"),
    ("evento", "Tracejado: disparo por evento S3 / agenda"),
]
x = 40
for fluxo, rotulo in itens:
    tracejado = ' stroke-dasharray="7 5"' if fluxo == "evento" else ""
    add(f'<line x1="{x}" y1="{ly + 4}" x2="{x + 34}" y2="{ly + 4}" stroke="{FLUXO[fluxo]}" '
        f'stroke-width="2.6"{tracejado} marker-end="url(#fim-{fluxo})"/>')
    texto(x + 44, ly + 9, rotulo, 12.5, 600, "#323F4B")
    x += 44 + 7.2 * len(rotulo) + 46

add("</svg>")

destino = Path(__file__).with_name("arquitetura-aws.svg")
destino.write_text("\n".join(partes), encoding="utf-8")
print(f"Gerado {destino}")
