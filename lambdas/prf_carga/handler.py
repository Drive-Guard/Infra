"""
Lambda prf_carga — carrega a base da PRF no banco.

Disparada pelo S3 quando a prf_download grava um arquivo no Bronze:

  prf/conjunto=ocorrencias/...  -> silver.incidentes (um acidente por linha)
  prf/conjunto=pessoas/...      -> tipos de veículo envolvidos em cada acidente
  referencias/ipca_sgs433.json  -> fator de correção do IPCA usado no ROI

Roda dentro da VPC (precisa do RDS). Lê o CSV em fluxo e grava com COPY,
sem pandas, para caber com folga na memória da Lambda.

Idempotência:
  * silver.prf_cargas guarda (s3_key, etag): o mesmo arquivo não é recarregado;
  * os acidentes entram por UPSERT na chave (origem, id da PRF), então uma
    versão nova do arquivo do ano corrente atualiza sem duplicar.

A ordem de chegada dos dois arquivos não importa: os veículos ficam em
silver.prf_veiculos_staging e são casados com os acidentes ao fim de cada
carga, seja ela de ocorrências ou de pessoas.

Ao terminar, atualiza as views mv_prf_* (as outras views são da etl_gold).
"""

from __future__ import annotations

import csv
import io
import json
import logging
import os
import re
import tempfile
import time
import urllib.parse
import zipfile

import boto3

from db import get_connection, reset_connection

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

s3 = boto3.client("s3")

# Causas que a PRF registra para sono. Em 2025 só aparece "Condutor Dormindo";
# os outros termos cobrem nomenclaturas de anos anteriores.
RE_CAUSA_SONO = re.compile(r"dormindo|sono|fadiga|cansa", re.I)

GRAVIDADE = {
    "com vítimas fatais": "com_fatais",
    "com vitimas fatais": "com_fatais",
    "com vítimas feridas": "com_feridos",
    "com vitimas feridas": "com_feridos",
    "sem vítimas": "sem_vitimas",
    "sem vitimas": "sem_vitimas",
}

COLUNAS_OCORRENCIA = [
    "id", "ocorrido", "uf", "municipio", "br", "km", "latitude", "longitude",
    "causa", "tipo_acidente", "gravidade", "mortos", "feridos", "ilesos",
    "fase_dia", "condicao_meteorologica", "tracado_via", "sono",
]


# ---------------------------------------------------------------------------
# Limpeza de campos (a PRF usa vírgula decimal, "NA" para vazio e já mudou o
# formato de data entre os anos)
# ---------------------------------------------------------------------------

def _vazio(v: str | None) -> bool:
    return v is None or v.strip() in ("", "NA", "N/A", "(null)", "null")


def num(v: str | None) -> str:
    """Número com vírgula decimal ("-23,48" ou "1.234,5") para "-23.48" / "1234.5"."""
    if _vazio(v):
        return ""
    v = v.strip()
    if "," in v and "." in v:  # ponto como separador de milhar
        v = v.replace(".", "")
    return v.replace(",", ".")


def inteiro(v: str | None) -> str:
    if _vazio(v):
        return "0"
    try:
        return str(int(float(v.replace(",", "."))))
    except ValueError:
        return "0"


def texto(v: str | None) -> str:
    return "" if _vazio(v) else v.strip()


def data_hora(data: str, hora: str) -> str:
    """Devolve 'AAAA-MM-DD HH:MM:SS' (horário local, sem fuso)."""
    data = data.strip()
    if "/" in data:  # formatos antigos: dd/mm/aaaa ou dd/mm/aa
        d, m, a = data.split("/")
        if len(a) == 2:
            a = "20" + a
        data = f"{a}-{m.zfill(2)}-{d.zfill(2)}"
    hora = (hora or "00:00:00").strip()
    if len(hora) == 5:
        hora += ":00"
    return f"{data} {hora}"


def br(v: str | None) -> str:
    if _vazio(v):
        return ""
    digitos = re.sub(r"\D", "", v)
    return digitos.lstrip("0") or digitos


# ---------------------------------------------------------------------------
# Leitura do zip
# ---------------------------------------------------------------------------

def abrir_csv(caminho_zip: str):
    """Abre o primeiro .csv do zip como texto (a PRF publica em latin-1)."""
    z = zipfile.ZipFile(caminho_zip)
    nome = next((n for n in z.namelist() if n.lower().endswith(".csv")), None)
    if not nome:
        raise ValueError(f"Nenhum CSV dentro de {caminho_zip}")
    bruto = z.open(nome)
    return io.TextIOWrapper(bruto, encoding="latin-1", newline=""), nome


def linhas_ocorrencias(leitor: csv.DictReader):
    for r in leitor:
        if _vazio(r.get("id")) or _vazio(r.get("data_inversa")):
            continue
        causa = texto(r.get("causa_acidente"))
        mortos, feridos = inteiro(r.get("mortos")), inteiro(r.get("feridos"))
        gravidade = GRAVIDADE.get(texto(r.get("classificacao_acidente")).lower(), "")
        if not gravidade:
            # Boletim sem classificação ("NA"): deduz pelas vítimas contadas.
            gravidade = (
                "com_fatais" if int(mortos) > 0
                else "com_feridos" if int(feridos) > 0
                else "sem_vitimas"
            )
        yield [
            r["id"].strip(),
            data_hora(r["data_inversa"], r.get("horario", "")),
            texto(r.get("uf"))[:2],
            texto(r.get("municipio")),
            br(r.get("br")),
            num(r.get("km")),
            num(r.get("latitude")),
            num(r.get("longitude")),
            causa,
            texto(r.get("tipo_acidente")),
            gravidade,
            mortos,
            feridos,
            inteiro(r.get("ilesos")),
            texto(r.get("fase_dia")),
            texto(r.get("condicao_metereologica")),
            texto(r.get("tracado_via")),
            "t" if RE_CAUSA_SONO.search(causa or "") else "f",
        ]


def veiculos_por_acidente(leitor: csv.DictReader) -> dict[tuple[str, str], int]:
    """
    Conta veículos distintos por (acidente, tipo de veículo).

    O arquivo tem uma linha por PESSOA, então o mesmo veículo aparece uma vez
    por ocupante; conta-se id_veiculo distinto.
    """
    vistos: dict[tuple[str, str], set] = {}
    for r in leitor:
        tipo = texto(r.get("tipo_veiculo"))
        id_acidente = texto(r.get("id"))
        id_veiculo = texto(r.get("id_veiculo"))
        if not tipo or not id_acidente or not id_veiculo:
            continue
        vistos.setdefault((id_acidente, tipo), set()).add(id_veiculo)
    return {k: len(v) for k, v in vistos.items()}


# ---------------------------------------------------------------------------
# Gravação
# ---------------------------------------------------------------------------

def _para_csv(linhas) -> tuple[io.StringIO, int]:
    buf = io.StringIO()
    w = csv.writer(buf)
    n = 0
    for linha in linhas:
        w.writerow(linha)
        n += 1
    buf.seek(0)
    return buf, n


def gravar_ocorrencias(conn, leitor: csv.DictReader, fonte: str) -> tuple[int, int]:
    cur = conn.cursor()
    cur.execute(
        "CREATE TEMP TABLE tmp_prf_ocorrencias (" + ", ".join(f"{c} TEXT" for c in COLUNAS_OCORRENCIA) + ") ON COMMIT DROP"
    )
    buf, lidas = _para_csv(linhas_ocorrencias(leitor))
    cur.execute("COPY tmp_prf_ocorrencias FROM STDIN WITH (FORMAT csv)", stream=buf)

    cur.execute(
        """
        INSERT INTO silver.incidentes (
            empresa_id, origem, origem_id_externo, ocorrido_em, uf, municipio, br, km,
            latitude, longitude, causa, tipo_acidente, gravidade, qtd_mortos, qtd_feridos,
            qtd_ilesos, fase_dia, condicao_meteorologica, tracado_via, relacionado_sonolencia,
            fonte_arquivo
        )
        SELECT
            NULL, 'prf', t.id,
            (t.ocorrido::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
            NULLIF(t.uf, ''), NULLIF(t.municipio, ''), NULLIF(t.br, ''),
            NULLIF(t.km, '')::NUMERIC,
            NULLIF(t.latitude, '')::NUMERIC, NULLIF(t.longitude, '')::NUMERIC,
            NULLIF(t.causa, ''), NULLIF(t.tipo_acidente, ''),
            NULLIF(t.gravidade, '')::silver.gravidade_incidente,
            t.mortos::SMALLINT, t.feridos::SMALLINT, t.ilesos::SMALLINT,
            NULLIF(t.fase_dia, ''), NULLIF(t.condicao_meteorologica, ''), NULLIF(t.tracado_via, ''),
            t.sono::BOOLEAN,
            %s
        FROM tmp_prf_ocorrencias t
        ON CONFLICT (origem, origem_id_externo) DO UPDATE SET
            ocorrido_em            = EXCLUDED.ocorrido_em,
            uf                     = EXCLUDED.uf,
            municipio              = EXCLUDED.municipio,
            br                     = EXCLUDED.br,
            km                     = EXCLUDED.km,
            latitude               = EXCLUDED.latitude,
            longitude              = EXCLUDED.longitude,
            causa                  = EXCLUDED.causa,
            tipo_acidente          = EXCLUDED.tipo_acidente,
            gravidade              = EXCLUDED.gravidade,
            qtd_mortos             = EXCLUDED.qtd_mortos,
            qtd_feridos            = EXCLUDED.qtd_feridos,
            qtd_ilesos             = EXCLUDED.qtd_ilesos,
            fase_dia               = EXCLUDED.fase_dia,
            condicao_meteorologica = EXCLUDED.condicao_meteorologica,
            tracado_via            = EXCLUDED.tracado_via,
            relacionado_sonolencia = EXCLUDED.relacionado_sonolencia,
            fonte_arquivo          = EXCLUDED.fonte_arquivo
        """,
        (fonte,),
    )
    gravadas = cur.rowcount
    # Coordenada fora do território brasileiro é erro de digitação no boletim:
    # o acidente fica, só sem ponto no mapa.
    cur.execute(
        """
        UPDATE silver.incidentes SET latitude = NULL, longitude = NULL
        WHERE origem = 'prf' AND fonte_arquivo = %s
          AND (latitude NOT BETWEEN -34 AND 6 OR longitude NOT BETWEEN -74 AND -34)
        """,
        (fonte,),
    )
    cur.close()
    return lidas, gravadas


def gravar_veiculos(conn, leitor: csv.DictReader) -> tuple[int, int]:
    contagem = veiculos_por_acidente(leitor)
    cur = conn.cursor()
    cur.execute(
        "CREATE TEMP TABLE tmp_prf_veiculos (id_acidente TEXT, tipo_veiculo TEXT, quantidade SMALLINT) ON COMMIT DROP"
    )
    buf, lidas = _para_csv([a, t, q] for (a, t), q in contagem.items())
    cur.execute("COPY tmp_prf_veiculos FROM STDIN WITH (FORMAT csv)", stream=buf)
    cur.execute(
        """
        INSERT INTO silver.prf_veiculos_staging (id_acidente, tipo_veiculo, quantidade)
        SELECT id_acidente, tipo_veiculo, quantidade FROM tmp_prf_veiculos
        ON CONFLICT (id_acidente, tipo_veiculo) DO UPDATE SET quantidade = EXCLUDED.quantidade
        """
    )
    gravadas = cur.rowcount
    cur.close()
    return lidas, gravadas


def casar_veiculos(conn) -> int:
    """Liga os veículos do staging aos acidentes que já existem."""
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO silver.incidentes_veiculos (incidente_id, tipo_veiculo, quantidade)
        SELECT i.id, s.tipo_veiculo, s.quantidade
        FROM silver.prf_veiculos_staging s
        JOIN silver.incidentes i ON i.origem = 'prf' AND i.origem_id_externo = s.id_acidente
        ON CONFLICT (incidente_id, tipo_veiculo) DO UPDATE SET quantidade = EXCLUDED.quantidade
        """
    )
    n = cur.rowcount
    cur.close()
    return n


def atualizar_views_prf(conn) -> list[dict]:
    """REFRESH CONCURRENTLY das views mv_prf_* (precisa de autocommit)."""
    resultado = []
    anterior = conn.autocommit
    conn.autocommit = True
    cur = conn.cursor()
    try:
        cur.execute("SELECT view_name FROM gold.vw_materialized_views WHERE grupo = 'prf'")
        for (nome,) in cur.fetchall():
            inicio = time.monotonic()
            cur.execute(f'REFRESH MATERIALIZED VIEW CONCURRENTLY gold."{nome}"')
            resultado.append({"view": nome, "ms": round((time.monotonic() - inicio) * 1000)})
    finally:
        cur.close()
        conn.autocommit = anterior
    return resultado


# ---------------------------------------------------------------------------
# Orquestração
# ---------------------------------------------------------------------------

def _conjunto_e_ano(chave: str) -> tuple[str, int | None]:
    m_conj = re.search(r"conjunto=([a-z]+)", chave)
    m_ano = re.search(r"ano=(\d{4})", chave)
    return (m_conj.group(1) if m_conj else ""), (int(m_ano.group(1)) if m_ano else None)


def carregar_zip(conn, caminho_zip: str, chave: str, etag: str) -> dict:
    """Carrega um zip da PRF já baixado. Separado do handler para ser testável."""
    conjunto, ano = _conjunto_e_ano(chave)
    if conjunto not in ("ocorrencias", "pessoas"):
        raise ValueError(f"Conjunto desconhecido na chave {chave}")

    cur = conn.cursor()
    cur.execute(
        "SELECT status FROM silver.prf_cargas WHERE s3_key = %s AND etag = %s", (chave, etag)
    )
    linha = cur.fetchone()
    if linha and linha[0] == "ok":
        cur.close()
        return {"chave": chave, "status": "ja_carregado"}

    cur.execute(
        """
        INSERT INTO silver.prf_cargas (conjunto, ano, s3_key, etag, status)
        VALUES (%s, %s, %s, %s, 'processando')
        ON CONFLICT (s3_key, etag) DO UPDATE SET status = 'processando', erro = NULL, iniciado_em = now()
        RETURNING id
        """,
        (conjunto, ano, chave, etag),
    )
    id_carga = cur.fetchone()[0]
    conn.commit()

    try:
        arquivo, nome_csv = abrir_csv(caminho_zip)
        leitor = csv.DictReader(arquivo, delimiter=";")
        if conjunto == "ocorrencias":
            lidas, gravadas = gravar_ocorrencias(conn, leitor, chave)
        else:
            lidas, gravadas = gravar_veiculos(conn, leitor)
        casados = casar_veiculos(conn)
        cur.execute(
            """
            UPDATE silver.prf_cargas
               SET status = 'ok', linhas_lidas = %s, linhas_gravadas = %s, concluido_em = now()
             WHERE id = %s
            """,
            (lidas, gravadas, id_carga),
        )
        conn.commit()
    except Exception as exc:
        conn.rollback()
        cur.execute(
            "UPDATE silver.prf_cargas SET status = 'erro', erro = %s, concluido_em = now() WHERE id = %s",
            (str(exc)[:2000], id_carga),
        )
        conn.commit()
        raise
    finally:
        cur.close()

    return {
        "chave": chave,
        "csv": nome_csv,
        "conjunto": conjunto,
        "ano": ano,
        "linhas_lidas": lidas,
        "linhas_gravadas": gravadas,
        "veiculos_casados": casados,
        "status": "ok",
    }


def atualizar_ipca(conn, conteudo: dict) -> dict:
    fator = float(conteudo["fator_acumulado"])
    if not 1.0 <= fator <= 10.0:
        raise ValueError(f"Fator de IPCA fora do esperado: {fator}")
    cur = conn.cursor()
    cur.execute(
        """
        UPDATE silver.parametros_roi_padrao
           SET valor = %s, referencia = %s, atualizado_em = now()
         WHERE chave = 'fator_ipca'
        """,
        (round(fator, 4), f"{conteudo.get('inicio', '01/2015')} a {conteudo.get('fim', '?')}"),
    )
    conn.commit()
    cur.close()
    return {"fator_ipca": round(fator, 4), "fim": conteudo.get("fim")}


# Os arquivos chegam em eventos S3 separados e podem disparar cargas ao mesmo
# tempo. As cargas mexem nas mesmas linhas (casamento de veículos, refresh das
# views), então uma trava do PostgreSQL faz uma esperar a outra.
TRAVA_CARGA = 482_001


def handler(event, context):
    try:
        conn = get_connection()
    except Exception:
        reset_connection()
        raise

    cur = conn.cursor()
    cur.execute("SELECT pg_advisory_lock(%s)", (TRAVA_CARGA,))
    conn.commit()
    try:
        return _processar(conn, event)
    finally:
        conn.rollback()  # uma falha no meio deixaria a transação abortada
        cur.execute("SELECT pg_advisory_unlock(%s)", (TRAVA_CARGA,))
        conn.commit()
        cur.close()


def _processar(conn, event) -> list:
    resultados = []
    houve_prf = False

    for registro in event.get("Records") or []:
        bucket = registro["s3"]["bucket"]["name"]
        chave = urllib.parse.unquote_plus(registro["s3"]["object"]["key"])
        etag = registro["s3"]["object"].get("eTag") or registro["s3"]["object"].get("etag") or ""

        if chave.startswith("referencias/"):
            corpo = s3.get_object(Bucket=bucket, Key=chave)["Body"].read()
            resultados.append(atualizar_ipca(conn, json.loads(corpo)))
            continue

        if not chave.startswith("prf/") or not chave.endswith(".zip"):
            continue

        with tempfile.TemporaryDirectory() as tmp:
            caminho = os.path.join(tmp, "arquivo.zip")
            s3.download_file(bucket, chave, caminho)
            resultados.append(carregar_zip(conn, caminho, chave, etag))
            houve_prf = True

    if houve_prf:
        resultados.append({"views_prf": atualizar_views_prf(conn)})

    logger.info("Carga concluída: %s", json.dumps(resultados, ensure_ascii=False, default=str))
    return resultados
