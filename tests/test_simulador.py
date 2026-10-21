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
    # Parada a cada 4 h (fase atual do programa): 4h00-4h30 parado.
    turno = {"inicio": datetime(2026, 10, 16, 9, tzinfo=timezone.utc), "respeita_parada": True, "parada_a_cada_h": 4.0}
    assert simulador.horas_sem_pausa(turno, turno["inicio"] + timedelta(hours=4.2)) is None
    assert abs(simulador.horas_sem_pausa(turno, turno["inicio"] + timedelta(hours=5.0)) - 0.5) < 1e-6
    # Madrugada: parada a cada 3h30.
    noturno = {**turno, "parada_a_cada_h": 3.5}
    assert simulador.horas_sem_pausa(noturno, noturno["inicio"] + timedelta(hours=3.7)) is None


def test_madrugada_limitada_a_8h_e_treinamento():
    simulador = carregar_lambda("simulador")
    for camera in (2, 6, 10, 14):  # turno da madrugada
        for d in range(14):
            t = simulador.turno_do_dia(camera, date(2026, 10, 1) + timedelta(days=d))
            if t:
                assert (t["fim"] - t["inicio"]).total_seconds() / 3600 <= 8.0 + 1e-6
    # Suscetibilidade >= 1,3 já com o efeito do treinamento (-25%).
    assert abs(simulador.perfil(7)["suscetibilidade"] - 1.6 * 0.75) < 1e-9
    assert abs(simulador.perfil(2)["suscetibilidade"] - 0.9) < 1e-9


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


# ---------------------------------------------------------------------------
# Preenchimento de lacunas
# ---------------------------------------------------------------------------


def _parse(iso: str) -> datetime:
    return datetime.fromisoformat(iso.replace("Z", "+00:00"))


def test_lacuna_vira_um_lote_por_turno_so_dentro_do_intervalo():
    simulador = carregar_lambda("simulador")
    ingest = carregar_lambda("ingest")
    de = datetime(2026, 10, 14, 3, 7, tzinfo=timezone.utc)
    ate = datetime(2026, 10, 17, 1, 0, tzinfo=timezone.utc)
    for camera in (1, 2, 5):
        lotes = simulador.lotes_da_lacuna(camera, de, ate)
        assert lotes, f"câmera {camera} sem turno em 3 dias"
        inicios = set()
        anterior = None
        for lote in lotes:
            assert ingest._validar(lote) == []
            ts = [_parse(l["registrado_em"]) for l in lote["leituras"]]
            assert all(de < t < ate for t in ts)
            assert all(int(t.timestamp() // 60) % 5 == 0 and t.second == 0 for t in ts)
            # Em ordem e sem misturar turnos num lote.
            assert ts == sorted(ts) and (anterior is None or ts[0] > anterior)
            anterior = ts[-1]
            turnos = {simulador.turno_atual(camera, t)["inicio"] for t in ts}
            assert len(turnos) == 1
            inicios |= turnos
            # Alerta de sonolência no máximo a cada 20 min.
            sono = sorted(_parse(a["disparado_em"]) for a in lote["alertas"] if a["tipo"] != "distracao")
            assert all((b - a) >= timedelta(minutes=20) for a, b in zip(sono, sono[1:]))
        assert len(inicios) == len(lotes)


def test_preencher_comeca_na_ultima_leitura_ou_na_meia_noite(monkeypatch):
    simulador = carregar_lambda("simulador")
    agora = datetime(2026, 10, 21, 1, 30, tzinfo=timezone.utc)  # 22h30 de 20/10 em Brasília
    monkeypatch.setattr(simulador, "ETL_SILVER_FUNCTION", "etl")
    monkeypatch.setattr(simulador, "CAMERAS", 3)
    estado = {}
    monkeypatch.setattr(simulador, "_ler_estado", lambda: dict(estado))
    monkeypatch.setattr(simulador, "_gravar_estado", lambda e: (estado.clear(), estado.update(e)))
    ontem = "2026-10-19T12:00:00+00:00"
    recente = (agora - timedelta(minutes=5)).isoformat()
    monkeypatch.setattr(simulador, "_ultimas_leituras", lambda devices: {"dg-edge-0001": ontem, "dg-edge-0002": None, "dg-edge-0003": recente})
    enviados = []
    monkeypatch.setattr(simulador, "enviar", lambda lote: enviados.append(lote) or 202)

    r = simulador.preencher_lacunas(agora, forcar=True)
    por_device = {}
    for lote in enviados:
        por_device.setdefault(lote["device_id"], []).extend(_parse(l["registrado_em"]) for l in lote["leituras"])
    # Câmera 1 desde a última leitura; câmera 2, sem dado, desde a meia-noite de hoje (Brasília);
    # câmera 3 com leitura há 5 min: nada a preencher.
    if "dg-edge-0001" in por_device:
        assert min(por_device["dg-edge-0001"]) > _parse(ontem)
    if "dg-edge-0002" in por_device:
        assert min(por_device["dg-edge-0002"]) >= datetime(2026, 10, 20, 0, 0, tzinfo=FUSO)
    assert "dg-edge-0003" not in por_device
    assert all(max(v) < agora for v in por_device.values())
    assert r["preenchimento"]["lotes"] == len(enviados) and estado.get("fim")

    # Logo em seguida, a checagem periódica não preenche de novo (o ETL ainda está gravando).
    enviados.clear()
    r2 = simulador.preencher_lacunas(agora + timedelta(minutes=2))
    assert r2["preenchimento"] == "ignorado" and enviados == []
