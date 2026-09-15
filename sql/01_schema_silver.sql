-- =============================================================================
-- DriveGuard — Camada SILVER (OLTP normalizado)
-- PostgreSQL 16 / Amazon RDS
--
-- Executado pela Lambda db_migrate. Idempotente: pode rodar várias vezes.
--
-- A camada Bronze não tem DDL aqui: ela é o JSON cru imutável no
-- s3://<projeto>-bronze/eventos/dt=YYYY-MM-DD/. A rastreabilidade Bronze->Silver
-- é mantida pelas colunas ingest_id e bronze_key em leituras_fadiga.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()

SET search_path TO silver, public;

-- -----------------------------------------------------------------------------
-- Tipos enumerados
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    CREATE TYPE silver.tipo_veiculo AS ENUM ('caminhao', 'onibus', 'van', 'carro_app');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.status_motorista AS ENUM ('ativo', 'inativo', 'afastado', 'ferias');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.papel_usuario AS ENUM ('gestor', 'operador', 'admin');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.status_turno AS ENUM ('em_andamento', 'concluido', 'interrompido');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Três classes do classificador embarcado (XGBoost / Random Forest).
DO $$
BEGIN
    CREATE TYPE silver.estado_fadiga AS ENUM ('alerta', 'fadiga', 'sonolento');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.gravidade AS ENUM ('baixa', 'media', 'alta', 'critica');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.status_alerta AS ENUM ('aberto', 'reconhecido', 'resolvido', 'descartado');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.tipo_alerta AS ENUM (
        'sonolencia', 'microssono', 'bocejo_excessivo', 'cabeca_baixa',
        'distracao', 'perda_de_face'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.gravidade_incidente AS ENUM ('sem_vitimas', 'com_feridos', 'com_fatais');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.origem_incidente AS ENUM ('prf', 'interno');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.tipo_acao AS ENUM (
        'pausa_obrigatoria', 'contato_telefonico', 'troca_motorista',
        'treinamento', 'advertencia', 'encerramento_turno'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.origem_insight AS ENUM ('regra', 'modelo');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- 1. empresas
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.empresas (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cnpj_hash      TEXT        NOT NULL UNIQUE,
    razao_social   TEXT        NOT NULL,
    nome_fantasia  TEXT,
    uf             CHAR(2),
    cidade         TEXT,
    ativo          BOOLEAN     NOT NULL DEFAULT TRUE,
    criado_em      TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  silver.empresas          IS 'Empresas de transporte clientes do DriveGuard.';
COMMENT ON COLUMN silver.empresas.cnpj_hash IS 'SHA-256 do CNPJ. LGPD: identificador irreversivel.';

-- -----------------------------------------------------------------------------
-- 2. usuarios
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.usuarios (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id       UUID        NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    email_hash       TEXT        NOT NULL UNIQUE,
    nome             TEXT        NOT NULL,
    papel            silver.papel_usuario NOT NULL DEFAULT 'operador',
    ativo            BOOLEAN     NOT NULL DEFAULT TRUE,
    ultimo_acesso_em TIMESTAMPTZ,
    criado_em        TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_usuarios_empresa ON silver.usuarios (empresa_id);

COMMENT ON TABLE silver.usuarios IS 'Contas de acesso ao dashboard (gestor/operador/admin).';

-- -----------------------------------------------------------------------------
-- 3. veiculos
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.veiculos (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id             UUID        NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    placa_hash             TEXT        NOT NULL UNIQUE,
    tipo                   silver.tipo_veiculo NOT NULL,
    modelo                 TEXT,
    ano_fabricacao         SMALLINT,
    capacidade_passageiros SMALLINT,
    ativo                  BOOLEAN     NOT NULL DEFAULT TRUE,
    criado_em              TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_veiculos_ano CHECK (ano_fabricacao IS NULL OR ano_fabricacao BETWEEN 1950 AND 2100)
);

CREATE INDEX IF NOT EXISTS ix_veiculos_empresa ON silver.veiculos (empresa_id);

COMMENT ON COLUMN silver.veiculos.placa_hash IS 'SHA-256 da placa. LGPD: nunca armazenar a placa em claro.';

-- -----------------------------------------------------------------------------
-- 4. motoristas
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.motoristas (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id        UUID        NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    usuario_id        UUID        REFERENCES silver.usuarios (id) ON DELETE SET NULL,
    motorista_hash    TEXT        NOT NULL UNIQUE,
    nome_exibicao     TEXT        NOT NULL,
    idade             SMALLINT,
    anos_experiencia  SMALLINT,
    categoria_cnh     CHAR(2),
    cnh_valida_ate    DATE,
    regiao_uf         CHAR(2),
    status            silver.status_motorista NOT NULL DEFAULT 'ativo',
    baseline_ear      NUMERIC(5, 4),
    criado_em         TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_motoristas_idade CHECK (idade IS NULL OR idade BETWEEN 16 AND 100)
);

CREATE INDEX IF NOT EXISTS ix_motoristas_empresa ON silver.motoristas (empresa_id);
CREATE INDEX IF NOT EXISTS ix_motoristas_uf      ON silver.motoristas (regiao_uf);

COMMENT ON COLUMN silver.motoristas.motorista_hash IS 'SHA-256 do CPF/matricula. Chave natural enviada pelo edge.';
COMMENT ON COLUMN silver.motoristas.baseline_ear  IS 'Baseline adaptativo de EAR por motorista, calibrado no inicio do turno.';

-- -----------------------------------------------------------------------------
-- 5. turnos
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.turnos (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    motorista_id      UUID        NOT NULL REFERENCES silver.motoristas (id) ON DELETE CASCADE,
    veiculo_id        UUID        REFERENCES silver.veiculos (id) ON DELETE SET NULL,
    device_id         TEXT        NOT NULL,
    iniciado_em       TIMESTAMPTZ NOT NULL,
    finalizado_em     TIMESTAMPTZ,
    duracao_minutos   INTEGER GENERATED ALWAYS AS (
        CASE
            WHEN finalizado_em IS NULL THEN NULL
            ELSE (EXTRACT(EPOCH FROM (finalizado_em - iniciado_em)) / 60)::INTEGER
        END
    ) STORED,
    origem_cidade     TEXT,
    origem_uf         CHAR(2),
    destino_cidade    TEXT,
    destino_uf        CHAR(2),
    distancia_km      NUMERIC(8, 2),
    status            silver.status_turno NOT NULL DEFAULT 'em_andamento',
    criado_em         TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_turnos_periodo CHECK (finalizado_em IS NULL OR finalizado_em >= iniciado_em)
);

CREATE INDEX IF NOT EXISTS ix_turnos_motorista ON silver.turnos (motorista_id, iniciado_em DESC);
CREATE INDEX IF NOT EXISTS ix_turnos_veiculo   ON silver.turnos (veiculo_id);
CREATE INDEX IF NOT EXISTS ix_turnos_iniciado  ON silver.turnos (iniciado_em DESC);

-- Um motorista só pode ter um turno aberto por vez.
CREATE UNIQUE INDEX IF NOT EXISTS ux_turnos_aberto_por_motorista
    ON silver.turnos (motorista_id)
    WHERE status = 'em_andamento';

COMMENT ON TABLE silver.turnos IS 'Periodos de conducao. Agrupa as leituras e os alertas de uma jornada.';

-- -----------------------------------------------------------------------------
-- 6. leituras_fadiga  (granularidade maxima)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.leituras_fadiga (
    id                         BIGSERIAL PRIMARY KEY,
    turno_id                   UUID        NOT NULL REFERENCES silver.turnos (id) ON DELETE CASCADE,
    motorista_id               UUID        NOT NULL REFERENCES silver.motoristas (id) ON DELETE CASCADE,
    veiculo_id                 UUID        REFERENCES silver.veiculos (id) ON DELETE SET NULL,
    device_id                  TEXT        NOT NULL,
    registrado_em              TIMESTAMPTZ NOT NULL,

    -- Features extraidas pelo pipeline MediaPipe Face Mesh no veiculo
    ear                        NUMERIC(6, 4),
    mar                        NUMERIC(6, 4),
    perclos                    NUMERIC(6, 4),
    blink_rate                 NUMERIC(6, 2),
    duracao_olhos_fechados_ms  INTEGER,
    head_pitch                 NUMERIC(6, 2),
    head_yaw                   NUMERIC(6, 2),
    head_roll                  NUMERIC(6, 2),

    -- Saida do classificador embarcado
    score_fadiga               NUMERIC(5, 2) NOT NULL,
    estado                     silver.estado_fadiga NOT NULL,

    -- Telemetria
    latitude                   NUMERIC(9, 6),
    longitude                  NUMERIC(9, 6),
    velocidade_kmh             NUMERIC(5, 1),

    -- Rastreabilidade Bronze -> Silver
    ingest_id                  UUID,
    bronze_key                 TEXT,
    criado_em                  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_leituras_score   CHECK (score_fadiga BETWEEN 0 AND 100),
    CONSTRAINT ck_leituras_perclos CHECK (perclos IS NULL OR perclos BETWEEN 0 AND 1),
    CONSTRAINT ck_leituras_ear     CHECK (ear IS NULL OR ear BETWEEN 0 AND 1),
    CONSTRAINT ck_leituras_mar     CHECK (mar IS NULL OR mar BETWEEN 0 AND 2),

    -- Idempotencia do ETL Silver: reprocessar o mesmo arquivo Bronze nao duplica.
    CONSTRAINT ux_leituras_device_ts UNIQUE (device_id, registrado_em)
);

CREATE INDEX IF NOT EXISTS ix_leituras_turno     ON silver.leituras_fadiga (turno_id, registrado_em);
CREATE INDEX IF NOT EXISTS ix_leituras_motorista ON silver.leituras_fadiga (motorista_id, registrado_em DESC);
CREATE INDEX IF NOT EXISTS ix_leituras_registrado ON silver.leituras_fadiga (registrado_em DESC);
CREATE INDEX IF NOT EXISTS ix_leituras_estado    ON silver.leituras_fadiga (estado) WHERE estado <> 'alerta';

COMMENT ON TABLE silver.leituras_fadiga IS
    'Granularidade maxima: uma linha por janela de monitoramento enviada pelo edge. '
    'Nenhuma imagem facial e persistida - apenas metricas numericas (LGPD / privacy by design).';

-- -----------------------------------------------------------------------------
-- 7. alertas
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.alertas (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    turno_id          UUID        REFERENCES silver.turnos (id) ON DELETE CASCADE,
    motorista_id      UUID        NOT NULL REFERENCES silver.motoristas (id) ON DELETE CASCADE,
    veiculo_id        UUID        REFERENCES silver.veiculos (id) ON DELETE SET NULL,
    disparado_em      TIMESTAMPTZ NOT NULL,
    tipo              silver.tipo_alerta NOT NULL,
    gravidade         silver.gravidade   NOT NULL,
    status            silver.status_alerta NOT NULL DEFAULT 'aberto',
    score_fadiga      NUMERIC(5, 2),
    mensagem          TEXT,
    reconhecido_por   UUID        REFERENCES silver.usuarios (id) ON DELETE SET NULL,
    reconhecido_em    TIMESTAMPTZ,
    resolvido_em      TIMESTAMPTZ,
    criado_em         TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ux_alertas_dedup UNIQUE (motorista_id, disparado_em, tipo)
);

CREATE INDEX IF NOT EXISTS ix_alertas_turno     ON silver.alertas (turno_id);
CREATE INDEX IF NOT EXISTS ix_alertas_disparado ON silver.alertas (disparado_em DESC);
CREATE INDEX IF NOT EXISTS ix_alertas_abertos   ON silver.alertas (status, disparado_em DESC) WHERE status = 'aberto';

COMMENT ON TABLE silver.alertas IS
    'Alertas disparados. O painel "Alertas em Tempo Real" le esta tabela direto (nao passa pelo Gold).';

-- -----------------------------------------------------------------------------
-- 8. incidentes
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.incidentes (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id             UUID        REFERENCES silver.empresas (id) ON DELETE SET NULL,
    motorista_id           UUID        REFERENCES silver.motoristas (id) ON DELETE SET NULL,
    veiculo_id             UUID        REFERENCES silver.veiculos (id) ON DELETE SET NULL,
    origem                 silver.origem_incidente NOT NULL,
    origem_id_externo      TEXT,
    ocorrido_em            TIMESTAMPTZ NOT NULL,
    uf                     CHAR(2),
    municipio              TEXT,
    br                     TEXT,
    km                     NUMERIC(8, 2),
    latitude               NUMERIC(9, 6),
    longitude              NUMERIC(9, 6),
    causa                  TEXT,
    tipo_acidente          TEXT,
    gravidade              silver.gravidade_incidente,
    qtd_mortos             SMALLINT NOT NULL DEFAULT 0,
    qtd_feridos            SMALLINT NOT NULL DEFAULT 0,
    qtd_ilesos             SMALLINT NOT NULL DEFAULT 0,
    fase_dia               TEXT,
    condicao_meteorologica TEXT,
    tracado_via            TEXT,
    relacionado_sonolencia BOOLEAN NOT NULL DEFAULT FALSE,
    criado_em              TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ux_incidentes_externo UNIQUE (origem, origem_id_externo)
);

CREATE INDEX IF NOT EXISTS ix_incidentes_ocorrido ON silver.incidentes (ocorrido_em DESC);
CREATE INDEX IF NOT EXISTS ix_incidentes_uf       ON silver.incidentes (uf, municipio);
CREATE INDEX IF NOT EXISTS ix_incidentes_sono     ON silver.incidentes (relacionado_sonolencia) WHERE relacionado_sonolencia;

COMMENT ON TABLE silver.incidentes IS
    'Acidentes. Alimentada pelo dataset aberto da PRF (origem=prf) e por ocorrencias internas da frota.';

-- -----------------------------------------------------------------------------
-- 9. acoes_motorista
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.acoes_motorista (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    motorista_id    UUID        NOT NULL REFERENCES silver.motoristas (id) ON DELETE CASCADE,
    turno_id        UUID        REFERENCES silver.turnos (id) ON DELETE SET NULL,
    alerta_id       UUID        REFERENCES silver.alertas (id) ON DELETE SET NULL,
    tipo            silver.tipo_acao NOT NULL,
    descricao       TEXT,
    realizado_por   UUID        REFERENCES silver.usuarios (id) ON DELETE SET NULL,
    realizado_em    TIMESTAMPTZ NOT NULL DEFAULT now(),
    eficaz          BOOLEAN,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_acoes_motorista ON silver.acoes_motorista (motorista_id, realizado_em DESC);

COMMENT ON TABLE silver.acoes_motorista IS 'Intervencoes do gestor sobre o motorista (componente "Acoes Rapidas").';

-- -----------------------------------------------------------------------------
-- 10. insights_motorista
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.insights_motorista (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    motorista_id        UUID        NOT NULL REFERENCES silver.motoristas (id) ON DELETE CASCADE,
    gerado_em           TIMESTAMPTZ NOT NULL DEFAULT now(),
    titulo              TEXT        NOT NULL,
    descricao           TEXT,
    severidade          silver.gravidade NOT NULL DEFAULT 'media',
    acao_sugerida       TEXT,
    metrica_referencia  JSONB,
    origem              silver.origem_insight NOT NULL DEFAULT 'regra',
    valido_ate          TIMESTAMPTZ,
    criado_em           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_insights_mot ON silver.insights_motorista (motorista_id, gerado_em DESC);
CREATE INDEX IF NOT EXISTS ix_insights_mot_metrica ON silver.insights_motorista USING GIN (metrica_referencia);

-- -----------------------------------------------------------------------------
-- 11. insights_frota
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.insights_frota (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id          UUID        NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    gerado_em           TIMESTAMPTZ NOT NULL DEFAULT now(),
    titulo              TEXT        NOT NULL,
    descricao           TEXT,
    severidade          silver.gravidade NOT NULL DEFAULT 'media',
    acao_sugerida       TEXT,
    metrica_referencia  JSONB,
    origem              silver.origem_insight NOT NULL DEFAULT 'regra',
    valido_ate          TIMESTAMPTZ,
    criado_em           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_insights_frota ON silver.insights_frota (empresa_id, gerado_em DESC);

-- -----------------------------------------------------------------------------
-- 12. previsoes_fadiga
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.previsoes_fadiga (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    motorista_id       UUID        NOT NULL REFERENCES silver.motoristas (id) ON DELETE CASCADE,
    turno_id           UUID        REFERENCES silver.turnos (id) ON DELETE SET NULL,
    gerado_em          TIMESTAMPTZ NOT NULL DEFAULT now(),
    horizonte_minutos  SMALLINT    NOT NULL,
    probabilidade      NUMERIC(5, 4) NOT NULL,
    score_previsto     NUMERIC(5, 2),
    classe_prevista    silver.estado_fadiga,
    modelo_nome        TEXT        NOT NULL,
    modelo_versao      TEXT        NOT NULL,
    features           JSONB,
    criado_em          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_previsoes_prob CHECK (probabilidade BETWEEN 0 AND 1)
);

CREATE INDEX IF NOT EXISTS ix_previsoes_motorista ON silver.previsoes_fadiga (motorista_id, gerado_em DESC);

COMMENT ON TABLE silver.previsoes_fadiga IS
    'Saida do modelo preditivo treinado no SageMaker. modelo_versao permite comparar XGBoost vs. YOLO no TCC.';

-- -----------------------------------------------------------------------------
-- Controle de ingestao (idempotencia no nivel de arquivo Bronze)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.ingestao_controle (
    bronze_key      TEXT PRIMARY KEY,
    ingest_id       UUID,
    processado_em   TIMESTAMPTZ NOT NULL DEFAULT now(),
    leituras_lidas  INTEGER NOT NULL DEFAULT 0,
    leituras_novas  INTEGER NOT NULL DEFAULT 0,
    alertas_novos   INTEGER NOT NULL DEFAULT 0,
    status          TEXT    NOT NULL DEFAULT 'ok',
    erro            TEXT
);

COMMENT ON TABLE silver.ingestao_controle IS
    'Registra cada objeto Bronze processado pelo ETL Silver. Evita reprocessamento em re-entrega do evento S3.';

-- -----------------------------------------------------------------------------
-- Gatilho de atualizado_em
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION silver.fn_touch_atualizado_em()
RETURNS TRIGGER AS $$
BEGIN
    NEW.atualizado_em := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['empresas', 'usuarios', 'veiculos', 'motoristas', 'turnos']
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS tg_touch_%1$s ON silver.%1$s;
             CREATE TRIGGER tg_touch_%1$s BEFORE UPDATE ON silver.%1$s
             FOR EACH ROW EXECUTE FUNCTION silver.fn_touch_atualizado_em();', t);
    END LOOP;
END $$;
