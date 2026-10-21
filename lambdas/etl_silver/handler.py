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
import re
import unicodedata
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


def normalizar_dispositivo(valor) -> str:
    """
    ID da câmera como o Backend grava (src/lib/identificadores.ts): sem acento,
    símbolos viram hífen, minúsculas. "Device_123" e "device-123" são a mesma.
    """
    sem_acento = "".join(c for c in unicodedata.normalize("NFD", str(valor)) if not unicodedata.combining(c))
    return re.sub(r"[^A-Za-z0-9]+", "-", sem_acento.strip()).strip("-").lower() or "desconhecido"


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
                   EXCLUDED.ultimo_contato_em),
               -- Câmera excluída (arquivada) que voltou a enviar: reaparece
               -- como pendente, para o gestor decidir de novo.
               empresa_id = CASE WHEN silver.dispositivos.arquivado_em IS NULL
                                 THEN silver.dispositivos.empresa_id END,
               status = CASE WHEN silver.dispositivos.arquivado_em IS NULL
                             THEN silver.dispositivos.status ELSE 'pendente' END,
               arquivado_em = NULL
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
        "SELECT id, empresa_id, arquivado_em FROM silver.motoristas WHERE motorista_hash = %s",
        (motorista_hash,),
    )
    row = cur.fetchone()
    if row:
        if row[2] is not None:
            # Excluído (arquivado) e voltou a dirigir: volta às listas.
            cur.execute("UPDATE silver.motoristas SET arquivado_em = NULL WHERE id = %s", (row[0],))
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


def _fim_efetivo_sql(alias: str) -> str:
    return (
        f"COALESCE({alias}.finalizado_em, (SELECT MAX(l.registrado_em) FROM silver.leituras_fadiga l "
        f"WHERE l.turno_id = {alias}.id), {alias}.iniciado_em)"
    )


def _fundir_turnos_vizinhos(cur, motorista_id, turno_id):
    """
    Junta ao turno os turnos do mesmo motorista e caminhão que encostam nele
    (menos de GAP_NOVO_TURNO_MINUTOS entre um e outro): é a mesma jornada que chegou em
    pedaços. Acontece quando os lotes chegam fora de ordem (o ETL roda em
    paralelo) ou quando o simulador preenche uma lacuna no meio do turno.
    Fica o turno que começou antes; leituras, alertas, ações e ocorrências do
    outro passam para ele. Devolve o turno que ficou.
    """
    while True:
        cur.execute(
            f"""
            SELECT o.id
              FROM silver.turnos a
              JOIN silver.turnos o ON o.motorista_id = a.motorista_id AND o.id <> a.id
             WHERE a.id = %s
               -- Troca de caminhão é turno novo, como no ao vivo.
               AND (o.veiculo_id IS NULL OR a.veiculo_id IS NULL OR o.veiculo_id = a.veiculo_id)
               AND o.iniciado_em <= {_fim_efetivo_sql("a")} + make_interval(mins => %s)
               AND {_fim_efetivo_sql("o")} >= a.iniciado_em - make_interval(mins => %s)
             ORDER BY o.iniciado_em
             LIMIT 1
            """,
            (turno_id, GAP_NOVO_TURNO_MINUTOS, GAP_NOVO_TURNO_MINUTOS),
        )
        row = cur.fetchone()
        if not row:
            return turno_id
        cur.execute(
            f"""
            SELECT id, iniciado_em, {_fim_efetivo_sql("t")}, status::text, viagem_id,
                   origem_cidade, origem_uf, destino_cidade, destino_uf, distancia_km
              FROM silver.turnos t WHERE id IN (%s, %s)
             ORDER BY iniciado_em, criado_em
            """,
            (turno_id, row[0]),
        )
        fica, sai = cur.fetchall()
        for tabela in ("leituras_fadiga", "alertas", "acoes_motorista", "incidentes"):
            cur.execute(f"UPDATE silver.{tabela} SET turno_id = %s WHERE turno_id = %s", (fica[0], sai[0]))
        aberto = "em_andamento" in (fica[3], sai[3])
        # Apaga antes de atualizar: só pode haver um turno aberto por motorista.
        cur.execute("DELETE FROM silver.turnos WHERE id = %s", (sai[0],))
        cur.execute(
            """
            UPDATE silver.turnos
               SET status         = %s::silver.status_turno,
                   finalizado_em  = %s,
                   viagem_id      = COALESCE(viagem_id, %s),
                   origem_cidade  = COALESCE(origem_cidade, %s),
                   origem_uf      = COALESCE(origem_uf, %s),
                   destino_cidade = COALESCE(destino_cidade, %s),
                   destino_uf     = COALESCE(destino_uf, %s),
                   distancia_km   = COALESCE(distancia_km, %s)
             WHERE id = %s
            """,
            (
                "em_andamento" if aberto else "concluido",
                None if aberto else max(fica[2], sai[2]),
                sai[4], sai[5], sai[6], sai[7], sai[8], sai[9], fica[0],
            ),
        )
        turno_id = fica[0]


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
    device_id = normalizar_dispositivo(payload.get("device_id") or "desconhecido")

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

        # Um lote por motorista de cada vez: lotes do mesmo turno processados
        # em paralelo não abrem dois turnos.
        cur.execute("SELECT 1 FROM silver.motoristas WHERE id = %s FOR UPDATE", (motorista_id,))

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
        turno_id = _fundir_turnos_vizinhos(cur, motorista_id, turno_id)

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


def ultimas_leituras(conn, devices: list[str]) -> dict:
    """
    Última leitura gravada de cada câmera (o simulador pergunta antes de
    preencher lacunas: ele fica fora da VPC e não enxerga o banco). O índice
    único (device_id, registrado_em) responde cada MAX sem varrer a tabela.
    """
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT d, (SELECT MAX(l.registrado_em) FROM silver.leituras_fadiga l WHERE l.device_id = d)
              FROM unnest(%s::text[]) AS d
            """,
            ([normalizar_dispositivo(d) for d in devices],),
        )
        linhas = cur.fetchall()
        conn.rollback()  # só leitura: não deixa transação aberta na conexão reaproveitada
    finally:
        cur.close()
    return {d: (ts.isoformat() if ts else None) for d, ts in linhas}


# ---------------------------------------------------------------------------
# Manutenção pedida pela Lambda simulador (lambda invoke, fora do S3)
#
# O simulador fica fora da VPC e não enxerga o banco: pergunta aqui o quanto
# de cada turno da escala já existe, pede a limpeza do que vai regenerar e as
# viagens planejadas (de onde o turno tira a rota).
# ---------------------------------------------------------------------------

def cobertura(conn, turnos: list[dict]) -> list[dict]:
    """
    Para cada turno da escala {device, inicio, fim}: quantos blocos de 5
    minutos têm leitura, o maior intervalo sem leitura (contando o começo e o
    fim do turno; o seed grava de 10 em 10 ou de 15 em 15 minutos, e a parada
    tem 30) e se ele é "protegido", caso em que não é apagado: alguém da
    central agiu nele (ação, ocorrência, alerta respondido) ou ele terminou
    antes de propósito (central encerrou a jornada, acidente).
    """
    if not turnos:
        return []
    linhas = [
        {"ord": i, "device": normalizar_dispositivo(t["device"]), "inicio": t["inicio"], "fim": t["fim"], "rota": t.get("rota")}
        for i, t in enumerate(turnos)
    ]
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT x.ord,
                   (SELECT COUNT(DISTINCT floor(extract(epoch FROM l.registrado_em) / 300))
                      FROM silver.leituras_fadiga l
                     WHERE l.device_id = x.device AND l.registrado_em >= x.inicio AND l.registrado_em < x.fim) AS blocos,
                   (SELECT MAX(EXTRACT(EPOCH FROM (g.prox - g.ts)) / 60)
                      FROM (SELECT ts, lead(ts) OVER (ORDER BY ts) AS prox
                              FROM (SELECT x.inicio AS ts
                                    UNION ALL
                                    SELECT l.registrado_em FROM silver.leituras_fadiga l
                                     WHERE l.device_id = x.device AND l.registrado_em >= x.inicio AND l.registrado_em < x.fim
                                    UNION ALL
                                    SELECT x.fim) pontos) g) AS maior_lacuna_min,
                   EXISTS (
                       SELECT 1 FROM silver.turnos t
                        WHERE t.device_id = x.device AND t.iniciado_em < x.fim
                          AND COALESCE(t.finalizado_em, 'infinity'::timestamptz) > x.inicio
                          AND (EXISTS (SELECT 1 FROM silver.acoes_motorista a
                                        WHERE a.turno_id = t.id AND (a.realizado_por IS NOT NULL OR a.tipo = 'encerramento_turno'))
                               OR EXISTS (SELECT 1 FROM silver.incidentes i WHERE i.turno_id = t.id)
                               OR EXISTS (SELECT 1 FROM silver.alertas al WHERE al.turno_id = t.id AND al.reconhecido_por IS NOT NULL))
                   ) AS protegido
              FROM jsonb_to_recordset(%s::jsonb) AS x(ord int, device text, inicio timestamptz, fim timestamptz, rota text)
            """,
            (json.dumps(linhas),),
        )
        resultado = {
            ord_: {"blocos": n, "maior_lacuna_min": round(float(lacuna), 1), "protegido": prot}
            for ord_, n, lacuna, prot in cur.fetchall()
        }
        conn.rollback()
    finally:
        cur.close()
    return [resultado[i] for i in range(len(linhas))]


def planejar_viagens(conn, turnos: list[dict]) -> int:
    """
    Viagem planejada da rota para cada turno {device, inicio, fim, rota} que
    ainda não tem uma (o veículo vem do vínculo da câmera naquela hora).
    """
    if not turnos:
        return 0
    linhas = [
        {"device": normalizar_dispositivo(t["device"]), "inicio": t["inicio"], "fim": t["fim"], "rota": t["rota"]}
        for t in turnos if t.get("rota")
    ]
    cur = conn.cursor()
    try:
        cur.execute(
            """
            INSERT INTO silver.viagens (empresa_id, rota_id, veiculo_id, partida_prevista, chegada_prevista, valor_viagem, status)
            SELECT d.empresa_id, r.id, vd.veiculo_id, x.inicio, x.fim,
                   ROUND((extract(epoch FROM x.fim - x.inicio) / 3600 * 70
                          * CASE ve.tipo WHEN 'onibus' THEN 9.5 WHEN 'van' THEN 4.0 ELSE 7.0 END)::numeric, 2),
                   'planejada'
              FROM jsonb_to_recordset(%s::jsonb) AS x(device text, inicio timestamptz, fim timestamptz, rota text)
              JOIN silver.dispositivos d ON d.device_id = x.device AND d.empresa_id IS NOT NULL
              JOIN silver.vinculos_dispositivo_veiculo vd
                ON vd.dispositivo_id = d.id AND vd.inicio <= x.inicio AND (vd.fim IS NULL OR vd.fim > x.inicio)
              JOIN silver.veiculos ve ON ve.id = vd.veiculo_id
              JOIN silver.rotas r ON r.empresa_id = d.empresa_id AND r.nome = x.rota
             WHERE x.fim > x.inicio
               AND NOT EXISTS (
                   SELECT 1 FROM silver.viagens v
                    WHERE v.veiculo_id = vd.veiculo_id
                      AND v.partida_prevista BETWEEN x.inicio - interval '3 hours' AND x.inicio + interval '3 hours')
            """,
            (json.dumps(linhas),),
        )
        n = cur.rowcount
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
    return n


def _liberar_viagens(cur, viagens) -> None:
    """Viagens dos turnos apagados voltam a planejadas, para o turno regenerado casar com elas."""
    ids = [v for v in viagens if v]
    if ids:
        cur.execute(
            """
            UPDATE silver.viagens SET status = 'planejada', partida_real = NULL, chegada_real = NULL
             WHERE id = ANY(%s::uuid[])
            """,
            (ids,),
        )


def limpar(conn, intervalos: list[dict]) -> dict:
    """
    Apaga a telemetria de cada câmera no intervalo {device, de, ate}: os
    turnos que se sobrepõem a ele (com leituras e alertas, em cascata) e o
    que sobrar de leitura e alerta solto. O simulador só pede isto para
    turnos que vai regenerar e que ninguém da central tocou.
    """
    cur = conn.cursor()
    turnos = leituras = 0
    try:
        for it in intervalos:
            device = normalizar_dispositivo(it["device"])
            cur.execute(
                f"""
                DELETE FROM silver.turnos t
                 WHERE t.device_id = %s AND t.iniciado_em < %s AND {_fim_efetivo_sql("t")} >= %s
                RETURNING t.viagem_id
                """,
                (device, it["ate"], it["de"]),
            )
            viagens = [r[0] for r in cur.fetchall()]
            turnos += len(viagens)
            _liberar_viagens(cur, viagens)
            cur.execute(
                "DELETE FROM silver.leituras_fadiga WHERE device_id = %s AND registrado_em >= %s AND registrado_em < %s",
                (device, it["de"], it["ate"]),
            )
            leituras += cur.rowcount
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
    return {"turnos": turnos, "leituras_soltas": leituras}


def simular_central(conn, ate: str) -> dict:
    """
    A central da simulação para o histórico gerado pelo simulador (câmeras
    dg-edge-*), na mesma política do seed (fase do programa): nos turnos já
    encerrados antes de `ate`, 85% dos alertas graves de sono recebem uma
    parada para descanso e 60% dos outros, um contato; todos ficam
    resolvidos. Sem autor (realizado_por nulo): é a simulação, não alguém da
    central. Os alertas mais recentes que `ate` ficam para quem usa a
    dashboard responder.

    Também encerra os turnos que ficaram abertos sem leitura há mais de 2 h
    (o último turno regenerado de cada motorista, que nenhum lote seguinte fechou).
    """
    cur = conn.cursor()
    try:
        cur.execute(
            f"""
            UPDATE silver.turnos t
               SET status = 'concluido', finalizado_em = {_fim_efetivo_sql("t")}
             WHERE t.status = 'em_andamento' AND t.device_id LIKE 'dg-edge-%%'
               AND {_fim_efetivo_sql("t")} < now() - interval '2 hours'
            """
        )
        fechados = cur.rowcount
        cur.execute(
            """
            CREATE TEMP TABLE _central ON COMMIT DROP AS
            SELECT a.id, a.motorista_id, a.turno_id,
                   a.disparado_em + make_interval(secs => 90 + abs(hashtext(a.id::text)) %% 150) AS reconh,
                   CASE
                       WHEN a.gravidade IN ('alta', 'critica') AND a.tipo NOT IN ('distracao', 'perda_de_face')
                            AND abs(hashtext(a.id::text || 'grave')) %% 100 < 85 THEN 'pausa_obrigatoria'
                       WHEN a.gravidade NOT IN ('alta', 'critica') OR a.tipo IN ('distracao', 'perda_de_face') THEN
                            CASE WHEN abs(hashtext(a.id::text || 'medio')) %% 100 < 60 THEN 'contato_telefonico' END
                   END AS acao
              FROM silver.alertas a
              JOIN silver.turnos t ON t.id = a.turno_id
             WHERE t.status <> 'em_andamento' AND t.device_id LIKE 'dg-edge-%%'
               AND t.finalizado_em < %s::timestamptz AND t.finalizado_em >= %s::timestamptz - interval '35 days'
               AND a.status = 'aberto'
               AND NOT EXISTS (SELECT 1 FROM silver.acoes_motorista ac WHERE ac.alerta_id = a.id)
            """,
            (ate, ate),
        )
        cur.execute(
            """
            INSERT INTO silver.acoes_motorista (motorista_id, turno_id, alerta_id, tipo, detalhe, realizado_em)
            SELECT motorista_id, turno_id, id, acao::silver.tipo_acao,
                   CASE acao WHEN 'pausa_obrigatoria' THEN '30 min' ELSE 'telefone' END,
                   reconh + interval '1 minute'
              FROM _central WHERE acao IS NOT NULL
            """
        )
        acoes = cur.rowcount
        cur.execute(
            """
            UPDATE silver.alertas a
               SET status = 'resolvido', reconhecido_em = c.reconh,
                   resolvido_em = c.reconh + CASE c.acao WHEN 'pausa_obrigatoria' THEN interval '35 minutes'
                                                          WHEN 'contato_telefonico' THEN interval '5 minutes'
                                                          ELSE interval '20 minutes' END
              FROM _central c WHERE a.id = c.id
            """
        )
        alertas = cur.rowcount
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
    return {"turnos_fechados": fechados, "alertas_resolvidos": alertas, "acoes": acoes}


def limpar_periodo(conn, de: str, ate: str) -> dict:
    """
    Apaga tudo o que aconteceu nos dias [de, ate] (datas de Brasília) nas
    empresas cadastradas: turnos que começaram nesses dias (com leituras e
    alertas), leituras e alertas soltos, ações da central, ocorrências
    internas e viagens. Cadastros (motoristas, veículos, câmeras) ficam. O
    simulador regenera os dias em seguida.
    """
    tz = "America/Sao_Paulo"
    cur = conn.cursor()
    apagado = {}
    try:
        def executar(nome, sql, extra=()):
            cur.execute(sql, (de, ate, *extra))
            apagado[nome] = cur.rowcount

        executar("acoes", f"""
            DELETE FROM silver.acoes_motorista a USING silver.motoristas m
             WHERE m.id = a.motorista_id AND m.empresa_id IS NOT NULL
               AND (a.realizado_em AT TIME ZONE '{tz}')::date BETWEEN %s AND %s""")
        executar("ocorrencias", f"""
            DELETE FROM silver.incidentes
             WHERE origem = 'interno' AND (ocorrido_em AT TIME ZONE '{tz}')::date BETWEEN %s AND %s""")
        cur.execute(f"""
            DELETE FROM silver.turnos t
             WHERE (t.iniciado_em AT TIME ZONE '{tz}')::date BETWEEN %s AND %s
            RETURNING t.viagem_id""", (de, ate))
        apagado["turnos"] = cur.rowcount
        executar("leituras", f"""
            DELETE FROM silver.leituras_fadiga
             WHERE (registrado_em AT TIME ZONE '{tz}')::date BETWEEN %s AND %s""")
        executar("alertas", f"""
            DELETE FROM silver.alertas
             WHERE (disparado_em AT TIME ZONE '{tz}')::date BETWEEN %s AND %s""")
        executar("viagens", f"""
            DELETE FROM silver.viagens
             WHERE (partida_prevista AT TIME ZONE '{tz}')::date BETWEEN %s AND %s""")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
    logger.info("Período %s a %s apagado: %s", de, ate, apagado)
    return apagado


def _acao(event):
    """Pedido direto do simulador (lambda invoke), não evento do S3."""
    try:
        conn = get_connection()
    except Exception:
        reset_connection()
        raise
    acao = event["acao"]
    if acao == "ultimas_leituras":
        return {"ultimas": ultimas_leituras(conn, list(event.get("devices") or []))}
    if acao == "cobertura":
        turnos = list(event.get("turnos") or [])
        resultado = cobertura(conn, turnos)
        return {"cobertura": resultado}
    if acao == "planejar_viagens":
        return {"viagens": planejar_viagens(conn, list(event.get("turnos") or []))}
    if acao == "limpar":
        return {"limpo": limpar(conn, list(event.get("intervalos") or []))}
    if acao == "simular_central":
        return {"central": simular_central(conn, event["ate"])}
    if acao == "limpar_periodo":
        return {"apagado": limpar_periodo(conn, event["de"], event["ate"])}
    raise ValueError(f"acao desconhecida: {acao}")


def handler(event, context):
    if isinstance(event, dict) and event.get("acao"):
        return _acao(event)

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
