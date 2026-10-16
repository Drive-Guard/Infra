"""Simulador: os lotes passam na mesma validação da API de ingestão."""

from __future__ import annotations

import os
import random
from datetime import datetime, timezone

from conftest import carregar_lambda

os.environ.setdefault("BRONZE_BUCKET", "bronze-teste")


def test_lote_do_simulador_e_aceito_pela_ingestao():
    simulador = carregar_lambda("simulador")
    ingest = carregar_lambda("ingest")
    agora = datetime(2026, 10, 16, 3, 0, tzinfo=timezone.utc)

    for camera in range(1, 7):
        lote = simulador.montar_lote(agora, camera, random.Random(camera))
        assert ingest._validar(lote) == []
        assert lote["device_id"] == f"dg-edge-{camera:04d}"
        assert len(lote["leituras"]) == simulador.LEITURAS_POR_LOTE


def test_score_sobe_com_as_horas_de_direcao():
    simulador = carregar_lambda("simulador")
    rng = random.Random(1)
    inicio = datetime(2026, 10, 16, 15, 0, tzinfo=timezone.utc)  # meio-dia em Brasília
    horas = simulador.horas_dirigindo(inicio, 1)
    cedo = inicio.timestamp() - horas * 3600 + 600          # 10 min de turno
    tarde = cedo + 8 * 3600                                  # 8 h depois
    s_cedo = simulador.score(datetime.fromtimestamp(cedo, timezone.utc), 1, rng)
    s_tarde = simulador.score(datetime.fromtimestamp(tarde, timezone.utc), 1, rng)
    assert s_tarde > s_cedo + 20
