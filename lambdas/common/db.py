"""
Conexão com o RDS PostgreSQL compartilhada pelas Lambdas de ETL.

Usa pg8000 (driver PostgreSQL 100% Python puro) em vez de psycopg2. psycopg2
tem extensão em C e precisaria ser compilado no Amazon Linux para virar layer;
pg8000 é instalável com `pip install --target` em qualquer sistema operacional,
o que mantém o build reprodutível em Windows, macOS e Linux.

A conexão é criada uma vez por container e reaproveitada entre invocações.
"""

import os
import time
import ssl
import logging

import pg8000.dbapi

logger = logging.getLogger()

# Bundle de CAs do RDS baixado durante o build (scripts/build_lambdas.*).
_RDS_CA_BUNDLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rds-ca-bundle.pem")

_connection = None


def _ssl_context() -> ssl.SSLContext:
    """
    Contexto TLS para falar com o RDS, com validação completa da cadeia.

    O parameter group do banco define rds.force_ssl=1, então a conexão sem TLS
    é recusada do outro lado. Aqui exigimos também que o certificado do
    servidor seja verificado contra o bundle oficial de CAs do RDS, embutido no
    pacote da Lambda pelo script de build.

    Se o bundle não estiver presente, a função falha em vez de desligar a
    verificação: uma conexão sem validação de cadeia aceitaria um servidor
    forjado, e o ETL trafega dados de motoristas.
    """
    if not os.path.exists(_RDS_CA_BUNDLE):
        raise RuntimeError(
            "rds-ca-bundle.pem nao encontrado no pacote da Lambda. "
            "Rode scripts/build_lambdas.ps1 (ou .sh) antes do terraform apply."
        )

    ctx = ssl.create_default_context(cafile=_RDS_CA_BUNDLE)
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


def _conectar():
    return pg8000.dbapi.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        database=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        ssl_context=_ssl_context(),
        timeout=int(os.environ.get("DB_CONNECT_TIMEOUT", "10")),
        application_name=os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "driveguard-etl"),
    )


def get_connection():
    """
    Devolve uma conexão viva, recriando-a se o container reciclou o socket.

    A primeira conexão tem retry com backoff: no `terraform apply` a Lambda de
    migração é invocada assim que o RDS reporta "available", e nesse instante
    a ENI da função na subnet privada ainda pode estar sendo anexada. Sem o
    retry, o apply falharia por uma corrida de poucos segundos.
    """
    global _connection

    if _connection is not None:
        try:
            cur = _connection.cursor()
            cur.execute("SELECT 1")
            cur.close()
            return _connection
        except Exception:
            logger.info("Conexao anterior invalida, reconectando.")
            try:
                _connection.close()
            except Exception:
                pass
            _connection = None

    tentativas = int(os.environ.get("DB_CONNECT_RETRIES", "6"))
    espera = float(os.environ.get("DB_CONNECT_BACKOFF_SECONDS", "3"))

    ultimo_erro = None
    for tentativa in range(1, tentativas + 1):
        try:
            _connection = _conectar()
            _connection.autocommit = False
            if tentativa > 1:
                logger.info("Conectado ao RDS na tentativa %d.", tentativa)
            return _connection
        except Exception as exc:
            ultimo_erro = exc
            if tentativa == tentativas:
                break
            logger.warning(
                "Conexao com o RDS falhou (tentativa %d/%d): %s. Nova tentativa em %.0fs.",
                tentativa, tentativas, exc, espera,
            )
            time.sleep(espera)
            espera = min(espera * 2, 30)

    raise RuntimeError(
        f"Nao foi possivel conectar ao RDS em {tentativas} tentativas: {ultimo_erro}"
    ) from ultimo_erro


def reset_connection() -> None:
    """Descarta a conexão em cache. Usado após erro fatal de transporte."""
    global _connection
    if _connection is not None:
        try:
            _connection.close()
        except Exception:
            pass
    _connection = None
