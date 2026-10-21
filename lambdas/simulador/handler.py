"""
Lambda simulador — telemetria de demonstração para a dashboard.

Faz o papel das câmeras embarcadas quando não há veículo rodando: a cada
execução (EventBridge, de minuto em minuto) monta um lote por câmera no mesmo
formato do DriveGuardClient do repositório ML e envia para a API de
ingestão, com a mesma API Key dos dispositivos. Tudo o que vem depois
(Bronze, ETL Silver, views Gold) é o caminho real.

As câmeras e motoristas são os do seed (dg-edge-0001 com DRV-1000, e assim
por diante), e a escala e o modelo de fadiga são os MESMOS do seed
(sql/05_seed_demo.sql), nas regras da fase atual (programa de gestão da
fadiga): horário de saída pelo perfil, duração pela rota (madrugada limitada a
8 h), folgas 5x2, parada a cada 4 h (3h30 na madrugada) em 85% dos turnos,
escala revisada, efeito do treinamento nos motoristas mais suscetíveis, dívida
de sono e ritmo circadiano, tudo calculado a partir da data, sem sorteio. Por isso o turno que
o seed deixou aberto continua aqui sem salto, cada câmera só envia enquanto o
motorista está no turno (fora dele, e durante a parada, não há lote) e o ETL
fecha o turno quando as leituras param.

O estado segue as faixas do modelo de 3 classes: alerta (< 40), fadiga
(40 a 70) e sonolento (>= 70). Sonolento gera alerta, no máximo um a cada 20
minutos por câmera.

Frota: as 16 câmeras do seed (um ano de histórico) e as 24 da frota
ampliada (dg-edge-0017 a 0040, cadastradas no fim do seed), com saídas
espalhadas pelas 24 horas: a qualquer hora há motoristas começando, no meio
e terminando o turno.

Preenchimento pela escala: ao ser ligado (scripts/dados_ao_vivo.* manda
{"preencher": true}), ao fim do subir e a cada 15 minutos, confere cada turno
da escala (de cada câmera, até PREENCHER_MAX_DIAS para trás; nas checagens
de 15 em 15 minutos, só os 2 últimos dias) contra o que existe no banco,
perguntando à Lambda do ETL Silver (dentro da VPC). O turno que falta, ou que
ficou pela metade (lab desligado no meio dele), é apagado e enviado de novo
inteiro, com uma leitura a cada 5 minutos, já com a viagem planejada da rota.
Assim o motorista que aparece ao vivo já tem as horas anteriores do turno. O
turno em que alguém da central agiu (ação, ocorrência, alerta respondido)
nunca é apagado. Um estado no S3 evita duas execuções preenchendo juntas.

{"regenerar": {"de": "AAAA-MM-DD", "ate": "AAAA-MM-DD"}} apaga esses dias
(telemetria, ações, ocorrências e viagens; cadastros ficam) e gera de novo.

Desligado por padrão (variável enable_simulador do Terraform). Usa a
biblioteca padrão e o boto3 do runtime (S3 e invocação do ETL).
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import os
import random
import re
import unicodedata
import urllib.request
from datetime import date, datetime, timedelta, timezone

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

INGEST_URL = os.environ.get("INGEST_URL", "")
API_KEY = os.environ.get("API_KEY", "")
CAMERAS = int(os.environ.get("CAMERAS", "16"))
LEITURAS_POR_LOTE = int(os.environ.get("LEITURAS_POR_LOTE", "1"))

# Preenchimento de lacunas (ver o cabeçalho).
ETL_SILVER_FUNCTION = os.environ.get("ETL_SILVER_FUNCTION", "")
ESTADO_BUCKET = os.environ.get("ESTADO_BUCKET", "")
ESTADO_CHAVE = "simulador/preenchimento.json"
PREENCHER_MAX_DIAS = int(os.environ.get("PREENCHER_MAX_DIAS", "30"))
PASSO_PREENCHIMENTO_MIN = int(os.environ.get("PASSO_PREENCHIMENTO_MIN", "5"))
LACUNA_MINIMA_MIN = 15
CHECAR_A_CADA_MIN = 15
# Nas checagens periódicas, só os turnos dos últimos dias (a checagem
# completa roda quando o simulador é ligado ou pedido).
DIAS_CHECAGEM_PERIODICA = 2
# Turno com um intervalo sem leitura maior que isto (contando o começo e o
# fim) está incompleto. A parada é de 30 min e o seed grava de 15 em 15.
LACUNA_MAXIMA_MIN = 50
# A central da simulação responde os alertas dos turnos encerrados há mais
# que isto; os mais recentes ficam para quem usa a dashboard.
CENTRAL_DEPOIS_H = 6
# Uma execução preenchendo (ou que acabou de preencher, com o ETL ainda
# gravando) segura as outras por este tempo.
TRAVA_MIN = 14
MAX_LEITURAS_POR_LOTE_PREENCHIMENTO = 500

# Brasília não tem horário de verão desde 2019.
FUSO = timezone(timedelta(hours=-3))
DIA_ZERO = date(2000, 1, 1)

# Mesma ordem das rotas no seed: o motorista i usa a rota 1 + (i % 8).
DISTANCIA_ROTA_KM = [430, 1620, 1370, 710, 210, 220, 800, 520]
NOMES_ROTAS = ["Via Dutra", "Rota do Centro-Oeste", "Rio-Bahia", "Rota Sul",
               "Eixo Goiás-DF", "Interior Paulista", "Litoral Nordeste", "Corredor Capixaba"]
# Motoristas 1 a 16: os do seed. Daí em diante, a frota ampliada.
MOTORISTAS_SEED = 16
TIPOS_VEICULO = ["caminhao", "onibus", "caminhao", "van"]
NOTURNOS = {2, 6, 10, 14}
# Deslocamento das folgas (índice = número do motorista), igual ao seed.
FOLGA_OFFSET = [None, 0, 1, 0, 1, 2, 3, 2, 3, 4, 5, 4, 5, 6, 0, 6, 2]
# Fase atual da simulação (programa): ver sql/05_seed_demo.sql.
PARADA_A_CADA_H = 4.0
PARADA_MADRUGADA_H = 3.5
DURACAO_PARADA_H = 0.5
DURACAO_MAX_MADRUGADA_H = 8.0
# Treinamento: quem tinha suscetibilidade >= 1,3 caiu 25% depois do programa.
LIMIAR_TREINAMENTO = 1.3
EFEITO_TREINAMENTO = 0.75


def _iso(ts: datetime) -> str:
    return ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _sha(valor: str) -> str:
    return hashlib.sha256(valor.encode("utf-8")).hexdigest()


def normalizar_id(valor: str) -> str:
    """
    Mesma regra do Backend (src/lib/identificadores.ts) e do cliente do modelo:
    sem acento, e espaço, ponto ou outro símbolo viram hífen.
    """
    sem_acento = "".join(c for c in unicodedata.normalize("NFD", str(valor)) if not unicodedata.combining(c))
    return re.sub(r"[^A-Za-z0-9]+", "-", sem_acento.strip()).strip("-")


def hash_motorista(codigo: str) -> str:
    """O que o dispositivo envia no lugar do ID do motorista (comparado em minúsculas)."""
    return _sha(normalizar_id(codigo).lower())


# ---------------------------------------------------------------------------
# Perfil e escala (iguais ao seed)
# ---------------------------------------------------------------------------

def perfil(i: int) -> dict:
    if i > MOTORISTAS_SEED:
        return _perfil_ampliada(i)
    tipo = TIPOS_VEICULO[i % 4]
    noturno = i in NOTURNOS
    if noturno:
        saida = 21 * 60 + 30 + (i % 3) * 30
    elif tipo == "onibus":
        saida = 13 * 60 + 30 + (i % 2) * 30
    else:
        saida = 5 * 60 + 30 + (i % 5) * 35
    base = 0.8 + ((i * 5) % 9) * 0.1
    return {
        "tipo": tipo,
        "noturno": noturno,
        "suscetibilidade": base * (EFEITO_TREINAMENTO if base >= LIMIAR_TREINAMENTO - 1e-9 else 1.0),
        "saida_min": saida,
        "distancia_km": DISTANCIA_ROTA_KM[i % 8],
    }


def _perfil_ampliada(i: int) -> dict:
    """
    Frota ampliada: uma saída a cada hora do dia (00h30, 01h30... 23h30, com
    um desvio por motorista), para haver gente dirigindo a qualquer hora.
    Quem sai entre 19h e 4h é da madrugada (turno de até 8 h).
    """
    k = i - MOTORISTAS_SEED - 1
    saida = (k * 60 + 30 + (k * 37) % 25) % 1440
    base = 0.8 + ((i * 5) % 9) * 0.1
    return {
        "tipo": TIPOS_VEICULO[i % 4],
        "noturno": saida >= 19 * 60 or saida < 4 * 60,
        "suscetibilidade": base * (EFEITO_TREINAMENTO if base >= LIMIAR_TREINAMENTO - 1e-9 else 1.0),
        "saida_min": saida,
        "distancia_km": DISTANCIA_ROTA_KM[i % 8],
    }


def folga(i: int, dnum: int) -> bool:
    deslocamento = FOLGA_OFFSET[i] if i <= MOTORISTAS_SEED else (i * 3) % 7
    return (dnum + deslocamento) % 7 in (0, 3)


def turno_do_dia(i: int, dia: date) -> dict | None:
    """Turno que o motorista i começa no dia (data local), ou None se é folga."""
    dnum = (dia - DIA_ZERO).days
    if folga(i, dnum):
        return None
    p = perfil(i)
    minutos = p["saida_min"] + (i * 7919 + dnum * 104729) % 51 - 25
    inicio = datetime(dia.year, dia.month, dia.day, tzinfo=FUSO) + timedelta(minutes=minutos)
    duracao = min(10.0, max(6.5, p["distancia_km"] / 70.0 + 1)) + ((i * 31 + dnum * 17) % 11 - 5) / 10.0
    if p["noturno"]:
        duracao = min(duracao, DURACAO_MAX_MADRUGADA_H)

    seguidos = 0
    while seguidos < 5 and not folga(i, dnum - seguidos):
        seguidos += 1
    divida = (
        0.8 * seguidos
        + (4 if p["noturno"] else 0)
        + (8 + (i + dnum) % 5 if (i * 13 + dnum * 7) % 100 < 12 else 0)
        - (2 if seguidos == 1 else 0)
    )
    return {
        "inicio": inicio,
        "fim": inicio + timedelta(seconds=int(duracao * 3600)),
        "divida": divida,
        "respeita_parada": (i * 17 + dnum * 3) % 100 < 85,
        "parada_a_cada_h": PARADA_MADRUGADA_H if p["noturno"] else PARADA_A_CADA_H,
    }


def turno_atual(i: int, agora: datetime) -> dict | None:
    """Turno em andamento agora (o de hoje ou, de madrugada, o de ontem)."""
    hoje = agora.astimezone(FUSO).date()
    for dia in (hoje, hoje - timedelta(days=1)):
        t = turno_do_dia(i, dia)
        if t and t["inicio"] <= agora < t["fim"]:
            return t
    return None


def horas_sem_pausa(turno: dict, agora: datetime) -> float | None:
    """Horas dirigidas desde a última parada; None durante a parada."""
    total = (agora - turno["inicio"]).total_seconds() / 3600
    if not turno["respeita_parada"]:
        return total
    a_cada = turno.get("parada_a_cada_h", PARADA_A_CADA_H)
    ciclo = a_cada + DURACAO_PARADA_H
    dentro = total - math.floor(total / ciclo) * ciclo
    return None if dentro >= a_cada else dentro


# ---------------------------------------------------------------------------
# Modelo de fadiga (igual ao seed)
# ---------------------------------------------------------------------------

def circadiano(agora: datetime) -> float:
    local = agora.astimezone(FUSO)
    h = local.hour + local.minute / 60

    def dist(a, b):
        return min(abs(a - b), 24 - abs(a - b))

    return 22 * math.exp(-dist(h, 4) ** 2 / 8.0) + 8 * math.exp(-dist(h, 14.5) ** 2 / 4.5)


def score(agora: datetime, camera: int, rng: random.Random) -> float | None:
    """Score de fadiga (0-100) da câmera agora; None se o motorista não está dirigindo."""
    turno = turno_atual(camera, agora)
    if turno is None:
        return None
    ef = horas_sem_pausa(turno, agora)
    if ef is None:
        return None
    p = perfil(camera)
    total = (agora - turno["inicio"]).total_seconds() / 3600
    t_min = agora.timestamp() / 60
    # Ruído suave (a fadiga não pula de um minuto para o outro) + um pouco de ruído branco.
    ruido = 2.5 * math.sin(2 * math.pi * t_min / 47 + camera) + 2.0 * math.sin(2 * math.pi * t_min / 113 + 2 * camera)
    valor = (
        4
        + ef * 4.6 * p["suscetibilidade"]
        + total * 0.8
        + circadiano(agora) * (0.6 + 0.4 * p["suscetibilidade"])
        + turno["divida"]
        + ruido
        + rng.gauss(0, 1.5)
    )
    return round(min(99.0, max(1.0, valor)), 2)


def estado(s: float) -> str:
    """Mesmas faixas do modelo de 3 classes (ver CloudPublisher no repositório ML)."""
    return "sonolento" if s >= 70 else "fadiga" if s >= 40 else "alerta"


def gravidade(s: float) -> str:
    return "critica" if s >= 90 else "alta" if s >= 80 else "media"


def leitura(ts: datetime, camera: int, rng: random.Random, passo_min: int = 1) -> tuple[dict | None, dict | None]:
    """
    Leitura da câmera no instante ts e o alerta que ela dispara, se houver.
    (None, None) quando o motorista não está dirigindo (fora do turno ou na
    parada).

    Alerta de sonolência: no máximo um a cada 20 minutos por câmera, num
    minuto que depende da câmera. Com `passo_min` > 1 (preenchimento), a
    regra vale por bloco de leituras, para continuar um a cada 20 minutos.
    """
    s = score(ts, camera, rng)
    if s is None:
        return None, None
    v = s / 100
    bocejo = rng.random() < 0.03 + 0.45 * v * v
    distracao = rng.random() < 0.00015 * passo_min
    olhos_ms = int(140 + 1300 * v ** 3 + rng.uniform(-30, 30))
    pitch = rng.uniform(-2, 2) - ((v - 0.6) * 55 if v > 0.6 else 0)
    dado = {
        "registrado_em": _iso(ts),
        "ear": round(min(0.40, max(0.10, 0.33 - 0.17 * v + rng.uniform(-0.01, 0.01))), 4),
        "mar": round(0.50 + rng.uniform(0, 0.15) if bocejo else 0.16 + rng.uniform(0, 0.08), 4),
        "perclos": round(min(0.90, max(0.0, 0.03 + 0.55 * v * v + rng.uniform(-0.02, 0.02))), 4),
        "blink_rate": round(max(4.0, 17 - 6 * v + rng.uniform(-2, 2)), 2),
        "duracao_olhos_fechados_ms": olhos_ms,
        "head_pitch": round(pitch, 2),
        "head_yaw": round(rng.uniform(-5, 5) + (35 if distracao else 0), 2),
        "head_roll": round(rng.uniform(-3, 3), 2),
        "score_fadiga": s,
        "estado": estado(s),
    }
    minuto = int(ts.timestamp() // 60)
    blocos = max(1, 20 // passo_min)
    alerta = None
    if s >= 70 and (minuto // passo_min) % blocos == camera % blocos:
        tipo = "microssono" if olhos_ms >= 1000 else "cabeca_baixa" if pitch <= -15 else "bocejo_excessivo" if bocejo else "sonolencia"
        alerta = {
            "disparado_em": _iso(ts),
            "tipo": tipo,
            "gravidade": gravidade(s),
            "score_fadiga": s,
            "mensagem": f"Score de fadiga {s:.0f} (simulador).",
        }
    elif distracao:
        alerta = {
            "disparado_em": _iso(ts),
            "tipo": "distracao",
            "gravidade": "alta",
            "score_fadiga": s,
            "mensagem": "Olhar fora da estrada por mais de 2 s (simulador).",
        }
    return dado, alerta


def _envelope(camera: int, enviado_em: datetime) -> dict:
    return {
        "device_id": f"dg-edge-{camera:04d}",
        "schema_version": "1.0",
        "motorista_hash": hash_motorista(f"DRV-{999 + camera}"),
        "veiculo_hash": None,
        "tipo_veiculo": perfil(camera)["tipo"],
        "enviado_em": _iso(enviado_em),
        "leituras": [],
        "alertas": [],
    }


def montar_lote(agora: datetime, camera: int, rng: random.Random) -> dict | None:
    """Lote do último minuto da câmera, ou None se o motorista não está dirigindo."""
    passo = 60 / LEITURAS_POR_LOTE
    lote = _envelope(camera, agora)
    for i in range(LEITURAS_POR_LOTE):
        ts = agora - timedelta(seconds=60 - (i + 1) * passo)
        dado, alerta = leitura(ts, camera, rng)
        if dado:
            lote["leituras"].append(dado)
        if alerta:
            lote["alertas"].append(alerta)
    return lote if lote["leituras"] else None


def lotes_da_lacuna(camera: int, de: datetime, ate: datetime, passo_min: int = PASSO_PREENCHIMENTO_MIN) -> list[dict]:
    """
    Lotes para preencher o intervalo (de, ate) da câmera, em ordem: um por
    turno (o ETL abre e fecha cada turno certinho), com no máximo
    MAX_LEITURAS_POR_LOTE_PREENCHIMENTO leituras. As leituras caem em minutos
    múltiplos de `passo_min`, os mesmos minutos do ao vivo, então uma leitura
    repetida é descartada pela constraint (device_id, registrado_em).
    """
    passo = timedelta(minutes=passo_min)
    base = de.astimezone(timezone.utc).replace(second=0, microsecond=0)
    resto = int(base.timestamp() // 60) % passo_min
    ts = base + timedelta(minutes=(passo_min - resto) % passo_min)
    if ts <= de:
        ts += passo
    lotes: list[dict] = []
    atual, turno_atual_inicio = None, None
    while ts < ate:
        turno = turno_atual(camera, ts)
        if turno is not None:
            # Semente por câmera e minuto: preencher de novo gera o mesmo dado.
            rng = random.Random(camera * 1_000_003 + int(ts.timestamp() // 60))
            dado, alerta = leitura(ts, camera, rng, passo_min)
            if dado:
                if atual is None or turno["inicio"] != turno_atual_inicio or len(atual["leituras"]) >= MAX_LEITURAS_POR_LOTE_PREENCHIMENTO:
                    atual = _envelope(camera, ts)
                    turno_atual_inicio = turno["inicio"]
                    lotes.append(atual)
                atual["leituras"].append(dado)
                if alerta:
                    atual["alertas"].append(alerta)
        ts += passo
    return lotes


def enviar(lote: dict) -> int:
    req = urllib.request.Request(
        f"{INGEST_URL.rstrip('/')}/eventos",
        data=json.dumps(lote).encode("utf-8"),
        headers={"x-api-key": API_KEY, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status


def _parse(iso: str) -> datetime:
    return datetime.fromisoformat(iso.replace("Z", "+00:00"))


def _ler_estado() -> dict:
    if not ESTADO_BUCKET:
        return {}
    import boto3  # do runtime da Lambda

    try:
        obj = boto3.client("s3").get_object(Bucket=ESTADO_BUCKET, Key=ESTADO_CHAVE)
        return json.loads(obj["Body"].read())
    except Exception:  # ainda não existe (ou não deu para ler): começa do zero
        return {}


def _gravar_estado(estado_atual: dict) -> None:
    if not ESTADO_BUCKET:
        return
    import boto3

    boto3.client("s3").put_object(
        Bucket=ESTADO_BUCKET, Key=ESTADO_CHAVE, Body=json.dumps(estado_atual).encode("utf-8"), ContentType="application/json"
    )


def _etl(pedido: dict) -> dict:
    """Pedido à Lambda do ETL Silver, que fica dentro da VPC e enxerga o banco."""
    import boto3

    r = boto3.client("lambda").invoke(FunctionName=ETL_SILVER_FUNCTION, Payload=json.dumps(pedido).encode("utf-8"))
    corpo = json.loads(r["Payload"].read())
    if r.get("FunctionError"):
        raise RuntimeError(f"ETL falhou em {pedido.get('acao')}: {str(corpo)[:300]}")
    return corpo


def meia_noite(ts: datetime) -> datetime:
    """00:00 de Brasília do dia de ts."""
    local = ts.astimezone(FUSO)
    return datetime(local.year, local.month, local.day, tzinfo=FUSO)


def turnos_da_escala(camera: int, de: datetime, ate: datetime) -> list[dict]:
    """Turnos da escala da câmera que se sobrepõem a [de, ate)."""
    turnos = []
    dia = (de - timedelta(days=1)).astimezone(FUSO).date()
    while dia <= ate.astimezone(FUSO).date():
        t = turno_do_dia(camera, dia)
        if t and t["inicio"] < ate and t["fim"] > de:
            turnos.append(t)
        dia += timedelta(days=1)
    return turnos


def turnos_a_conferir(agora: datetime, dias: int) -> list[dict]:
    """
    Cada turno da escala nos últimos `dias` (até agora), com os lotes que o
    representam: o que seria enviado se ele faltasse.
    """
    ate = agora.replace(second=0, microsecond=0)  # o minuto atual é do ao vivo
    limite = meia_noite(agora - timedelta(days=dias))
    candidatos = []
    for camera in range(1, CAMERAS + 1):
        for t in turnos_da_escala(camera, limite, ate):
            de, fim = max(t["inicio"], limite), min(t["fim"], ate)
            if (fim - de).total_seconds() / 60 < LACUNA_MINIMA_MIN:
                continue
            lotes = lotes_da_lacuna(camera, de - timedelta(seconds=1), fim)
            esperado = sum(len(l["leituras"]) for l in lotes)
            if esperado >= 3:
                candidatos.append({
                    "camera": camera, "de": de, "ate": fim, "lotes": lotes, "esperado": esperado,
                    "rota": NOMES_ROTAS[camera % 8],
                })
    return candidatos


def preencher_lacunas(agora: datetime, forcar: bool = False, dias: int | None = None) -> dict:
    """
    Confere os turnos da escala contra o banco e regenera os que faltam ou
    ficaram pela metade (ver o cabeçalho).
    """
    if not ETL_SILVER_FUNCTION:
        return {"preenchimento": "desligado (sem ETL_SILVER_FUNCTION)"}
    estado_ant = _ler_estado()
    if estado_ant.get("inicio"):
        desde = (agora - _parse(estado_ant["inicio"])).total_seconds() / 60
        em_andamento = not estado_ant.get("fim")
        if desde < TRAVA_MIN and (em_andamento or not forcar):
            return {"preenchimento": "ignorado", "motivo": "outro preenchimento recente", "estado": estado_ant}
    _gravar_estado({"inicio": _iso(agora)})

    dias = dias or (PREENCHER_MAX_DIAS if forcar else DIAS_CHECAGEM_PERIODICA)
    # Os lotes da execução anterior já foram gravados: a central da simulação
    # responde os alertas do histórico (ver simular_central no ETL).
    central = _etl({"acao": "simular_central", "ate": _iso(agora - timedelta(hours=CENTRAL_DEPOIS_H))})["central"]
    candidatos = turnos_a_conferir(agora, dias)
    device = lambda c: f"dg-edge-{c['camera']:04d}"  # noqa: E731
    cobertura = _etl({
        "acao": "cobertura",
        "turnos": [{"device": device(c), "inicio": _iso(c["de"]), "fim": _iso(c["ate"])} for c in candidatos],
    })["cobertura"]

    regenerar, limpar, protegidos = [], [], 0
    for c, cob in zip(candidatos, cobertura):
        if cob["blocos"] and cob["maior_lacuna_min"] <= LACUNA_MAXIMA_MIN:
            continue
        if cob["blocos"] and cob["protegido"]:
            protegidos += 1
            continue
        if cob["blocos"]:
            limpar.append({"device": device(c), "de": _iso(c["de"]), "ate": _iso(c["ate"])})
        regenerar.append(c)

    if regenerar:
        _etl({"acao": "planejar_viagens", "turnos": [
            {"device": device(c), "inicio": _iso(c["de"]), "fim": _iso(c["ate"]), "rota": c["rota"]} for c in regenerar
        ]})
    for i in range(0, len(limpar), 200):
        _etl({"acao": "limpar", "intervalos": limpar[i:i + 200]})

    lotes = leituras = 0
    falhas = []
    for c in sorted(regenerar, key=lambda x: (x["camera"], x["de"])):
        for lote in c["lotes"]:
            for tentativa in range(2):
                try:
                    enviar(lote)
                    lotes += 1
                    leituras += len(lote["leituras"])
                    break
                except Exception as exc:
                    if tentativa == 1:
                        falhas.append({"camera": c["camera"], "erro": str(exc)[:200]})

    resumo = {
        "inicio": _iso(agora), "fim": _iso(datetime.now(timezone.utc)), "dias": dias,
        "turnos_conferidos": len(candidatos), "turnos_regenerados": len(regenerar), "turnos_refeitos": len(limpar),
        "turnos_protegidos": protegidos, "lotes": lotes, "leituras": leituras, "falhas": falhas[:10],
        "central": central,
    }
    _gravar_estado(resumo)
    logger.info("Preenchimento: %s", resumo)
    return {"preenchimento": resumo}


def regenerar_periodo(agora: datetime, de: str, ate: str) -> dict:
    """Apaga os dias [de, ate] (datas de Brasília) e gera de novo pela escala."""
    date.fromisoformat(de), date.fromisoformat(ate)  # valida antes de apagar
    if de > ate or date.fromisoformat(de) > agora.astimezone(FUSO).date():
        raise ValueError("intervalo inválido para regenerar")
    apagado = _etl({"acao": "limpar_periodo", "de": de, "ate": ate})["apagado"]
    dias = (agora.astimezone(FUSO).date() - date.fromisoformat(de)).days + 1
    _gravar_estado({})  # libera a trava: o preenchimento abaixo precisa rodar
    return {"apagado": apagado, **preencher_lacunas(agora, forcar=True, dias=max(dias, DIAS_CHECAGEM_PERIODICA))}


def handler(event, context):
    if not INGEST_URL or not API_KEY:
        raise RuntimeError("INGEST_URL e API_KEY precisam estar configurados")

    agora = datetime.now(timezone.utc)
    # Semente por minuto: reexecutar o mesmo minuto gera o mesmo lote, e a
    # constraint (device_id, registrado_em) descarta a duplicata.
    rng = random.Random(math.floor(agora.timestamp() / 60))
    enviados, fora_do_turno, falhas = 0, 0, []
    for camera in range(1, CAMERAS + 1):
        lote = montar_lote(agora.replace(second=0, microsecond=0), camera, rng)
        if lote is None:
            fora_do_turno += 1
            continue
        try:
            enviar(lote)
            enviados += 1
        except Exception as exc:  # uma câmera fora do ar não para as outras
            falhas.append({"camera": camera, "erro": str(exc)[:200]})

    logger.info("Lotes enviados: %d, fora do turno: %d, falhas: %s", enviados, fora_do_turno, falhas)
    resultado = {"enviados": enviados, "fora_do_turno": fora_do_turno, "falhas": falhas}

    # Depois do ao vivo (que não pode atrasar): regenerar dias, lacunas
    # quando pedido, ou a checagem de 15 em 15 minutos.
    if isinstance(event, dict) and event.get("regenerar"):
        r = event["regenerar"]
        resultado["regenerar"] = regenerar_periodo(agora, str(r["de"]), str(r.get("ate") or r["de"]))
        return resultado
    pedido = isinstance(event, dict) and bool(event.get("preencher"))
    if pedido or int(agora.timestamp() // 60) % CHECAR_A_CADA_MIN == 3:
        try:
            resultado["lacunas"] = preencher_lacunas(agora, forcar=pedido)
        except Exception as exc:  # o ao vivo já foi; a próxima checagem tenta de novo
            logger.exception("Falha no preenchimento de lacunas")
            _gravar_estado({})
            resultado["lacunas"] = {"erro": str(exc)[:300]}
    return resultado
