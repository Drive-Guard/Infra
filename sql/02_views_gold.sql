-- =============================================================================
-- DriveGuard — Camada GOLD (analítica)
--
-- 7 MATERIALIZED VIEWs, uma por componente do dashboard. São atualizadas a
-- cada 5 minutos pela Lambda etl_gold via
--     REFRESH MATERIALIZED VIEW CONCURRENTLY gold.mv_*;
--
-- O REFRESH CONCURRENTLY exige um índice UNIQUE em cada view — por isso toda
-- view abaixo tem um ux_* logo depois. Sem ele o refresh trava a leitura do
-- dashboard durante a atualização.
--
-- Componentes que precisam de dado ao vivo (Alertas em Tempo Real, Ações
-- Rápidas, Insights) consultam a Silver diretamente e não passam por aqui.
-- =============================================================================

SET search_path TO gold, silver, public;

-- -----------------------------------------------------------------------------
-- 1. mv_kpis_diarios  ->  "KPIs principais" (Visão Geral)
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_kpis_diarios CASCADE;

-- As quatro colunas de dimensão são normalizadas com COALESCE para nunca
-- serem NULL. Um índice UNIQUE não desduplica linhas com NULL, e o
-- REFRESH CONCURRENTLY aborta com "contains duplicate rows" quando isso
-- acontece — daí os sentinelas 'ND' e 'nd'.
CREATE MATERIALIZED VIEW gold.mv_kpis_diarios AS
WITH agg_leituras AS (
    SELECT
        date_trunc('day', l.registrado_em)::DATE AS dia,
        m.empresa_id                             AS empresa_id,
        COALESCE(m.regiao_uf, 'ND')              AS regiao_uf,
        COALESCE(v.tipo::TEXT, 'nd')             AS tipo_veiculo,
        COUNT(*)                                             AS total_leituras,
        COUNT(DISTINCT l.motorista_id)                       AS motoristas_monitorados,
        ROUND(AVG(l.score_fadiga), 2)                        AS score_fadiga_medio,
        ROUND(MAX(l.score_fadiga), 2)                        AS score_fadiga_maximo,
        ROUND(AVG(l.perclos), 4)                             AS perclos_medio,
        COUNT(*) FILTER (WHERE l.estado = 'sonolento')       AS leituras_sonolento,
        COUNT(*) FILTER (WHERE l.estado = 'fadiga')          AS leituras_fadiga,
        COUNT(DISTINCT l.motorista_id) FILTER (WHERE l.score_fadiga >= 80) AS motoristas_risco_critico
    FROM silver.leituras_fadiga l
    JOIN silver.motoristas m ON m.id = l.motorista_id
    LEFT JOIN silver.veiculos v ON v.id = l.veiculo_id
    GROUP BY 1, 2, 3, 4
),
agg_alertas AS (
    SELECT
        date_trunc('day', a.disparado_em)::DATE AS dia,
        m.empresa_id                            AS empresa_id,
        COALESCE(m.regiao_uf, 'ND')             AS regiao_uf,
        COALESCE(v.tipo::TEXT, 'nd')            AS tipo_veiculo,
        COUNT(*)                                AS total_alertas,
        COUNT(*) FILTER (WHERE a.gravidade IN ('alta', 'critica')) AS alertas_graves,
        ROUND(AVG(EXTRACT(EPOCH FROM (a.reconhecido_em - a.disparado_em)) / 60.0)::NUMERIC, 2)
                                                AS tempo_medio_reconhecimento_min
    FROM silver.alertas a
    JOIN silver.motoristas m ON m.id = a.motorista_id
    LEFT JOIN silver.veiculos v ON v.id = a.veiculo_id
    GROUP BY 1, 2, 3, 4
),
agg_turnos AS (
    SELECT
        date_trunc('day', t.iniciado_em)::DATE  AS dia,
        m.empresa_id                            AS empresa_id,
        COALESCE(m.regiao_uf, 'ND')             AS regiao_uf,
        COALESCE(v.tipo::TEXT, 'nd')            AS tipo_veiculo,
        COUNT(*)                                AS total_turnos,
        ROUND(AVG(t.duracao_minutos) / 60.0, 2) AS duracao_media_turno_h,
        ROUND(SUM(t.distancia_km), 2)           AS distancia_total_km
    FROM silver.turnos t
    JOIN silver.motoristas m ON m.id = t.motorista_id
    LEFT JOIN silver.veiculos v ON v.id = t.veiculo_id
    GROUP BY 1, 2, 3, 4
),
-- Conjunto de chaves: garante uma linha por combinação existente em
-- qualquer uma das três agregações, sem depender de FULL OUTER JOIN.
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
    k.tipo_veiculo,
    COALESCE(l.total_leituras, 0)           AS total_leituras,
    COALESCE(l.motoristas_monitorados, 0)   AS motoristas_monitorados,
    l.score_fadiga_medio,
    l.score_fadiga_maximo,
    l.perclos_medio,
    COALESCE(l.leituras_sonolento, 0)       AS leituras_sonolento,
    COALESCE(l.leituras_fadiga, 0)          AS leituras_fadiga,
    COALESCE(l.motoristas_risco_critico, 0) AS motoristas_risco_critico,
    COALESCE(a.total_alertas, 0)            AS total_alertas,
    COALESCE(a.alertas_graves, 0)           AS alertas_graves,
    a.tempo_medio_reconhecimento_min,
    COALESCE(t.total_turnos, 0)             AS total_turnos,
    t.duracao_media_turno_h,
    t.distancia_total_km,
    now()                                   AS atualizado_em
FROM chaves k
LEFT JOIN agg_leituras l
       ON l.dia = k.dia AND l.empresa_id = k.empresa_id
      AND l.regiao_uf = k.regiao_uf AND l.tipo_veiculo = k.tipo_veiculo
LEFT JOIN agg_alertas a
       ON a.dia = k.dia AND a.empresa_id = k.empresa_id
      AND a.regiao_uf = k.regiao_uf AND a.tipo_veiculo = k.tipo_veiculo
LEFT JOIN agg_turnos t
       ON t.dia = k.dia AND t.empresa_id = k.empresa_id
      AND t.regiao_uf = k.regiao_uf AND t.tipo_veiculo = k.tipo_veiculo;

CREATE UNIQUE INDEX ux_mv_kpis_diarios
    ON gold.mv_kpis_diarios (dia, empresa_id, regiao_uf, tipo_veiculo);

COMMENT ON MATERIALIZED VIEW gold.mv_kpis_diarios IS
    'KPIs principais por dia/empresa/UF/tipo de veiculo. Alimenta os cards da Visao Geral.';

-- -----------------------------------------------------------------------------
-- 2. mv_incidentes_por_faixa_horaria  ->  "Acidentes por faixa horária"
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_incidentes_por_faixa_horaria CASCADE;

CREATE MATERIALIZED VIEW gold.mv_incidentes_por_faixa_horaria AS
SELECT
    CASE
        WHEN EXTRACT(HOUR FROM i.ocorrido_em) <  6 THEN 'madrugada'
        WHEN EXTRACT(HOUR FROM i.ocorrido_em) < 12 THEN 'manha'
        WHEN EXTRACT(HOUR FROM i.ocorrido_em) < 18 THEN 'tarde'
        ELSE 'noite'
    END                                              AS faixa_horaria,
    CASE
        WHEN EXTRACT(HOUR FROM i.ocorrido_em) <  6 THEN 1
        WHEN EXTRACT(HOUR FROM i.ocorrido_em) < 12 THEN 2
        WHEN EXTRACT(HOUR FROM i.ocorrido_em) < 18 THEN 3
        ELSE 4
    END                                              AS ordem_faixa,
    COALESCE(i.uf, 'ND')                             AS uf,
    i.origem,
    date_trunc('month', i.ocorrido_em)::DATE         AS mes,
    COUNT(*)                                         AS total_incidentes,
    COUNT(*) FILTER (WHERE i.relacionado_sonolencia)  AS incidentes_sonolencia,
    SUM(i.qtd_mortos)                                AS total_mortos,
    SUM(i.qtd_feridos)                               AS total_feridos,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE i.relacionado_sonolencia) / NULLIF(COUNT(*), 0),
        2
    )                                                AS pct_sonolencia,
    now()                                            AS atualizado_em
FROM silver.incidentes i
GROUP BY 1, 2, 3, 4, 5;

CREATE UNIQUE INDEX ux_mv_incidentes_faixa
    ON gold.mv_incidentes_por_faixa_horaria (faixa_horaria, uf, origem, mes);

COMMENT ON MATERIALIZED VIEW gold.mv_incidentes_por_faixa_horaria IS
    'Distribuicao de acidentes por faixa do dia. Evidencia o pico da madrugada, argumento central do TCC.';

-- -----------------------------------------------------------------------------
-- 3. mv_incidentes_por_causa_mes  ->  "Causas dos acidentes"
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_incidentes_por_causa_mes CASCADE;

CREATE MATERIALIZED VIEW gold.mv_incidentes_por_causa_mes AS
SELECT
    date_trunc('month', i.ocorrido_em)::DATE  AS mes,
    COALESCE(NULLIF(TRIM(LOWER(i.causa)), ''), 'nao informada') AS causa,
    COALESCE(i.uf, 'ND')                      AS uf,
    i.origem,
    COUNT(*)                                  AS total_incidentes,
    COUNT(*) FILTER (WHERE i.gravidade = 'com_fatais') AS incidentes_fatais,
    SUM(i.qtd_mortos)                         AS total_mortos,
    SUM(i.qtd_feridos)                        AS total_feridos,
    BOOL_OR(i.relacionado_sonolencia)         AS causa_ligada_a_sonolencia,
    now()                                     AS atualizado_em
FROM silver.incidentes i
GROUP BY 1, 2, 3, 4;

CREATE UNIQUE INDEX ux_mv_incidentes_causa
    ON gold.mv_incidentes_por_causa_mes (mes, causa, uf, origem);

COMMENT ON MATERIALIZED VIEW gold.mv_incidentes_por_causa_mes IS
    'Ranking mensal das causas de acidente, para comparar sonolencia com velocidade, alcool e distracao.';

-- -----------------------------------------------------------------------------
-- 4. mv_fadiga_por_tempo_direcao  ->  "Fadiga vs Tempo de Direção"
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_fadiga_por_tempo_direcao CASCADE;

CREATE MATERIALIZED VIEW gold.mv_fadiga_por_tempo_direcao AS
WITH leituras_com_tempo AS (
    SELECT
        l.score_fadiga,
        l.perclos,
        l.blink_rate,
        l.estado,
        m.regiao_uf,
        v.tipo AS tipo_veiculo,
        -- Horas completas de direcao no momento da leitura
        FLOOR(EXTRACT(EPOCH FROM (l.registrado_em - t.iniciado_em)) / 3600.0)::INT AS hora_direcao
    FROM silver.leituras_fadiga l
    JOIN silver.turnos t     ON t.id = l.turno_id
    JOIN silver.motoristas m ON m.id = l.motorista_id
    LEFT JOIN silver.veiculos v ON v.id = l.veiculo_id
    WHERE l.registrado_em >= t.iniciado_em
)
SELECT
    GREATEST(LEAST(hora_direcao, 14), 0) AS hora_direcao,
    COALESCE(regiao_uf, 'ND')            AS regiao_uf,
    COALESCE(tipo_veiculo::TEXT, 'nd')   AS tipo_veiculo,
    COUNT(*)                             AS total_leituras,
    ROUND(AVG(score_fadiga), 2)          AS score_fadiga_medio,
    ROUND(
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY score_fadiga)::NUMERIC, 2
    )                                    AS score_fadiga_p95,
    ROUND(AVG(perclos), 4)               AS perclos_medio,
    ROUND(AVG(blink_rate), 2)            AS blink_rate_medio,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE estado = 'sonolento') / NULLIF(COUNT(*), 0),
        2
    )                                    AS pct_sonolento,
    now()                                AS atualizado_em
FROM leituras_com_tempo
GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX ux_mv_fadiga_tempo
    ON gold.mv_fadiga_por_tempo_direcao (hora_direcao, regiao_uf, tipo_veiculo);

COMMENT ON MATERIALIZED VIEW gold.mv_fadiga_por_tempo_direcao IS
    'Heatmap fadiga x horas de direcao. Base quantitativa para a politica de pausa obrigatoria.';

-- -----------------------------------------------------------------------------
-- 5. mv_hotspots_cidades  ->  "Mapa do Brasil"
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_hotspots_cidades CASCADE;

CREATE MATERIALIZED VIEW gold.mv_hotspots_cidades AS
WITH base AS (
    SELECT
        COALESCE(NULLIF(TRIM(i.municipio), ''), 'nao informado') AS municipio,
        COALESCE(i.uf, 'ND')                                     AS uf,
        i.relacionado_sonolencia,
        i.qtd_mortos,
        i.gravidade,
        i.latitude,
        i.longitude
    FROM silver.incidentes i
)
SELECT
    municipio,
    uf,
    COUNT(*)                                            AS total_incidentes,
    COUNT(*) FILTER (WHERE relacionado_sonolencia)      AS incidentes_sonolencia,
    SUM(qtd_mortos)                                     AS total_mortos,
    COUNT(*) FILTER (WHERE gravidade = 'com_fatais')    AS incidentes_fatais,
    ROUND(AVG(latitude), 6)                             AS latitude_media,
    ROUND(AVG(longitude), 6)                            AS longitude_media,
    -- Severidade derivada, no mesmo vocabulario do dashboard (RiskLevel)
    CASE
        WHEN COUNT(*) FILTER (WHERE relacionado_sonolencia) >= 200 THEN 'critical'
        WHEN COUNT(*) FILTER (WHERE relacionado_sonolencia) >= 100 THEN 'high'
        WHEN COUNT(*) FILTER (WHERE relacionado_sonolencia) >=  40 THEN 'medium'
        ELSE 'low'
    END                                                 AS severidade,
    now()                                               AS atualizado_em
FROM base
GROUP BY municipio, uf;

CREATE UNIQUE INDEX ux_mv_hotspots
    ON gold.mv_hotspots_cidades (uf, municipio);

COMMENT ON MATERIALIZED VIEW gold.mv_hotspots_cidades IS
    'Concentracao geografica de acidentes por municipio. Alimenta o mapa do dashboard.';

-- -----------------------------------------------------------------------------
-- 6. mv_curva_fadiga_turno  ->  "Evolução da Fadiga no Turno"
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_curva_fadiga_turno CASCADE;

CREATE MATERIALIZED VIEW gold.mv_curva_fadiga_turno AS
SELECT
    t.id                                   AS turno_id,
    t.motorista_id,
    m.nome_exibicao                        AS motorista,
    t.iniciado_em,
    -- Bucket de 30 minutos dentro do turno
    (FLOOR(EXTRACT(EPOCH FROM (l.registrado_em - t.iniciado_em)) / 1800.0) * 30)::INT
                                           AS minuto_do_turno,
    COUNT(*)                               AS leituras,
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
GROUP BY t.id, t.motorista_id, m.nome_exibicao, t.iniciado_em, 5;

CREATE UNIQUE INDEX ux_mv_curva_fadiga
    ON gold.mv_curva_fadiga_turno (turno_id, minuto_do_turno);

CREATE INDEX ix_mv_curva_fadiga_motorista
    ON gold.mv_curva_fadiga_turno (motorista_id, iniciado_em DESC);

COMMENT ON MATERIALIZED VIEW gold.mv_curva_fadiga_turno IS
    'Serie temporal da fadiga dentro de cada turno, em janelas de 30 min.';

-- -----------------------------------------------------------------------------
-- 7. mv_ranking_motoristas  ->  "Lista de Motoristas" + "KPIs do Motorista"
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS gold.mv_ranking_motoristas CASCADE;

CREATE MATERIALIZED VIEW gold.mv_ranking_motoristas AS
WITH janela AS (
    SELECT
        l.motorista_id,
        l.score_fadiga,
        l.perclos,
        l.blink_rate,
        l.duracao_olhos_fechados_ms,
        l.head_pitch,
        l.estado,
        l.registrado_em,
        l.veiculo_id
    FROM silver.leituras_fadiga l
    WHERE l.registrado_em >= now() - INTERVAL '30 days'
),
metricas AS (
    SELECT
        motorista_id,
        COUNT(*)                                   AS leituras_30d,
        ROUND(AVG(score_fadiga), 2)                AS score_fadiga_medio,
        ROUND(MAX(score_fadiga), 2)                AS score_fadiga_maximo,
        ROUND(AVG(blink_rate), 2)                  AS blink_rate_medio,
        ROUND(AVG(duracao_olhos_fechados_ms), 0)   AS fechamento_olhos_medio_ms,
        ROUND(AVG(ABS(head_pitch)), 2)             AS inclinacao_cabeca_media,
        ROUND(AVG(perclos), 4)                     AS perclos_medio,
        COUNT(*) FILTER (WHERE estado = 'sonolento') AS leituras_sonolento,
        MAX(registrado_em)                         AS ultima_leitura_em
    FROM janela
    GROUP BY motorista_id
),
alertas_30d AS (
    SELECT
        motorista_id,
        COUNT(*)                                                   AS alertas_30d,
        COUNT(*) FILTER (WHERE gravidade IN ('alta', 'critica'))   AS alertas_graves_30d,
        COUNT(*) FILTER (WHERE status = 'aberto')                  AS alertas_abertos
    FROM silver.alertas
    WHERE disparado_em >= now() - INTERVAL '30 days'
    GROUP BY motorista_id
),
turnos_30d AS (
    SELECT
        motorista_id,
        COUNT(*)                                     AS turnos_30d,
        ROUND(SUM(duracao_minutos) / 60.0, 2)        AS horas_dirigidas_30d,
        ROUND(AVG(duracao_minutos) / 60.0, 2)        AS duracao_media_turno_h,
        ROUND(SUM(distancia_km), 2)                  AS km_rodados_30d
    FROM silver.turnos
    WHERE iniciado_em >= now() - INTERVAL '30 days'
    GROUP BY motorista_id
)
SELECT
    m.id                                 AS motorista_id,
    m.empresa_id,
    m.nome_exibicao                      AS motorista,
    m.idade,
    m.anos_experiencia,
    m.regiao_uf,
    m.status,
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
    -- Mesma escala de risco usada pelo front (riskFromScore em mockData.ts)
    CASE
        WHEN me.score_fadiga_medio IS NULL  THEN 'sem_dados'
        WHEN me.score_fadiga_medio < 35     THEN 'low'
        WHEN me.score_fadiga_medio < 60     THEN 'medium'
        WHEN me.score_fadiga_medio < 80     THEN 'high'
        ELSE 'critical'
    END                                  AS nivel_risco,
    RANK() OVER (ORDER BY COALESCE(me.score_fadiga_medio, -1) DESC) AS posicao_risco,
    now()                                AS atualizado_em
FROM silver.motoristas m
LEFT JOIN metricas    me ON me.motorista_id = m.id
LEFT JOIN alertas_30d al ON al.motorista_id = m.id
LEFT JOIN turnos_30d  tu ON tu.motorista_id = m.id;

CREATE UNIQUE INDEX ux_mv_ranking_motoristas
    ON gold.mv_ranking_motoristas (motorista_id);

CREATE INDEX ix_mv_ranking_empresa
    ON gold.mv_ranking_motoristas (empresa_id, posicao_risco);

COMMENT ON MATERIALIZED VIEW gold.mv_ranking_motoristas IS
    'Um registro por motorista com metricas agregadas de 30 dias e nivel de risco.';

-- -----------------------------------------------------------------------------
-- Catálogo das views, consumido pela Lambda etl_gold
--
-- O refresh NÃO é feito por uma função plpgsql: REFRESH MATERIALIZED VIEW
-- CONCURRENTLY chama PreventInTransactionBlock no PostgreSQL, ou seja, recusa
-- rodar dentro de um bloco de transação — e todo corpo de função plpgsql é um.
-- A Lambda lê esta view, e dispara um REFRESH por statement em autocommit.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW gold.vw_materialized_views AS
SELECT
    c.relname::TEXT AS view_name,
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
    'Lista as MATERIALIZED VIEWs do schema gold. A coluna tem_indice_unico '
    'precisa ser TRUE em todas: sem indice UNIQUE o REFRESH CONCURRENTLY falha.';

-- Fallback manual, sem CONCURRENTLY (bloqueia leitura durante o refresh).
-- Útil para recarregar tudo de uma vez depois de recriar o schema:
--     SELECT gold.fn_refresh_bloqueante();
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
    'Refresh sequencial SEM CONCURRENTLY. O caminho normal e a Lambda etl_gold; '
    'esta funcao existe para recarga manual apos recriar o schema.';
