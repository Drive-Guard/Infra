"""Simulador: lotes válidos para a ingestão e a mesma escala/modelo do seed."""

from __future__ import annotations

import os
import random
from datetime import date, datetime, timedelta, timezone

from conftest import carregar_lambda

os.environ.setdefault("BRONZE_BUCKET", "bronze-teste")

FUSO = timezone(timedelta(hours=-3))


def _em_turno(simulador, camera: int, a_partir: datetime, horas: float = 0.5) -> datetime:
    """Primeiro minuto, a partir de `a_partir`, com o motorista dirigindo há `horas`."""
    for d in range(14):
        t = simulador.turno_do_dia(camera, (a_partir + timedelta(days=d)).astimezone(FUSO).date())
        if t:
            return t["inicio"] + timedelta(hours=horas)
    raise AssertionError("nenhum turno em 14 dias")


def test_lote_do_simulador_e_aceito_pela_ingestao():
    simulador = carregar_lambda("simulador")
    ingest = carregar_lambda("ingest")
    base = datetime(2026, 10, 16, 12, 0, tzinfo=timezone.utc)

    for camera in range(1, 17):
        agora = _em_turno(simulador, camera, base, horas=1)
        lote = simulador.montar_lote(agora, camera, random.Random(camera))
        assert lote is not None
        assert ingest._validar(lote) == []
        assert lote["device_id"] == f"dg-edge-{camera:04d}"
        assert lote["tipo_veiculo"] == simulador.perfil(camera)["tipo"]


def test_fora_do_turno_nao_envia():
    simulador = carregar_lambda("simulador")
    camera = 1
    turno = simulador.turno_do_dia(camera, _em_turno(simulador, camera, datetime(2026, 10, 16, tzinfo=timezone.utc)).astimezone(FUSO).date())
    depois = turno["fim"] + timedelta(minutes=30)
    assert simulador.turno_atual(camera, depois) is None
    assert simulador.montar_lote(depois, camera, random.Random(1)) is None


def test_escala_5x2():
    simulador = carregar_lambda("simulador")
    for camera in range(1, 17):
        semana = [simulador.turno_do_dia(camera, date(2026, 10, 12) + timedelta(days=d)) for d in range(7)]
        assert sum(t is None for t in semana) == 2


def test_perfis_de_horario():
    simulador = carregar_lambda("simulador")
    for camera in range(1, 17):
        t = simulador.turno_do_dia(camera, _em_turno(simulador, camera, datetime(2026, 10, 16, tzinfo=timezone.utc)).astimezone(FUSO).date())
        hora = t["inicio"].astimezone(FUSO).hour
        p = simulador.perfil(camera)
        if p["noturno"]:
            assert 21 <= hora <= 22
        elif p["tipo"] == "onibus":
            assert 13 <= hora <= 14
        else:
            assert 5 <= hora <= 8
        assert 6.0 <= (t["fim"] - t["inicio"]).total_seconds() / 3600 <= 10.5


def test_parada_interrompe_as_leituras():
    simulador = carregar_lambda("simulador")
    turno = {"inicio": datetime(2026, 10, 16, 9, tzinfo=timezone.utc), "respeita_parada": True}
    assert simulador.horas_sem_pausa(turno, turno["inicio"] + timedelta(hours=4.7)) is None
    assert abs(simulador.horas_sem_pausa(turno, turno["inicio"] + timedelta(hours=5.5)) - 0.5) < 1e-6


def test_score_sobe_com_as_horas_de_direcao():
    simulador = carregar_lambda("simulador")
    camera = 3  # turno diurno, sem parada obrigatória no dia escolhido abaixo
    for d in range(30):
        dia = date(2026, 10, 1) + timedelta(days=d)
        t = simulador.turno_do_dia(camera, dia)
        if t and not t["respeita_parada"]:
            break
    cedo = simulador.score(t["inicio"] + timedelta(minutes=10), camera, random.Random(1))
    tarde = simulador.score(t["inicio"] + timedelta(hours=6), camera, random.Random(1))
    assert tarde > cedo + 20


def test_estados_em_tres_niveis():
    simulador = carregar_lambda("simulador")
    assert [simulador.estado(s) for s in (10, 39.9, 40, 69.9, 70, 95)] == [
        "alerta", "alerta", "fadiga", "fadiga", "sonolento", "sonolento"]
