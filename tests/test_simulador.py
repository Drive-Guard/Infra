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


def test_preencher_regenera_turnos_que_faltam_ou_pela_metade(monkeypatch):
    simulador = carregar_lambda("simulador")
    agora = datetime(2026, 10, 21, 1, 30, tzinfo=timezone.utc)  # 22h30 de 20/10 em Brasília
    monkeypatch.setattr(simulador, "ETL_SILVER_FUNCTION", "etl")
    monkeypatch.setattr(simulador, "CAMERAS", 4)
    estado = {}
    monkeypatch.setattr(simulador, "_ler_estado", lambda: dict(estado))
    monkeypatch.setattr(simulador, "_gravar_estado", lambda e: (estado.clear(), estado.update(e)))
    pedidos = []

    # Banco de mentira: câmera 1 sem nada, 2 pela metade, 3 completa, 4 pela metade mas protegida.
    def etl(pedido):
        pedidos.append(pedido)
        if pedido["acao"] == "cobertura":
            resposta = []
            for t in pedido["turnos"]:
                c = int(t["device"][-4:])
                resposta.append({1: {"blocos": 0, "maior_lacuna_min": 600, "protegido": False},
                                 2: {"blocos": 3, "maior_lacuna_min": 300, "protegido": False},
                                 # Leitura de 15 em 15 min (como o seed) e paradas de 30: completo.
                                 3: {"blocos": 30, "maior_lacuna_min": 45, "protegido": False},
                                 4: {"blocos": 3, "maior_lacuna_min": 300, "protegido": True}}[c])
            return {"cobertura": resposta}
        if pedido["acao"] == "simular_central":
            return {"central": {"turnos_fechados": 0, "alertas_resolvidos": 0, "acoes": 0}}
        return {}

    monkeypatch.setattr(simulador, "_etl", etl)
    enviados = []
    monkeypatch.setattr(simulador, "enviar", lambda lote: enviados.append(lote) or 202)

    r = simulador.preencher_lacunas(agora, forcar=True, dias=3)["preenchimento"]
    por_device = {}
    for lote in enviados:
        por_device.setdefault(lote["device_id"], []).extend(_parse(l["registrado_em"]) for l in lote["leituras"])
    assert set(por_device) == {"dg-edge-0001", "dg-edge-0002"}
    assert all(max(v) < agora for v in por_device.values())
    # Só a câmera 2 (que tinha parte do turno) é limpa antes; as duas ganham viagem planejada com a rota.
    limpar = [p for p in pedidos if p["acao"] == "limpar"]
    assert {i["device"] for p in limpar for i in p["intervalos"]} == {"dg-edge-0002"}
    planejar = next(p for p in pedidos if p["acao"] == "planejar_viagens")
    assert {t["device"] for t in planejar["turnos"]} == {"dg-edge-0001", "dg-edge-0002"}
    assert planejar["turnos"][0]["rota"] in simulador.NOMES_ROTAS
    assert r["turnos_protegidos"] >= 1 and r["lotes"] == len(enviados) and estado.get("fim")
    # A central da simulação só responde turnos encerrados há mais de 6 h.
    central = next(p for p in pedidos if p["acao"] == "simular_central")
    assert _parse(central["ate"]) == agora - timedelta(hours=6)
    # Cada turno vai inteiro, num lote só, do começo ao fim (ou até agora).
    for lote in enviados:
        ts = [_parse(l["registrado_em"]) for l in lote["leituras"]]
        assert ts == sorted(ts)

    # Logo em seguida, a checagem periódica não preenche de novo (o ETL ainda está gravando).
    enviados.clear()
    r2 = simulador.preencher_lacunas(agora + timedelta(minutes=2))
    assert r2["preenchimento"] == "ignorado" and enviados == []


def test_frota_ampliada_tem_gente_dirigindo_a_qualquer_hora():
    simulador = carregar_lambda("simulador")
    for camera in range(17, 41):
        semana = [simulador.turno_do_dia(camera, date(2026, 10, 12) + timedelta(days=d)) for d in range(7)]
        assert sum(t is None for t in semana) == 2
    saidas = sorted({simulador.perfil(c)["saida_min"] // 60 for c in range(17, 41)})
    assert saidas == list(range(24))
    for hora in range(24):
        agora = datetime(2026, 10, 21, hora, 10, tzinfo=FUSO)
        assert sum(1 for c in range(1, 41) if simulador.turno_atual(c, agora)) >= 6
    # Os 16 do seed não mudam.
    assert simulador.perfil(2)["noturno"] and simulador.perfil(2)["saida_min"] == 21 * 60 + 30 + 2 * 30


def _cenario(monkeypatch, simulador, agora, acoes=None):
    """Liga o cenário com o S3 e o ETL de mentira; `acoes` = {device: [ação]}."""
    guardado, pedidos = {}, []
    monkeypatch.setattr(simulador, "ESTADO_BUCKET", "teste")
    monkeypatch.setattr(simulador, "ETL_SILVER_FUNCTION", "etl")
    monkeypatch.setattr(simulador, "_gravar_json", lambda chave, dado: guardado.__setitem__(chave, dado))
    monkeypatch.setattr(simulador, "_ler_json", lambda chave: guardado.get(chave, {}))

    def etl(pedido):
        pedidos.append(pedido)
        return {"acoes": acoes or {}} if pedido["acao"] == "acoes_cenario" else {"viagens": 1}

    monkeypatch.setattr(simulador, "_etl", etl)
    return simulador.ligar_cenario(agora, 120), pedidos


def _serie(simulador, ctx, inicio, camera, minutos):
    """Score e alerta de cada minuto do cenário."""
    out = []
    for k in range(minutos):
        ts = inicio + timedelta(minutes=k)
        dado, alerta = simulador.leitura(ts, camera, random.Random(k), cenario=ctx)
        out.append((k, dado["score_fadiga"] if dado else None, alerta["gravidade"] if alerta and alerta["tipo"] != "distracao" else None))
    return out


def test_cenario_leva_os_motoristas_ao_risco_e_alerta(monkeypatch):
    simulador = carregar_lambda("simulador")
    monkeypatch.setattr(simulador, "CAMERAS", 40)
    agora = datetime(2026, 10, 21, 20, 0, tzinfo=FUSO)
    cenario, pedidos = _cenario(monkeypatch, simulador, agora)
    papeis = [m["papel"] for m in cenario["motoristas"]]
    assert papeis == ["critico", "alto", "fadiga"]
    # Os escolhidos são os que dirigem há mais tempo, com turno para a janela.
    horas = [(agora - simulador.turno_atual(m["camera"], agora)["inicio"]).total_seconds() for m in cenario["motoristas"]]
    assert horas == sorted(horas, reverse=True)
    # A câmera da demonstração ao vivo ganha a viagem do dia.
    assert pedidos[0]["acao"] == "planejar_viagens" and pedidos[0]["turnos"][0]["device"] == simulador.DEMO_DEVICE_ID

    ao_vivo = simulador.cenario_ao_vivo(agora)
    critico = next(m for m in cenario["motoristas"] if m["papel"] == "critico")
    serie = [x for x in _serie(simulador, ao_vivo[critico["camera"]], agora, critico["camera"], 40) if x[1] is not None]
    assert max(s for _, s, _ in serie) >= 88
    alertas = [k for k, _, a in serie if a]
    assert alertas and alertas[0] <= 8  # cruza 70 em poucos minutos
    assert all(b - a >= 10 for a, b in zip(alertas, alertas[1:]))  # repete a cada 10 min, não a cada minuto
    fadiga = next(m for m in cenario["motoristas"] if m["papel"] == "fadiga")
    assert not any(a for _, _, a in _serie(simulador, ao_vivo[fadiga["camera"]], agora, fadiga["camera"], 40))


def test_cenario_reage_a_resposta_da_central(monkeypatch):
    simulador = carregar_lambda("simulador")
    monkeypatch.setattr(simulador, "CAMERAS", 40)
    agora = datetime(2026, 10, 21, 20, 0, tzinfo=FUSO)
    cenario, _ = _cenario(monkeypatch, simulador, agora)
    critico, alto = cenario["motoristas"][0]["camera"], cenario["motoristas"][1]["camera"]
    parada = agora + timedelta(minutes=15)
    acoes = {
        f"dg-edge-{critico:04d}": [{"tipo": "pausa_obrigatoria", "detalhe": "30 min", "em": simulador._iso(parada)}],
        f"dg-edge-{alto:04d}": [{"tipo": "encerramento_turno", "detalhe": None, "em": simulador._iso(parada)}],
    }
    _cenario(monkeypatch, simulador, agora, acoes)  # mesmo cenário, agora com as ações
    ao_vivo = simulador.cenario_ao_vivo(agora + timedelta(minutes=16))
    serie = dict((k, s) for k, s, _ in _serie(simulador, ao_vivo[critico], agora, critico, 60))
    # Mandou parar: o score cai para o descanso e não há alerta enquanto ele descansa.
    assert serie[14] is not None and serie[14] >= 75
    assert serie[20] is not None and serie[20] < 30
    # Parar de dirigir hoje: a câmera para em 5 minutos.
    fim = dict((k, s) for k, s, _ in _serie(simulador, ao_vivo[alto], agora, alto, 30))
    assert fim[16] is not None and fim[22] is None
