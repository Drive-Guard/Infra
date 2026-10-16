"""
Fixtures dos testes do ETL.

Os testes rodam contra um PostgreSQL 16 de verdade (o mesmo motor do RDS),
porque o que importa testar aqui é SQL: UPSERT, COPY, views materializadas,
REFRESH CONCURRENTLY. O jeito mais simples de subir um é o script do
repositório Backend, que baixa os binários oficiais via npm:

    cd ../Backend && npm run db:local       # localhost:54329, postgres/postgres

Qualquer outro PostgreSQL 16 serve (Docker, instalação local), apontado pelas
variáveis DG_TEST_PGHOST, DG_TEST_PGPORT, DG_TEST_PGUSER e DG_TEST_PGPASSWORD.
Sem banco disponível, os testes são pulados.
"""

from __future__ import annotations

import importlib.util
import io
import os
import pathlib
import sys

import pytest

RAIZ = pathlib.Path(__file__).resolve().parents[1]
SQL = RAIZ / "sql"

# As Lambdas criam o cliente boto3 no import; sem região o import falha.
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
sys.path.insert(0, str(RAIZ / "lambdas" / "common"))

import pg8000.dbapi  # noqa: E402  (depois do sys.path)

PG = {
    "host": os.environ.get("DG_TEST_PGHOST", "localhost"),
    "port": int(os.environ.get("DG_TEST_PGPORT", "54329")),
    "user": os.environ.get("DG_TEST_PGUSER", "postgres"),
    "password": os.environ.get("DG_TEST_PGPASSWORD", "postgres"),
}

SCHEMA = ["01_schema_silver.sql", "02_enums.sql", "03_cadastros.sql", "04_views_gold.sql"]


def conectar(database: str):
    return pg8000.dbapi.connect(database=database, **PG)


def aplicar(conn, arquivos: list[str]) -> None:
    """Aplica os scripts como a Lambda db_migrate: um por transação."""
    cur = conn.cursor()
    for nome in arquivos:
        cur.execute((SQL / nome).read_text(encoding="utf-8"))
        conn.commit()
    cur.close()


def criar_banco(nome: str, arquivos: list[str]):
    adm = conectar("postgres")
    adm.autocommit = True
    cur = adm.cursor()
    cur.execute(f'DROP DATABASE IF EXISTS "{nome}" WITH (FORCE)')
    cur.execute(f'CREATE DATABASE "{nome}"')
    adm.close()
    conn = conectar(nome)
    aplicar(conn, arquivos)
    return conn


def remover_banco(nome: str) -> None:
    adm = conectar("postgres")
    adm.autocommit = True
    adm.cursor().execute(f'DROP DATABASE IF EXISTS "{nome}" WITH (FORCE)')
    adm.close()


def carregar_lambda(nome: str):
    """Importa lambdas/<nome>/handler.py com um nome de módulo único."""
    caminho = RAIZ / "lambdas" / nome / "handler.py"
    spec = importlib.util.spec_from_file_location(f"lambda_{nome}", caminho)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


class FakeS3:
    """O pedaço da API do S3 que as Lambdas usam, em memória."""

    def __init__(self):
        self.objetos: dict[tuple[str, str], dict] = {}

    def put_object(self, Bucket, Key, Body, Metadata=None, **_):
        corpo = Body if isinstance(Body, bytes) else Body.encode("utf-8")
        self.objetos[(Bucket, Key)] = {"Body": corpo, "Metadata": Metadata or {}}
        return {"ETag": f'"{abs(hash(corpo))}"'}

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(self.objetos[(Bucket, Key)]["Body"])}

    def head_object(self, Bucket, Key):
        from botocore.exceptions import ClientError

        if (Bucket, Key) not in self.objetos:
            raise ClientError({"Error": {"Code": "404"}}, "HeadObject")
        return {"Metadata": self.objetos[(Bucket, Key)]["Metadata"]}

    def download_file(self, Bucket, Key, Filename):
        pathlib.Path(Filename).write_bytes(self.objetos[(Bucket, Key)]["Body"])


@pytest.fixture(scope="session")
def pg():
    try:
        conectar("postgres").close()
    except Exception as exc:  # pragma: no cover - depende do ambiente
        pytest.skip(f"PostgreSQL de teste indisponível em {PG['host']}:{PG['port']} ({exc})")
    return PG


@pytest.fixture(scope="session")
def banco_schema(pg):
    """Banco com o schema completo e sem dados de demonstração."""
    nome = "driveguard_test_etl"
    conn = criar_banco(nome, SCHEMA)
    yield conn
    conn.close()
    remover_banco(nome)


@pytest.fixture
def conn(banco_schema):
    """Conexão limpa para cada teste: apaga os dados, mantém as referências."""
    banco_schema.rollback()
    banco_schema.autocommit = False
    cur = banco_schema.cursor()
    cur.execute(
        """
        TRUNCATE silver.empresas, silver.incidentes, silver.dispositivos,
                 silver.prf_cargas, silver.prf_veiculos_staging,
                 silver.ingestao_controle
        CASCADE
        """
    )
    banco_schema.commit()
    cur.close()
    return banco_schema


@pytest.fixture
def s3():
    return FakeS3()
