"""ETL Silver: câmera -> caminhão -> empresa, turno e viagem."""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from conftest import carregar_lambda

BUCKET = "bronze-teste"
BASE = datetime(2026, 10, 10, 8, 0, tzinfo=timezone.utc)


def iso(ts: datetime) -> str:
    return ts.isoformat().replace("+00:00", "Z")


def sha(valor: str) -> str:
    return hashlib.sha256(valor.encode("utf-8")).hexdigest()


def lote(device_id, motorista, inicio, n=10, passo_s=60, alertas=(), **extra):
    leituras = [
        {
            "registrado_em": iso(inicio + timedelta(seconds=i * passo_s)),
            "ear": 0.3,
            "perclos": 0.1,
            "score_fadiga": 40 + i,
            "estado": "alerta",
        }
        for i in range(n)
    ]
    payload = {
        "device_id": device_id,
        "motorista_hash": sha(motorista),
        "leituras": leituras,
        "alertas": list(alertas),
        **extra,
    }
    return {"ingest_id": str(uuid.uuid4()), "payload": payload}


def um(conn, sql, params=()):
    cur = conn.cursor()
    cur.execute(sql, params)
    linha = cur.fetchone()
    cur.close()
    return tuple(linha) if linha is not None else None


def todos(conn, sql, params=()):
    cur = conn.cursor()
    cur.execute(sql, params)
    linhas = cur.fetchall()
    cur.close()
    return [tuple(l) for l in linhas]


@pytest.fixture
def etl(conn, s3, monkeypatch):
    modulo = carregar_lambda("etl_silver")
    monkeypatch.setattr(modulo, "get_connection", lambda: conn)
    monkeypatch.setattr(modulo, "s3", s3)
    return modulo


@pytest.fixture
def enviar(etl, s3):
    def _enviar(envelope, key=None, formato="s3"):
        key = key or f"eventos/{uuid.uuid4()}.json"
        s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(envelope).encode("utf-8"))
        if formato == "eventbridge":
            evento = {"detail": {"bucket": {"name": BUCKET}, "object": {"key": key}}}
        else:
            evento = {"Records": [{"s3": {"bucket": {"name": BUCKET}, "object": {"key": key}}}]}
        return etl.handler(evento, None)

    return _enviar


def cadastrar_frota(conn, device_id="dg-edge-0500", partida=BASE, horas=6, sufixo="A"):
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO silver.empresas (cnpj_hash, razao_social, frota_total)
        VALUES ('cnpj-teste', 'Transportes Teste', 10)
        ON CONFLICT (cnpj_hash) DO UPDATE SET razao_social = EXCLUDED.razao_social
        RETURNING id
        """
    )
    empresa = cur.fetchone()[0]
    cur.execute(
        """
        INSERT INTO silver.veiculos (empresa_id, placa_hash, placa, tipo)
        VALUES (%s, %s, %s, 'caminhao') RETURNING id
        """,
        (empresa, f"hash-placa-{sufixo}", f"TST1A2{sufixo}"),
    )
    veiculo = cur.fetchone()[0]
    cur.execute(
        """
        INSERT INTO silver.dispositivos (empresa_id, device_id, codigo, status)
        VALUES (%s, %s, %s, 'ativo')
        ON CONFLICT (device_id) DO UPDATE
           SET empresa_id = EXCLUDED.empresa_id, codigo = EXCLUDED.codigo, status = 'ativo'
        RETURNING id
        """,
        (empresa, device_id, f"TRK-50{sufixo}"),
    )
    dispositivo = cur.fetchone()[0]
    cur.execute(
        """
        INSERT INTO silver.vinculos_dispositivo_veiculo (dispositivo_id, veiculo_id, inicio)
        VALUES (%s, %s, %s)
        """,
        (dispositivo, veiculo, partida - timedelta(days=30)),
    )
    cur.execute(
        """
        INSERT INTO silver.rotas (empresa_id, nome, origem_cidade, origem_uf, destino_cidade,
                                  destino_uf, brs, ufs_percorridas, distancia_km)
        VALUES (%s, 'Via Dutra', 'São Paulo', 'SP', 'Rio de Janeiro', 'RJ', '{116}', '{SP,RJ}', 430)
        RETURNING id
        """,
        (empresa,),
    )
    rota = cur.fetchone()[0]
    cur.execute(
        """
        INSERT INTO silver.viagens (empresa_id, rota_id, veiculo_id, partida_prevista,
                                    chegada_prevista, valor_viagem)
        VALUES (%s, %s, %s, %s, %s, 4500) RETURNING id
        """,
        (empresa, rota, veiculo, partida, partida + timedelta(hours=horas)),
    )
    viagem = cur.fetchone()[0]
    conn.commit()
    cur.close()
    return {"empresa": empresa, "veiculo": veiculo, "dispositivo": dispositivo, "rota": rota, "viagem": viagem}


def test_camera_desconhecida_entra_como_pendente(conn, enviar):
    r = enviar(lote("dg-edge-0900", "DRV-9000", BASE))
    assert r["detalhes"][0]["camera_pendente"] is True

    status, empresa, contato = um(
        conn, "SELECT status::text, empresa_id, ultimo_contato_em FROM silver.dispositivos WHERE device_id = 'dg-edge-0900'"
    )
    assert status == "pendente" and empresa is None
    assert contato == BASE + timedelta(minutes=9)

    nome, cnpj = um(
        conn,
        """
        SELECT m.nome_exibicao, e.cnpj_hash FROM silver.motoristas m
        JOIN silver.empresas e ON e.id = m.empresa_id WHERE m.motorista_hash = %s
        """,
        (sha("DRV-9000"),),
    )
    assert nome.startswith("Motorista não cadastrado")
    assert cnpj == "0" * 32  # empresa provisória

    status_turno, veiculo, dispositivo, viagem = um(
        conn, "SELECT status::text, veiculo_id, dispositivo_id, viagem_id FROM silver.turnos"
    )
    assert status_turno == "em_andamento" and veiculo is None and viagem is None
    assert dispositivo is not None
    assert um(conn, "SELECT count(*) FROM silver.leituras_fadiga")[0] == 10


def test_id_da_camera_e_normalizado(conn, enviar):
    # Mesma regra do cadastro: "Device_123" e "device-123" são a mesma câmera.
    enviar(lote("Device_123", "DRV-9000", BASE))
    enviar(lote("device-123", "DRV-9000", BASE + timedelta(minutes=20)))
    assert todos(conn, "SELECT device_id FROM silver.dispositivos") == [("device-123",)]
    assert um(conn, "SELECT count(DISTINCT device_id) FROM silver.leituras_fadiga") == (1,)


def test_camera_e_motorista_arquivados_voltam_quando_enviam(conn, enviar):
    frota = cadastrar_frota(conn)
    enviar(lote("dg-edge-0500", "DRV-1000", BASE))
    cur = conn.cursor()
    cur.execute("UPDATE silver.dispositivos SET arquivado_em = now(), status = 'inativo' WHERE id = %s", (frota["dispositivo"],))
    cur.execute("UPDATE silver.motoristas SET arquivado_em = now() WHERE motorista_hash = %s", (sha("DRV-1000"),))
    cur.execute("UPDATE silver.vinculos_dispositivo_veiculo SET fim = %s WHERE dispositivo_id = %s",
                (BASE + timedelta(minutes=30), frota["dispositivo"]))
    conn.commit()
    cur.close()

    enviar(lote("dg-edge-0500", "DRV-1000", BASE + timedelta(hours=2)))
    status, empresa, arquivado = um(
        conn, "SELECT status::text, empresa_id, arquivado_em FROM silver.dispositivos WHERE id = %s", (frota["dispositivo"],)
    )
    # Volta como pendente e sem empresa: o gestor decide de novo.
    assert status == "pendente" and empresa is None and arquivado is None
    assert um(conn, "SELECT arquivado_em FROM silver.motoristas WHERE motorista_hash = %s", (sha("DRV-1000"),)) == (None,)


def test_ultimas_leituras_por_camera(conn, enviar, etl):
    enviar(lote("dg-edge-0900", "DRV-9000", BASE))
    r = etl.handler({"acao": "ultimas_leituras", "devices": ["dg-edge-0900", "Dg_Edge_0901"]}, None)
    assert datetime.fromisoformat(r["ultimas"]["dg-edge-0900"]) == BASE + timedelta(minutes=9)
    assert r["ultimas"]["dg-edge-0901"] is None


def test_mesmo_arquivo_nao_e_processado_duas_vezes(conn, enviar):
    envelope = lote("dg-edge-0900", "DRV-9000", BASE)
    enviar(envelope, key="eventos/fixo.json")
    r = enviar(envelope, key="eventos/fixo.json")
    assert r["detalhes"][0]["status"] == "ignorado"
    assert um(conn, "SELECT count(*) FROM silver.leituras_fadiga")[0] == 10


def test_camera_vinculada_resolve_caminhao_e_viagem(conn, enviar):
    frota = cadastrar_frota(conn)
    enviar(lote("dg-edge-0500", "DRV-1000", BASE + timedelta(minutes=10)))

    turno = um(
        conn,
        """
        SELECT veiculo_id, viagem_id, origem_cidade, destino_cidade, distancia_km, dispositivo_id
        FROM silver.turnos
        """,
    )
    assert turno[0] == frota["veiculo"]
    assert turno[1] == frota["viagem"]
    assert turno[2:5] == ("São Paulo", "Rio de Janeiro", 430)
    assert turno[5] == frota["dispositivo"]

    assert um(conn, "SELECT count(DISTINCT veiculo_id) FROM silver.leituras_fadiga")[0] == 1
    assert um(conn, "SELECT veiculo_id FROM silver.leituras_fadiga LIMIT 1")[0] == frota["veiculo"]

    status, partida_real, motorista = um(
        conn, "SELECT status::text, partida_real, motorista_id FROM silver.viagens"
    )
    assert status == "em_andamento"
    assert partida_real == BASE + timedelta(minutes=10)
    assert motorista is not None

    assert um(conn, "SELECT empresa_id FROM silver.motoristas")[0] == frota["empresa"]


def test_motorista_da_empresa_provisoria_passa_para_a_empresa_da_camera(conn, enviar):
    enviar(lote("dg-edge-0500", "DRV-1000", BASE))  # câmera ainda sem cadastro
    frota = cadastrar_frota(conn)  # gestor associa a câmera pendente a um caminhão

    enviar(lote("dg-edge-0500", "DRV-1000", BASE + timedelta(minutes=15)))

    assert um(conn, "SELECT empresa_id FROM silver.motoristas")[0] == frota["empresa"]
    # Mesmo turno (intervalo curto); ganha o caminhão e a viagem.
    assert um(conn, "SELECT count(*) FROM silver.turnos")[0] == 1
    veiculo, viagem = um(conn, "SELECT veiculo_id, viagem_id FROM silver.turnos")
    assert veiculo == frota["veiculo"] and viagem == frota["viagem"]
    # As leituras de antes do cadastro também ficam com o caminhão.
    assert um(conn, "SELECT count(*) FROM silver.leituras_fadiga WHERE veiculo_id IS NULL")[0] == 0


def test_intervalo_longo_fecha_turno_e_ultimo_turno_conclui_a_viagem(conn, enviar):
    frota = cadastrar_frota(conn, horas=6)
    enviar(lote("dg-edge-0500", "DRV-1000", BASE))                                # 08:00-08:09
    enviar(lote("dg-edge-0500", "DRV-1000", BASE + timedelta(hours=5, minutes=50)))  # 13:50-13:59
    enviar(lote("dg-edge-0500", "DRV-1000", BASE + timedelta(hours=8)))           # 16:00

    turnos = todos(
        conn,
        "SELECT status::text, finalizado_em, viagem_id FROM silver.turnos ORDER BY iniciado_em",
    )
    assert [t[0] for t in turnos] == ["concluido", "concluido", "em_andamento"]
    assert turnos[0][1] == BASE + timedelta(minutes=9)
    assert turnos[0][2] == frota["viagem"] and turnos[1][2] == frota["viagem"]
    assert turnos[2][2] is None  # viagem já concluída, não casa mais

    status, chegada = um(conn, "SELECT status::text, chegada_real FROM silver.viagens")
    assert status == "concluida"
    assert chegada == BASE + timedelta(hours=5, minutes=59)


def test_lote_atrasado_entra_no_turno_ja_encerrado(conn, enviar):
    enviar(lote("dg-edge-0900", "DRV-9000", BASE))
    enviar(lote("dg-edge-0900", "DRV-9000", BASE + timedelta(hours=2)))
    primeiro = um(conn, "SELECT id FROM silver.turnos ORDER BY iniciado_em LIMIT 1")[0]

    # Backlog que a câmera guardou offline: cai dentro do primeiro turno.
    enviar(lote("dg-edge-0900", "DRV-9000", BASE + timedelta(minutes=2, seconds=30), n=4))

    assert um(conn, "SELECT count(*) FROM silver.turnos")[0] == 2
    assert um(
        conn,
        "SELECT count(*) FROM silver.leituras_fadiga WHERE turno_id = %s",
        (primeiro,),
    )[0] == 14


def test_troca_de_caminhao_abre_turno_novo(conn, enviar):
    cadastrar_frota(conn, device_id="dg-edge-0500", sufixo="A")
    frota_b = cadastrar_frota(conn, device_id="dg-edge-0501", sufixo="B")
    enviar(lote("dg-edge-0500", "DRV-1000", BASE))
    enviar(lote("dg-edge-0501", "DRV-1000", BASE + timedelta(minutes=12)))

    turnos = todos(conn, "SELECT status::text, veiculo_id FROM silver.turnos ORDER BY iniciado_em")
    assert [t[0] for t in turnos] == ["concluido", "em_andamento"]
    assert turnos[1][1] == frota_b["veiculo"]


def test_tipo_de_alerta_desconhecido_nao_derruba_o_lote(conn, enviar):
    alerta = {
        "disparado_em": iso(BASE + timedelta(minutes=5)),
        "tipo": "olhar_celular",
        "gravidade": "gravissima",
        "score_fadiga": 88,
    }
    enviar(lote("dg-edge-0900", "DRV-9000", BASE, alertas=[alerta]))
    assert um(conn, "SELECT tipo::text, gravidade::text, status::text FROM silver.alertas") == (
        "sonolencia",
        "media",
        "aberto",
    )


def test_aceita_evento_do_eventbridge(conn, enviar):
    r = enviar(lote("dg-edge-0900", "DRV-9000", BASE), formato="eventbridge")
    assert r["processados"] == 1
    assert um(conn, "SELECT count(*) FROM silver.leituras_fadiga")[0] == 10


def test_lote_fora_de_ordem_vira_um_turno_so(conn, enviar):
    # O ao vivo (10:00) chega antes do preenchimento das horas anteriores.
    enviar(lote("dg-edge-0900", "DRV-9000", BASE + timedelta(hours=2)))
    enviar(lote("dg-edge-0900", "DRV-9000", BASE, n=24, passo_s=300))  # 08:00-09:55, de 5 em 5 min
    turnos = todos(conn, "SELECT iniciado_em, status::text FROM silver.turnos")
    assert turnos == [(BASE, "em_andamento")]
    assert um(conn, "SELECT count(*) FROM silver.leituras_fadiga")[0] == 34


def test_cobertura_limpar_e_viagem_planejada(conn, enviar, etl):
    frota = cadastrar_frota(conn, device_id="dg-edge-0500", partida=BASE)
    enviar(lote("dg-edge-0500", "DRV-1000", BASE, n=12, passo_s=300))  # 1 h de leituras
    pedido = [
        {"device": "dg-edge-0500", "inicio": iso(BASE), "fim": iso(BASE + timedelta(hours=2)), "rota": "Via Dutra"},
        {"device": "dg-edge-0500", "inicio": iso(BASE + timedelta(days=1)), "fim": iso(BASE + timedelta(days=1, hours=2)), "rota": "Via Dutra"},
    ]
    cob = etl.handler({"acao": "cobertura", "turnos": pedido}, None)["cobertura"]
    assert cob == [{"blocos": 12, "protegido": False}, {"blocos": 0, "protegido": False}]

    # Alguém da central agiu no turno: ele passa a ser protegido.
    cur = conn.cursor()
    cur.execute(
        """INSERT INTO silver.usuarios (empresa_id, email_hash, nome, papel) VALUES (%s, 'hash-central', 'Central', 'operador')
           RETURNING id""", (frota["empresa"],))
    usuario = cur.fetchone()[0]
    cur.execute(
        """INSERT INTO silver.acoes_motorista (motorista_id, turno_id, tipo, realizado_por)
           SELECT motorista_id, id, 'contato_telefonico', %s FROM silver.turnos""", (usuario,))
    conn.commit()
    assert etl.handler({"acao": "cobertura", "turnos": pedido[:1]}, None)["cobertura"][0]["protegido"] is True
    cur.execute("DELETE FROM silver.acoes_motorista")
    conn.commit()
    cur.close()

    # Limpar apaga o turno (leituras em cascata) e devolve a viagem para planejada.
    r = etl.handler({"acao": "limpar", "intervalos": [{"device": "dg-edge-0500", "de": pedido[0]["inicio"], "ate": pedido[0]["fim"]}]}, None)
    assert r["limpo"]["turnos"] == 1
    assert um(conn, "SELECT count(*) FROM silver.leituras_fadiga")[0] == 0
    assert um(conn, "SELECT status::text, partida_real FROM silver.viagens WHERE id = %s", (frota["viagem"],)) == ("planejada", None)

    # Viagem planejada só onde não há uma (o primeiro horário já tem).
    assert etl.handler({"acao": "planejar_viagens", "turnos": pedido}, None)["viagens"] == 1
    assert um(conn, "SELECT count(*) FROM silver.viagens")[0] == 2


def test_limpar_periodo_apaga_os_dias_e_mantem_cadastros(conn, enviar, etl):
    cadastrar_frota(conn, device_id="dg-edge-0500", partida=BASE)
    enviar(lote("dg-edge-0500", "DRV-1000", BASE))                       # 10/10
    enviar(lote("dg-edge-0500", "DRV-1000", BASE + timedelta(days=1)))   # 11/10
    r = etl.handler({"acao": "limpar_periodo", "de": "2026-10-10", "ate": "2026-10-10"}, None)
    assert r["apagado"]["turnos"] == 1 and r["apagado"]["viagens"] == 1
    assert um(conn, "SELECT count(*), min(registrado_em) FROM silver.leituras_fadiga") == (10, BASE + timedelta(days=1))
    assert um(conn, "SELECT count(*) FROM silver.motoristas")[0] == 1
    assert um(conn, "SELECT count(*) FROM silver.dispositivos")[0] == 1
