"""Migrações: aplicam do zero, reaplicam sem erro e o seed alimenta as views."""

from __future__ import annotations

import pytest

from conftest import SCHEMA, aplicar, criar_banco, remover_banco

TODOS = [*SCHEMA, "05_seed_demo.sql", "06_refresh_gold.sql"]


@pytest.fixture(scope="module")
def banco_demo(pg):
    nome = "driveguard_test_seed"
    conn = criar_banco(nome, TODOS)
    yield conn
    conn.close()
    remover_banco(nome)


def _valor(conn, sql, params=()):
    cur = conn.cursor()
    cur.execute(sql, params)
    linha = cur.fetchone()
    cur.close()
    return linha[0]


def test_seed_cria_a_frota_de_demonstracao(banco_demo):
    # 16 com um ano de histórico + 24 da frota ampliada (histórico vem do simulador).
    assert _valor(banco_demo, "SELECT count(*) FROM silver.motoristas") == 40
    assert _valor(banco_demo, "SELECT count(*) FROM silver.veiculos") == 40
    assert _valor(banco_demo, "SELECT count(*) FROM silver.dispositivos") == 41
    assert _valor(banco_demo, "SELECT count(*) FROM silver.dispositivos WHERE device_id = 'dg-edge-0040' AND status = 'ativo'") == 1
    assert _valor(banco_demo, "SELECT frota_total FROM silver.empresas") == 50
    assert _valor(banco_demo, "SELECT count(*) FROM silver.rotas") == 8
    assert _valor(banco_demo, "SELECT count(*) FROM silver.alertas") > 0
    # Um vínculo encerrado (câmera trocada) e 40 abertos.
    assert _valor(banco_demo, "SELECT count(*) FROM silver.vinculos_dispositivo_veiculo WHERE fim IS NULL") == 40
    # BRs no formato da PRF (sem zero à esquerda).
    assert _valor(banco_demo, "SELECT count(*) FROM silver.rotas WHERE EXISTS (SELECT 1 FROM unnest(brs) b WHERE b LIKE '0%')") == 0


def test_todas_as_views_materializadas_tem_indice_unico(banco_demo):
    cur = banco_demo.cursor()
    cur.execute("SELECT view_name, tem_indice_unico, grupo FROM gold.vw_materialized_views")
    views = cur.fetchall()
    cur.close()
    assert len(views) >= 11
    assert all(v[1] for v in views), [v[0] for v in views if not v[1]]
    assert {v[2] for v in views} == {"frota", "prf"}


def test_refresh_concurrently_de_todas_as_views(banco_demo):
    banco_demo.autocommit = True
    cur = banco_demo.cursor()
    try:
        cur.execute("SELECT view_name FROM gold.vw_materialized_views")
        for (nome,) in cur.fetchall():
            cur.execute(f'REFRESH MATERIALIZED VIEW CONCURRENTLY gold."{nome}"')
    finally:
        cur.close()
        banco_demo.autocommit = False


def test_views_da_dashboard_tem_dados(banco_demo):
    assert _valor(banco_demo, "SELECT count(*) FROM gold.vw_frota_agora") == 16
    assert _valor(banco_demo, "SELECT count(*) FROM gold.mv_kpis_diarios") > 0
    assert _valor(banco_demo, "SELECT count(*) FROM gold.mv_ranking_motoristas") == 40
    assert _valor(banco_demo, "SELECT count(*) FROM gold.mv_rotas_desempenho") > 0
    assert _valor(banco_demo, "SELECT count(*) FROM gold.mv_fadiga_por_tempo_direcao") > 0


def test_reaplicar_as_migracoes_nao_muda_os_dados(banco_demo):
    antes = _valor(banco_demo, "SELECT count(*) FROM silver.leituras_fadiga")
    aplicar(banco_demo, TODOS)
    assert _valor(banco_demo, "SELECT count(*) FROM silver.leituras_fadiga") == antes
    assert _valor(banco_demo, "SELECT count(*) FROM silver.motoristas") == 40


def test_hash_antigo_do_motorista_vira_o_normalizado(banco_demo):
    import hashlib

    sha = lambda s: hashlib.sha256(s.encode("utf-8")).hexdigest()  # noqa: E731
    cur = banco_demo.cursor()
    # Seed já nasce no formato novo.
    cur.execute("SELECT motorista_hash FROM silver.motoristas WHERE codigo = 'DRV-1000'")
    assert cur.fetchone()[0] == sha("drv-1000")
    # Motorista e câmera cadastrados antes da normalização.
    cur.execute("SELECT empresa_id FROM silver.motoristas WHERE codigo = 'DRV-1000'")
    empresa = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO silver.motoristas (empresa_id, codigo, motorista_hash, nome_exibicao) VALUES (%s, 'Ana.Paula_X', %s, 'Ana')",
        (empresa, sha("Ana.Paula_X")),
    )
    cur.execute("INSERT INTO silver.dispositivos (device_id, status) VALUES ('Device_777', 'pendente')")
    banco_demo.commit()
    aplicar(banco_demo, ["03_cadastros.sql"])
    cur.execute("SELECT motorista_hash FROM silver.motoristas WHERE codigo = 'Ana.Paula_X'")
    assert cur.fetchone()[0] == sha("ana-paula-x")
    cur.execute("SELECT count(*) FROM silver.dispositivos WHERE device_id = 'device-777'")
    assert cur.fetchone()[0] == 1
    cur.close()
