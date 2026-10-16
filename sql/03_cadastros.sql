-- =============================================================================
-- DriveGuard — Cadastros, ROI, relatórios e controle das cargas
--
-- Tabelas que a dashboard e o backend precisam além do que o veículo envia:
-- câmeras e o caminhão em que cada uma está, rotas e viagens cadastradas pelo
-- gestor, parâmetros do ROI com a fonte de cada número, relatórios e
-- agendamentos, e o controle das cargas da base da PRF.
--
-- Idempotente: CREATE ... IF NOT EXISTS, ADD COLUMN IF NOT EXISTS e
-- ON CONFLICT nos dados de referência.
-- =============================================================================

SET search_path TO silver, public;

-- -----------------------------------------------------------------------------
-- UF -> macro-região (filtro de região da dashboard)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.dim_uf (
    uf            CHAR(2) PRIMARY KEY,
    nome          TEXT NOT NULL,
    macro_regiao  TEXT NOT NULL
);

INSERT INTO silver.dim_uf (uf, nome, macro_regiao) VALUES
    ('AC', 'Acre', 'Norte'), ('AP', 'Amapá', 'Norte'), ('AM', 'Amazonas', 'Norte'),
    ('PA', 'Pará', 'Norte'), ('RO', 'Rondônia', 'Norte'), ('RR', 'Roraima', 'Norte'),
    ('TO', 'Tocantins', 'Norte'),
    ('AL', 'Alagoas', 'Nordeste'), ('BA', 'Bahia', 'Nordeste'), ('CE', 'Ceará', 'Nordeste'),
    ('MA', 'Maranhão', 'Nordeste'), ('PB', 'Paraíba', 'Nordeste'), ('PE', 'Pernambuco', 'Nordeste'),
    ('PI', 'Piauí', 'Nordeste'), ('RN', 'Rio Grande do Norte', 'Nordeste'), ('SE', 'Sergipe', 'Nordeste'),
    ('DF', 'Distrito Federal', 'Centro-Oeste'), ('GO', 'Goiás', 'Centro-Oeste'),
    ('MT', 'Mato Grosso', 'Centro-Oeste'), ('MS', 'Mato Grosso do Sul', 'Centro-Oeste'),
    ('ES', 'Espírito Santo', 'Sudeste'), ('MG', 'Minas Gerais', 'Sudeste'),
    ('RJ', 'Rio de Janeiro', 'Sudeste'), ('SP', 'São Paulo', 'Sudeste'),
    ('PR', 'Paraná', 'Sul'), ('RS', 'Rio Grande do Sul', 'Sul'), ('SC', 'Santa Catarina', 'Sul')
ON CONFLICT (uf) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Códigos legíveis e placa
-- -----------------------------------------------------------------------------

-- Código interno do motorista (ex.: DRV-1000), exibido na dashboard no lugar
-- do UUID. O vínculo com o dispositivo continua sendo o motorista_hash.
ALTER TABLE silver.motoristas ADD COLUMN IF NOT EXISTS codigo TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS ux_motoristas_codigo
    ON silver.motoristas (empresa_id, codigo) WHERE codigo IS NOT NULL;

-- Placa em claro: é o veículo da empresa, cadastrado pelo gestor na tela de
-- câmeras. O placa_hash continua sendo o que o dispositivo pode enviar.
ALTER TABLE silver.veiculos ADD COLUMN IF NOT EXISTS placa TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS ux_veiculos_placa
    ON silver.veiculos (empresa_id, placa) WHERE placa IS NOT NULL;

-- Tamanho da frota, usado na cobertura do ROI (veículos com câmera / frota).
ALTER TABLE silver.empresas ADD COLUMN IF NOT EXISTS frota_total INTEGER;

-- -----------------------------------------------------------------------------
-- Câmeras e o caminhão em que cada uma está
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.dispositivos (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id         UUID REFERENCES silver.empresas (id) ON DELETE SET NULL,
    device_id          TEXT        NOT NULL UNIQUE,
    codigo             TEXT,
    descricao          TEXT,
    status             silver.status_dispositivo NOT NULL DEFAULT 'pendente',
    ultimo_contato_em  TIMESTAMPTZ,
    criado_em          TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_dispositivos_codigo
    ON silver.dispositivos (empresa_id, codigo) WHERE codigo IS NOT NULL;

COMMENT ON TABLE silver.dispositivos IS
    'Câmeras embarcadas. Uma câmera que envia dados sem cadastro entra como pendente, '
    'para o gestor associá-la a um veículo.';
COMMENT ON COLUMN silver.dispositivos.codigo IS
    'Código legível exibido na dashboard (ex.: TRK-1045). É o código do veículo nos relatórios.';

CREATE TABLE IF NOT EXISTS silver.vinculos_dispositivo_veiculo (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dispositivo_id  UUID        NOT NULL REFERENCES silver.dispositivos (id) ON DELETE CASCADE,
    veiculo_id      UUID        NOT NULL REFERENCES silver.veiculos (id) ON DELETE CASCADE,
    inicio          TIMESTAMPTZ NOT NULL DEFAULT now(),
    fim             TIMESTAMPTZ,
    motivo          TEXT,
    criado_por      UUID REFERENCES silver.usuarios (id) ON DELETE SET NULL,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_vinculo_periodo CHECK (fim IS NULL OR fim > inicio)
);

-- Uma câmera fica em um caminhão por vez, e um caminhão tem uma câmera por vez.
CREATE UNIQUE INDEX IF NOT EXISTS ux_vinculo_dispositivo_aberto
    ON silver.vinculos_dispositivo_veiculo (dispositivo_id) WHERE fim IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_vinculo_veiculo_aberto
    ON silver.vinculos_dispositivo_veiculo (veiculo_id) WHERE fim IS NULL;
CREATE INDEX IF NOT EXISTS ix_vinculo_dispositivo_periodo
    ON silver.vinculos_dispositivo_veiculo (dispositivo_id, inicio DESC);

COMMENT ON TABLE silver.vinculos_dispositivo_veiculo IS
    'Histórico de qual câmera esteve em qual caminhão. O ETL usa o vínculo vigente '
    'na hora da leitura; uma troca encerra o vínculo atual e abre outro.';

-- -----------------------------------------------------------------------------
-- Rotas e viagens (cadastro manual do gestor)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.rotas (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id      UUID        NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    nome            TEXT,
    origem_cidade   TEXT        NOT NULL,
    origem_uf       CHAR(2)     NOT NULL REFERENCES silver.dim_uf (uf),
    destino_cidade  TEXT        NOT NULL,
    destino_uf      CHAR(2)     NOT NULL REFERENCES silver.dim_uf (uf),
    -- BRs percorridas, só o número e sem zero à esquerda (ex.: {116, 40} para
    -- BR-116 e BR-040), no mesmo formato da PRF. É a chave de cruzamento com a
    -- base da PRF, que registra os acidentes por BR + UF + km.
    brs             TEXT[]      NOT NULL DEFAULT '{}',
    ufs_percorridas CHAR(2)[]   NOT NULL DEFAULT '{}',
    distancia_km    NUMERIC(8, 1),
    ativo           BOOLEAN     NOT NULL DEFAULT TRUE,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_rotas_empresa ON silver.rotas (empresa_id);

CREATE TABLE IF NOT EXISTS silver.viagens (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id        UUID        NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    rota_id           UUID        NOT NULL REFERENCES silver.rotas (id) ON DELETE CASCADE,
    veiculo_id        UUID        NOT NULL REFERENCES silver.veiculos (id) ON DELETE CASCADE,
    motorista_id      UUID REFERENCES silver.motoristas (id) ON DELETE SET NULL,
    partida_prevista  TIMESTAMPTZ NOT NULL,
    chegada_prevista  TIMESTAMPTZ,
    partida_real      TIMESTAMPTZ,
    chegada_real      TIMESTAMPTZ,
    -- Valor informado pelo gestor (frete ou valor da operação). Entra no ROI
    -- como valor/hora para estimar o custo de uma estrada parada.
    valor_viagem      NUMERIC(12, 2),
    status            silver.status_viagem NOT NULL DEFAULT 'planejada',
    criado_em         TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_viagem_previsao CHECK (chegada_prevista IS NULL OR chegada_prevista > partida_prevista)
);

CREATE INDEX IF NOT EXISTS ix_viagens_veiculo ON silver.viagens (veiculo_id, partida_prevista DESC);
CREATE INDEX IF NOT EXISTS ix_viagens_rota    ON silver.viagens (rota_id);

ALTER TABLE silver.turnos ADD COLUMN IF NOT EXISTS viagem_id UUID REFERENCES silver.viagens (id) ON DELETE SET NULL;
ALTER TABLE silver.turnos ADD COLUMN IF NOT EXISTS dispositivo_id UUID REFERENCES silver.dispositivos (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS ix_turnos_viagem ON silver.turnos (viagem_id);

-- -----------------------------------------------------------------------------
-- Parâmetros do ROI
--
-- Os padrões ficam em parametros_roi_padrao, cada um com a fonte. A empresa
-- pode sobrescrever qualquer valor em parametros_roi; o backend sempre lê o
-- valor da empresa e cai no padrão quando ele não existe.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.parametros_roi_padrao (
    chave        TEXT PRIMARY KEY,
    valor        NUMERIC,
    unidade      TEXT NOT NULL,
    descricao    TEXT NOT NULL,
    fonte        TEXT,
    url_fonte    TEXT,
    referencia   TEXT,
    editavel     BOOLEAN NOT NULL DEFAULT TRUE,
    atualizado_em TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS silver.parametros_roi (
    empresa_id     UUID NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    chave          TEXT NOT NULL REFERENCES silver.parametros_roi_padrao (chave) ON DELETE CASCADE,
    valor          NUMERIC NOT NULL,
    fonte          TEXT,
    atualizado_por UUID REFERENCES silver.usuarios (id) ON DELETE SET NULL,
    atualizado_em  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (empresa_id, chave)
);

INSERT INTO silver.parametros_roi_padrao (chave, valor, unidade, descricao, fonte, url_fonte, referencia, editavel) VALUES
    ('acidentes_ano_frota', NULL, 'acidentes/ano',
     'Acidentes que a frota teve no último ano. Sem esse número o ROI não é calculado.',
     'Histórico da empresa', NULL, NULL, TRUE),
    ('horas_parada_por_acidente', NULL, 'horas',
     'Horas que a operação fica parada após um acidente. Não há estudo nacional; notícias de interdição com caminhão vão de 4 a 26 horas.',
     'Informado pelo gestor', NULL, NULL, TRUE),
    ('eficacia_alerta', 0.50, 'fração',
     'Redução dos eventos de fadiga com o alarme ligado (razão de taxas 0,5).',
     'Estudo com caminhoneiros, sistema de câmera com alarme', 'https://pubmed.ncbi.nlm.nih.gov/40063832/', NULL, TRUE),
    ('fracao_sono_conservador', 0.028, 'fração',
     'Acidentes com causa "Condutor Dormindo" registrada pela PRF (rodovias federais, 2014). Cenário conservador: o boletim policial subnotifica sono.',
     'IPEA 2015, gráfico 3', 'https://www.ipea.gov.br/portal/images/stories/PDFs/relatoriopesquisa/150922_relatorio_acidentes_transito.pdf', '2014', TRUE),
    ('fracao_sono_realista', 0.06, 'fração',
     'Acidentes com motorista sonolento segundo investigação aprofundada (EUA, 2009-2013). Mostra o tamanho da subnotificação.',
     'AAA Foundation, Tefft 2014', 'https://aaafoundation.org/prevalence-motor-vehicle-crashes-involving-drowsy-drivers-united-states-2009-2013/', '2009-2013', TRUE),
    ('custo_acidente_fatal', 646762.94, 'R$',
     'Custo médio de um acidente com vítima fatal nas rodovias federais.',
     'IPEA 2015, tabela 8', 'https://www.ipea.gov.br/portal/images/stories/PDFs/relatoriopesquisa/150922_relatorio_acidentes_transito.pdf', 'dez/2014', TRUE),
    ('custo_acidente_feridos', 90182.71, 'R$',
     'Custo médio de um acidente com feridos nas rodovias federais.',
     'IPEA 2015, tabela 8', 'https://www.ipea.gov.br/portal/images/stories/PDFs/relatoriopesquisa/150922_relatorio_acidentes_transito.pdf', 'dez/2014', TRUE),
    ('custo_acidente_sem_vitimas', 23062.97, 'R$',
     'Custo médio de um acidente sem vítimas nas rodovias federais.',
     'IPEA 2015, tabela 8', 'https://www.ipea.gov.br/portal/images/stories/PDFs/relatoriopesquisa/150922_relatorio_acidentes_transito.pdf', 'dez/2014', TRUE),
    ('fator_ipca', 1.8956, 'fator',
     'IPCA acumulado desde dez/2014, para trazer os custos do IPEA a valores atuais. Atualizado pelo ETL semanal.',
     'Banco Central, SGS série 433', 'https://api.bcb.gov.br/dados/serie/bcdata.sgs.433/dados?formato=json', 'jan/2015 a set/2026', FALSE),
    ('proporcao_fatal_padrao', 0.0399, 'fração',
     'Proporção de acidentes com morte, usada enquanto a base da PRF não estiver carregada.',
     'IPEA 2015, tabela 8 (6.742 de 169.153)', 'https://www.ipea.gov.br/portal/images/stories/PDFs/relatoriopesquisa/150922_relatorio_acidentes_transito.pdf', '2014', FALSE),
    ('proporcao_feridos_padrao', 0.3692, 'fração',
     'Proporção de acidentes com feridos, usada enquanto a base da PRF não estiver carregada.',
     'IPEA 2015, tabela 8 (62.458 de 169.153)', 'https://www.ipea.gov.br/portal/images/stories/PDFs/relatoriopesquisa/150922_relatorio_acidentes_transito.pdf', '2014', FALSE),
    ('mortos_por_acidente_padrao', 0.0627, 'mortos/acidente',
     'Mortos por acidente envolvendo caminhão, usado enquanto a base da PRF não estiver carregada.',
     'IPEA 2015, tabela B.1 (3.537 mortos em 56.408 acidentes)', 'https://www.ipea.gov.br/portal/images/stories/PDFs/relatoriopesquisa/150922_relatorio_acidentes_transito.pdf', '2014', FALSE)
ON CONFLICT (chave) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Relatórios e agendamentos
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.agendamentos_relatorio (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id        UUID        NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    criado_por        UUID REFERENCES silver.usuarios (id) ON DELETE SET NULL,
    tipo              silver.tipo_relatorio NOT NULL,
    formato           silver.formato_relatorio NOT NULL,
    frequencia        silver.frequencia_agendamento NOT NULL,
    horario           TIME        NOT NULL DEFAULT '08:00',
    -- 0 = domingo ... 6 = sábado, só para frequência semanal
    dia_semana        SMALLINT CHECK (dia_semana BETWEEN 0 AND 6),
    -- 1..28, só para frequência mensal (28 para existir em todo mês)
    dia_mes           SMALLINT CHECK (dia_mes BETWEEN 1 AND 28),
    destinatarios     TEXT[]      NOT NULL DEFAULT '{}',
    filtros           JSONB       NOT NULL DEFAULT '{}',
    ativo             BOOLEAN     NOT NULL DEFAULT TRUE,
    proxima_execucao  TIMESTAMPTZ NOT NULL,
    ultima_execucao   TIMESTAMPTZ,
    criado_em         TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_agendamentos_proxima
    ON silver.agendamentos_relatorio (proxima_execucao) WHERE ativo;

CREATE TABLE IF NOT EXISTS silver.relatorios_gerados (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id      UUID        NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    agendamento_id  UUID REFERENCES silver.agendamentos_relatorio (id) ON DELETE SET NULL,
    solicitado_por  UUID REFERENCES silver.usuarios (id) ON DELETE SET NULL,
    tipo            silver.tipo_relatorio NOT NULL,
    formato         silver.formato_relatorio NOT NULL,
    filtros         JSONB       NOT NULL DEFAULT '{}',
    status          silver.status_relatorio NOT NULL DEFAULT 'pendente',
    s3_key          TEXT,
    tamanho_bytes   INTEGER,
    erro            TEXT,
    envio           silver.status_envio NOT NULL DEFAULT 'nao_solicitado',
    destinatarios   TEXT[]      NOT NULL DEFAULT '{}',
    envio_erro      TEXT,
    enviado_em      TIMESTAMPTZ,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT now(),
    concluido_em    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS ix_relatorios_empresa ON silver.relatorios_gerados (empresa_id, criado_em DESC);

-- -----------------------------------------------------------------------------
-- Insights por IA: rastro de cada geração
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.insights_execucoes (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id       UUID        NOT NULL REFERENCES silver.empresas (id) ON DELETE CASCADE,
    iniciado_em      TIMESTAMPTZ NOT NULL DEFAULT now(),
    concluido_em     TIMESTAMPTZ,
    provedor         TEXT,
    modelo           TEXT,
    versao_prompt    TEXT,
    tokens_entrada   INTEGER,
    tokens_saida     INTEGER,
    -- 'pendente' | 'ok' | 'fallback_regras' | 'erro'
    status           TEXT        NOT NULL DEFAULT 'pendente',
    erro             TEXT,
    contexto_s3_key  TEXT
);

CREATE INDEX IF NOT EXISTS ix_insights_execucoes_empresa
    ON silver.insights_execucoes (empresa_id, iniciado_em DESC);

-- 'recomendacao' (cards de insight) ou 'resumo' (resumo inteligente dos relatórios)
ALTER TABLE silver.insights_frota ADD COLUMN IF NOT EXISTS categoria TEXT NOT NULL DEFAULT 'recomendacao';
ALTER TABLE silver.insights_frota ADD COLUMN IF NOT EXISTS execucao_id UUID REFERENCES silver.insights_execucoes (id) ON DELETE SET NULL;
ALTER TABLE silver.insights_motorista ADD COLUMN IF NOT EXISTS execucao_id UUID REFERENCES silver.insights_execucoes (id) ON DELETE SET NULL;

-- -----------------------------------------------------------------------------
-- Ocorrências internas registradas pelo gestor ("Registrar ocorrência")
-- -----------------------------------------------------------------------------

ALTER TABLE silver.incidentes ADD COLUMN IF NOT EXISTS turno_id UUID REFERENCES silver.turnos (id) ON DELETE SET NULL;
ALTER TABLE silver.incidentes ADD COLUMN IF NOT EXISTS descricao TEXT;
ALTER TABLE silver.incidentes ADD COLUMN IF NOT EXISTS registrado_por UUID REFERENCES silver.usuarios (id) ON DELETE SET NULL;
ALTER TABLE silver.incidentes ADD COLUMN IF NOT EXISTS fonte_arquivo TEXT;
CREATE INDEX IF NOT EXISTS ix_incidentes_empresa ON silver.incidentes (empresa_id, ocorrido_em DESC);
CREATE INDEX IF NOT EXISTS ix_incidentes_br_uf ON silver.incidentes (br, uf) WHERE origem = 'prf';

-- -----------------------------------------------------------------------------
-- Base da PRF: veículos envolvidos e controle das cargas
-- -----------------------------------------------------------------------------

-- Tipos de veículo por acidente (vem do arquivo "agrupado por pessoa").
CREATE TABLE IF NOT EXISTS silver.incidentes_veiculos (
    incidente_id  UUID     NOT NULL REFERENCES silver.incidentes (id) ON DELETE CASCADE,
    tipo_veiculo  TEXT     NOT NULL,
    quantidade    SMALLINT NOT NULL DEFAULT 1,
    PRIMARY KEY (incidente_id, tipo_veiculo)
);

-- Veículos por acidente como vieram do arquivo, antes de casar com o acidente.
-- Existe porque os dois arquivos da PRF chegam em eventos S3 independentes, e
-- o de pessoas pode ser processado antes do de ocorrências. A carga de cada um
-- termina casando o que estiver aqui com os acidentes que já existem, então a
-- ordem de chegada não importa.
CREATE TABLE IF NOT EXISTS silver.prf_veiculos_staging (
    id_acidente   TEXT     NOT NULL,
    tipo_veiculo  TEXT     NOT NULL,
    quantidade    SMALLINT NOT NULL,
    PRIMARY KEY (id_acidente, tipo_veiculo)
);

CREATE TABLE IF NOT EXISTS silver.prf_cargas (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conjunto         TEXT        NOT NULL,
    ano              SMALLINT,
    s3_key           TEXT        NOT NULL,
    etag             TEXT        NOT NULL,
    linhas_lidas     INTEGER     NOT NULL DEFAULT 0,
    linhas_gravadas  INTEGER     NOT NULL DEFAULT 0,
    status           TEXT        NOT NULL DEFAULT 'processando',
    erro             TEXT,
    iniciado_em      TIMESTAMPTZ NOT NULL DEFAULT now(),
    concluido_em     TIMESTAMPTZ,
    CONSTRAINT ux_prf_cargas_arquivo UNIQUE (s3_key, etag)
);

COMMENT ON TABLE silver.prf_cargas IS
    'Cada arquivo da PRF processado. O par (s3_key, etag) impede recarregar o mesmo arquivo.';

-- Classificação de veículo pesado (caminhão e ônibus, inclusive reboques
-- puxados por caminhão-trator). É o recorte que interessa ao DriveGuard.
CREATE OR REPLACE FUNCTION silver.fn_veiculo_pesado(p_tipo TEXT)
RETURNS BOOLEAN AS $$
    SELECT lower(coalesce(p_tipo, '')) IN (
        'caminhão', 'caminhão-trator', 'caminhão-tanque', 'semireboque', 'reboque',
        'ônibus', 'micro-ônibus'
    );
$$ LANGUAGE sql IMMUTABLE;

-- -----------------------------------------------------------------------------
-- Gatilho de atualizado_em nas tabelas novas
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['dispositivos', 'rotas', 'viagens', 'agendamentos_relatorio']
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS tg_touch_%1$s ON silver.%1$s;
             CREATE TRIGGER tg_touch_%1$s BEFORE UPDATE ON silver.%1$s
             FOR EACH ROW EXECUTE FUNCTION silver.fn_touch_atualizado_em();', t);
    END LOOP;
END $$;
