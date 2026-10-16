"""
Lambda db_migrate — aplica o DDL no RDS.

Lê os scripts .sql do bucket de artefatos (prefixo sql/), em ordem alfabética,
e os executa contra o banco. É invocada uma vez pelo Terraform ao final do
apply (aws_lambda_invocation) e pode ser chamada à mão depois para reaplicar
o schema:

    aws lambda invoke --function-name driveguard-dev-db-migrate \
        --payload '{"seed": true}' /dev/stdout

Todos os scripts são idempotentes (CREATE IF NOT EXISTS, CREATE OR REPLACE,
DROP ... CASCADE antes de recriar as views), então reexecutar é seguro.

Para refazer a massa de demonstração (scripts/injetar_dados.*), o evento
{"seed": true, "resemear": true, "dias": 180} apaga a frota (empresas, câmeras
e tudo que depende delas) e roda o seed de novo com `dias` de histórico; a base
da PRF fica.

Cada arquivo roda numa transação própria: se o seed falhar, o schema já
aplicado permanece.

O DDL precisa de trava exclusiva nas tabelas. Antes de começar, a função
encerra sessões esquecidas ("idle in transaction" há mais de 2 minutos e
migrações anteriores ainda esperando trava) e cada script roda com
lock_timeout: se outra sessão segurar a tabela, falha em segundos dizendo
quem bloqueia, em vez de esperar até o limite da Lambda. O evento
{"diagnostico": true} só devolve as sessões abertas no banco.
"""

import json
import logging
import os

import boto3

from db import get_connection, reset_connection

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

s3 = boto3.client("s3")

ARTIFACTS_BUCKET = os.environ["ARTIFACTS_BUCKET"]
SQL_PREFIX = os.environ.get("SQL_PREFIX", "sql/")
# Scripts cujo nome contém este marcador só rodam quando seed=true.
SEED_MARKER = "seed"
DIAS_PADRAO = int(os.environ.get("SEED_DIAS", "120"))
LOCK_TIMEOUT = os.environ.get("MIGRATE_LOCK_TIMEOUT", "60s")

_SESSOES_SQL = """
    SELECT pid, application_name, state, wait_event_type,
           EXTRACT(EPOCH FROM now() - COALESCE(xact_start, query_start))::int AS segundos,
           LEFT(query, 160) AS consulta
      FROM pg_stat_activity
     WHERE datname = current_database() AND pid <> pg_backend_pid()
     ORDER BY segundos DESC NULLS LAST
"""


def _sessoes(cur) -> list:
    cur.execute(_SESSOES_SQL)
    colunas = ["pid", "aplicacao", "estado", "espera", "segundos", "consulta"]
    return [dict(zip(colunas, linha)) for linha in cur.fetchall()]


def _encerrar_esquecidas(cur) -> list:
    """Encerra transações abandonadas e migrações anteriores presas em trava."""
    cur.execute(
        """
        SELECT pid, application_name, state, pg_terminate_backend(pid)
          FROM pg_stat_activity
         WHERE datname = current_database() AND pid <> pg_backend_pid()
           AND (
                (state = 'idle in transaction' AND xact_start < now() - interval '2 minutes')
             OR (application_name = %s AND wait_event_type = 'Lock')
           )
        """,
        (os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "driveguard-dev-db-migrate"),),
    )
    encerradas = [{"pid": r[0], "aplicacao": r[1], "estado": r[2]} for r in cur.fetchall()]
    if encerradas:
        logger.warning("Sessões encerradas antes da migração: %s", encerradas)
    return encerradas


def _listar_scripts():
    paginator = s3.get_paginator("list_objects_v2")
    chaves = []
    for page in paginator.paginate(Bucket=ARTIFACTS_BUCKET, Prefix=SQL_PREFIX):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(".sql"):
                chaves.append(obj["Key"])
    return sorted(chaves)


def _executar(conn, key: str) -> dict:
    corpo = s3.get_object(Bucket=ARTIFACTS_BUCKET, Key=key)["Body"].read().decode("utf-8")

    cur = conn.cursor()
    try:
        cur.execute(f"SET lock_timeout = '{LOCK_TIMEOUT}'")
        # pg8000 envia o texto inteiro no protocolo simple query, que aceita
        # múltiplos statements separados por ';' — inclusive blocos DO $$.
        cur.execute(corpo)
        conn.commit()
        logger.info("Script aplicado: %s", key)
        return {"script": key, "status": "ok"}
    except Exception as exc:
        conn.rollback()
        logger.exception("Falha ao aplicar %s", key)
        resultado = {"script": key, "status": "erro", "erro": str(exc)[:2000]}
        if "lock timeout" in str(exc).lower() or "55P03" in str(exc):
            # Quem está segurando a trava, para o erro já dizer o que fazer.
            resultado["sessoes"] = _sessoes(cur)[:10]
        return resultado
    finally:
        cur.close()


def handler(event, context):
    event = event or {}
    aplicar_seed = bool(event.get("seed", os.environ.get("SEED_DEMO", "false") == "true"))
    dias = max(1, min(400, int(event.get("dias", DIAS_PADRAO))))

    try:
        conn = get_connection()
    except Exception:
        reset_connection()
        raise

    cur = conn.cursor()
    if event.get("diagnostico"):
        sessoes = _sessoes(cur)
        conn.commit()
        cur.close()
        return {"sessoes": sessoes}

    encerradas = _encerrar_esquecidas(cur)
    # O seed lê o tamanho do histórico desta configuração da sessão.
    cur.execute("SELECT set_config('driveguard.dias_historico', %s, false)", (str(dias),))
    if event.get("resemear"):
        # DELETE (e não TRUNCATE) respeita o ON DELETE SET NULL dos acidentes
        # da PRF, que não têm empresa e ficam.
        cur.execute("""
            DO $$ BEGIN
                IF to_regclass('silver.dispositivos') IS NOT NULL THEN
                    DELETE FROM silver.incidentes WHERE origem = 'interno';
                    DELETE FROM silver.dispositivos;
                    DELETE FROM silver.empresas;
                END IF;
            END $$;
        """)
        logger.info("Frota apagada para resemear com %d dias", dias)
    conn.commit()
    cur.close()

    scripts = _listar_scripts()
    if not scripts:
        raise RuntimeError(
            f"Nenhum .sql encontrado em s3://{ARTIFACTS_BUCKET}/{SQL_PREFIX}"
        )

    resultados = []
    for key in scripts:
        nome = key.rsplit("/", 1)[-1].lower()
        if SEED_MARKER in nome and not aplicar_seed:
            logger.info("Seed ignorado (seed=false): %s", key)
            resultados.append({"script": key, "status": "ignorado"})
            continue

        resultados.append(_executar(conn, key))

    erros = [r for r in resultados if r["status"] == "erro"]

    resumo = {
        "scripts_encontrados": len(scripts),
        "aplicados": len([r for r in resultados if r["status"] == "ok"]),
        "ignorados": len([r for r in resultados if r["status"] == "ignorado"]),
        "erros": len(erros),
        "seed": aplicar_seed,
        "dias_historico": dias,
        "resemeado": bool(event.get("resemear")),
        "sessoes_encerradas": encerradas,
        "detalhes": resultados,
    }

    logger.info("Migracao concluida: %s", json.dumps(resumo, ensure_ascii=False)[:2000])

    if erros:
        raise RuntimeError(
            "Migracao falhou em "
            + ", ".join(f"{e['script']}: {e['erro'][:200]}" for e in erros)
        )

    return resumo
