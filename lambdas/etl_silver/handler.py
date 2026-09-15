"""
Lambda ETL Silver — Bronze (S3) -> Silver (RDS PostgreSQL).

Disparada por evento `s3:ObjectCreated:*` no bucket Bronze. Para cada objeto:

  1. lê o JSON cru;
  2. resolve as chaves estrangeiras por hash (motorista, veículo, turno),
     criando o registro quando ele ainda não existe;
  3. insere as leituras e os alertas com ON CONFLICT DO NOTHING;
  4. registra o arquivo em silver.ingestao_controle.

Idempotência em duas camadas: `silver.ingestao_controle` evita reprocessar o
mesmo objeto, e as constraints UNIQUE (device_id, registrado_em) em
leituras_fadiga e (motorista_id, disparado_em, tipo) em alertas garantem que
mesmo um reprocessamento forçado não duplique linhas.

Roda dentro da VPC (subnet privada) porque precisa alcançar o RDS.
"""

import json
import logging
import os
import urllib.parse
from datetime import datetime, timezone

import boto3

from db import get_connection, reset_connection

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

s3 = boto3.client("s3")

EMPRESA_PADRAO_CNPJ_HASH = os.environ.get(
    "EMPRESA_PADRAO_CNPJ_HASH", "00000000000000000000000000000000"
)
EMPRESA_PADRAO_NOME = os.environ.get("EMPRESA_PADRAO_NOME", "Empresa nao identificada")

# Uma leitura mais nova que isto reabre o mesmo turno; acima disso o edge é
# tratado como tendo iniciado uma nova jornada.
GAP_NOVO_TURNO_MINUTOS = int(os.environ.get("GAP_NOVO_TURNO_MINUTOS", "45"))


def _parse_ts(valor):
    """Converte ISO-8601 (inclusive com sufixo Z) em datetime timezone-aware."""
    if valor is None:
        return None
    if isinstance(valor, datetime):
        return valor if valor.tzinfo else valor.replace(tzinfo=timezone.utc)
    texto = str(valor).strip().replace("Z", "+00:00")
    dt = datetime.fromisoformat(texto)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _ja_processado(cur, key: str) -> bool:
    cur.execute(
        "SELECT 1 FROM silver.ingestao_controle WHERE bronze_key = %s AND status = 'ok'",
        (key,),
    )
    return cur.fetchone() is not None


def _empresa_padrao(cur) -> str:
    """
    Empresa usada quando o lote não traz vínculo explícito.

    O edge envia apenas hashes; o cadastro de empresa/motorista é feito pelo
    dashboard. Para não perder telemetria de um dispositivo ainda não
    cadastrado, criamos um vínculo provisório que o gestor reconcilia depois.
    """
    cur.execute(
        """
        INSERT INTO silver.empresas (cnpj_hash, razao_social, nome_fantasia)
        VALUES (%s, %s, %s)
        ON CONFLICT (cnpj_hash) DO UPDATE SET atualizado_em = now()
        RETURNING id
        """,
        (EMPRESA_PADRAO_CNPJ_HASH, EMPRESA_PADRAO_NOME, EMPRESA_PADRAO_NOME),
    )
    return cur.fetchone()[0]


def _resolver_motorista(cur, empresa_id, motorista_hash, device_id) -> str:
    cur.execute(
        "SELECT id FROM silver.motoristas WHERE motorista_hash = %s",
        (motorista_hash,),
    )
    row = cur.fetchone()
    if row:
        return row[0]

    cur.execute(
        """
        INSERT INTO silver.motoristas (empresa_id, motorista_hash, nome_exibicao, status)
        VALUES (%s, %s, %s, 'ativo')
        ON CONFLICT (motorista_hash) DO UPDATE SET atualizado_em = now()
        RETURNING id
        """,
        (empresa_id, motorista_hash, f"Motorista {device_id}"),
    )
    return cur.fetchone()[0]


def _resolver_veiculo(cur, empresa_id, veiculo_hash, tipo):
    if not veiculo_hash:
        return None

    cur.execute("SELECT id FROM silver.veiculos WHERE placa_hash = %s", (veiculo_hash,))
    row = cur.fetchone()
    if row:
        return row[0]

    tipo_valido = tipo if tipo in ("caminhao", "onibus", "van", "carro_app") else "caminhao"
    cur.execute(
        """
        INSERT INTO silver.veiculos (empresa_id, placa_hash, tipo)
        VALUES (%s, %s, %s::silver.tipo_veiculo)
        ON CONFLICT (placa_hash) DO UPDATE SET atualizado_em = now()
        RETURNING id
        """,
        (empresa_id, veiculo_hash, tipo_valido),
    )
    return cur.fetchone()[0]


def _resolver_turno(cur, motorista_id, veiculo_id, device_id, primeira_leitura_em, turno_externo):
    """
    Resolve o turno ao qual o lote pertence.

    Se o edge mandou um turno_id conhecido, usa. Senão reaproveita o turno
    aberto do motorista quando a última leitura é recente; caso contrário
    fecha o anterior e abre um novo.
    """
    if turno_externo:
        cur.execute("SELECT id FROM silver.turnos WHERE id = %s", (turno_externo,))
        row = cur.fetchone()
        if row:
            return row[0]

    cur.execute(
        """
        SELECT t.id,
               COALESCE(MAX(l.registrado_em), t.iniciado_em) AS ultima
        FROM silver.turnos t
        LEFT JOIN silver.leituras_fadiga l ON l.turno_id = t.id
        WHERE t.motorista_id = %s AND t.status = 'em_andamento'
        GROUP BY t.id, t.iniciado_em
        """,
        (motorista_id,),
    )
    row = cur.fetchone()

    if row:
        turno_id, ultima = row[0], row[1]
        gap_min = (primeira_leitura_em - ultima).total_seconds() / 60.0
        if gap_min <= GAP_NOVO_TURNO_MINUTOS:
            return turno_id

        cur.execute(
            """
            UPDATE silver.turnos
               SET status = 'concluido', finalizado_em = %s
             WHERE id = %s
            """,
            (ultima, turno_id),
        )

    cur.execute(
        """
        INSERT INTO silver.turnos (motorista_id, veiculo_id, device_id, iniciado_em, status)
        VALUES (%s, %s, %s, %s, 'em_andamento')
        RETURNING id
        """,
        (motorista_id, veiculo_id, device_id, primeira_leitura_em),
    )
    return cur.fetchone()[0]


def _inserir_leituras(cur, contexto, leituras, ingest_id, bronze_key) -> int:
    linhas = []
    for l in leituras:
        registrado_em = _parse_ts(l.get("registrado_em"))
        if registrado_em is None:
            continue

        linhas.append(
            (
                contexto["turno_id"],
                contexto["motorista_id"],
                contexto["veiculo_id"],
                contexto["device_id"],
                registrado_em,
                l.get("ear"),
                l.get("mar"),
                l.get("perclos"),
                l.get("blink_rate"),
                l.get("duracao_olhos_fechados_ms"),
                l.get("head_pitch", l.get("pitch")),
                l.get("head_yaw", l.get("yaw")),
                l.get("head_roll", l.get("roll")),
                l.get("score_fadiga"),
                l.get("estado"),
                l.get("latitude"),
                l.get("longitude"),
                l.get("velocidade_kmh"),
                ingest_id,
                bronze_key,
            )
        )

    if not linhas:
        return 0

    cur.executemany(
        """
        INSERT INTO silver.leituras_fadiga (
            turno_id, motorista_id, veiculo_id, device_id, registrado_em,
            ear, mar, perclos, blink_rate, duracao_olhos_fechados_ms,
            head_pitch, head_yaw, head_roll,
            score_fadiga, estado, latitude, longitude, velocidade_kmh,
            ingest_id, bronze_key
        ) VALUES (
            %s, %s, %s, %s, %s,
            %s, %s, %s, %s, %s,
            %s, %s, %s,
            %s, %s::silver.estado_fadiga, %s, %s, %s,
            %s, %s
        )
        ON CONFLICT (device_id, registrado_em) DO NOTHING
        """,
        linhas,
    )
    return len(linhas)


def _inserir_alertas(cur, contexto, alertas) -> int:
    linhas = []
    for a in alertas or []:
        disparado_em = _parse_ts(a.get("disparado_em") or a.get("registrado_em"))
        if disparado_em is None:
            continue

        linhas.append(
            (
                contexto["turno_id"],
                contexto["motorista_id"],
                contexto["veiculo_id"],
                disparado_em,
                a.get("tipo", "sonolencia"),
                a.get("gravidade", "media"),
                a.get("score_fadiga"),
                a.get("mensagem"),
            )
        )

    if not linhas:
        return 0

    cur.executemany(
        """
        INSERT INTO silver.alertas (
            turno_id, motorista_id, veiculo_id, disparado_em,
            tipo, gravidade, status, score_fadiga, mensagem
        ) VALUES (
            %s, %s, %s, %s,
            %s::silver.tipo_alerta, %s::silver.gravidade, 'aberto', %s, %s
        )
        ON CONFLICT (motorista_id, disparado_em, tipo) DO NOTHING
        """,
        linhas,
    )
    return len(linhas)


def _processar_objeto(conn, bucket: str, key: str) -> dict:
    obj = s3.get_object(Bucket=bucket, Key=key)
    envelope = json.loads(obj["Body"].read().decode("utf-8"))

    payload = envelope.get("payload", envelope)
    ingest_id = envelope.get("ingest_id")
    leituras = payload.get("leituras") or []
    alertas = payload.get("alertas") or []

    cur = conn.cursor()
    try:
        if _ja_processado(cur, key):
            logger.info("Objeto ja processado, ignorando: %s", key)
            return {"key": key, "status": "ignorado", "motivo": "ja processado"}

        empresa_id = _empresa_padrao(cur)
        motorista_id = _resolver_motorista(
            cur, empresa_id, payload["motorista_hash"], payload.get("device_id", "desconhecido")
        )
        veiculo_id = _resolver_veiculo(
            cur, empresa_id, payload.get("veiculo_hash"), payload.get("tipo_veiculo")
        )

        timestamps = [_parse_ts(l.get("registrado_em")) for l in leituras]
        timestamps = [t for t in timestamps if t is not None]
        if not timestamps:
            raise ValueError("lote sem nenhuma leitura com registrado_em valido")

        turno_id = _resolver_turno(
            cur,
            motorista_id,
            veiculo_id,
            payload.get("device_id", "desconhecido"),
            min(timestamps),
            payload.get("turno_id"),
        )

        contexto = {
            "turno_id": turno_id,
            "motorista_id": motorista_id,
            "veiculo_id": veiculo_id,
            "device_id": payload.get("device_id", "desconhecido"),
        }

        n_leituras = _inserir_leituras(cur, contexto, leituras, ingest_id, key)
        n_alertas = _inserir_alertas(cur, contexto, alertas)

        cur.execute(
            """
            INSERT INTO silver.ingestao_controle
                (bronze_key, ingest_id, leituras_lidas, leituras_novas, alertas_novos, status)
            VALUES (%s, %s, %s, %s, %s, 'ok')
            ON CONFLICT (bronze_key) DO UPDATE
               SET processado_em  = now(),
                   leituras_lidas = EXCLUDED.leituras_lidas,
                   leituras_novas = EXCLUDED.leituras_novas,
                   alertas_novos  = EXCLUDED.alertas_novos,
                   status         = 'ok',
                   erro           = NULL
            """,
            (key, ingest_id, len(leituras), n_leituras, n_alertas),
        )

        conn.commit()
        logger.info(
            "Silver atualizada: key=%s leituras=%d alertas=%d turno=%s",
            key, n_leituras, n_alertas, turno_id,
        )
        return {
            "key": key,
            "status": "ok",
            "leituras": n_leituras,
            "alertas": n_alertas,
            "turno_id": str(turno_id),
        }

    except Exception as exc:
        conn.rollback()
        # Registra a falha numa transação própria para não perder o rastro.
        try:
            cur2 = conn.cursor()
            cur2.execute(
                """
                INSERT INTO silver.ingestao_controle (bronze_key, status, erro)
                VALUES (%s, 'erro', %s)
                ON CONFLICT (bronze_key) DO UPDATE
                   SET status = 'erro', erro = EXCLUDED.erro, processado_em = now()
                """,
                (key, str(exc)[:2000]),
            )
            conn.commit()
            cur2.close()
        except Exception:
            conn.rollback()
        raise
    finally:
        try:
            cur.close()
        except Exception:
            pass


def handler(event, context):
    registros = event.get("Records") or []
    logger.info("Recebidos %d registros do S3", len(registros))

    try:
        conn = get_connection()
    except Exception:
        reset_connection()
        raise

    resultados = []
    falhas = []

    for registro in registros:
        bucket = registro["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(registro["s3"]["object"]["key"])

        try:
            resultados.append(_processar_objeto(conn, bucket, key))
        except Exception as exc:
            logger.exception("Falha ao processar %s", key)
            falhas.append({"key": key, "erro": str(exc)})

    # Levantar a exceção faz o Lambda reentregar o evento e, esgotadas as
    # tentativas, mandar para a DLQ configurada no Terraform.
    if falhas:
        raise RuntimeError(f"{len(falhas)} objeto(s) falharam: {json.dumps(falhas)[:1500]}")

    return {"processados": len(resultados), "detalhes": resultados}
