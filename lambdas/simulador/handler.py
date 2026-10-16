"""
Lambda simulador — telemetria de demonstração para a dashboard.

Faz o papel das câmeras embarcadas quando não há veículo rodando: a cada
execução (EventBridge, de minuto em minuto) monta um lote por câmera no mesmo
formato do DriveGuardClient do repositório ML e envia para a API de
ingestão, com a mesma API Key dos dispositivos. Tudo o que vem depois
(Bronze, ETL Silver, views Gold) é o caminho real.

As câmeras e motoristas são os do seed (dg-edge-0001 com DRV-1000, e assim
por diante), então os turnos abertos pelo seed continuam e casam com as
viagens cadastradas.

O score segue a mesma lógica do seed: cresce com as horas de direção, pesa
mais na madrugada e tem ruído. Acima de 72 há chance de alerta.

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
import urllib.request
from datetime import datetime, timedelta, timezone

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

INGEST_URL = os.environ.get("INGEST_URL", "")
API_KEY = os.environ.get("API_KEY", "")
CAMERAS = int(os.environ.get("CAMERAS", "6"))
LEITURAS_POR_LOTE = int(os.environ.get("LEITURAS_POR_LOTE", "12"))

TIPOS_ALERTA = ["microssono", "bocejo_excessivo", "cabeca_baixa", "fechamento_prolongado", "piscadas_excessivas", "sonolencia"]


def _iso(ts: datetime) -> str:
    return ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _sha(valor: str) -> str:
    return hashlib.sha256(valor.encode("utf-8")).hexdigest()


def horas_dirigindo(agora: datetime, camera: int) -> float:
    """Jornadas de 10 h defasadas entre as câmeras, para a frota não andar em bloco."""
    horas = agora.timestamp() / 3600 + camera * 1.7
    return horas % 10


def score(agora: datetime, camera: int, rng: random.Random) -> float:
    hora_local = (agora - timedelta(hours=3)).hour
    madrugada = 18 if hora_local < 6 else 0
    base = 8 + horas_dirigindo(agora, camera) * 6.5 + madrugada + (camera % 4) * 4
    return round(min(98, max(2, base + rng.uniform(-7, 7))), 2)


def montar_lote(agora: datetime, camera: int, rng: random.Random) -> dict:
    passo = 60 / LEITURAS_POR_LOTE
    leituras, alertas = [], []
    for i in range(LEITURAS_POR_LOTE):
        ts = agora - timedelta(seconds=60 - i * passo)
        s = score(ts, camera, rng)
        perclos = round(min(0.6, 0.05 + s / 250 + rng.uniform(-0.02, 0.02)), 4)
        leituras.append(
            {
                "registrado_em": _iso(ts),
                "ear": round(max(0.12, 0.32 - s / 600 + rng.uniform(-0.01, 0.01)), 4),
                "mar": round(0.3 + rng.uniform(0, 0.25) + (0.2 if s > 70 else 0), 4),
                "perclos": perclos,
                "blink_rate": round(14 + s / 6 + rng.uniform(-2, 2), 2),
                "duracao_olhos_fechados_ms": int(150 + s * 6 + rng.uniform(-40, 40)),
                "head_pitch": round(-4 - s / 8 + rng.uniform(-2, 2), 2),
                "head_yaw": round(rng.uniform(-8, 8), 2),
                "head_roll": round(rng.uniform(-3, 3), 2),
                "score_fadiga": s,
                "estado": "sonolento" if s >= 50 else "alerta",
            }
        )
        if s >= 72 and rng.random() < 0.08:
            alertas.append(
                {
                    "disparado_em": _iso(ts),
                    "tipo": rng.choice(TIPOS_ALERTA),
                    "gravidade": "critica" if s >= 90 else "alta" if s >= 80 else "media",
                    "score_fadiga": s,
                    "mensagem": "Alerta sonoro emitido na cabine (simulador)",
                }
            )

    return {
        "device_id": f"dg-edge-{camera:04d}",
        "schema_version": "1.0",
        "motorista_hash": _sha(f"DRV-{999 + camera}"),
        "veiculo_hash": None,
        "tipo_veiculo": "caminhao",
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
    enviados, falhas = 0, []
    for camera in range(1, CAMERAS + 1):
        lote = montar_lote(agora.replace(second=0, microsecond=0), camera, rng)
        try:
            enviar(lote)
            enviados += 1
        except Exception as exc:  # uma câmera fora do ar não para as outras
            falhas.append({"camera": camera, "erro": str(exc)[:200]})

    logger.info("Lotes enviados: %d, falhas: %s", enviados, falhas)
    return {"enviados": enviados, "falhas": falhas}
