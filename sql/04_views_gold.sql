-- =============================================================================
-- DriveGuard — Camada GOLD (analítica)
--
-- MATERIALIZED VIEWs consumidas pela API da dashboard. Três regras valem para
-- todas:
--
-- 1. Guardam SOMAS e CONTAGENS, não só médias. A API agrega vários dias,
--    regiões e tipos de veículo; tirar a média de médias dá número errado.
--    A média pronta continua disponível para quem lê uma linha só.
--
-- 2. As views da frota têm empresa_id. A API sempre filtra pela empresa do
--    usuário logado, para um cliente nunca ver a frota de outro.
--
-- 3. Dias e horas são do fuso de Brasília. "Horário crítico 03h-05h" precisa
--    ser horário local, não UTC.
--
-- Atualização:
--   mv_*      -> Lambda etl_gold, a cada 5 minutos (REFRESH CONCURRENTLY)
--   mv_prf_*  -> Lambda prf_carga, só quando chega arquivo novo da PRF
--
-- O REFRESH CONCURRENTLY exige um índice UNIQUE sem colunas nulas em cada view
-- (um UNIQUE não desduplica NULL e o refresh aborta com "duplicate rows").
-- Por isso toda dimensão passa por COALESCE com um sentinela ('ND', 'nd').
--
-- Componentes ao vivo (alertas em tempo real, lista de motoristas) leem a view
-- comum gold.vw_frota_agora, que consulta a Silver na hora.
-- =============================================================================

SET search_path TO gold, silver, public;

-- -----------------------------------------------------------------------------
-- Funções auxiliares
-- -----------------------------------------------------------------------------

-- Mesma escala do front (riskFromScore em mockData.ts).
CREATE OR REPLACE FUNCTION gold.fn_nivel_risco(p_score NUMERIC)
RETURNS TEXT AS $$
    SELECT CASE
        WHEN p_score IS NULL THEN 'sem_dados'
        WHEN p_score < 35    THEN 'low'
        WHEN p_score < 60    THEN 'medium'
        WHEN p_score < 80    THEN 'high'
        ELSE 'critical'
    END;
$$ LANGUAGE sql IMMUTABLE;

-- Horário de Brasília. STABLE (e não IMMUTABLE) porque regras de fuso podem mudar.
CREATE OR REPLACE FUNCTION gold.fn_local(p_ts TIMESTAMPTZ)
RETURNS TIMESTAMP AS $$
    SELECT p_ts AT TIME ZONE 'America/Sao_Paulo';
$$ LANGUAGE sql STABLE;

-- Remove as views da versão anterior que mudaram de nome.
DROP MATERIALIZED VIEW IF EXISTS gold.mv_incidentes_por_faixa_horaria CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_incidentes_por_causa_mes CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_hotspots_cidades CASCADE;

-- =============================================================================
-- FROTA (refresh a cada 5 minutos)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- mv_kpis_diarios -> KPIs, evolução da fadiga (30 dias), relatórios
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_kpis_diarios CASCADE;

CREATE MATERIALIZED VIEW gold.mv_kpis_diarios AS
WITH agg_leituras AS (
    SELECT
        gold.fn_local(l.registrado_em)::DATE AS dia,
        m.empresa_id,
        COALESCE(m.regiao_uf, 'ND')          AS regiao_uf,
        COALESCE(v.tipo::TEXT, 'nd')         AS tipo_veiculo,
        COUNT(*)                                       AS total_leituras,
        SUM(l.score_fadiga)                            AS soma_score,
        MAX(l.score_fadiga)                            AS score_fadiga_maximo,
        SUM(l.perclos)                                 AS soma_perclos,
        COUNT(l.perclos)                               AS leituras_com_perclos,
        COUNT(*) FILTER (WHERE l.estado = 'sonolento') AS leituras_sonolento,
        COUNT(*) FILTER (WHERE l.estado = 'fadiga')    AS leituras_fadiga,
        COUNT(DISTINCT l.motorista_id)                 AS motoristas_monitorados,
        COUNT(DISTINCT l.motorista_id) FILTER (WHERE l.score_fadiga >= 80) AS motoristas_risco_critico
    FROM silver.leituras_fadiga l
    JOIN silver.motoristas m ON m.id = l.motorista_id
    LEFT JOIN silver.veiculos v ON v.id = l.veiculo_id
    GROUP BY 1, 2, 3, 4
),
agg_alertas AS (
    SELECT
        gold.fn_local(a.disparado_em)::DATE AS dia,
        m.empresa_id,
        COALESCE(m.regiao_uf, 'ND')         AS regiao_uf,
        COALESCE(v.tipo::TEXT, 'nd')        AS tipo_veiculo,
        COUNT(*)                                                  AS total_alertas,
        COUNT(*) FILTER (WHERE a.gravidade IN ('alta', 'critica')) AS alertas_graves,
        SUM(EXTRACT(EPOCH FROM (a.reconhecido_em - a.disparado_em)) / 60.0)
            FILTER (WHERE a.reconhecido_em IS NOT NULL)          AS soma_minutos_reconhecimento,
        COUNT(*) FILTER (WHERE a.reconhecido_em IS NOT NULL)     AS alertas_reconhecidos
    FROM silver.alertas a
    JOIN silver.motoristas m ON m.id = a.motorista_id
    LEFT JOIN silver.veiculos v ON v.id = a.veiculo_id
    GROUP BY 1, 2, 3, 4
),
agg_turnos AS (
    SELECT
        gold.fn_local(t.iniciado_em)::DATE AS dia,
        m.empresa_id,
        COALESCE(m.regiao_uf, 'ND')        AS regiao_uf,
        COALESCE(v.tipo::TEXT, 'nd')       AS tipo_veiculo,
        COUNT(*)                  AS total_turnos,
        SUM(t.duracao_minutos)    AS soma_minutos_turno,
        COUNT(t.duracao_minutos)  AS turnos_concluidos,
        SUM(t.distancia_km)       AS distancia_total_km
    FROM silver.turnos t
    JOIN silver.motoristas m ON m.id = t.motorista_id
    LEFT JOIN silver.veiculos v ON v.id = t.veiculo_id
    GROUP BY 1, 2, 3, 4
),
chaves AS (
    SELECT dia, empresa_id, regiao_uf, tipo_veiculo FROM agg_leituras
    UNION
    SELECT dia, empresa_id, regiao_uf, tipo_veiculo FROM agg_alertas
    UNION
    SELECT dia, empresa_id, regiao_uf, tipo_veiculo FROM agg_turnos
)
SELECT
    k.dia,
    k.empresa_id,
    k.regiao_uf,
    COALESCE(u.macro_regiao, 'ND')            AS macro_regiao,
    k.tipo_veiculo,
    COALESCE(l.total_leituras, 0)             AS total_leituras,
    COALESCE(l.soma_score, 0)                 AS soma_score,
    ROUND(l.soma_score / NULLIF(l.total_leituras, 0), 2) AS score_fadiga_medio,
    l.score_fadiga_maximo,
    COALESCE(l.soma_perclos, 0)               AS soma_perclos,
    COALESCE(l.leituras_com_perclos, 0)       AS leituras_com_perclos,
    COALESCE(l.leituras_sonolento, 0)         AS leituras_sonolento,
    COALESCE(l.leituras_fadiga, 0)            AS leituras_fadiga,
    COALESCE(l.motoristas_monitorados, 0)     AS motoristas_monitorados,
    COALESCE(l.motoristas_risco_critico, 0)   AS motoristas_risco_critico,
    COALESCE(a.total_alertas, 0)              AS total_alertas,
    COALESCE(a.alertas_graves, 0)             AS alertas_graves,
    COALESCE(a.soma_minutos_reconhecimento, 0) AS soma_minutos_reconhecimento,
    COALESCE(a.alertas_reconhecidos, 0)       AS alertas_reconhecidos,
    COALESCE(t.total_turnos, 0)               AS total_turnos,
    COALESCE(t.soma_minutos_turno, 0)         AS soma_minutos_turno,
    COALESCE(t.turnos_concluidos, 0)          AS turnos_concluidos,
    COALESCE(t.distancia_total_km, 0)         AS distancia_total_km,
    now()                                     AS atualizado_em
FROM chaves k
LEFT JOIN agg_leituras l
       ON l.dia = k.dia AND l.empresa_id = k.empresa_id
      AND l.regiao_uf = k.regiao_uf AND l.tipo_veiculo = k.tipo_veiculo
LEFT JOIN agg_alertas a
       ON a.dia = k.dia AND a.empresa_id = k.empresa_id
      AND a.regiao_uf = k.regiao_uf AND a.tipo_veiculo = k.tipo_veiculo
LEFT JOIN agg_turnos t
       ON t.dia = k.dia AND t.empresa_id = k.empresa_id
      AND t.regiao_uf = k.regiao_uf AND t.tipo_veiculo = k.tipo_veiculo
LEFT JOIN silver.dim_uf u ON u.uf = k.regiao_uf;

CREATE UNIQUE INDEX ux_mv_kpis_diarios
    ON gold.mv_kpis_diarios (dia, empresa_id, regiao_uf, tipo_veiculo);
CREATE INDEX ix_mv_kpis_diarios_empresa ON gold.mv_kpis_diarios (empresa_id, dia);

COMMENT ON MATERIALIZED VIEW gold.mv_kpis_diarios IS
    'KPIs por dia/empresa/UF/tipo de veículo. Some soma_score e divida por total_leituras para a média do período.';

-- -----------------------------------------------------------------------------
-- mv_alertas_agregados -> horário crítico, sinais detectados, distribuição dos
--                         alertas, indicador de alertas atendidos (ROI)
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_alertas_agregados CASCADE;

CREATE MATERIALIZED VIEW gold.mv_alertas_agregados AS
SELECT
    m.empresa_id,
    gold.fn_local(a.disparado_em)::DATE              AS dia,
    EXTRACT(HOUR FROM gold.fn_local(a.disparado_em))::INT AS hora,
    COALESCE(m.regiao_uf, 'ND')                      AS regiao_uf,
    COALESCE(u.macro_regiao, 'ND')                   AS macro_regiao,
    COALESCE(v.tipo::TEXT, 'nd')                     AS tipo_veiculo,
    a.tipo::TEXT                                     AS tipo,
    a.gravidade::TEXT                                AS gravidade,
    COUNT(*)                                         AS total,
    -- Atendido = teve uma ação de pausa, troca ou encerramento registrada.
    -- É o indicador operacional que aparece ao lado do ROI.
    COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM silver.acoes_motorista ac
        WHERE ac.alerta_id = a.id
          AND ac.tipo IN ('pausa_obrigatoria', 'encerramento_turno', 'troca_motorista')
    ))                                               AS atendidos,
    COUNT(*) FILTER (WHERE a.status = 'aberto')      AS abertos,
    now()                                            AS atualizado_em
FROM silver.alertas a
JOIN silver.motoristas m ON m.id = a.motorista_id
LEFT JOIN silver.veiculos v ON v.id = a.veiculo_id
LEFT JOIN silver.dim_uf u ON u.uf = m.regiao_uf
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8;

CREATE UNIQUE INDEX ux_mv_alertas_agregados
    ON gold.mv_alertas_agregados (empresa_id, dia, hora, regiao_uf, tipo_veiculo, tipo, gravidade);
CREATE INDEX ix_mv_alertas_agregados_dia ON gold.mv_alertas_agregados (empresa_id, dia);

COMMENT ON MATERIALIZED VIEW gold.mv_alertas_agregados IS
    'Alertas por empresa, dia, hora local, região, tipo de veículo, tipo e gravidade.';

-- -----------------------------------------------------------------------------
-- mv_fadiga_por_tempo_direcao -> tendência ao longo do turno, fadiga vs tempo
--                                de direção, heatmap (horas de direção x dia)
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_fadiga_por_tempo_direcao CASCADE;

CREATE MATERIALIZED VIEW gold.mv_fadiga_por_tempo_direcao AS
WITH leituras AS (
    SELECT
        m.empresa_id,
        gold.fn_local(l.registrado_em)::DATE AS dia,
        COALESCE(m.regiao_uf, 'ND')          AS regiao_uf,
        COALESCE(v.tipo::TEXT, 'nd')         AS tipo_veiculo,
        LEAST(GREATEST(FLOOR(EXTRACT(EPOCH FROM (l.registrado_em - t.iniciado_em)) / 3600.0)::INT, 0), 14)
                                             AS hora_direcao,
        l.score_fadiga, l.perclos, l.blink_rate, l.estado
    FROM silver.leituras_fadiga l
    JOIN silver.turnos t     ON t.id = l.turno_id
    JOIN silver.motoristas m ON m.id = l.motorista_id
    LEFT JOIN silver.veiculos v ON v.id = l.veiculo_id
    WHERE l.registrado_em >= t.iniciado_em
),
agg_leituras AS (
    SELECT
        empresa_id, dia, regiao_uf, tipo_veiculo, hora_direcao,
        COUNT(*)                                     AS leituras,
        SUM(score_fadiga)                            AS soma_score,
        SUM(perclos)                                 AS soma_perclos,
        COUNT(perclos)                               AS leituras_com_perclos,
        SUM(blink_rate)                              AS soma_blink_rate,
        COUNT(blink_rate)                            AS leituras_com_blink_rate,
        COUNT(*) FILTER (WHERE estado = 'sonolento') AS leituras_sonolento
    FROM leituras
    GROUP BY 1, 2, 3, 4, 5
),
agg_alertas AS (
    SELECT
        m.empresa_id,
        gold.fn_local(a.disparado_em)::DATE  AS dia,
        COALESCE(m.regiao_uf, 'ND')          AS regiao_uf,
        COALESCE(v.tipo::TEXT, 'nd')         AS tipo_veiculo,
        LEAST(GREATEST(FLOOR(EXTRACT(EPOCH FROM (a.disparado_em - t.iniciado_em)) / 3600.0)::INT, 0), 14)
                                             AS hora_direcao,
        COUNT(*)                             AS alertas
    FROM silver.alertas a
    JOIN silver.turnos t     ON t.id = a.turno_id
    JOIN silver.motoristas m ON m.id = a.motorista_id
    LEFT JOIN silver.veiculos v ON v.id = a.veiculo_id
    WHERE a.disparado_em >= t.iniciado_em
    GROUP BY 1, 2, 3, 4, 5
),
chaves AS (
    SELECT empresa_id, dia, regiao_uf, tipo_veiculo, hora_direcao FROM agg_leituras
    UNION
    SELECT empresa_id, dia, regiao_uf, tipo_veiculo, hora_direcao FROM agg_alertas
)
SELECT
    k.empresa_id,
    k.dia,
    k.regiao_uf,
    COALESCE(u.macro_regiao, 'ND')            AS macro_regiao,
    k.tipo_veiculo,
    k.hora_direcao,
    COALESCE(l.leituras, 0)                   AS leituras,
    COALESCE(l.soma_score, 0)                 AS soma_score,
    ROUND(l.soma_score / NULLIF(l.leituras, 0), 2) AS score_fadiga_medio,
    COALESCE(l.soma_perclos, 0)               AS soma_perclos,
    COALESCE(l.leituras_com_perclos, 0)       AS leituras_com_perclos,
    COALESCE(l.soma_blink_rate, 0)            AS soma_blink_rate,
    COALESCE(l.leituras_com_blink_rate, 0)    AS leituras_com_blink_rate,
    COALESCE(l.leituras_sonolento, 0)         AS leituras_sonolento,
    COALESCE(al.alertas, 0)                   AS alertas,
    now()                                     AS atualizado_em
FROM chaves k
LEFT JOIN agg_leituras l
       ON l.empresa_id = k.empresa_id AND l.dia = k.dia AND l.regiao_uf = k.regiao_uf
      AND l.tipo_veiculo = k.tipo_veiculo AND l.hora_direcao = k.hora_direcao
LEFT JOIN agg_alertas al
       ON al.empresa_id = k.empresa_id AND al.dia = k.dia AND al.regiao_uf = k.regiao_uf
      AND al.tipo_veiculo = k.tipo_veiculo AND al.hora_direcao = k.hora_direcao
LEFT JOIN silver.dim_uf u ON u.uf = k.regiao_uf;

CREATE UNIQUE INDEX ux_mv_fadiga_tempo
    ON gold.mv_fadiga_por_tempo_direcao (empresa_id, dia, regiao_uf, tipo_veiculo, hora_direcao);
CREATE INDEX ix_mv_fadiga_tempo_empresa ON gold.mv_fadiga_por_tempo_direcao (empresa_id, dia);

COMMENT ON MATERIALIZED VIEW gold.mv_fadiga_por_tempo_direcao IS
    'Fadiga e alertas por hora de direção (0 a 14h) e dia. Alimenta a tendência no turno, '
    'o gráfico fadiga x tempo de direção e o heatmap.';

-- -----------------------------------------------------------------------------
-- mv_curva_fadiga_turno -> evolução da fadiga no turno (por motorista)
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_curva_fadiga_turno CASCADE;

CREATE MATERIALIZED VIEW gold.mv_curva_fadiga_turno AS
SELECT
    t.id                                   AS turno_id,
    m.empresa_id,
    t.motorista_id,
    m.nome_exibicao                        AS motorista,
    t.iniciado_em,
    -- Blocos de 1 hora, igual ao eixo do gráfico (1h, 2h, ...)
    FLOOR(EXTRACT(EPOCH FROM (l.registrado_em - t.iniciado_em)) / 3600.0)::INT AS hora_do_turno,
    COUNT(*)                               AS leituras,
    SUM(l.score_fadiga)                    AS soma_score,
    ROUND(AVG(l.score_fadiga), 2)          AS score_fadiga_medio,
    ROUND(MAX(l.score_fadiga), 2)          AS score_fadiga_maximo,
    ROUND(AVG(l.perclos), 4)               AS perclos_medio,
    ROUND(AVG(l.ear), 4)                   AS ear_medio,
    ROUND(AVG(l.mar), 4)                   AS mar_medio,
    ROUND(AVG(l.head_pitch), 2)            AS head_pitch_medio,
    COUNT(*) FILTER (WHERE l.estado = 'sonolento') AS leituras_sonolento,
    now()                                  AS atualizado_em
FROM silver.leituras_fadiga l
JOIN silver.turnos t     ON t.id = l.turno_id
JOIN silver.motoristas m ON m.id = t.motorista_id
WHERE l.registrado_em >= t.iniciado_em
GROUP BY t.id, m.empresa_id, t.motorista_id, m.nome_exibicao, t.iniciado_em, 6;

CREATE UNIQUE INDEX ux_mv_curva_fadiga
    ON gold.mv_curva_fadiga_turno (turno_id, hora_do_turno);
CREATE INDEX ix_mv_curva_fadiga_motorista
    ON gold.mv_curva_fadiga_turno (motorista_id, iniciado_em DESC);
CREATE INDEX ix_mv_curva_fadiga_empresa
    ON gold.mv_curva_fadiga_turno (empresa_id, iniciado_em DESC);

COMMENT ON MATERIALIZED VIEW gold.mv_curva_fadiga_turno IS
    'Série da fadiga dentro de cada turno, em blocos de 1 hora.';

-- -----------------------------------------------------------------------------
-- mv_ranking_motoristas -> lista de motoristas, KPIs do motorista
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_ranking_motoristas CASCADE;

CREATE MATERIALIZED VIEW gold.mv_ranking_motoristas AS
WITH janela AS (
    SELECT l.*
    FROM silver.leituras_fadiga l
    WHERE l.registrado_em >= now() - INTERVAL '30 days'
),
metricas AS (
    SELECT
        motorista_id,
        COUNT(*)                                     AS leituras_30d,
        ROUND(AVG(score_fadiga), 2)                  AS score_fadiga_medio,
        ROUND(MAX(score_fadiga), 2)                  AS score_fadiga_maximo,
        ROUND(AVG(blink_rate), 2)                    AS blink_rate_medio,
        ROUND(AVG(duracao_olhos_fechados_ms), 0)     AS fechamento_olhos_medio_ms,
        ROUND(AVG(ABS(head_pitch)), 2)               AS inclinacao_cabeca_media,
        ROUND(AVG(perclos), 4)                       AS perclos_medio,
        COUNT(*) FILTER (WHERE estado = 'sonolento') AS leituras_sonolento,
        MAX(registrado_em)                           AS ultima_leitura_em
    FROM janela
    GROUP BY motorista_id
),
alertas_30d AS (
    SELECT
        motorista_id,
        COUNT(*)                                                  AS alertas_30d,
        COUNT(*) FILTER (WHERE gravidade IN ('alta', 'critica'))  AS alertas_graves_30d,
        COUNT(*) FILTER (WHERE status = 'aberto')                 AS alertas_abertos
    FROM silver.alertas
    WHERE disparado_em >= now() - INTERVAL '30 days'
    GROUP BY motorista_id
),
turnos_30d AS (
    SELECT
        motorista_id,
        COUNT(*)                               AS turnos_30d,
        ROUND(SUM(duracao_minutos) / 60.0, 2)  AS horas_dirigidas_30d,
        ROUND(AVG(duracao_minutos) / 60.0, 2)  AS duracao_media_turno_h,
        ROUND(SUM(distancia_km), 2)            AS km_rodados_30d
    FROM silver.turnos
    WHERE iniciado_em >= now() - INTERVAL '30 days'
    GROUP BY motorista_id
),
ultimo_veiculo AS (
    SELECT DISTINCT ON (t.motorista_id)
        t.motorista_id, t.veiculo_id
    FROM silver.turnos t
    WHERE t.veiculo_id IS NOT NULL
    ORDER BY t.motorista_id, t.iniciado_em DESC
)
SELECT
    m.id                                 AS motorista_id,
    m.empresa_id,
    m.codigo,
    m.nome_exibicao                      AS motorista,
    m.idade,
    m.anos_experiencia,
    COALESCE(m.regiao_uf, 'ND')          AS regiao_uf,
    COALESCE(u.macro_regiao, 'ND')       AS macro_regiao,
    m.status,
    ve.id                                AS veiculo_id,
    COALESCE(ve.tipo::TEXT, 'nd')        AS tipo_veiculo,
    ve.placa,
    d.codigo                             AS veiculo_codigo,
    COALESCE(me.leituras_30d, 0)         AS leituras_30d,
    me.score_fadiga_medio,
    me.score_fadiga_maximo,
    me.blink_rate_medio,
    me.fechamento_olhos_medio_ms,
    me.inclinacao_cabeca_media,
    me.perclos_medio,
    COALESCE(me.leituras_sonolento, 0)   AS leituras_sonolento,
    me.ultima_leitura_em,
    COALESCE(al.alertas_30d, 0)          AS alertas_30d,
    COALESCE(al.alertas_graves_30d, 0)   AS alertas_graves_30d,
    COALESCE(al.alertas_abertos, 0)      AS alertas_abertos,
    COALESCE(tu.turnos_30d, 0)           AS turnos_30d,
    tu.horas_dirigidas_30d,
    tu.duracao_media_turno_h,
    tu.km_rodados_30d,
    gold.fn_nivel_risco(me.score_fadiga_medio) AS nivel_risco,
    RANK() OVER (PARTITION BY m.empresa_id ORDER BY COALESCE(me.score_fadiga_medio, -1) DESC) AS posicao_risco,
    now()                                AS atualizado_em
FROM silver.motoristas m
LEFT JOIN metricas    me ON me.motorista_id = m.id
LEFT JOIN alertas_30d al ON al.motorista_id = m.id
LEFT JOIN turnos_30d  tu ON tu.motorista_id = m.id
LEFT JOIN ultimo_veiculo uv ON uv.motorista_id = m.id
LEFT JOIN silver.veiculos ve ON ve.id = uv.veiculo_id
LEFT JOIN silver.vinculos_dispositivo_veiculo vd ON vd.veiculo_id = ve.id AND vd.fim IS NULL
LEFT JOIN silver.dispositivos d ON d.id = vd.dispositivo_id
LEFT JOIN silver.dim_uf u ON u.uf = m.regiao_uf;

CREATE UNIQUE INDEX ux_mv_ranking_motoristas ON gold.mv_ranking_motoristas (motorista_id);
CREATE INDEX ix_mv_ranking_empresa ON gold.mv_ranking_motoristas (empresa_id, posicao_risco);

COMMENT ON MATERIALIZED VIEW gold.mv_ranking_motoristas IS
    'Um registro por motorista: métricas de 30 dias, veículo atual e nível de risco.';

-- -----------------------------------------------------------------------------
-- mv_rotas_desempenho -> rotas com maior incidência
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_rotas_desempenho CASCADE;

CREATE MATERIALIZED VIEW gold.mv_rotas_desempenho AS
WITH agg_leituras AS (
    SELECT
        r.empresa_id,
        r.id                                     AS rota_id,
        gold.fn_local(l.registrado_em)::DATE     AS dia,
        COUNT(DISTINCT t.id)                     AS turnos,
        COUNT(*)                                 AS leituras,
        SUM(l.score_fadiga)                      AS soma_score,
        COUNT(*) FILTER (WHERE l.estado = 'sonolento') AS leituras_sonolento
    FROM silver.leituras_fadiga l
    JOIN silver.turnos  t  ON t.id = l.turno_id
    JOIN silver.viagens vg ON vg.id = t.viagem_id
    JOIN silver.rotas   r  ON r.id = vg.rota_id
    GROUP BY 1, 2, 3
),
agg_alertas AS (
    SELECT
        r.empresa_id,
        r.id                                     AS rota_id,
        gold.fn_local(a.disparado_em)::DATE      AS dia,
        COUNT(*)                                 AS alertas,
        COUNT(*) FILTER (WHERE a.gravidade IN ('alta', 'critica')) AS alertas_graves
    FROM silver.alertas a
    JOIN silver.turnos  t  ON t.id = a.turno_id
    JOIN silver.viagens vg ON vg.id = t.viagem_id
    JOIN silver.rotas   r  ON r.id = vg.rota_id
    GROUP BY 1, 2, 3
),
chaves AS (
    SELECT empresa_id, rota_id, dia FROM agg_leituras
    UNION
    SELECT empresa_id, rota_id, dia FROM agg_alertas
)
SELECT
    k.empresa_id,
    k.rota_id,
    k.dia,
    COALESCE(l.turnos, 0)              AS turnos,
    COALESCE(l.leituras, 0)            AS leituras,
    COALESCE(l.soma_score, 0)          AS soma_score,
    COALESCE(l.leituras_sonolento, 0)  AS leituras_sonolento,
    COALESCE(a.alertas, 0)             AS alertas,
    COALESCE(a.alertas_graves, 0)      AS alertas_graves,
    now()                              AS atualizado_em
FROM chaves k
LEFT JOIN agg_leituras l ON l.rota_id = k.rota_id AND l.dia = k.dia
LEFT JOIN agg_alertas  a ON a.rota_id = k.rota_id AND a.dia = k.dia;

CREATE UNIQUE INDEX ux_mv_rotas_desempenho ON gold.mv_rotas_desempenho (rota_id, dia);
CREATE INDEX ix_mv_rotas_desempenho_empresa ON gold.mv_rotas_desempenho (empresa_id, dia);

COMMENT ON MATERIALIZED VIEW gold.mv_rotas_desempenho IS
    'Fadiga e alertas por rota e dia. A API calcula o período, o risco e a variação contra o período anterior.';

-- =============================================================================
-- PRF (refresh quando chega arquivo novo da PRF)
--
-- Só acidentes com origem = 'prf'. Ocorrências internas de cada empresa ficam
-- fora daqui, porque estas views não têm empresa_id.
-- =============================================================================

-- Base comum: acidente da PRF + se envolveu veículo pesado.
CREATE OR REPLACE VIEW gold.vw_prf_base AS
SELECT
    i.id,
    i.ocorrido_em,
    gold.fn_local(i.ocorrido_em)  AS ocorrido_local,
    -- Só os dígitos e sem zero à esquerda: a PRF grava a BR-040 como "40".
    COALESCE(NULLIF(ltrim(regexp_replace(COALESCE(i.br, ''), '\D', '', 'g'), '0'), ''), 'ND') AS br,
    COALESCE(i.uf, 'ND')          AS uf,
    COALESCE(NULLIF(TRIM(i.municipio), ''), 'NAO INFORMADO') AS municipio,
    i.km,
    i.latitude,
    i.longitude,
    COALESCE(NULLIF(TRIM(i.causa), ''), 'Não informada') AS causa,
    i.tipo_acidente,
    i.gravidade,
    i.qtd_mortos,
    i.qtd_feridos,
    i.relacionado_sonolencia,
    EXISTS (
        SELECT 1 FROM silver.incidentes_veiculos iv
        WHERE iv.incidente_id = i.id AND silver.fn_veiculo_pesado(iv.tipo_veiculo)
    ) AS veiculo_pesado
FROM silver.incidentes i
WHERE i.origem = 'prf';

-- -----------------------------------------------------------------------------
-- mv_prf_faixa_horaria -> acidentes por faixa horária (fonte: PRF)
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_prf_faixa_horaria CASCADE;

CREATE MATERIALIZED VIEW gold.mv_prf_faixa_horaria AS
SELECT
    CASE
        WHEN EXTRACT(HOUR FROM ocorrido_local) <  6 THEN 'madrugada'
        WHEN EXTRACT(HOUR FROM ocorrido_local) < 12 THEN 'manha'
        WHEN EXTRACT(HOUR FROM ocorrido_local) < 18 THEN 'tarde'
        ELSE 'noite'
    END                                          AS faixa_horaria,
    CASE
        WHEN EXTRACT(HOUR FROM ocorrido_local) <  6 THEN 1
        WHEN EXTRACT(HOUR FROM ocorrido_local) < 12 THEN 2
        WHEN EXTRACT(HOUR FROM ocorrido_local) < 18 THEN 3
        ELSE 4
    END                                          AS ordem_faixa,
    uf,
    date_trunc('month', ocorrido_local)::DATE    AS mes,
    veiculo_pesado,
    COUNT(*)                                     AS total_incidentes,
    COUNT(*) FILTER (WHERE relacionado_sonolencia) AS incidentes_sonolencia,
    SUM(qtd_mortos)                              AS total_mortos,
    SUM(qtd_feridos)                             AS total_feridos,
    now()                                        AS atualizado_em
FROM gold.vw_prf_base
GROUP BY 1, 2, 3, 4, 5;

CREATE UNIQUE INDEX ux_mv_prf_faixa_horaria
    ON gold.mv_prf_faixa_horaria (faixa_horaria, uf, mes, veiculo_pesado);

-- -----------------------------------------------------------------------------
-- mv_prf_causas_mes -> causas dos acidentes (fonte: PRF)
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_prf_causas_mes CASCADE;

CREATE MATERIALIZED VIEW gold.mv_prf_causas_mes AS
SELECT
    date_trunc('month', ocorrido_local)::DATE  AS mes,
    causa,
    uf,
    veiculo_pesado,
    COUNT(*)                                   AS total_incidentes,
    COUNT(*) FILTER (WHERE gravidade = 'com_fatais') AS incidentes_fatais,
    SUM(qtd_mortos)                            AS total_mortos,
    SUM(qtd_feridos)                           AS total_feridos,
    BOOL_OR(relacionado_sonolencia)            AS causa_ligada_a_sono,
    now()                                      AS atualizado_em
FROM gold.vw_prf_base
GROUP BY 1, 2, 3, 4;

CREATE UNIQUE INDEX ux_mv_prf_causas_mes
    ON gold.mv_prf_causas_mes (mes, causa, uf, veiculo_pesado);

-- -----------------------------------------------------------------------------
-- mv_prf_hotspots -> mapa do Brasil (fonte: PRF)
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_prf_hotspots CASCADE;

CREATE MATERIALIZED VIEW gold.mv_prf_hotspots AS
SELECT
    uf,
    municipio,
    date_trunc('month', ocorrido_local)::DATE  AS mes,
    veiculo_pesado,
    COUNT(*)                                   AS total_incidentes,
    COUNT(*) FILTER (WHERE relacionado_sonolencia) AS incidentes_sonolencia,
    COUNT(*) FILTER (WHERE gravidade = 'com_fatais') AS incidentes_fatais,
    SUM(qtd_mortos)                            AS total_mortos,
    SUM(latitude)                              AS soma_latitude,
    SUM(longitude)                             AS soma_longitude,
    COUNT(latitude)                            AS pontos_com_coordenada,
    now()                                      AS atualizado_em
FROM gold.vw_prf_base
GROUP BY 1, 2, 3, 4;

CREATE UNIQUE INDEX ux_mv_prf_hotspots
    ON gold.mv_prf_hotspots (uf, municipio, mes, veiculo_pesado);

COMMENT ON MATERIALIZED VIEW gold.mv_prf_hotspots IS
    'Acidentes por município e mês. A API soma o período e calcula a coordenada média '
    '(soma_latitude / pontos_com_coordenada) e a severidade relativa.';

-- -----------------------------------------------------------------------------
-- mv_prf_trechos -> risco das rotas (cruzamento por BR + UF)
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_prf_trechos CASCADE;

CREATE MATERIALIZED VIEW gold.mv_prf_trechos AS
SELECT
    br,
    uf,
    (FLOOR(COALESCE(km, 0) / 50) * 50)::INT       AS faixa_km,
    date_trunc('month', ocorrido_local)::DATE     AS mes,
    COUNT(*)                                      AS acidentes,
    COUNT(*) FILTER (WHERE gravidade = 'com_fatais') AS fatais,
    SUM(qtd_mortos)                               AS mortos,
    COUNT(*) FILTER (WHERE relacionado_sonolencia) AS acidentes_sono,
    COUNT(*) FILTER (WHERE veiculo_pesado)        AS acidentes_pesados,
    COUNT(*) FILTER (WHERE veiculo_pesado AND relacionado_sonolencia) AS acidentes_pesados_sono,
    SUM(qtd_mortos) FILTER (WHERE veiculo_pesado) AS mortos_pesados,
    now()                                         AS atualizado_em
FROM gold.vw_prf_base
GROUP BY 1, 2, 3, 4;

CREATE UNIQUE INDEX ux_mv_prf_trechos ON gold.mv_prf_trechos (br, uf, faixa_km, mes);
CREATE INDEX ix_mv_prf_trechos_br ON gold.mv_prf_trechos (br, uf);

COMMENT ON MATERIALIZED VIEW gold.mv_prf_trechos IS
    'Acidentes por BR, UF, faixa de 50 km e mês. Uma rota cruza aqui pelas BRs e UFs que percorre.';

-- -----------------------------------------------------------------------------
-- mv_prf_perfil_sono -> parâmetros do ROI calculados da PRF
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_prf_perfil_sono CASCADE;

CREATE MATERIALIZED VIEW gold.mv_prf_perfil_sono AS
SELECT
    EXTRACT(YEAR FROM b.ocorrido_local)::INT          AS ano,
    r.recorte,
    COUNT(*)                                          AS acidentes,
    COUNT(*) FILTER (WHERE b.gravidade = 'com_fatais')  AS fatais,
    COUNT(*) FILTER (WHERE b.gravidade = 'com_feridos') AS com_feridos,
    COUNT(*) FILTER (WHERE b.gravidade = 'sem_vitimas') AS sem_vitimas,
    SUM(b.qtd_mortos)                                 AS mortos,
    now()                                             AS atualizado_em
FROM gold.vw_prf_base b
CROSS JOIN LATERAL (VALUES
    ('todos',        TRUE),
    ('sono',         b.relacionado_sonolencia),
    ('pesados',      b.veiculo_pesado),
    ('pesados_sono', b.veiculo_pesado AND b.relacionado_sonolencia)
) AS r(recorte, incluir)
WHERE r.incluir
GROUP BY 1, 2;

CREATE UNIQUE INDEX ux_mv_prf_perfil_sono ON gold.mv_prf_perfil_sono (ano, recorte);

COMMENT ON MATERIALIZED VIEW gold.mv_prf_perfil_sono IS
    'Gravidade e mortos por ano em quatro recortes. "pesados_sono" (caminhão/ônibus + condutor '
    'dormindo) dá a proporção por gravidade e a letalidade usadas no ROI.';

-- =============================================================================
-- AO VIVO (view comum, lida na hora)
-- =============================================================================

CREATE OR REPLACE VIEW gold.vw_frota_agora AS
SELECT
    m.empresa_id,
    m.id                                 AS motorista_id,
    m.codigo,
    m.nome_exibicao                      AS nome,
    m.idade,
    m.anos_experiencia,
    COALESCE(m.regiao_uf, 'ND')          AS regiao_uf,
    COALESCE(u.macro_regiao, 'ND')       AS macro_regiao,
    ul.registrado_em                     AS ultima_leitura_em,
    ul.score_fadiga                      AS score_atual,
    ul.estado::TEXT                      AS estado_atual,
    ul.blink_rate,
    ul.duracao_olhos_fechados_ms,
    ul.head_pitch,
    ul.perclos,
    ant.score_medio_anterior,
    CASE
        WHEN ant.score_medio_anterior IS NULL                 THEN 'estavel'
        WHEN ul.score_fadiga > ant.score_medio_anterior + 1   THEN 'up'
        WHEN ul.score_fadiga < ant.score_medio_anterior - 1   THEN 'down'
        ELSE 'estavel'
    END                                  AS tendencia,
    t.id                                 AS turno_id,
    t.iniciado_em                        AS turno_iniciado_em,
    t.status::TEXT                       AS turno_status,
    ROUND(EXTRACT(EPOCH FROM (COALESCE(t.finalizado_em, ul.registrado_em) - t.iniciado_em)) / 3600.0, 1)
                                         AS horas_turno,
    ve.id                                AS veiculo_id,
    COALESCE(ve.tipo::TEXT, 'nd')        AS tipo_veiculo,
    ve.placa,
    d.codigo                             AS veiculo_codigo,
    (
        SELECT COUNT(*)
        FROM silver.alertas a
        WHERE a.motorista_id = m.id
          AND a.disparado_em >= (date_trunc('day', now() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo')
    )                                    AS alertas_hoje,
    gold.fn_nivel_risco(ul.score_fadiga) AS risco
FROM silver.motoristas m
JOIN LATERAL (
    SELECT l.*
    FROM silver.leituras_fadiga l
    WHERE l.motorista_id = m.id
    ORDER BY l.registrado_em DESC
    LIMIT 1
) ul ON TRUE
LEFT JOIN LATERAL (
    SELECT AVG(x.score_fadiga) AS score_medio_anterior
    FROM (
        SELECT l2.score_fadiga
        FROM silver.leituras_fadiga l2
        WHERE l2.motorista_id = m.id AND l2.registrado_em < ul.registrado_em
        ORDER BY l2.registrado_em DESC
        LIMIT 5
    ) x
) ant ON TRUE
LEFT JOIN silver.turnos t ON t.id = ul.turno_id
LEFT JOIN silver.veiculos ve ON ve.id = COALESCE(ul.veiculo_id, t.veiculo_id)
LEFT JOIN silver.vinculos_dispositivo_veiculo vd ON vd.veiculo_id = ve.id AND vd.fim IS NULL
LEFT JOIN silver.dispositivos d ON d.id = vd.dispositivo_id
LEFT JOIN silver.dim_uf u ON u.uf = m.regiao_uf;

COMMENT ON VIEW gold.vw_frota_agora IS
    'Estado atual de cada motorista: última leitura, tendência contra as 5 anteriores, turno, '
    'veículo e alertas de hoje. A API filtra pela recência de ultima_leitura_em.';

-- =============================================================================
-- Catálogo e refresh
--
-- O refresh NÃO é feito por função plpgsql: REFRESH MATERIALIZED VIEW
-- CONCURRENTLY recusa rodar dentro de bloco de transação, e todo corpo de
-- função plpgsql é um. As Lambdas leem este catálogo e disparam um REFRESH por
-- statement em autocommit.
-- =============================================================================

CREATE OR REPLACE VIEW gold.vw_materialized_views AS
SELECT
    c.relname::TEXT AS view_name,
    CASE WHEN c.relname LIKE 'mv\_prf\_%' THEN 'prf' ELSE 'frota' END AS grupo,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS tamanho,
    c.relispopulated AS populada,
    EXISTS (
        SELECT 1 FROM pg_index i
        WHERE i.indrelid = c.oid AND i.indisunique
    ) AS tem_indice_unico
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gold'
  AND c.relkind = 'm'
ORDER BY c.relname;

COMMENT ON VIEW gold.vw_materialized_views IS
    'MATERIALIZED VIEWs do schema gold. grupo = frota (etl_gold, 5 min) ou prf (prf_carga). '
    'tem_indice_unico precisa ser TRUE em todas para o REFRESH CONCURRENTLY.';

-- Recarga manual, sem CONCURRENTLY (bloqueia leitura durante o refresh).
-- Usada ao final da migração, quando ainda não há leitor para proteger.
CREATE OR REPLACE FUNCTION gold.fn_refresh_bloqueante()
RETURNS TABLE (view_name TEXT, duracao_ms NUMERIC) AS $$
DECLARE
    v_name   TEXT;
    v_inicio TIMESTAMPTZ;
BEGIN
    FOR v_name IN SELECT v.view_name FROM gold.vw_materialized_views v
    LOOP
        v_inicio := clock_timestamp();
        EXECUTE format('REFRESH MATERIALIZED VIEW gold.%I', v_name);

        view_name  := v_name;
        duracao_ms := ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_inicio)) * 1000, 2);
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION gold.fn_refresh_bloqueante IS
    'Refresh sequencial SEM CONCURRENTLY de todas as views. Usado ao final da migração.';
