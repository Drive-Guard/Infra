"""
Lambda ETL Gold — atualiza as MATERIALIZED VIEWs da camada analítica.

Disparada pelo EventBridge a cada 5 minutos. Lê a lista de views em
gold.vw_materialized_views e roda um
`REFRESH MATERIALIZED VIEW CONCURRENTLY` por view.

Dois detalhes que definem o desenho desta função:

1. CONCURRENTLY mantém a view legível durante o refresh — sem ele o dashboard
   ficaria bloqueado a cada 5 minutos. Em troca exige índice UNIQUE em cada MV
   (criados em sql/02_views_gold.sql) e é mais lento.

2. O PostgreSQL recusa REFRESH ... CONCURRENTLY dentro de um bloco de
   transação, e todo corpo de função plpgsql é um. Por isso o laço vive aqui,
   em Python, com a conexão em autocommit — e não numa função no banco.

A falha de uma view não impede as demais: cada refresh é isolado e o erro é
acumulado para o final.
"""

import logging
import os
import time

import boto3

from db import get_connection, reset_connection

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

cloudwatch = boto3.client("cloudwatch")

METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "DriveGuard/ETL")
# Teto por view: se uma agregação degradar, as outras ainda cabem na janela
# de 5 minutos entre execuções.
STATEMENT_TIMEOUT_MS = int(os.environ.get("STATEMENT_TIMEOUT_MS", "120000"))


def _listar_views(conn) -> list:
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT view_name, tem_indice_unico FROM gold.vw_materialized_views"
        )
        return [(row[0], bool(row[1])) for row in cur.fetchall()]
    finally:
        cur.close()


def _refresh(conn, view_name: str, concorrente: bool) -> float:
    """Atualiza uma view e devolve a duração em milissegundos."""
    modo = "CONCURRENTLY " if concorrente else ""
    # view_name vem do catálogo do próprio PostgreSQL (pg_class), não de
    # entrada externa; ainda assim é citado com aspas duplas.
    sql = f'REFRESH MATERIALIZED VIEW {modo}gold."{view_name}"'

    cur = conn.cursor()
    inicio = time.monotonic()
    try:
        cur.execute(f"SET statement_timeout = {STATEMENT_TIMEOUT_MS}")
        cur.execute(sql)
    finally:
        cur.close()
    return round((time.monotonic() - inicio) * 1000, 2)


def _publicar_metricas(resultados: list) -> None:
    metricas = []
    for r in resultados:
        metricas.append(
            {
                "MetricName": "RefreshDuracaoMs",
                "Dimensions": [{"Name": "View", "Value": r["view"]}],
                "Unit": "Milliseconds",
                "Value": float(r["duracao_ms"]),
            }
        )
        metricas.append(
            {
                "MetricName": "RefreshFalhas",
                "Dimensions": [{"Name": "View", "Value": r["view"]}],
                "Unit": "Count",
                "Value": 0.0 if r["sucesso"] else 1.0,
            }
        )

    # PutMetricData aceita no máximo 20 métricas por chamada.
    for i in range(0, len(metricas), 20):
        try:
            cloudwatch.put_metric_data(
                Namespace=METRIC_NAMESPACE, MetricData=metricas[i : i + 20]
            )
        except Exception:
            # Métrica é observabilidade, não o trabalho: não derruba o refresh.
            logger.warning("Falha ao publicar metricas no CloudWatch", exc_info=True)


def handler(event, context):
    try:
        conn = get_connection()
    except Exception:
        reset_connection()
        raise

    # REFRESH ... CONCURRENTLY nao roda dentro de transacao.
    conn.autocommit = True

    try:
        views = _listar_views(conn)
        if not views:
            raise RuntimeError(
                "Nenhuma MATERIALIZED VIEW encontrada no schema gold. "
                "Rode a Lambda de migracao antes."
            )

        resultados = []
        for view_name, tem_indice_unico in views:
            if not tem_indice_unico:
                # Sem índice UNIQUE o CONCURRENTLY seria recusado; cai para o
                # refresh bloqueante em vez de falhar a execução inteira.
                logger.warning(
                    "%s nao tem indice UNIQUE: refresh bloqueante como fallback",
                    view_name,
                )

            try:
                duracao = _refresh(conn, view_name, concorrente=tem_indice_unico)
                logger.info("REFRESH %s concluido em %s ms", view_name, duracao)
                resultados.append(
                    {"view": view_name, "duracao_ms": duracao, "sucesso": True, "erro": None}
                )
            except Exception as exc:
                logger.exception("REFRESH %s falhou", view_name)
                resultados.append(
                    {
                        "view": view_name,
                        "duracao_ms": 0.0,
                        "sucesso": False,
                        "erro": str(exc)[:500],
                    }
                )
    finally:
        conn.autocommit = False

    _publicar_metricas(resultados)

    falhas = [r for r in resultados if not r["sucesso"]]
    if falhas:
        raise RuntimeError(
            "Refresh falhou em "
            + ", ".join(f"{r['view']}: {r['erro']}" for r in falhas)
        )

    return {
        "views_atualizadas": len(resultados),
        "duracao_total_ms": round(sum(r["duracao_ms"] for r in resultados), 2),
        "detalhes": [{"view": r["view"], "duracao_ms": r["duracao_ms"]} for r in resultados],
    }
