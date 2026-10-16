-- =============================================================================
-- DriveGuard — Dados de demonstração: uma SIMULAÇÃO da operação
--
-- Não são números aleatórios soltos: o script simula a frota rodando dia a dia
-- com o DriveGuard instalado, e cada tabela sai como consequência da anterior.
-- 1 empresa, 16 motoristas, 16 caminhões/ônibus/vans com câmera, 8 rotas,
-- um ano de histórico (365 dias por padrão; ajustável com SET
-- driveguard.dias_historico, que a Lambda db_migrate define a partir da
-- variável seed_dias_historico do Terraform) e os turnos que estão em
-- andamento na hora da carga, que o simulador de frota continua.
--
-- O modelo da simulação
-- ---------------------
-- * Perfis: cada motorista tem uma suscetibilidade à fadiga (0,8 a 1,6), um
--   horário de saída (madrugada para 4 caminhoneiros de rota longa, tarde para
--   os ônibus, manhã para o resto) e a rota fixa dele. Escala 5x2.
-- * A escala é determinística: horário de saída, duração, folgas, noite mal
--   dormida e se o motorista respeita a parada saem da data (dias desde
--   1/1/2000) e do número do motorista, sem sorteio. A Lambda simulador usa a
--   mesma conta, então o turno que o seed deixa aberto agora é o mesmo que o
--   simulador continua, e as leituras param quando o turno acaba.
-- * Fadiga (score 0-100, a saída do modelo) a cada leitura =
--     horas dirigidas desde a última pausa x 4,6 x suscetibilidade
--   + horas de turno x 0,8
--   + ritmo circadiano (pico às 4h e queda depois do almoço, ~14h30)
--   + dívida de sono (dias seguidos de trabalho, noite mal dormida, quem
--     dorme de dia por trabalhar de madrugada)
--   + ruído com memória (a fadiga não pula de um minuto para o outro).
-- * Estado: três níveis, como o modelo de 3 classes do repositório ML:
--   alerta (< 40), fadiga (40 a 70) e sonolento (>= 70). As features (EAR,
--   PERCLOS, piscadas, olhos fechados, bocejo, cabeça) saem do score com as
--   relações da literatura usada no TCC.
-- * Alertas: o modelo entra em sonolento -> alerta (no máximo um a cada 20
--   min). O tipo vem do sinal dominante: olhos fechados >= 1 s é microssono,
--   cabeça caída é cabeça baixa, bocejo é bocejo excessivo. Distração (olhar
--   fora da estrada) e perda de face são eventos à parte.
-- * Três fases, como uma implantação de verdade:
--     piloto (primeiro quarto do histórico): só o alarme na cabine; a central
--       ainda não acompanha e a parada legal (Lei 13.103) é feita em metade
--       dos turnos;
--     central (segundo quarto): a central atende os alertas graves (85%) com
--       pausa obrigatória de 25-30 min, encerra o turno no segundo alerta
--       crítico, liga para o motorista nos médios; parada a cada 4h30 em 3 de
--       cada 4 turnos;
--     programa (metade mais recente): programa de gestão da fadiga depois
--       dos acidentes: turno da madrugada limitado a 8 h com parada a cada
--       3h30, parada a cada 4 h para todos (85% dos turnos), escala revisada
--       (menos dívida de sono) e treinamento individual dos motoristas mais
--       suscetíveis, cuja fadiga cai nas semanas seguintes (ação registrada).
--   A pausa zera as horas dirigidas, então a fadiga cai de verdade depois
--   dela: por isso o histórico melhora fase a fase.
-- * Quase-acidentes: com fadiga muito alta, há ocorrências sem acidente
--   (saída de faixa, quase colisão), registradas sem gravidade; na operação a
--   central manda parar em seguida.
-- * Acidentes da frota: risco proporcional à fadiga (cresce ao cubo acima de
--   75) mais um risco de base pequeno, maior em distração. O risco é somado
--   na frota e cada 1,0 acumulado vira um acidente, no momento em que a soma
--   passa do limite (onde o risco é maior); assim o total é o valor esperado,
--   e não a sorte de um sorteio. Cada acidente
--   interrompe o turno no ponto da rota em que o veículo está e afasta o
--   motorista por alguns dias. Assim os acidentes por sono acontecem onde
--   houve detecção forte sem intervenção, quase todos na fase piloto.
-- * ROI: acidentes_ano_frota é a taxa anual esperada da fase piloto (a frota
--   sem a central) e fracao_sono_realista a parte dela ligada ao sono, as
--   duas calculadas pela própria simulação.
--
-- É determinístico (setseed): rodar de novo gera o mesmo histórico, deslocado
-- para a data de hoje.
--
-- Coerência com o resto da solução:
--   * a empresa tem UUID fixo, o mesmo que os usuários de demonstração do
--     Cognito carregam em custom:empresa_id;
--   * o ID fixo de cada dispositivo é o código do motorista (DRV-1000...), e
--     motorista_hash = SHA-256 desse código, igual ao que o cliente do modelo
--     calcula antes de enviar. O simulador de frota usa os mesmos IDs e o
--     mesmo modelo de fadiga;
--   * as features seguem a literatura usada no TCC (EAR ~0,31 x ~0,16,
--     MAR ~0,22 x ~0,51, PERCLOS ~0,08 x ~0,54, pitch ~0 x ~-18 graus).
--
-- Acidentes da PRF NÃO são gerados aqui: vêm da base real pelo ETL da PRF.
--
-- Guardado por um IF: só roda com o banco vazio, então reexecutar é seguro.
-- =============================================================================

SET search_path TO silver, public;

DO $seed$
DECLARE
    c_empresa   CONSTANT UUID := '00000000-0000-4000-8000-000000000001';
    c_tz        CONSTANT TEXT := 'America/Sao_Paulo';
    v_dias      INT := COALESCE(NULLIF(current_setting('driveguard.dias_historico', TRUE), '')::INT, 365);
    v_hoje      DATE := (now() AT TIME ZONE 'America/Sao_Paulo')::DATE;
    v_piloto_ate TIMESTAMPTZ;
    v_programa_desde TIMESTAMPTZ;

    -- cadastros
    v_motorista UUID;
    v_veiculo   UUID;
    v_disp      UUID;
    v_ufs       TEXT[] := ARRAY['SP','RJ','MG','PR','RS','BA','PE','GO'];
    v_nomes     TEXT[] := ARRAY['Carlos Silva','João Pereira','Marcos Lima','Roberto Souza',
                                'Antonio Costa','Paulo Mendes','Ricardo Alves','Eduardo Rocha',
                                'Fernando Dias','Sérgio Ramos','Luiz Gomes','André Martins',
                                'Bruno Cardoso','Felipe Nunes','Gustavo Reis','Henrique Castro'];
    v_tipos     silver.tipo_veiculo[] := ARRAY['caminhao','onibus','caminhao','van']::silver.tipo_veiculo[];
    v_prefixo   TEXT[] := ARRAY['TRK','BUS','TRK','VAN'];
    v_modelos   TEXT[] := ARRAY['Volvo FH 540','Marcopolo Paradiso G8','Scania R450','Iveco Daily'];
    v_motoristas UUID[] := '{}';
    v_veiculos   UUID[] := '{}';
    v_rotas      UUID[] := '{}';

    -- rotas, na ordem do INSERT: nome, coordenadas (origem e destino) e a
    -- cidade do meio do caminho, usada para localizar um acidente.
    v_nomes_rotas TEXT[] := ARRAY['Via Dutra','Rota do Centro-Oeste','Rio-Bahia','Rota Sul',
                                  'Eixo Goiás-DF','Interior Paulista','Litoral Nordeste','Corredor Capixaba'];
    v_lat_o NUMERIC[] := ARRAY[-23.55, -23.55, -19.92, -25.43, -16.68, -22.91,  -8.05, -20.32];
    v_lon_o NUMERIC[] := ARRAY[-46.63, -46.63, -43.94, -49.27, -49.25, -47.06, -34.88, -40.34];
    v_lat_d NUMERIC[] := ARRAY[-22.91, -15.60, -12.97, -30.03, -15.79, -21.18,  -3.73, -22.91];
    v_lon_d NUMERIC[] := ARRAY[-43.17, -56.10, -38.50, -51.23, -47.88, -47.81, -38.52, -43.17];
    v_meio_cidade TEXT[] := ARRAY['Resende','Rio Verde','Vitória da Conquista','Joinville',
                                  'Alexânia','Limeira','Natal','Campos dos Goytacazes'];
    v_meio_uf   TEXT[] := ARRAY['RJ','GO','BA','SC','GO','SP','RN','RJ'];
    -- Deslocamento das folgas de cada motorista, escolhido para que, dentro
    -- de cada grupo de horário (manhã, tarde, madrugada), as folgas caiam em
    -- dias diferentes: todo dia tem gente de cada turno trabalhando.
    v_folga_off INT[] := ARRAY[0,1,0,1,2,3,2,3,4,5,4,5,6,0,6,2];

    -- perfil do motorista
    v_idx_rota  INT;
    v_rota      UUID;
    v_dist_rota NUMERIC;
    v_br        TEXT;
    v_tipo_v    silver.tipo_veiculo;
    v_noturno   BOOLEAN;
    v_susc      NUMERIC;
    v_susc_base NUMERIC;
    v_treinado  BOOLEAN;
    v_data_treino DATE;
    v_min_saida INT;
    v_rs_km     NUMERIC;
    v_seq_trab  INT;
    v_afastado_ate DATE;
    -- Risco acumulado da frota: cada 1,0 vira um acidente (começa em 0,5
    -- para arredondar o valor esperado).
    v_acc_sono  NUMERIC := 0.5;
    v_acc_outro NUMERIC := 0.5;

    -- turno
    v_dia       DATE;
    v_dnum      INT;
    v_aberto    BOOLEAN;
    v_operacao  BOOLEAN;
    v_fase      INT;
    v_inicio    TIMESTAMPTZ;
    v_fim       TIMESTAMPTZ;
    v_fim_plan  TIMESTAMPTZ;
    v_dur_h     NUMERIC;
    v_divida    NUMERIC;
    v_parada_h  NUMERIC;
    v_respeita  BOOLEAN;
    v_passo     INT;
    v_viagem    UUID;
    v_turno     UUID;
    v_device    TEXT;
    v_status    silver.status_turno;
    v_status_vg silver.status_viagem;
    v_ida       BOOLEAN;

    -- leitura
    v_ts        TIMESTAMPTZ;
    v_ref       TIMESTAMPTZ;
    v_ref_prev  TIMESTAMPTZ;
    v_pausa_ate TIMESTAMPTZ;
    v_alivio    NUMERIC;
    v_alivio_ate TIMESTAMPTZ;
    v_ruido     NUMERIC;
    v_ef        NUMERIC;
    v_tot       NUMERIC;
    v_hl        NUMERIC;
    v_circ      NUMERIC;
    v_score     NUMERIC;
    v_s         NUMERIC;
    v_estado    silver.estado_fadiga;
    v_ear       NUMERIC;
    v_perclos   NUMERIC;
    v_mar       NUMERIC;
    v_bocejo    BOOLEAN;
    v_blink     NUMERIC;
    v_olhos_ms  INT;
    v_pitch     NUMERIC;
    v_yaw       NUMERIC;
    v_distracao BOOLEAN;
    v_sem_face  BOOLEAN;
    v_vel       NUMERIC;
    v_km        NUMERIC;
    v_frac      NUMERIC;
    v_pos       NUMERIC;
    v_lat       NUMERIC;
    v_lon       NUMERIC;

    -- alertas, ações e acidentes
    v_ult_alerta TIMESTAMPTZ;
    v_ult_tipo  silver.tipo_alerta;
    v_criticos  INT;
    v_tipo      silver.tipo_alerta;
    v_grav      silver.gravidade;
    v_alerta    UUID;
    v_reconh    TIMESTAMPTZ;
    v_resolv    TIMESTAMPTZ;
    v_st_alerta silver.status_alerta;
    v_acao      silver.tipo_acao;
    v_lambda_s  NUMERIC;
    v_lambda_o  NUMERIC;
    v_lambda_q  NUMERIC;
    v_acc_quase NUMERIC := 0.5;
    v_n_quase   INT := 0;
    v_soma_piloto NUMERIC := 0;
    v_soma_piloto_sono NUMERIC := 0;
    v_n_incid   INT := 0;
    v_r         NUMERIC;
    v_r2        NUMERIC;
    v_por_sono  BOOLEAN;
    v_grav_inc  silver.gravidade_incidente;
    v_mortos    INT;
    v_feridos   INT;
    v_hora_txt  TEXT;
    v_antes     TEXT;

    i INT; j INT;
BEGIN
    IF EXISTS (SELECT 1 FROM silver.empresas) THEN
        RAISE NOTICE 'Seed ignorado: o banco ja contem dados.';
        RETURN;
    END IF;

    PERFORM setseed(0.4242);
    -- Fases: piloto (1º quarto), central (2º quarto), programa (metade recente).
    v_piloto_ate     := now() - make_interval(days => CEIL(v_dias * 0.75)::INT);
    v_programa_desde := now() - make_interval(days => CEIL(v_dias * 0.5)::INT);

    -- ------------------------------------------------------------------ empresa
    INSERT INTO silver.empresas (id, cnpj_hash, razao_social, nome_fantasia, uf, cidade, frota_total)
    VALUES (c_empresa, encode(sha256(convert_to('12345678000199', 'UTF8')), 'hex'),
            'Transportadora Rodoviária Demo LTDA', 'DriveGuard Demo', 'SP', 'São Paulo', 20);

    -- ------------------------------------------------------------------ rotas
    INSERT INTO silver.rotas (empresa_id, nome, origem_cidade, origem_uf, destino_cidade, destino_uf, brs, ufs_percorridas, distancia_km)
    VALUES
        (c_empresa, 'Via Dutra',            'São Paulo',      'SP', 'Rio de Janeiro', 'RJ', '{116}',         '{SP,RJ}',       430),
        (c_empresa, 'Rota do Centro-Oeste', 'São Paulo',      'SP', 'Cuiabá',         'MT', '{50,364}',     '{SP,MG,GO,MT}', 1620),
        (c_empresa, 'Rio-Bahia',            'Belo Horizonte', 'MG', 'Salvador',       'BA', '{381,116}',     '{MG,BA}',       1370),
        (c_empresa, 'Rota Sul',             'Curitiba',       'PR', 'Porto Alegre',   'RS', '{376,101,116}', '{PR,SC,RS}',    710),
        (c_empresa, 'Eixo Goiás-DF',        'Goiânia',        'GO', 'Brasília',       'DF', '{60}',         '{GO,DF}',       210),
        (c_empresa, 'Interior Paulista',    'Campinas',       'SP', 'Ribeirão Preto', 'SP', '{}',            '{SP}',          220),
        (c_empresa, 'Litoral Nordeste',     'Recife',         'PE', 'Fortaleza',      'CE', '{101,304,116}', '{PE,PB,RN,CE}', 800),
        (c_empresa, 'Corredor Capixaba',    'Vitória',        'ES', 'Rio de Janeiro', 'RJ', '{101}',         '{ES,RJ}',       520);

    -- Na ordem do INSERT (não alfabética: a ordenação muda com o collation).
    SELECT array_agg(id ORDER BY array_position(v_nomes_rotas, nome)) INTO v_rotas
    FROM silver.rotas WHERE empresa_id = c_empresa;

    -- ------------------------------------------------------- veículos e câmeras
    FOR i IN 1..16 LOOP
        INSERT INTO silver.veiculos (empresa_id, placa_hash, placa, tipo, modelo, ano_fabricacao, capacidade_passageiros)
        VALUES (c_empresa,
                encode(sha256(convert_to('DGD' || lpad(i::TEXT, 4, '0'), 'UTF8')), 'hex'),
                'DGD' || chr(64 + ((i - 1) % 26) + 1) || lpad((10 + i)::TEXT, 2, '0'),
                v_tipos[1 + (i % 4)],
                v_modelos[1 + (i % 4)],
                2016 + (i % 9),
                CASE WHEN v_tipos[1 + (i % 4)] = 'onibus' THEN 44 ELSE NULL END)
        RETURNING id INTO v_veiculo;
        v_veiculos := array_append(v_veiculos, v_veiculo);

        INSERT INTO silver.dispositivos (empresa_id, device_id, codigo, descricao, status, ultimo_contato_em)
        VALUES (c_empresa, 'dg-edge-' || lpad(i::TEXT, 4, '0'),
                v_prefixo[1 + (i % 4)] || '-' || (1040 + i)::TEXT,
                'Câmera IR embarcada', 'ativo', now())
        RETURNING id INTO v_disp;

        IF i = 16 THEN
            -- Histórico de troca: o veículo 16 usou outra câmera até 10 dias
            -- atrás, quando ela foi substituída pela atual.
            INSERT INTO silver.dispositivos (empresa_id, device_id, codigo, descricao, status, ultimo_contato_em)
            VALUES (c_empresa, 'dg-edge-0099', 'TRK-1099', 'Câmera substituída por defeito no sensor IR',
                    'inativo', now() - INTERVAL '10 days');

            INSERT INTO silver.vinculos_dispositivo_veiculo (dispositivo_id, veiculo_id, inicio, fim, motivo)
            SELECT d.id, v_veiculo, now() - make_interval(days => v_dias + 5), now() - INTERVAL '10 days', 'Instalação inicial'
            FROM silver.dispositivos d WHERE d.device_id = 'dg-edge-0099';
        END IF;

        INSERT INTO silver.vinculos_dispositivo_veiculo (dispositivo_id, veiculo_id, inicio, motivo)
        VALUES (v_disp, v_veiculo,
                CASE WHEN i = 16 THEN now() - INTERVAL '10 days' ELSE now() - make_interval(days => v_dias + 5) END,
                CASE WHEN i = 16 THEN 'Troca de câmera: sensor IR com defeito' ELSE 'Instalação inicial' END);
    END LOOP;

    -- ------------------------------------------------------------------ motoristas
    FOR i IN 1..16 LOOP
        INSERT INTO silver.motoristas (empresa_id, codigo, motorista_hash, nome_exibicao, idade,
                                       anos_experiencia, categoria_cnh, cnh_valida_ate, regiao_uf,
                                       status, baseline_ear)
        VALUES (c_empresa,
                'DRV-' || (999 + i)::TEXT,
                encode(sha256(convert_to('DRV-' || (999 + i)::TEXT, 'UTF8')), 'hex'),
                v_nomes[i],
                28 + (i * 2) % 32,
                1 + (i * 3) % 25,
                CASE WHEN v_tipos[1 + (i % 4)] = 'onibus' THEN 'D' ELSE 'E' END,
                CURRENT_DATE + ((i % 24) || ' months')::INTERVAL,
                v_ufs[1 + (i % 8)],
                'ativo',
                0.2900 + (i % 5) * 0.0100)
        RETURNING id INTO v_motorista;
        v_motoristas := array_append(v_motoristas, v_motorista);
    END LOOP;

    -- ===================================================== simulação da operação
    FOR i IN 1..16 LOOP
        v_idx_rota  := 1 + (i % 8);
        v_rota      := v_rotas[v_idx_rota];
        SELECT distancia_km, brs[1] INTO v_dist_rota, v_br FROM silver.rotas WHERE id = v_rota;
        v_tipo_v    := v_tipos[1 + (i % 4)];
        -- Caminhoneiros de rota longa que saem de madrugada.
        v_noturno   := i IN (2, 6, 10, 14);
        v_susc_base := 0.8 + ((i * 5) % 9) * 0.1;
        -- Os mais suscetíveis fazem o treinamento no início do programa
        -- (escalonado em até 30 dias); o efeito cresce em 45 dias.
        v_treinado    := v_susc_base >= 1.3;
        v_data_treino := (v_programa_desde AT TIME ZONE c_tz)::DATE + (i * 3) % 30;
        IF v_treinado AND v_data_treino <= v_hoje THEN
            INSERT INTO silver.acoes_motorista (motorista_id, tipo, descricao, realizado_em)
            VALUES (v_motoristas[i], 'treinamento',
                    'Programa de gestão da fadiga: treinamento sobre sono, pausas e sinais de alerta',
                    (v_data_treino::TIMESTAMP + TIME '09:00') AT TIME ZONE c_tz);
        END IF;
        v_min_saida := CASE
                           WHEN v_noturno               THEN 21 * 60 + 30 + (i % 3) * 30   -- 21h30 a 22h30
                           WHEN v_tipo_v = 'onibus'     THEN 13 * 60 + 30 + (i % 2) * 30   -- 13h30 a 14h
                           ELSE 5 * 60 + 30 + (i % 5) * 35                                 -- 5h30 a 7h50
                       END;
        v_rs_km     := CASE v_tipo_v WHEN 'onibus' THEN 9.5 WHEN 'van' THEN 4.0 ELSE 7.0 END;

        v_seq_trab := 0;
        v_afastado_ate := NULL;

        FOR j IN REVERSE v_dias..0 LOOP
            v_dia  := v_hoje - j;
            v_dnum := v_dia - DATE '2000-01-01';

            -- Escala 5x2: duas folgas por semana, em dias diferentes por motorista.
            IF (v_dnum + v_folga_off[i]) % 7 IN (0, 3) THEN v_seq_trab := 0; CONTINUE; END IF;
            IF v_afastado_ate IS NOT NULL AND v_dia <= v_afastado_ate THEN v_seq_trab := 0; CONTINUE; END IF;

            -- Saída no horário do perfil (+-25 min) e duração pelo tamanho da
            -- rota (rotas curtas fazem ida e volta), +-30 min.
            v_inicio   := ((v_dia::TIMESTAMP + make_interval(mins => v_min_saida + (i * 7919 + v_dnum * 104729) % 51 - 25)) AT TIME ZONE c_tz);
            v_dur_h    := LEAST(10, GREATEST(6.5, v_dist_rota / 70.0 + 1)) + ((i * 31 + v_dnum * 17) % 11 - 5) / 10.0;
            -- Programa: turno da madrugada limitado a 8 h.
            IF v_noturno AND v_inicio >= v_programa_desde THEN v_dur_h := LEAST(v_dur_h, 8.0); END IF;
            v_fim_plan := v_inicio + make_interval(secs => (v_dur_h * 3600)::INT);

            -- Turno que ainda não começou fica para o simulador.
            IF v_inicio > now() THEN CONTINUE; END IF;
            -- Turno em andamento agora: leituras até este minuto, a cada 5 min.
            v_aberto := v_fim_plan > now();
            v_fim    := LEAST(v_fim_plan, now());
            -- Leituras a cada 5 min no turno de agora, 10 min nos últimos 120
            -- dias e 15 min no histórico mais antigo (volume do ano inteiro).
            v_passo  := CASE WHEN v_aberto THEN 5 WHEN j <= 120 THEN 10 ELSE 15 END;

            v_seq_trab := v_seq_trab + 1;
            v_fase     := CASE WHEN v_inicio >= v_programa_desde THEN 2 WHEN v_inicio >= v_piloto_ate THEN 1 ELSE 0 END;
            v_operacao := v_fase >= 1;
            -- Treinamento: suscetibilidade cai até 25% nos 45 dias seguintes.
            v_susc := v_susc_base * CASE WHEN v_treinado AND v_dia > v_data_treino
                                         THEN 1 - 0.25 * LEAST(1, (v_dia - v_data_treino) / 45.0) ELSE 1 END;
            v_ida      := (v_dnum % 2 = 0);

            -- Dívida de sono do dia (noite mal dormida em ~12% dos dias).
            v_divida := CASE WHEN v_fase = 2 THEN 0.8 ELSE 1.2 END * LEAST(v_seq_trab, 5)
                        + CASE WHEN v_noturno THEN 4 ELSE 0 END
                        + CASE WHEN (i * 13 + v_dnum * 7) % 100 < 12 THEN 8 + (i + v_dnum) % 5 ELSE 0 END
                        - CASE WHEN v_seq_trab = 1 THEN 2 ELSE 0 END;

            -- Parada legal: no piloto a cada 5h30 e só em metade dos turnos; na
            -- operação a frota adota parada a cada 4h30 em 3 de cada 4 turnos.
            v_parada_h := CASE WHEN v_fase = 2 AND v_noturno THEN 3.5 WHEN v_fase = 2 THEN 4.0 WHEN v_fase = 1 THEN 4.5 ELSE 5.5 END;
            v_respeita := (i * 17 + v_dnum * 3) % 100 < CASE v_fase WHEN 2 THEN 85 WHEN 1 THEN 75 ELSE 50 END;

            SELECT d.device_id, d.id INTO v_device, v_disp
            FROM silver.vinculos_dispositivo_veiculo vd
            JOIN silver.dispositivos d ON d.id = vd.dispositivo_id
            WHERE vd.veiculo_id = v_veiculos[i]
              AND vd.inicio <= v_inicio AND (vd.fim IS NULL OR vd.fim > v_inicio)
            LIMIT 1;

            INSERT INTO silver.viagens (empresa_id, rota_id, veiculo_id, motorista_id, partida_prevista,
                                        chegada_prevista, partida_real, valor_viagem, status)
            VALUES (c_empresa, v_rota, v_veiculos[i], v_motoristas[i],
                    v_inicio, v_fim_plan, v_inicio,
                    ROUND(v_dur_h * 70 * v_rs_km * (0.9 + random()::NUMERIC * 0.2), 2),
                    'em_andamento')
            RETURNING id INTO v_viagem;

            INSERT INTO silver.turnos (motorista_id, veiculo_id, device_id, dispositivo_id, viagem_id,
                                       iniciado_em, origem_cidade, origem_uf, destino_cidade, destino_uf, status)
            SELECT v_motoristas[i], v_veiculos[i], v_device, v_disp, v_viagem, v_inicio,
                   CASE WHEN v_ida THEN r.origem_cidade ELSE r.destino_cidade END,
                   CASE WHEN v_ida THEN r.origem_uf ELSE r.destino_uf END,
                   CASE WHEN v_ida THEN r.destino_cidade ELSE r.origem_cidade END,
                   CASE WHEN v_ida THEN r.destino_uf ELSE r.origem_uf END,
                   'em_andamento'
            FROM silver.rotas r WHERE r.id = v_rota
            RETURNING id INTO v_turno;

            -- --------------------------------------------------- leituras do turno
            v_status := 'concluido';
            v_status_vg := 'concluida';
            v_ts := v_inicio; v_ref := v_inicio; v_pausa_ate := NULL;
            v_alivio := 0; v_alivio_ate := NULL; v_ruido := 0; v_km := 0;
            v_ult_alerta := v_inicio - INTERVAL '1 day'; v_ult_tipo := NULL; v_criticos := 0;

            WHILE v_ts <= v_fim LOOP
                -- Parado (pausa): sem leitura, sem quilometragem.
                IF v_pausa_ate IS NOT NULL AND v_ts < v_pausa_ate THEN
                    v_ts := v_ts + make_interval(mins => v_passo);
                    CONTINUE;
                END IF;

                v_ef  := EXTRACT(EPOCH FROM (v_ts - v_ref)) / 3600.0;
                v_tot := EXTRACT(EPOCH FROM (v_ts - v_inicio)) / 3600.0;

                -- Parada planejada (30 min).
                IF v_respeita AND v_ef >= v_parada_h THEN
                    v_pausa_ate := v_ts + INTERVAL '30 minutes';
                    v_ref := v_pausa_ate;
                    v_ts := v_ts + make_interval(mins => v_passo);
                    CONTINUE;
                END IF;

                v_hl := EXTRACT(HOUR FROM v_ts AT TIME ZONE c_tz) + EXTRACT(MINUTE FROM v_ts AT TIME ZONE c_tz) / 60.0;
                v_circ := 22 * exp(-power(LEAST(abs(v_hl - 4), 24 - abs(v_hl - 4)), 2) / 8.0)
                        +  8 * exp(-power(LEAST(abs(v_hl - 14.5), 24 - abs(v_hl - 14.5)), 2) / 4.5);
                IF v_alivio_ate IS NOT NULL AND v_ts > v_alivio_ate THEN v_alivio := 0; END IF;

                -- Ruído com memória (AR(1)) mais um ruído branco pequeno.
                v_ruido := 0.75 * v_ruido + 0.25 * ((random()::NUMERIC + random()::NUMERIC + random()::NUMERIC + random()::NUMERIC - 2) * 1.732) * 9;
                v_score := 4
                           + v_ef * 4.6 * v_susc
                           + v_tot * 0.8
                           + v_circ * (0.6 + 0.4 * v_susc)
                           + v_divida
                           + v_ruido
                           + (random()::NUMERIC + random()::NUMERIC + random()::NUMERIC + random()::NUMERIC - 2) * 1.732 * 2
                           - v_alivio;
                v_score := ROUND(LEAST(99, GREATEST(1, v_score)), 2);
                v_s := v_score / 100.0;
                v_estado := CASE WHEN v_score >= 70 THEN 'sonolento'
                                 WHEN v_score >= 40 THEN 'fadiga'
                                 ELSE 'alerta' END;

                -- Features coerentes com o score.
                v_ear     := LEAST(0.40, GREATEST(0.10, 0.33 - 0.17 * v_s + (random()::NUMERIC - 0.5) * 0.02));
                v_perclos := LEAST(0.90, GREATEST(0.00, 0.03 + 0.55 * v_s * v_s + (random()::NUMERIC - 0.5) * 0.04));
                v_bocejo  := random()::NUMERIC < 0.03 + 0.45 * v_s * v_s;
                v_mar     := CASE WHEN v_bocejo THEN 0.50 + random()::NUMERIC * 0.15 ELSE 0.16 + random()::NUMERIC * 0.08 END;
                v_blink   := GREATEST(4, 17 - 6 * v_s + (random()::NUMERIC - 0.5) * 4);
                v_olhos_ms := (140 + 1300 * power(v_s, 3) + (random()::NUMERIC - 0.5) * 60)::INT;
                v_pitch   := random()::NUMERIC * 4 - 2 - CASE WHEN v_s > 0.6 THEN (v_s - 0.6) * 55 ELSE 0 END;
                v_distracao := random()::NUMERIC < 0.0015;
                v_sem_face  := NOT v_distracao AND random()::NUMERIC < 0.0008;
                v_yaw     := random()::NUMERIC * 10 - 5 + CASE WHEN v_distracao THEN 35 ELSE 0 END;

                -- Posição na rota (rotas curtas: ida e volta no mesmo turno).
                v_vel  := CASE WHEN v_tipo_v = 'onibus' THEN 70 ELSE 62 END + random()::NUMERIC * 25;
                v_km   := v_km + v_vel * v_passo / 60.0;
                v_frac := v_km / v_dist_rota;
                v_pos  := v_frac - floor(v_frac);
                IF (floor(v_frac)::INT % 2 = 1) <> NOT v_ida THEN v_pos := 1 - v_pos; END IF;
                v_lat  := v_lat_o[v_idx_rota] + (v_lat_d[v_idx_rota] - v_lat_o[v_idx_rota]) * v_pos + (random()::NUMERIC - 0.5) * 0.04;
                v_lon  := v_lon_o[v_idx_rota] + (v_lon_d[v_idx_rota] - v_lon_o[v_idx_rota]) * v_pos + (random()::NUMERIC - 0.5) * 0.04;

                INSERT INTO silver.leituras_fadiga (
                    turno_id, motorista_id, veiculo_id, device_id, registrado_em,
                    ear, mar, perclos, blink_rate, duracao_olhos_fechados_ms,
                    head_pitch, head_yaw, head_roll, score_fadiga, estado,
                    latitude, longitude, velocidade_kmh, ingest_id, bronze_key
                ) VALUES (
                    v_turno, v_motoristas[i], v_veiculos[i], v_device, v_ts,
                    ROUND(v_ear, 4), ROUND(v_mar, 4), ROUND(v_perclos, 4), ROUND(v_blink, 2), v_olhos_ms,
                    ROUND(v_pitch, 2), ROUND(v_yaw, 2), ROUND((random()::NUMERIC * 6 - 3)::NUMERIC, 2), v_score, v_estado,
                    ROUND(v_lat, 6), ROUND(v_lon, 6), ROUND(v_vel, 1), gen_random_uuid(), 'seed/simulacao'
                ) ON CONFLICT (device_id, registrado_em) DO NOTHING;

                -- --------------------------------------------------- alertas
                v_tipo := NULL;
                IF v_estado = 'sonolento' AND v_ts - v_ult_alerta >= INTERVAL '20 minutes' THEN
                    v_tipo := CASE WHEN v_olhos_ms >= 1000 THEN 'microssono'
                                   WHEN v_pitch <= -15    THEN 'cabeca_baixa'
                                   WHEN v_bocejo          THEN 'bocejo_excessivo'
                                   ELSE 'sonolencia' END;
                    v_grav := CASE WHEN v_score >= 90 THEN 'critica'
                                   WHEN v_score >= 80 THEN 'alta'
                                   ELSE 'media' END;
                ELSIF v_distracao AND v_ts - v_ult_alerta >= INTERVAL '10 minutes' THEN
                    v_tipo := 'distracao';  v_grav := 'alta';
                ELSIF v_sem_face AND v_ts - v_ult_alerta >= INTERVAL '10 minutes' THEN
                    v_tipo := 'perda_de_face';  v_grav := 'media';
                END IF;

                IF v_tipo IS NOT NULL THEN
                    v_ult_alerta := v_ts;
                    v_ult_tipo := v_tipo;
                    v_ref_prev := v_ref;
                    v_acao := NULL;
                    v_reconh := NULL;
                    v_resolv := NULL;

                    IF NOT v_operacao THEN
                        -- Piloto: só o alarme na cabine, que acorda por alguns minutos.
                        v_st_alerta := 'resolvido';
                        v_resolv := v_ts + INTERVAL '15 minutes';
                        IF v_tipo NOT IN ('distracao', 'perda_de_face') THEN
                            v_alivio := 6; v_alivio_ate := v_ts + INTERVAL '10 minutes';
                        END IF;
                    ELSE
                        v_reconh := v_ts + make_interval(secs => (90 + random()::NUMERIC * 150)::INT);
                        IF v_grav IN ('alta', 'critica') AND v_tipo NOT IN ('distracao', 'perda_de_face') AND random()::NUMERIC < 0.85 THEN
                            IF v_grav = 'critica' AND v_criticos >= 1 THEN
                                -- Segundo alerta crítico no turno: a central encerra o turno.
                                v_acao := 'encerramento_turno';
                                v_resolv := v_reconh + INTERVAL '15 minutes';
                                v_fim := LEAST(v_fim, v_resolv);
                            ELSE
                                v_acao := 'pausa_obrigatoria';
                                v_resolv := v_reconh + make_interval(mins => CASE WHEN v_grav = 'critica' THEN 30 ELSE 25 END + 5);
                                v_pausa_ate := v_resolv;
                                v_ref := v_resolv;
                            END IF;
                        ELSIF random()::NUMERIC < 0.6 THEN
                            -- Alertas médios e distração: a central liga para o motorista.
                            v_acao := 'contato_telefonico';
                            v_resolv := v_reconh + INTERVAL '5 minutes';
                            v_alivio := 8; v_alivio_ate := v_ts + INTERVAL '20 minutes';
                        ELSE
                            v_resolv := v_ts + INTERVAL '20 minutes';
                        END IF;
                        v_st_alerta := 'resolvido';
                        IF v_grav = 'critica' THEN v_criticos := v_criticos + 1; END IF;

                        -- Turno de agora: o que ainda não aconteceu fica pendente.
                        IF v_aberto THEN
                            IF v_reconh > now() THEN
                                -- Ninguém atendeu ainda: desfaz a pausa ou o encerramento.
                                v_st_alerta := 'aberto'; v_reconh := NULL; v_resolv := NULL; v_acao := NULL;
                                v_pausa_ate := NULL; v_ref := v_ref_prev; v_fim := LEAST(v_fim_plan, now());
                            ELSIF v_resolv > now() THEN
                                v_st_alerta := 'reconhecido'; v_resolv := NULL;
                            END IF;
                        END IF;
                    END IF;

                    INSERT INTO silver.alertas (turno_id, motorista_id, veiculo_id, disparado_em, tipo,
                                                gravidade, status, score_fadiga, mensagem,
                                                reconhecido_em, resolvido_em)
                    VALUES (v_turno, v_motoristas[i], v_veiculos[i], v_ts + INTERVAL '2 seconds', v_tipo,
                            v_grav, v_st_alerta, v_score,
                            CASE v_tipo
                                WHEN 'distracao'     THEN 'Olhar fora da estrada por mais de 2 s.'
                                WHEN 'perda_de_face' THEN 'Rosto fora do alcance da câmera.'
                                WHEN 'microssono'    THEN 'Olhos fechados por ' || v_olhos_ms || ' ms após ' || ROUND(v_ef, 1) || 'h sem pausa.'
                                ELSE 'Score de fadiga ' || ROUND(v_score) || ' após ' || ROUND(v_ef, 1) || 'h sem pausa.'
                            END,
                            v_reconh, v_resolv)
                    ON CONFLICT (motorista_id, disparado_em, tipo) DO NOTHING
                    RETURNING id INTO v_alerta;

                    IF v_acao IS NOT NULL AND v_alerta IS NOT NULL THEN
                        INSERT INTO silver.acoes_motorista (motorista_id, turno_id, alerta_id, tipo, descricao, realizado_em)
                        VALUES (v_motoristas[i], v_turno, v_alerta, v_acao,
                                CASE v_acao
                                    WHEN 'pausa_obrigatoria'  THEN 'Pausa obrigatória após alerta de ' || replace(v_tipo::TEXT, '_', ' ')
                                    WHEN 'encerramento_turno' THEN 'Turno encerrado: segundo alerta crítico'
                                    ELSE 'Contato com o motorista após alerta de ' || replace(v_tipo::TEXT, '_', ' ')
                                END,
                                v_reconh + INTERVAL '1 minute');
                    END IF;
                END IF;

                -- --------------------------------------------------- acidentes
                -- Risco a cada 10 min: por sono (cresce ao cubo acima de 75) e de
                -- base (maior com o olhar fora da estrada).
                v_lambda_s := 0.02 * power(GREATEST(0, (v_score - 75) / 25.0), 3) * v_passo / 10.0;
                v_lambda_o := 0.000018 * CASE WHEN v_distracao THEN 20 ELSE 1 END * v_passo / 10.0;
                IF v_fase = 0 THEN
                    v_soma_piloto := v_soma_piloto + v_lambda_s + v_lambda_o;
                    v_soma_piloto_sono := v_soma_piloto_sono + v_lambda_s;
                END IF;
                v_acc_sono  := v_acc_sono + v_lambda_s;
                v_acc_outro := v_acc_outro + v_lambda_o;
                -- Quase-acidente por sono (ocorrência sem acidente): bem mais
                -- comum que o acidente, também concentrado na fadiga alta.
                v_lambda_q := 0.05 * power(GREATEST(0, (v_score - 80) / 20.0), 2) * v_passo / 10.0;
                v_acc_quase := v_acc_quase + v_lambda_q;
                IF NOT v_aberto AND v_acc_quase >= 1 AND v_acc_sono < 1 AND v_acc_outro < 1 THEN
                    v_acc_quase := v_acc_quase - 1;
                    v_n_quase := v_n_quase + 1;
                    v_hora_txt := to_char(v_ts AT TIME ZONE c_tz, 'HH24:MI');
                    INSERT INTO silver.incidentes (empresa_id, motorista_id, veiculo_id, turno_id, origem, origem_id_externo,
                                                   ocorrido_em, uf, municipio, br, km, latitude, longitude,
                                                   causa, tipo_acidente, gravidade, qtd_mortos, qtd_feridos, qtd_ilesos,
                                                   fase_dia, relacionado_sonolencia, descricao)
                    SELECT c_empresa, v_motoristas[i], v_veiculos[i], v_turno, 'interno', 'SIM-Q-' || lpad(v_n_quase::TEXT, 3, '0'),
                           v_ts,
                           CASE WHEN v_pos < 0.3 THEN r.origem_uf WHEN v_pos > 0.7 THEN r.destino_uf ELSE v_meio_uf[v_idx_rota] END,
                           CASE WHEN v_pos < 0.3 THEN r.origem_cidade WHEN v_pos > 0.7 THEN r.destino_cidade ELSE v_meio_cidade[v_idx_rota] END,
                           v_br, ROUND((10 + random()::NUMERIC * 480)::NUMERIC, 1), ROUND(v_lat, 6), ROUND(v_lon, 6),
                           'Condutor sonolento (sem acidente)',
                           CASE (v_n_quase % 3) WHEN 0 THEN 'Quase acidente: saída de faixa sem colisão'
                                                WHEN 1 THEN 'Quase acidente: quase colisão traseira'
                                                ELSE 'Quase acidente: invasão do acostamento' END,
                           NULL, 0, 0, 0,
                           CASE WHEN v_hl >= 5 AND v_hl < 6.5 THEN 'Amanhecer'
                                WHEN v_hl >= 6.5 AND v_hl < 18 THEN 'Pleno dia'
                                WHEN v_hl >= 18 AND v_hl < 19 THEN 'Anoitecer'
                                ELSE 'Plena Noite' END,
                           TRUE,
                           'Às ' || v_hora_txt || ', após ' || ROUND(v_ef, 1) || 'h sem pausa, com score de fadiga ' || ROUND(v_score) || '. '
                           || CASE WHEN v_operacao THEN 'A central mandou parar em seguida (pausa de 30 min).'
                                   ELSE 'Fase piloto: o motorista seguiu viagem.' END
                    FROM silver.rotas r WHERE r.id = v_rota;
                    -- Na operação, a central manda parar depois do susto.
                    IF v_operacao THEN
                        v_pausa_ate := v_ts + INTERVAL '30 minutes';
                        v_ref := v_pausa_ate;
                    END IF;
                END IF;

                IF NOT v_aberto AND (v_acc_sono >= 1 OR v_acc_outro >= 1) THEN
                    v_n_incid := v_n_incid + 1;
                    v_r := random()::NUMERIC;
                    v_r2 := random()::NUMERIC;
                    -- Com o motorista sonolento, a perícia atribui ao sono mesmo que o
                    -- risco sorteado tenha sido o de base.
                    v_por_sono := v_acc_sono >= 1 OR v_score >= 70;
                    IF v_por_sono THEN
                        v_grav_inc := CASE WHEN v_r < 0.50 THEN 'sem_vitimas' WHEN v_r < 0.90 THEN 'com_feridos' ELSE 'com_fatais' END;
                    ELSE
                        v_grav_inc := CASE WHEN v_r < 0.70 THEN 'sem_vitimas' WHEN v_r < 0.97 THEN 'com_feridos' ELSE 'com_fatais' END;
                    END IF;
                    v_mortos  := CASE WHEN v_grav_inc = 'com_fatais' THEN 1 ELSE 0 END;
                    v_feridos := CASE WHEN v_grav_inc = 'sem_vitimas' THEN 0
                                      ELSE 1 + (random()::NUMERIC * CASE WHEN v_tipo_v = 'onibus' THEN 6 ELSE 2 END)::INT END;
                    v_hora_txt := to_char(v_ts AT TIME ZONE c_tz, 'HH24:MI');
                    v_antes := CASE
                        WHEN NOT v_por_sono AND NOT v_distracao THEN 'Sem sinais de sonolência no momento.'
                        WHEN NOT v_por_sono THEN 'Alerta de distração no momento do acidente.'
                        WHEN v_ts - v_ult_alerta <= INTERVAL '40 minutes' THEN
                            'Alerta de ' || replace(v_ult_tipo::TEXT, '_', ' ') || ' '
                            || GREATEST(1, ROUND(EXTRACT(EPOCH FROM (v_ts - v_ult_alerta)) / 60)) || ' min antes'
                            || CASE WHEN v_operacao THEN ', sem pausa registrada.'
                                    ELSE ' (fase piloto: só o alarme na cabine, sem a central).' END
                        ELSE 'Sem alerta nos 40 min anteriores.' END;

                    INSERT INTO silver.incidentes (empresa_id, motorista_id, veiculo_id, turno_id, origem, origem_id_externo,
                                                   ocorrido_em, uf, municipio, br, km, latitude, longitude,
                                                   causa, tipo_acidente, gravidade, qtd_mortos, qtd_feridos, qtd_ilesos,
                                                   fase_dia, relacionado_sonolencia, descricao)
                    SELECT c_empresa, v_motoristas[i], v_veiculos[i], v_turno, 'interno', 'SIM-' || lpad(v_n_incid::TEXT, 3, '0'),
                           v_ts,
                           CASE WHEN v_pos < 0.3 THEN r.origem_uf WHEN v_pos > 0.7 THEN r.destino_uf ELSE v_meio_uf[v_idx_rota] END,
                           CASE WHEN v_pos < 0.3 THEN r.origem_cidade WHEN v_pos > 0.7 THEN r.destino_cidade ELSE v_meio_cidade[v_idx_rota] END,
                           v_br, ROUND((10 + random()::NUMERIC * 480)::NUMERIC, 1), ROUND(v_lat, 6), ROUND(v_lon, 6),
                           CASE WHEN v_por_sono THEN 'Condutor Dormindo'
                                WHEN v_distracao THEN 'Falta de atenção à condução'
                                ELSE 'Reação tardia ou ineficiente do condutor' END,
                           CASE WHEN v_por_sono
                                THEN CASE WHEN v_r2 < 0.45 THEN 'Saída de leito carroçável' WHEN v_r2 < 0.75 THEN 'Tombamento' ELSE 'Colisão traseira' END
                                ELSE CASE WHEN v_r2 < 0.6 THEN 'Colisão traseira' ELSE 'Colisão lateral mesmo sentido' END END,
                           v_grav_inc, v_mortos, v_feridos,
                           CASE WHEN v_grav_inc = 'sem_vitimas' THEN 1 ELSE 0 END,
                           CASE WHEN v_hl >= 5 AND v_hl < 6.5 THEN 'Amanhecer'
                                WHEN v_hl >= 6.5 AND v_hl < 18 THEN 'Pleno dia'
                                WHEN v_hl >= 18 AND v_hl < 19 THEN 'Anoitecer'
                                ELSE 'Plena Noite' END,
                           v_por_sono,
                           CASE WHEN v_por_sono
                                THEN 'Às ' || v_hora_txt || ', após ' || ROUND(v_ef, 1) || 'h sem pausa (' || ROUND(v_tot, 1)
                                     || 'h de turno), com score de fadiga ' || ROUND(v_score) || '. '
                                ELSE 'Às ' || v_hora_txt || ', com score de fadiga ' || ROUND(v_score) || '. ' END
                           || v_antes
                    FROM silver.rotas r WHERE r.id = v_rota;

                    IF v_acc_sono >= 1 THEN v_acc_sono := v_acc_sono - 1; END IF;
                    IF v_acc_outro >= 1 THEN v_acc_outro := v_acc_outro - 1; END IF;

                    v_status := 'interrompido';
                    v_status_vg := 'cancelada';
                    v_fim := v_ts;
                    -- Afastamento: 3 dias sem vítimas, 10 com vítimas.
                    v_afastado_ate := v_dia + CASE WHEN v_grav_inc = 'sem_vitimas' THEN 3 ELSE 10 END;
                    EXIT;
                END IF;

                v_ts := v_ts + make_interval(mins => v_passo);
            END LOOP;

            -- Fecha o turno e a viagem com o que de fato aconteceu. O turno de
            -- agora continua aberto, a não ser que a central já o tenha encerrado.
            IF v_aberto AND v_fim >= now() - INTERVAL '10 minutes' THEN
                NULL;
            ELSE
                UPDATE silver.turnos
                   SET finalizado_em = LEAST(v_fim, v_fim_plan), status = v_status, distancia_km = ROUND(v_km)
                 WHERE id = v_turno;
                UPDATE silver.viagens
                   SET status = v_status_vg,
                       chegada_real = CASE WHEN v_status_vg = 'concluida' THEN LEAST(v_fim, v_fim_plan) END
                 WHERE id = v_viagem;
            END IF;
        END LOOP;

        IF v_afastado_ate IS NOT NULL AND v_afastado_ate >= v_hoje THEN
            UPDATE silver.motoristas SET status = 'afastado' WHERE id = v_motoristas[i];
        END IF;
    END LOOP;

    -- Último contato de cada câmera = a última leitura que ela enviou.
    UPDATE silver.dispositivos d
       SET ultimo_contato_em = x.ultima
      FROM (SELECT device_id, MAX(registrado_em) AS ultima FROM silver.leituras_fadiga GROUP BY device_id) x
     WHERE x.device_id = d.device_id AND d.status = 'ativo';

    -- ------------------------------------------------- eficácia das pausas
    -- Eficaz = nenhum alerta grave de sono na hora seguinte ao fim da pausa.
    UPDATE silver.acoes_motorista a
       SET eficaz = NOT EXISTS (
               SELECT 1 FROM silver.alertas x
               WHERE x.turno_id = a.turno_id
                 AND x.gravidade IN ('alta', 'critica')
                 AND x.tipo NOT IN ('distracao', 'perda_de_face')
                 AND x.disparado_em >  al.resolvido_em
                 AND x.disparado_em <= al.resolvido_em + INTERVAL '60 minutes')
      FROM silver.alertas al
     WHERE al.id = a.alerta_id AND al.resolvido_em IS NOT NULL;

    -- Treinamento eficaz = fadiga média do motorista nos 30 dias seguintes
    -- menor que nos 30 dias anteriores.
    UPDATE silver.acoes_motorista a
       SET eficaz = (SELECT AVG(score_fadiga) FROM silver.leituras_fadiga l
                      WHERE l.motorista_id = a.motorista_id AND l.registrado_em BETWEEN a.realizado_em AND a.realizado_em + INTERVAL '30 days')
                  < (SELECT AVG(score_fadiga) FROM silver.leituras_fadiga l
                      WHERE l.motorista_id = a.motorista_id AND l.registrado_em BETWEEN a.realizado_em - INTERVAL '30 days' AND a.realizado_em)
     WHERE a.tipo = 'treinamento';

    -- ------------------------------------------------------------------ ROI
    -- Taxa anual esperada de acidentes da frota sem a central (fase piloto),
    -- calculada pela própria simulação.
    INSERT INTO silver.parametros_roi (empresa_id, chave, valor, fonte) VALUES
        (c_empresa, 'acidentes_ano_frota',
         GREATEST(1, ROUND(v_soma_piloto / GREATEST(1, v_dias - CEIL(v_dias * 0.75)) * 365, 1)),
         'Histórico da frota antes do DriveGuard (fase piloto da simulação de demonstração)'),
        (c_empresa, 'horas_parada_por_acidente', 8, 'Informado pelo gestor (dados de demonstração)'),
        -- Cenário realista com a fração de acidentes por sono da própria frota
        -- (o conservador continua com a referência nacional da PRF).
        (c_empresa, 'fracao_sono_realista',
         ROUND(LEAST(0.9, GREATEST(0.06, v_soma_piloto_sono / NULLIF(v_soma_piloto, 0))), 3),
         'Histórico de acidentes da frota: fração ligada ao sono na fase piloto (simulação de demonstração)');

    RAISE NOTICE 'Seed concluido: % acidentes e % quase-acidentes simulados; taxa da fase piloto % por ano.',
        v_n_incid, v_n_quase, ROUND(v_soma_piloto / GREATEST(1, v_dias - CEIL(v_dias * 0.75)) * 365, 1);
END
$seed$;
