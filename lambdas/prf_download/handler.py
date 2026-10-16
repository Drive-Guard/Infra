"""
Lambda prf_download — busca a base aberta da PRF e as referências do ROI.

Roda FORA da VPC, porque precisa da internet, e só grava no S3. A carga no
banco é feita pela Lambda prf_carga (dentro da VPC), disparada pelo arquivo
novo no bucket. É o padrão do projeto: quem fala com a internet fica fora da
VPC, quem fala com o banco fica dentro, e as duas trocam arquivos pelo S3.

O que faz, uma vez por semana (EventBridge) e a cada `terraform apply`:

1. Lê a página de dados abertos da PRF e encontra, para os N anos mais
   recentes, os arquivos "Agrupados por ocorrência" (um acidente por linha) e
   "Agrupados por pessoa" (de onde sai o tipo de veículo envolvido).
2. Baixa cada zip do Google Drive e só grava no Bronze se o conteúdo mudou
   (compara o SHA-256 com o do arquivo anterior). Sem mudança, nada dispara.
3. Busca no Banco Central o IPCA acumulado desde dez/2014 (série SGS 433) e
   grava em referencias/, para corrigir os custos do IPEA usados no ROI.

Usa só a biblioteca padrão + boto3 (já inclusa no runtime da Lambda).
"""

from __future__ import annotations

import hashlib
import html
import io
import json
import logging
import os
import re
import urllib.request
import zipfile
from datetime import date, datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

s3 = boto3.client("s3")

BRONZE_BUCKET = os.environ.get("BRONZE_BUCKET", "")
ANOS = int(os.environ.get("PRF_ANOS", "2"))
PAGINA = os.environ.get(
    "PRF_PAGINA_URL",
    "https://www.gov.br/prf/pt-br/acesso-a-informacao/dados-abertos/dados-abertos-da-prf",
)
USER_AGENT = "Mozilla/5.0 (DriveGuard ETL; +https://github.com/Drive-Guard/Infra)"

# Rótulos exatos da página. "Agrupados por pessoa - Todas as causas e tipos de
# acidentes" é outra base (uma linha por causa) e fica de fora de propósito.
CONJUNTOS = {
    "ocorrencias": "(Agrupados por ocorrência)",
    "pessoas": "(Agrupados por pessoa)",
}


def _get(url: str, timeout: int = 120) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


# ---------------------------------------------------------------------------
# Página da PRF
# ---------------------------------------------------------------------------

def listar_arquivos(pagina_html: str) -> dict[tuple[int, str], str]:
    """
    Devolve {(ano, conjunto): id_do_arquivo_no_drive}.

    Cada linha da tabela traz um link do Google Drive. Algumas linhas têm um
    SEGUNDO link que aponta para o arquivo de outra linha (vício do HTML da
    página), então vale sempre o primeiro.
    """
    arquivos: dict[tuple[int, str], str] = {}
    for linha in re.findall(r"<tr[^>]*>(.*?)</tr>", pagina_html, re.S | re.I):
        texto = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", linha))).strip()
        m_ano = re.search(r"Acidentes (\d{4})", texto)
        if not m_ano:
            continue
        for conjunto, rotulo in CONJUNTOS.items():
            if rotulo not in texto:
                continue
            m_link = re.search(r'href="[^"]*?/file/d/([A-Za-z0-9_-]+)', linha)
            if m_link:
                arquivos.setdefault((int(m_ano.group(1)), conjunto), m_link.group(1))
    return arquivos


def baixar_do_drive(id_arquivo: str) -> bytes:
    """Baixa um arquivo público do Google Drive, pulando o aviso de antivírus."""
    url = f"https://drive.usercontent.google.com/download?id={id_arquivo}&export=download&confirm=t"
    dados = _get(url, timeout=300)
    if not dados.startswith(b"PK"):
        raise ValueError(
            f"O Drive não devolveu um zip para {id_arquivo} (início: {dados[:60]!r})"
        )
    zipfile.ZipFile(io.BytesIO(dados)).testzip()  # zip corrompido falha aqui
    return dados


def chave_bronze(conjunto: str, ano: int) -> str:
    return f"prf/conjunto={conjunto}/ano={ano}/{conjunto}_{ano}.zip"


def sha_anterior(chave: str) -> str | None:
    try:
        cab = s3.head_object(Bucket=BRONZE_BUCKET, Key=chave)
        return cab.get("Metadata", {}).get("sha256")
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
            return None
        raise


# ---------------------------------------------------------------------------
# IPCA (Banco Central)
# ---------------------------------------------------------------------------

def buscar_ipca() -> dict:
    """
    IPCA acumulado de jan/2015 até o último mês publicado (série SGS 433).

    A API do Banco Central limita cada consulta a 10 anos, então a busca é
    feita em janelas.
    """
    hoje = date.today()
    meses = []
    inicio = 2015
    while inicio <= hoje.year:
        fim = min(inicio + 9, hoje.year)
        url = (
            "https://api.bcb.gov.br/dados/serie/bcdata.sgs.433/dados?formato=json"
            f"&dataInicial=01/01/{inicio}&dataFinal=31/12/{fim}"
        )
        meses.extend(json.loads(_get(url, timeout=60)))
        inicio = fim + 1

    fator = 1.0
    for m in meses:
        fator *= 1 + float(m["valor"]) / 100

    ultimo = meses[-1]["data"]  # dd/mm/aaaa
    return {
        "serie": "SGS 433 (IPCA, variação mensal)",
        "fator_acumulado": round(fator, 6),
        "inicio": "01/2015",
        "fim": ultimo[3:],
        "meses": len(meses),
        "obtido_em": datetime.now(timezone.utc).isoformat(),
    }


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

def handler(event, context):
    if not BRONZE_BUCKET:
        raise RuntimeError("BRONZE_BUCKET não configurado")

    pagina = _get(PAGINA).decode("utf-8", "replace")
    arquivos = listar_arquivos(pagina)
    if not arquivos:
        raise RuntimeError("Nenhum arquivo de acidentes encontrado na página da PRF; o layout pode ter mudado.")

    anos = sorted({ano for ano, _ in arquivos}, reverse=True)[:ANOS]
    resultado = {"anos": anos, "arquivos": [], "ipca": None}

    # Ocorrências primeiro: a carga de pessoas só casa veículos com acidentes
    # que já existem (e guarda o resto para casar depois).
    for conjunto in ("ocorrencias", "pessoas"):
        for ano in anos:
            id_arquivo = arquivos.get((ano, conjunto))
            if not id_arquivo:
                resultado["arquivos"].append({"conjunto": conjunto, "ano": ano, "status": "ausente"})
                continue

            dados = baixar_do_drive(id_arquivo)
            sha = hashlib.sha256(dados).hexdigest()
            chave = chave_bronze(conjunto, ano)

            if sha_anterior(chave) == sha:
                logger.info("%s %s sem mudança, nada a fazer", conjunto, ano)
                resultado["arquivos"].append({"conjunto": conjunto, "ano": ano, "status": "sem_mudanca"})
                continue

            s3.put_object(
                Bucket=BRONZE_BUCKET,
                Key=chave,
                Body=dados,
                ContentType="application/zip",
                ServerSideEncryption="AES256",
                Metadata={"sha256": sha, "drive-id": id_arquivo, "conjunto": conjunto, "ano": str(ano)},
            )
            logger.info("Gravado %s (%.1f MB)", chave, len(dados) / 1e6)
            resultado["arquivos"].append(
                {"conjunto": conjunto, "ano": ano, "status": "atualizado", "bytes": len(dados)}
            )

    try:
        ipca = buscar_ipca()
        s3.put_object(
            Bucket=BRONZE_BUCKET,
            Key="referencias/ipca_sgs433.json",
            Body=json.dumps(ipca, ensure_ascii=False).encode("utf-8"),
            ContentType="application/json",
            ServerSideEncryption="AES256",
        )
        resultado["ipca"] = ipca
    except Exception as exc:  # o IPCA é acessório: não derruba a carga da PRF
        logger.warning("Falha ao buscar o IPCA: %s", exc)
        resultado["ipca"] = {"erro": str(exc)[:300]}

    logger.info("Resultado: %s", json.dumps(resultado, ensure_ascii=False))
    return resultado
