"""Base da PRF: leitura da página, carga dos dois arquivos e views mv_prf_*."""

from __future__ import annotations

import io
import json
import zipfile

import pytest

from conftest import carregar_lambda

CAB_OCORRENCIAS = (
    '"id";"data_inversa";"dia_semana";"horario";"uf";"br";"km";"municipio";"causa_acidente";'
    '"tipo_acidente";"classificacao_acidente";"fase_dia";"sentido_via";"condicao_metereologica";'
    '"tipo_pista";"tracado_via";"uso_solo";"pessoas";"mortos";"feridos_leves";"feridos_graves";'
    '"ilesos";"ignorados";"feridos";"veiculos";"latitude";"longitude";"regional";"delegacia";"uop"'
)
OCORRENCIAS = [
    # Sono, caminhão-trator, madrugada, com morte
    '900001;2025-03-01;"sábado";"03:20:00";"MG";381;"12,5";"BETIM";"Condutor Dormindo";'
    '"Saída de leito carroçável";"Com Vítimas Fatais";"Plena Noite";"Crescente";"Céu Claro";'
    '"Dupla";"Reta;Declive";"Não";2;1;0;1;0;0;1;1;"-19,96";"-44,19";"SPRF-MG";"DEL01-MG";"UOP01"',
    # Outra causa, automóvel x caminhão, sem vítimas
    '900002;2025-03-02;"domingo";"14:10:00";"SP";116;225;"GUARULHOS";"Velocidade Incompatível";'
    '"Colisão traseira";"Sem Vítimas";"Pleno dia";"Decrescente";"Nublado";"Múltipla";"Reta";"Sim";'
    '3;0;0;0;3;0;0;2;"-23,48";"-46,54";"SPRF-SP";"DEL01-SP";"UOP01"',
    # Sono, ônibus, classificação NA (deduz feridos), BR com zero à esquerda,
    # coordenada fora do Brasil
    '900003;2025-03-03;"segunda-feira";"05:00:00";"MG";"040";"10";"SETE LAGOAS";"Condutor Dormindo";'
    '"Tombamento";NA;"Amanhecer";"Crescente";"Céu Claro";"Simples";"Curva";"Não";'
    '20;0;2;0;18;0;2;1;"12,5";"-44,2";"SPRF-MG";"DEL02-MG";"UOP02"',
]

CAB_PESSOAS = (
    '"id";"pesid";"data_inversa";"dia_semana";"horario";"uf";"br";"km";"municipio";"causa_acidente";'
    '"tipo_acidente";"classificacao_acidente";"fase_dia";"sentido_via";"condicao_metereologica";'
    '"tipo_pista";"tracado_via";"uso_solo";"id_veiculo";"tipo_veiculo";"marca";"ano_fabricacao_veiculo";'
    '"tipo_envolvido";"estado_fisico";"idade";"sexo";"ilesos";"feridos_leves";"feridos_graves";'
    '"mortos";"latitude";"longitude";"regional";"delegacia";"uop"'
)


def _pessoa(id_acidente, pesid, id_veiculo, tipo):
    return (
        f'{id_acidente};{pesid};2025-03-01;"x";"00:00:00";"MG";381;1;"X";"X";"X";"X";"X";"X";"X";'
        f'"X";"X";"X";{id_veiculo};"{tipo}";"X";2020;"Condutor";"Ileso";40;"Masculino";1;0;0;0;'
        '"-19";"-44";"X";"X";"X"'
    )


PESSOAS = [
    _pessoa(900001, 1, 10, "Caminhão-trator"),
    _pessoa(900001, 2, 10, "Caminhão-trator"),  # mesmo veículo, outro ocupante
    _pessoa(900002, 3, 20, "Automóvel"),
    _pessoa(900002, 4, 21, "Caminhão"),
    _pessoa(900003, 5, 30, "Ônibus"),
]


def _zip(caminho, cabecalho, linhas):
    texto = "\r\n".join([cabecalho, *linhas]) + "\r\n"
    with zipfile.ZipFile(caminho, "w") as z:
        z.writestr("dados.csv", texto.encode("latin-1"))
    return caminho


@pytest.fixture
def prf(conn, s3, monkeypatch):
    modulo = carregar_lambda("prf_carga")
    monkeypatch.setattr(modulo, "get_connection", lambda: conn)
    monkeypatch.setattr(modulo, "s3", s3)
    return modulo


def _um(conn, sql, params=()):
    cur = conn.cursor()
    cur.execute(sql, params)
    linha = cur.fetchone()
    cur.close()
    return tuple(linha) if linha is not None else None


def test_carga_independe_da_ordem_e_e_idempotente(conn, prf, tmp_path):
    z_pessoas = _zip(tmp_path / "p.zip", CAB_PESSOAS, PESSOAS)
    z_ocorr = _zip(tmp_path / "o.zip", CAB_OCORRENCIAS, OCORRENCIAS)
    chave_p = "prf/conjunto=pessoas/ano=2025/pessoas_2025.zip"
    chave_o = "prf/conjunto=ocorrencias/ano=2025/ocorrencias_2025.zip"

    # Pessoas chegam primeiro: nada para casar ainda.
    r = prf.carregar_zip(conn, str(z_pessoas), chave_p, "etag-p")
    assert r["linhas_gravadas"] == 4 and r["veiculos_casados"] == 0

    r = prf.carregar_zip(conn, str(z_ocorr), chave_o, "etag-o")
    assert r["linhas_lidas"] == 3 and r["veiculos_casados"] == 4

    assert prf.carregar_zip(conn, str(z_ocorr), chave_o, "etag-o")["status"] == "ja_carregado"
    assert _um(conn, "SELECT count(*) FROM silver.incidentes")[0] == 3


def test_limpeza_dos_campos(conn, prf, tmp_path):
    prf.carregar_zip(conn, str(_zip(tmp_path / "o.zip", CAB_OCORRENCIAS, OCORRENCIAS)),
                     "prf/conjunto=ocorrencias/ano=2025/o.zip", "e1")

    sono, gravidade, ocorrido, km = _um(
        conn,
        """
        SELECT relacionado_sonolencia, gravidade::text,
               to_char(ocorrido_em AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), km
        FROM silver.incidentes WHERE origem_id_externo = '900001'
        """,
    )
    assert sono is True and gravidade == "com_fatais"
    assert ocorrido == "2025-03-01 06:20"  # 03:20 em Brasília
    assert float(km) == 12.5

    br, gravidade, lat = _um(
        conn,
        "SELECT br, gravidade::text, latitude FROM silver.incidentes WHERE origem_id_externo = '900003'",
    )
    assert br == "40"                # "040" sem o zero à esquerda
    assert gravidade == "com_feridos"  # NA deduzido pelas vítimas
    assert lat is None               # 12,5 de latitude está fora do Brasil

    assert _um(
        conn, "SELECT relacionado_sonolencia FROM silver.incidentes WHERE origem_id_externo = '900002'"
    )[0] is False


def test_views_da_prf(conn, prf, s3, tmp_path):
    s3.put_object(Bucket="b", Key="prf/conjunto=ocorrencias/ano=2025/o.zip",
                  Body=_zip(tmp_path / "o.zip", CAB_OCORRENCIAS, OCORRENCIAS).read_bytes())
    s3.put_object(Bucket="b", Key="prf/conjunto=pessoas/ano=2025/p.zip",
                  Body=_zip(tmp_path / "p.zip", CAB_PESSOAS, PESSOAS).read_bytes())
    evento = {
        "Records": [
            {"s3": {"bucket": {"name": "b"}, "object": {"key": k, "eTag": k}}}
            for k in ("prf/conjunto=ocorrencias/ano=2025/o.zip", "prf/conjunto=pessoas/ano=2025/p.zip")
        ]
    }
    resultado = prf.handler(evento, None)
    assert {v["view"] for v in resultado[-1]["views_prf"]} >= {"mv_prf_perfil_sono", "mv_prf_trechos"}

    acidentes, mortos = _um(
        conn,
        "SELECT acidentes, mortos FROM gold.mv_prf_perfil_sono WHERE ano = 2025 AND recorte = 'pesados_sono'",
    )
    assert (acidentes, mortos) == (2, 1)  # 900001 (caminhão-trator) e 900003 (ônibus)

    assert _um(conn, "SELECT count(*) FROM gold.vw_prf_base WHERE veiculo_pesado")[0] == 3
    assert _um(
        conn, "SELECT sum(acidentes_sono) FROM gold.mv_prf_trechos WHERE br = '40' AND uf = 'MG'"
    )[0] == 1


def test_ipca_atualiza_o_parametro_do_roi(conn, prf, s3):
    conteudo = {"fator_acumulado": 1.9123, "inicio": "01/2015", "fim": "09/2026"}
    s3.put_object(Bucket="b", Key="referencias/ipca_sgs433.json", Body=json.dumps(conteudo).encode())
    prf.handler({"Records": [{"s3": {"bucket": {"name": "b"}, "object": {"key": "referencias/ipca_sgs433.json"}}}]}, None)
    valor, referencia = _um(
        conn, "SELECT valor, referencia FROM silver.parametros_roi_padrao WHERE chave = 'fator_ipca'"
    )
    assert float(valor) == 1.9123 and referencia == "01/2015 a 09/2026"

    with pytest.raises(ValueError):
        prf.atualizar_ipca(conn, {"fator_acumulado": 42})


# ---------------------------------------------------------------------------
# prf_download (sem rede: página e downloads simulados)
# ---------------------------------------------------------------------------

PAGINA = """
<table>
<tr><td>Documento CSV de Acidentes 2025 (Agrupados por ocorrência)</td>
    <td><a href="https://drive.google.com/file/d/AAA111/view">CSV</a>
        <a href="https://drive.google.com/file/d/ZZZ999/view">outro</a></td></tr>
<tr><td>Documento CSV de Acidentes 2025 (Agrupados por pessoa)</td>
    <td><a href="https://drive.google.com/file/d/BBB222/view">CSV</a></td></tr>
<tr><td>Documento CSV de Acidentes 2025 (Agrupados por pessoa - Todas as causas e tipos de acidentes)</td>
    <td><a href="https://drive.google.com/file/d/CCC333/view">CSV</a></td></tr>
<tr><td>Documento CSV de Acidentes 2024 (Agrupados por ocorr&ecirc;ncia)</td>
    <td><a href="https://drive.google.com/file/d/DDD444/view">CSV</a></td></tr>
</table>
"""


def test_listar_arquivos_usa_o_primeiro_link_de_cada_linha():
    download = carregar_lambda("prf_download")
    assert download.listar_arquivos(PAGINA) == {
        (2025, "ocorrencias"): "AAA111",
        (2025, "pessoas"): "BBB222",
        (2024, "ocorrencias"): "DDD444",
    }


def test_download_so_regrava_quando_o_arquivo_muda(s3, monkeypatch):
    download = carregar_lambda("prf_download")
    monkeypatch.setattr(download, "s3", s3)
    monkeypatch.setattr(download, "BRONZE_BUCKET", "bronze")
    monkeypatch.setattr(download, "ANOS", 1)
    monkeypatch.setattr(download, "_get", lambda url, timeout=120: PAGINA.encode("utf-8"))
    monkeypatch.setattr(download, "buscar_ipca", lambda: {"fator_acumulado": 1.9})

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("a.csv", "x")
    monkeypatch.setattr(download, "baixar_do_drive", lambda id_arquivo: buf.getvalue())

    primeira = download.handler({}, None)
    assert [a["status"] for a in primeira["arquivos"]] == ["atualizado", "atualizado"]
    assert ("bronze", "referencias/ipca_sgs433.json") in s3.objetos

    segunda = download.handler({}, None)
    assert [a["status"] for a in segunda["arquivos"]] == ["sem_mudanca", "sem_mudanca"]
