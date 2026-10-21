"""Ingestão: link de upload de modelo (POST /v1/modelos) sem credencial da AWS no cliente."""

from __future__ import annotations

import json
from urllib.parse import parse_qs, urlparse

import pytest

from conftest import carregar_lambda


@pytest.fixture
def ingest(monkeypatch):
    # Assinar a URL é local (não chama a AWS); só precisa de uma credencial qualquer.
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "AKIATESTE")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "segredo-teste")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    modulo = carregar_lambda("ingest")
    monkeypatch.setattr(modulo, "ARTIFACTS_BUCKET", "artefatos-teste")
    return modulo


def pedir(ingest, corpo):
    evento = {"resource": "/modelos", "path": "/modelos", "httpMethod": "POST", "body": json.dumps(corpo)}
    r = ingest.handler(evento, None)
    return r["statusCode"], json.loads(r["body"])


def test_link_de_upload_do_modelo(ingest):
    status, r = pedir(ingest, {"arquivo": "models/saved_models/pipeline_neural_network.pkl", "tamanho": 12_000_000})
    assert status == 201
    assert r["metodo"] == "PUT"
    assert r["chave"].startswith("modelos/pipeline_neural_network/") and r["chave"].endswith("/pipeline_neural_network.pkl")
    url = urlparse(r["url"])
    assert "artefatos-teste" in url.netloc + url.path
    q = parse_qs(url.query)
    assert q["X-Amz-Expires"] == ["900"]
    assert r["cabecalhos"]["x-amz-server-side-encryption"] == "AES256"


def test_link_recusa_arquivo_estranho_ou_grande(ingest):
    assert pedir(ingest, {"arquivo": "../../etc/passwd"})[0] == 422
    assert pedir(ingest, {"arquivo": "modelo.exe"})[0] == 422
    assert pedir(ingest, {"arquivo": "modelo.pkl", "tamanho": 10 * 1024**3})[0] == 413


def test_eventos_continuam_iguais(ingest):
    evento = {"resource": "/eventos", "httpMethod": "POST", "body": json.dumps({"device_id": "x"})}
    assert ingest.handler(evento, None)["statusCode"] == 422
