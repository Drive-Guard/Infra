"""
Lambda Ingest — porta de entrada da nuvem.

API Gateway (POST /v1/eventos) -> esta função -> S3 Bronze.

Responsabilidade principal: validar o formato do lote e gravar o JSON cru,
imutável, na camada Bronze. Nenhuma transformação acontece aqui — é o que
mantém a Bronze auditável e permite reprocessar a Silver do zero.

POST /v1/modelos devolve um link de upload (URL pré-assinada do S3) para o
modelo treinado ir ao bucket de artefatos sem credencial da AWS no
computador: basta a mesma API Key das leituras. O link vale só para aquele
arquivo, naquela pasta, por alguns minutos; quem envia pede um novo a cada
upload (e outro se o primeiro vencer).

Esta função NÃO roda dentro da VPC: ela só fala com o S3, e manter a Lambda
fora da VPC evita o custo de ENI e o cold start extra da interface de rede.
"""

import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# SigV4: as URLs pré-assinadas de upload de modelo exigem (e o cabeçalho SSE entra na assinatura).
s3 = boto3.client("s3", config=Config(signature_version="s3v4"))

BRONZE_BUCKET = os.environ["BRONZE_BUCKET"]
BRONZE_PREFIX = os.environ.get("BRONZE_PREFIX", "eventos")
MAX_LEITURAS = int(os.environ.get("MAX_LEITURAS_POR_LOTE", "1000"))

ARTIFACTS_BUCKET = os.environ.get("ARTIFACTS_BUCKET", "")
VALIDADE_LINK_MODELO_S = int(os.environ.get("VALIDADE_LINK_MODELO_S", "900"))
MAX_MODELO_BYTES = int(os.environ.get("MAX_MODELO_MB", "500")) * 1024 * 1024
EXTENSOES_MODELO = {".pkl", ".joblib", ".h5", ".keras", ".onnx", ".pt", ".pth", ".json", ".zip"}

CAMPOS_OBRIGATORIOS_LEITURA = ("registrado_em", "score_fadiga", "estado")
ESTADOS_VALIDOS = {"alerta", "fadiga", "sonolento"}


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _validar(payload: dict) -> list:
    """Valida o lote e devolve a lista de erros encontrados (vazia = ok)."""
    erros = []

    if not isinstance(payload, dict):
        return ["corpo deve ser um objeto JSON"]

    if not payload.get("device_id"):
        erros.append("device_id ausente")

    if not payload.get("motorista_hash"):
        erros.append("motorista_hash ausente")

    leituras = payload.get("leituras")
    if not isinstance(leituras, list) or not leituras:
        erros.append("leituras deve ser uma lista nao vazia")
        return erros

    if len(leituras) > MAX_LEITURAS:
        erros.append(f"lote com {len(leituras)} leituras excede o maximo de {MAX_LEITURAS}")
        return erros

    for i, leitura in enumerate(leituras):
        if not isinstance(leitura, dict):
            erros.append(f"leituras[{i}] deve ser um objeto")
            continue

        for campo in CAMPOS_OBRIGATORIOS_LEITURA:
            if leitura.get(campo) is None:
                erros.append(f"leituras[{i}].{campo} ausente")

        estado = leitura.get("estado")
        if estado is not None and estado not in ESTADOS_VALIDOS:
            erros.append(f"leituras[{i}].estado invalido: {estado}")

        score = leitura.get("score_fadiga")
        if isinstance(score, (int, float)) and not (0 <= score <= 100):
            erros.append(f"leituras[{i}].score_fadiga fora da faixa 0-100")

    return erros


def _link_modelo(payload: dict) -> dict:
    """POST /v1/modelos: {"arquivo": "pipeline_voting.pkl", "tamanho": 1234} -> link de upload."""
    if not ARTIFACTS_BUCKET:
        return _response(503, {"erro": "bucket de artefatos nao configurado"})
    if not isinstance(payload, dict):
        return _response(400, {"erro": "corpo deve ser um objeto JSON"})
    nome = os.path.basename(str(payload.get("arquivo") or "")).strip()
    raiz, extensao = os.path.splitext(nome)
    raiz = re.sub(r"[^A-Za-z0-9._-]+", "-", raiz).strip("-.")
    if not raiz or extensao.lower() not in EXTENSOES_MODELO:
        return _response(422, {"erro": "arquivo invalido", "detalhe": f"use um nome com extensao {sorted(EXTENSOES_MODELO)}"})
    tamanho = payload.get("tamanho")
    if isinstance(tamanho, (int, float)) and tamanho > MAX_MODELO_BYTES:
        return _response(413, {"erro": "arquivo grande demais", "maximo_bytes": MAX_MODELO_BYTES})

    versao = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    chave = f"modelos/{raiz}/{versao}/{raiz}{extensao.lower()}"
    cabecalhos = {"Content-Type": "application/octet-stream", "x-amz-server-side-encryption": "AES256"}
    url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": ARTIFACTS_BUCKET, "Key": chave, "ContentType": cabecalhos["Content-Type"], "ServerSideEncryption": "AES256"},
        ExpiresIn=VALIDADE_LINK_MODELO_S,
    )
    logger.info("Link de upload de modelo: %s", chave)
    return _response(
        201,
        {
            "metodo": "PUT",
            "url": url,
            "cabecalhos": cabecalhos,
            "chave": chave,
            "uri": f"s3://{ARTIFACTS_BUCKET}/{chave}",
            "expira_em_segundos": VALIDADE_LINK_MODELO_S,
        },
    )


def handler(event, context):
    request_id = getattr(context, "aws_request_id", str(uuid.uuid4()))

    # Health check simples: GET /v1/health
    if event.get("httpMethod") == "GET":
        return _response(200, {"status": "ok", "servico": "driveguard-ingest"})

    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64

        raw_body = base64.b64decode(raw_body).decode("utf-8")

    try:
        payload = json.loads(raw_body)
    except (ValueError, TypeError) as exc:
        logger.warning("JSON invalido: %s", exc)
        return _response(400, {"erro": "JSON invalido", "detalhe": str(exc)})

    if (event.get("resource") or event.get("path") or "").rstrip("/").endswith("/modelos"):
        return _link_modelo(payload)

    erros = _validar(payload)
    if erros:
        logger.warning("Lote rejeitado: %s", erros)
        return _response(422, {"erro": "payload invalido", "detalhes": erros})

    agora = datetime.now(timezone.utc)
    ingest_id = str(uuid.uuid4())

    envelope = {
        "ingest_id": ingest_id,
        "ingest_timestamp": agora.isoformat(),
        "api_request_id": request_id,
        "source_ip": event.get("requestContext", {})
        .get("identity", {})
        .get("sourceIp"),
        "schema_version": payload.get("schema_version", "1.0"),
        "payload": payload,
    }

    # Particionamento por data e hora: o ETL Silver e qualquer reprocessamento
    # conseguem recortar uma janela sem varrer o bucket inteiro.
    key = (
        f"{BRONZE_PREFIX}/"
        f"dt={agora:%Y-%m-%d}/"
        f"hr={agora:%H}/"
        f"{payload['device_id']}/"
        f"{agora:%Y%m%dT%H%M%S}-{ingest_id}.json"
    )

    try:
        s3.put_object(
            Bucket=BRONZE_BUCKET,
            Key=key,
            Body=json.dumps(envelope, ensure_ascii=False).encode("utf-8"),
            ContentType="application/json",
            ServerSideEncryption="AES256",
            Metadata={
                "device-id": str(payload["device_id"]),
                "ingest-id": ingest_id,
                "leituras": str(len(payload["leituras"])),
            },
        )
    except ClientError as exc:
        logger.exception("Falha ao gravar no Bronze")
        return _response(502, {"erro": "falha ao persistir o lote", "detalhe": str(exc)})

    logger.info(
        "Lote aceito: device=%s leituras=%d alertas=%d key=%s",
        payload["device_id"],
        len(payload["leituras"]),
        len(payload.get("alertas") or []),
        key,
    )

    return _response(
        202,
        {
            "status": "aceito",
            "ingest_id": ingest_id,
            "bronze_key": key,
            "leituras_recebidas": len(payload["leituras"]),
            "alertas_recebidos": len(payload.get("alertas") or []),
        },
    )
