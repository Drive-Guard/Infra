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

Desligado por padrão (variável enable_simulador do Terraform). Só usa a
biblioteca padrão.
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

# Brasília não tem horário de verão desde 2019.
FUSO = timezone(timedelta(hours=-3))
DIA_ZERO = date(2000, 1, 1)

# Mesma ordem das rotas no seed: o motorista i usa a rota 1 + (i % 8).
DISTANCIA_ROTA_KM = [430, 1620, 1370, 710, 210, 220, 800, 520]
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


def folga(i: int, dnum: int) -> bool:
    return (dnum + FOLGA_OFFSET[i]) % 7 in (0, 3)


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


def montar_lote(agora: datetime, camera: int, rng: random.Random) -> dict | None:
    """Lote do último minuto da câmera, ou None se o motorista não está dirigindo."""
    passo = 60 / LEITURAS_POR_LOTE
    leituras, alertas = [], []
    for i in range(LEITURAS_POR_LOTE):
        ts = agora - timedelta(seconds=60 - (i + 1) * passo)
        s = score(ts, camera, rng)
        if s is None:
            continue
        v = s / 100
        bocejo = rng.random() < 0.03 + 0.45 * v * v
        distracao = rng.random() < 0.00015
        olhos_ms = int(140 + 1300 * v ** 3 + rng.uniform(-30, 30))
        pitch = rng.uniform(-2, 2) - ((v - 0.6) * 55 if v > 0.6 else 0)
        leituras.append(
            {
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
        )
        minuto = int(ts.timestamp() // 60)
        if s >= 70 and minuto % 20 == camera % 20:
            tipo = "microssono" if olhos_ms >= 1000 else "cabeca_baixa" if pitch <= -15 else "bocejo_excessivo" if bocejo else "sonolencia"
            alertas.append(
                {
                    "disparado_em": _iso(ts),
                    "tipo": tipo,
                    "gravidade": gravidade(s),
                    "score_fadiga": s,
                    "mensagem": f"Score de fadiga {s:.0f} (simulador).",
                }
            )
        elif distracao:
            alertas.append(
                {
                    "disparado_em": _iso(ts),
                    "tipo": "distracao",
                    "gravidade": "alta",
                    "score_fadiga": s,
                    "mensagem": "Olhar fora da estrada por mais de 2 s (simulador).",
                }
            )

    if not leituras:
        return None
    return {
        "device_id": f"dg-edge-{camera:04d}",
        "schema_version": "1.0",
        "motorista_hash": hash_motorista(f"DRV-{999 + camera}"),
        "veiculo_hash": None,
        "tipo_veiculo": perfil(camera)["tipo"],
        "enviado_em": _iso(agora),
        "leituras": leituras,
        "alertas": alertas,
    }


def enviar(lote: dict) -> int:
    req = urllib.request.Request(
        f"{INGEST_URL.rstrip('/')}/eventos",
        data=json.dumps(lote).encode("utf-8"),
        headers={"x-api-key": API_KEY, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status


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
    return {"enviados": enviados, "fora_do_turno": fora_do_turno, "falhas": falhas}
