"""
Lambda ETL Silver — Bronze (S3) -> Silver (RDS PostgreSQL).

Disparada por evento `s3:ObjectCreated:*` no bucket Bronze. Para cada objeto:

  1. lê o JSON cru;
  2. resolve a câmera pelo device_id e, pelo vínculo vigente na hora da
     leitura, o caminhão e a empresa (a câmera que nunca foi cadastrada entra
     como pendente, para o gestor associar a um veículo);
  3. resolve o motorista pelo hash (o ID fixo gravado no dispositivo) e o
     turno, casando o turno com a viagem cadastrada pelo gestor para aquele
     caminhão, de onde vêm origem, destino e distância;
  4. insere as leituras e os alertas com ON CONFLICT DO NOTHING;
  5. registra o arquivo em silver.ingestao_controle.

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

# Folga para casar um turno com a viagem cadastrada: o caminhão pode sair
# antes ou depois do horário previsto.
JANELA_VIAGEM_HORAS = int(os.environ.get("JANELA_VIAGEM_HORAS", "3"))

TIPOS_VEICULO = {"caminhao", "onibus", "van", "carro_app"}
TIPOS_ALERTA = {
    "sonolencia", "microssono", "bocejo_excessivo", "cabeca_baixa", "distracao",
    "perda_de_face", "piscadas_excessivas", "fechamento_prolongado",
}
GRAVIDADES = {"baixa", "media", "alta", "critica"}

_empresa_padrao_id = None


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
    Empresa provisória para telemetria que ainda não tem dono.

    Acontece com a câmera que começou a enviar antes de o gestor associá-la a
    um caminhão. Os dados não se perdem: quando o motorista é cadastrado (ou a
    câmera é associada), o registro passa para a empresa certa.
    """
    global _empresa_padrao_id
    if _empresa_padrao_id is None:
        cur.execute(
            """
            INSERT INTO silver.empresas (cnpj_hash, razao_social, nome_fantasia)
            VALUES (%s, %s, %s)
            ON CONFLICT (cnpj_hash) DO UPDATE SET cnpj_hash = EXCLUDED.cnpj_hash
            RETURNING id
            """,
            (EMPRESA_PADRAO_CNPJ_HASH, EMPRESA_PADRAO_NOME, EMPRESA_PADRAO_NOME),
        )
        _empresa_padrao_id = str(cur.fetchone()[0])
    return _empresa_padrao_id


def _resolver_dispositivo(cur, device_id, primeira_em, ultima_em) -> dict:
    """
    Câmera, caminhão e empresa do lote.

    Vale o vínculo câmera-caminhão vigente na hora da primeira leitura. Se o
    lote é anterior a qualquer vínculo (a câmera gravou offline antes de ser
    cadastrada), usa o vínculo aberto. Câmera desconhecida é registrada como
    pendente e aparece na tela de câmeras para o gestor associar.
    """
    cur.execute(
        """
        INSERT INTO silver.dispositivos (device_id, status, ultimo_contato_em)
        VALUES (%s, 'pendente', %s)
        ON CONFLICT (device_id) DO UPDATE
           SET ultimo_contato_em = GREATEST(
                   COALESCE(silver.dispositivos.ultimo_contato_em, EXCLUDED.ultimo_contato_em),
                   EXCLUDED.ultimo_contato_em)
        RETURNING id, empresa_id, status::text
        """,
        (device_id, ultima_em),
    )
    dispositivo_id, empresa_dispositivo, status = cur.fetchone()

    cur.execute(
        """
        SELECT v.veiculo_id, ve.empresa_id, ve.tipo::text
          FROM silver.vinculos_dispositivo_veiculo v
          JOIN silver.veiculos ve ON ve.id = v.veiculo_id
         WHERE v.dispositivo_id = %s
           AND ((v.inicio <= %s AND (v.fim IS NULL OR v.fim > %s)) OR v.fim IS NULL)
         ORDER BY (v.inicio <= %s AND (v.fim IS NULL OR v.fim > %s)) DESC, v.inicio DESC
         LIMIT 1
        """,
        (dispositivo_id, primeira_em, primeira_em, primeira_em, primeira_em),
    )
    vinculo = cur.fetchone()

    if status == "inativo":
        logger.warning("Câmera %s está inativa no cadastro e enviou dados", device_id)

    return {
        "dispositivo_id": dispositivo_id,
        "veiculo_id": vinculo[0] if vinculo else None,
        "empresa_id": (vinculo[1] if vinculo else None) or empresa_dispositivo,
        "tipo_veiculo": vinculo[2] if vinculo else None,
        "pendente": status == "pendente",
    }


def _resolver_motorista(cur, empresa_id, motorista_hash) -> str:
    """
    Motorista pelo hash do ID gravado no dispositivo.

    Um hash nunca visto vira "Motorista não cadastrado"; o gestor completa o
    cadastro depois pelo código. Se o motorista estava na empresa provisória e
    agora a câmera pertence a uma empresa de verdade, ele passa para ela.
    """
    padrao = _empresa_padrao(cur)
    cur.execute(
        "SELECT id, empresa_id FROM silver.motoristas WHERE motorista_hash = %s",
        (motorista_hash,),
    )
    row = cur.fetchone()
    if row:
        if str(row[1]) == padrao and empresa_id and str(empresa_id) != padrao:
            cur.execute(
                "UPDATE silver.motoristas SET empresa_id = %s WHERE id = %s",
                (empresa_id, row[0]),
            )
        return row[0]

    cur.execute(
        """
        INSERT INTO silver.motoristas (empresa_id, motorista_hash, nome_exibicao, status)
        VALUES (%s, %s, %s, 'ativo')
        ON CONFLICT (motorista_hash) DO UPDATE SET atualizado_em = now()
        RETURNING id
        """,
        (empresa_id or padrao, motorista_hash, f"Motorista não cadastrado ({motorista_hash[:6]})"),
    )
    return cur.fetchone()[0]


def _resolver_veiculo_por_hash(cur, empresa_id, veiculo_hash, tipo):
    """Caminho antigo: o dispositivo manda o hash da placa em vez de ter vínculo."""
    if not veiculo_hash:
        return None

    cur.execute("SELECT id FROM silver.veiculos WHERE placa_hash = %s", (veiculo_hash,))
    row = cur.fetchone()
    if row:
        return row[0]

    tipo_valido = tipo if tipo in TIPOS_VEICULO else "caminhao"
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


def _vincular_viagem(cur, turno_id, veiculo_id, motorista_id, referencia):
    """
    Casa o turno com a viagem cadastrada para o caminhão naquele horário.

    A viagem traz a rota (origem, destino, distância), que o turno copia para
    as views da dashboard. A viagem planejada passa a "em andamento".
    """
    if not veiculo_id:
        return None

    cur.execute(
        """
        SELECT v.id, r.origem_cidade, r.origem_uf, r.destino_cidade, r.destino_uf, r.distancia_km
          FROM silver.viagens v
          JOIN silver.rotas r ON r.id = v.rota_id
         WHERE v.veiculo_id = %s
           AND v.status IN ('planejada', 'em_andamento')
           AND %s BETWEEN v.partida_prevista - make_interval(hours => %s)
                      AND COALESCE(v.chegada_prevista, v.partida_prevista + interval '24 hours')
                          + make_interval(hours => %s)
         ORDER BY (v.status = 'em_andamento') DESC,
                  abs(extract(epoch FROM (v.partida_prevista - %s)))
         LIMIT 1
        """,
        (veiculo_id, referencia, JANELA_VIAGEM_HORAS, JANELA_VIAGEM_HORAS, referencia),
    )
    viagem = cur.fetchone()
    if not viagem:
        return None

    viagem_id, origem_cidade, origem_uf, destino_cidade, destino_uf, distancia = viagem
    cur.execute(
        """
        UPDATE silver.turnos
           SET viagem_id      = %s,
               origem_cidade  = COALESCE(origem_cidade, %s),
               origem_uf      = COALESCE(origem_uf, %s),
               destino_cidade = COALESCE(destino_cidade, %s),
               destino_uf     = COALESCE(destino_uf, %s),
               distancia_km   = COALESCE(distancia_km, %s)
         WHERE id = %s
        """,
        (viagem_id, origem_cidade, origem_uf, destino_cidade, destino_uf, distancia, turno_id),
    )
    cur.execute(
        """
        UPDATE silver.viagens
           SET status       = 'em_andamento',
               partida_real = COALESCE(partida_real, %s),
               motorista_id = COALESCE(motorista_id, %s)
         WHERE id = %s
        """,
        (referencia, motorista_id, viagem_id),
    )
    return viagem_id


def _fechar_turno(cur, turno_id, finalizado_em):
    """
    Encerra o turno e, se ele fechou perto da chegada prevista, conclui a
    viagem. Uma viagem longa pode ter vários turnos; só o último a conclui.
    """
    cur.execute(
        """
        UPDATE silver.turnos
           SET status = 'concluido', finalizado_em = %s
         WHERE id = %s
        RETURNING viagem_id
        """,
        (finalizado_em, turno_id),
    )
    row = cur.fetchone()
    if row and row[0]:
        cur.execute(
            """
            UPDATE silver.viagens
               SET status = 'concluida', chegada_real = %s
             WHERE id = %s
               AND status = 'em_andamento'
               AND chegada_prevista IS NOT NULL
               AND %s >= chegada_prevista - make_interval(hours => %s)
            """,
            (finalizado_em, row[0], finalizado_em, JANELA_VIAGEM_HORAS),
        )


def _resolver_turno(cur, motorista_id, veiculo_id, device_id, dispositivo_id,
                    primeira_em, ultima_em, turno_externo):
    """
    Resolve o turno ao qual o lote pertence.

    Ordem de decisão:
      1. turno_id enviado pelo edge, se existir;
      2. turno já encerrado que contém o lote (backlog que a câmera guardou
         offline e mandou depois);
      3. turno aberto do motorista, se a última leitura é recente e o caminhão
         é o mesmo;
      4. senão, encerra o aberto e abre um novo. Um lote anterior ao turno
         aberto vira um turno já encerrado, para não bagunçar o atual.
    """
    if turno_externo:
        cur.execute("SELECT id FROM silver.turnos WHERE id = %s", (turno_externo,))
        row = cur.fetchone()
        if row:
            return row[0]

    cur.execute(
        """
        SELECT id FROM silver.turnos
         WHERE motorista_id = %s
           AND status <> 'em_andamento'
           AND iniciado_em <= %s AND finalizado_em >= %s
         ORDER BY iniciado_em DESC
         LIMIT 1
        """,
        (motorista_id, primeira_em, primeira_em),
    )
    row = cur.fetchone()
    if row:
        return row[0]

    cur.execute(
        """
        SELECT t.id, t.iniciado_em, t.veiculo_id, t.viagem_id,
               COALESCE(MAX(l.registrado_em), t.iniciado_em) AS ultima
          FROM silver.turnos t
          LEFT JOIN silver.leituras_fadiga l ON l.turno_id = t.id
         WHERE t.motorista_id = %s AND t.status = 'em_andamento'
         GROUP BY t.id, t.iniciado_em, t.veiculo_id, t.viagem_id
        """,
        (motorista_id,),
    )
    aberto = cur.fetchone()
    status_novo = "em_andamento"

    if aberto:
        turno_id, iniciado_em, veiculo_turno, viagem_turno, ultima = aberto
        mesmo_veiculo = veiculo_turno is None or veiculo_id is None or veiculo_turno == veiculo_id
        gap_min = (primeira_em - ultima).total_seconds() / 60.0

        if primeira_em < iniciado_em:
            # Lote mais antigo que o turno aberto: vira um turno encerrado.
            status_novo = "concluido"
        elif mesmo_veiculo and gap_min <= GAP_NOVO_TURNO_MINUTOS:
            if veiculo_turno is None and veiculo_id is not None:
                # A câmera foi associada a um caminhão no meio do turno: o
                # turno e o que já chegou dele passam a ser desse caminhão.
                cur.execute(
                    "UPDATE silver.turnos SET veiculo_id = %s, dispositivo_id = COALESCE(dispositivo_id, %s) WHERE id = %s",
                    (veiculo_id, dispositivo_id, turno_id),
                )
                cur.execute(
                    "UPDATE silver.leituras_fadiga SET veiculo_id = %s WHERE turno_id = %s AND veiculo_id IS NULL",
                    (veiculo_id, turno_id),
                )
                cur.execute(
                    "UPDATE silver.alertas SET veiculo_id = %s WHERE turno_id = %s AND veiculo_id IS NULL",
                    (veiculo_id, turno_id),
                )
            if viagem_turno is None:
                _vincular_viagem(cur, turno_id, veiculo_id, motorista_id, iniciado_em)
            return turno_id
        else:
            _fechar_turno(cur, turno_id, ultima)

    cur.execute(
        """
        INSERT INTO silver.turnos
            (motorista_id, veiculo_id, device_id, dispositivo_id, iniciado_em, finalizado_em, status)
        VALUES (%s, %s, %s, %s, %s, %s, %s::silver.status_turno)
        RETURNING id
        """,
        (
            motorista_id, veiculo_id, device_id, dispositivo_id, primeira_em,
            ultima_em if status_novo == "concluido" else None, status_novo,
        ),
    )
    turno_id = cur.fetchone()[0]
    _vincular_viagem(cur, turno_id, veiculo_id, motorista_id, primeira_em)
    return turno_id


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

        # Um tipo novo no edge não pode derrubar o lote inteiro: vira o genérico.
        tipo = a.get("tipo") if a.get("tipo") in TIPOS_ALERTA else "sonolencia"
        gravidade = a.get("gravidade") if a.get("gravidade") in GRAVIDADES else "media"
        linhas.append(
            (
                contexto["turno_id"],
                contexto["motorista_id"],
                contexto["veiculo_id"],
                disparado_em,
                tipo,
                gravidade,
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
    device_id = payload.get("device_id", "desconhecido")

    cur = conn.cursor()
    try:
        if _ja_processado(cur, key):
            logger.info("Objeto ja processado, ignorando: %s", key)
            return {"key": key, "status": "ignorado", "motivo": "ja processado"}

        timestamps = [_parse_ts(l.get("registrado_em")) for l in leituras]
        timestamps = [t for t in timestamps if t is not None]
        if not timestamps:
            raise ValueError("lote sem nenhuma leitura com registrado_em valido")
        primeira_em, ultima_em = min(timestamps), max(timestamps)

        disp = _resolver_dispositivo(cur, device_id, primeira_em, ultima_em)
        empresa_id = disp["empresa_id"] or _empresa_padrao(cur)

        motorista_id = _resolver_motorista(cur, empresa_id, payload["motorista_hash"])
        veiculo_id = disp["veiculo_id"] or _resolver_veiculo_por_hash(
            cur, empresa_id, payload.get("veiculo_hash"), payload.get("tipo_veiculo")
        )

        turno_id = _resolver_turno(
            cur,
            motorista_id,
            veiculo_id,
            device_id,
            disp["dispositivo_id"],
            primeira_em,
            ultima_em,
            payload.get("turno_id"),
        )

        contexto = {
            "turno_id": turno_id,
            "motorista_id": motorista_id,
            "veiculo_id": veiculo_id,
            "device_id": device_id,
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
            "Silver atualizada: key=%s leituras=%d alertas=%d turno=%s camera_pendente=%s",
            key, n_leituras, n_alertas, turno_id, disp["pendente"],
        )
        return {
            "key": key,
            "status": "ok",
            "leituras": n_leituras,
            "alertas": n_alertas,
            "turno_id": str(turno_id),
            "veiculo_id": str(veiculo_id) if veiculo_id else None,
            "camera_pendente": disp["pendente"],
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


def _registros(event) -> list:
    """
    Aceita os dois formatos de evento do S3: a notificação clássica
    (`Records`) e o evento "Object Created" entregue pelo EventBridge.
    """
    if event.get("Records"):
        return [
            (r["s3"]["bucket"]["name"], urllib.parse.unquote_plus(r["s3"]["object"]["key"]))
            for r in event["Records"]
        ]
    detalhe = event.get("detail") or {}
    if detalhe.get("bucket") and detalhe.get("object"):
        return [(detalhe["bucket"]["name"], detalhe["object"]["key"])]
    return []


def handler(event, context):
    registros = _registros(event)
    logger.info("Recebidos %d objetos do S3", len(registros))

    try:
        conn = get_connection()
    except Exception:
        reset_connection()
        raise

    resultados = []
    falhas = []

    for bucket, key in registros:
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
