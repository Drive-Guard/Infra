-- =============================================================================
-- DriveGuard — Dados sintéticos de demonstração
--
-- Frota de exemplo para o dashboard sair do zero na banca: 1 empresa,
-- 16 motoristas, 16 caminhões/ônibus/vans com câmera, 8 rotas, 8 semanas de
-- histórico e 12 turnos em andamento no momento do deploy.
--
-- O histórico mais antigo é um pouco mais cansado que o recente (a frota
-- "melhora" depois de adotar as pausas), para os comparativos contra o
-- período anterior terem o que mostrar.
--
-- Coerência com o resto da solução:
--   * a empresa tem UUID fixo, o mesmo que os usuários de demonstração do
--     Cognito carregam em custom:empresa_id;
--   * o ID fixo de cada dispositivo é o código do motorista (DRV-1000...), e
--     motorista_hash = SHA-256 desse código, igual ao que o cliente do modelo
--     calcula antes de enviar. O simulador de frota usa os mesmos IDs;
--   * o estado segue o modelo da branch stable, que é binário: score =
--     100 x P(sono); estado 'sonolento' quando P(sono) >= 0,5;
--   * as features seguem a literatura usada no TCC (EAR ~0,31 x ~0,16,
--     MAR ~0,22 x ~0,51, PERCLOS ~0,08 x ~0,54, pitch ~0 x ~-18 graus).
--
-- Acidentes da PRF NÃO são gerados aqui: vêm da base real pelo ETL da PRF.
-- Só entram duas ocorrências internas da própria frota.
--
-- Guardado por um IF: só roda com o banco vazio, então reexecutar é seguro.
-- =============================================================================

SET search_path TO silver, public;

DO $seed$
DECLARE
    c_empresa   CONSTANT UUID := '00000000-0000-4000-8000-000000000001';
    v_motorista UUID;
    v_veiculo   UUID;
    v_disp      UUID;
    v_turno     UUID;
    v_viagem    UUID;
    v_rota      UUID;
    v_inicio    TIMESTAMPTZ;
    v_fim       TIMESTAMPTZ;
    v_ts        TIMESTAMPTZ;
    v_horas     NUMERIC;
    v_score     NUMERIC(5,2);
    v_sono      BOOLEAN;
    v_aberto    BOOLEAN;
    v_estado    silver.estado_fadiga;
    v_perclos   NUMERIC;
    v_mar       NUMERIC;
    v_pitch     NUMERIC;
    v_yaw       NUMERIC;
    v_hora_loc  INT;
    v_passo     INTERVAL;
    v_dur_h     INT;
    v_tipo      silver.tipo_alerta;
    i INT; j INT; k INT;
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
BEGIN
    IF EXISTS (SELECT 1 FROM silver.empresas) THEN
        RAISE NOTICE 'Seed ignorado: o banco ja contem dados.';
        RETURN;
    END IF;

    -- ------------------------------------------------------------------ empresa
    INSERT INTO silver.empresas (id, cnpj_hash, razao_social, nome_fantasia, uf, cidade, frota_total)
    VALUES (c_empresa, encode(sha256(convert_to('12345678000199', 'UTF8')), 'hex'),
            'Transportadora Rodoviária Demo LTDA', 'DriveGuard Demo', 'SP', 'São Paulo', 20);

    -- ROI: os dois números que só o gestor sabe.
    INSERT INTO silver.parametros_roi (empresa_id, chave, valor, fonte) VALUES
        (c_empresa, 'acidentes_ano_frota', 6, 'Informado pelo gestor (dados de demonstração)'),
        (c_empresa, 'horas_parada_por_acidente', 8, 'Informado pelo gestor (dados de demonstração)');

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

    SELECT array_agg(id ORDER BY criado_em, nome) INTO v_rotas FROM silver.rotas WHERE empresa_id = c_empresa;

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
            SELECT d.id, v_veiculo, now() - INTERVAL '60 days', now() - INTERVAL '10 days', 'Instalação inicial'
            FROM silver.dispositivos d WHERE d.device_id = 'dg-edge-0099';
        END IF;

        INSERT INTO silver.vinculos_dispositivo_veiculo (dispositivo_id, veiculo_id, inicio, motivo)
        VALUES (v_disp, v_veiculo,
                CASE WHEN i = 16 THEN now() - INTERVAL '10 days' ELSE now() - INTERVAL '60 days' END,
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

    -- ------------------------------------------------- turnos, viagens e leituras
    -- Para cada motorista: 16 turnos concluídos nas últimas 8 semanas e, para
    -- os 12 primeiros, um turno em andamento agora.
    FOR i IN 1..16 LOOP
        v_rota := v_rotas[1 + (i % 8)];

        FOR j IN 0..16 LOOP
            IF j = 0 AND i > 12 THEN CONTINUE; END IF;

            IF j = 0 THEN
                -- Turno em andamento: começou entre 1h e 7h atrás.
                v_inicio := now() - (((i % 6) + 1) || ' hours')::INTERVAL - ((i * 7 % 50) || ' minutes')::INTERVAL;
                v_fim    := now();
                v_passo  := INTERVAL '5 minutes';
            ELSE
                v_dur_h  := 6 + (i + j) % 5;
                v_inicio := now()
                            - make_interval(days => (j * 18) / 5 + (i % 3))
                            - ((6 + (i * j) % 14) || ' hours')::INTERVAL;
                v_fim    := v_inicio + (v_dur_h || ' hours')::INTERVAL;
                v_passo  := INTERVAL '15 minutes';
            END IF;

            INSERT INTO silver.viagens (empresa_id, rota_id, veiculo_id, motorista_id, partida_prevista,
                                        chegada_prevista, partida_real, chegada_real, valor_viagem, status)
            VALUES (c_empresa, v_rota, v_veiculos[i], v_motoristas[i],
                    v_inicio, v_inicio + INTERVAL '10 hours', v_inicio,
                    CASE WHEN j = 0 THEN NULL ELSE v_fim END,
                    3000 + ((i * 731 + j * 157) % 9000),
                    CASE WHEN j = 0 THEN 'em_andamento' ELSE 'concluida' END::silver.status_viagem)
            RETURNING id INTO v_viagem;

            INSERT INTO silver.turnos (motorista_id, veiculo_id, device_id, dispositivo_id, viagem_id,
                                       iniciado_em, finalizado_em, origem_cidade, origem_uf,
                                       destino_cidade, destino_uf, distancia_km, status)
            SELECT v_motoristas[i], v_veiculos[i], d.device_id, d.id, v_viagem,
                   v_inicio, CASE WHEN j = 0 THEN NULL ELSE v_fim END,
                   r.origem_cidade, r.origem_uf, r.destino_cidade, r.destino_uf,
                   CASE WHEN j = 0 THEN NULL ELSE ROUND(r.distancia_km * 0.6) END,
                   CASE WHEN j = 0 THEN 'em_andamento' ELSE 'concluido' END::silver.status_turno
            FROM silver.rotas r
            -- A câmera que estava no veículo no início do turno.
            JOIN silver.vinculos_dispositivo_veiculo vd
              ON vd.veiculo_id = v_veiculos[i]
             AND vd.inicio <= v_inicio
             AND (vd.fim IS NULL OR vd.fim > v_inicio)
            JOIN silver.dispositivos d ON d.id = vd.dispositivo_id
            WHERE r.id = v_rota
            RETURNING id INTO v_turno;

            v_ts := v_inicio;
            k := 0;
            WHILE v_ts <= v_fim LOOP
                v_horas    := EXTRACT(EPOCH FROM (v_ts - v_inicio)) / 3600.0;
                v_hora_loc := EXTRACT(HOUR FROM v_ts AT TIME ZONE 'America/Sao_Paulo');

                -- P(sono) cresce com as horas ao volante e na madrugada.
                v_score := LEAST(98, GREATEST(2,
                    8
                    + v_horas * 6.5
                    + CASE WHEN v_hora_loc BETWEEN 0 AND 5 THEN 18 ELSE 0 END
                    + (i % 4) * 4
                    -- histórico antigo um pouco mais cansado (até +6 pontos)
                    + j * 0.4
                    + (random() * 14 - 7)));

                v_sono   := v_score >= 50;
                v_estado := CASE WHEN v_sono THEN 'sonolento' ELSE 'alerta' END::silver.estado_fadiga;
                v_perclos := CASE WHEN v_sono THEN 0.40 + random() * 0.20 ELSE 0.04 + random() * 0.08 END;
                v_mar     := CASE WHEN v_sono THEN 0.45 + random() * 0.12 ELSE 0.18 + random() * 0.08 END;
                v_pitch   := CASE WHEN v_sono THEN -14 - random() * 8 ELSE random() * 5 - 2.5 END;
                v_yaw     := random() * 10 - 5 + CASE WHEN random() < 0.03 THEN 35 ELSE 0 END;

                INSERT INTO silver.leituras_fadiga (
                    turno_id, motorista_id, veiculo_id, device_id, registrado_em,
                    ear, mar, perclos, blink_rate, duracao_olhos_fechados_ms,
                    head_pitch, head_yaw, head_roll, score_fadiga, estado,
                    latitude, longitude, velocidade_kmh, ingest_id, bronze_key
                )
                SELECT v_turno, v_motoristas[i], v_veiculos[i], t.device_id, v_ts,
                       CASE WHEN v_sono THEN 0.15 + random() * 0.04 ELSE 0.29 + random() * 0.04 END,
                       v_mar, v_perclos,
                       CASE WHEN v_sono THEN 7 + random() * 3 ELSE 15 + random() * 4 END,
                       (120 + v_perclos * 900)::INT,
                       v_pitch, v_yaw, random() * 6 - 3,
                       ROUND(v_score, 2), v_estado,
                       -23.55 + (random() * 8 - 4), -46.63 + (random() * 8 - 4),
                       CASE WHEN random() < 0.08 THEN 0 ELSE 60 + random() * 30 END,
                       gen_random_uuid(), 'seed/demo'
                FROM silver.turnos t WHERE t.id = v_turno
                ON CONFLICT (device_id, registrado_em) DO NOTHING;

                -- Alerta quando o modelo indica sono com probabilidade alta.
                IF v_score >= 72 AND random() < 0.30 THEN
                    v_tipo := CASE
                        WHEN abs(v_yaw) > 30   THEN 'distracao'
                        WHEN v_perclos > 0.52  THEN 'microssono'
                        WHEN v_mar > 0.53      THEN 'bocejo_excessivo'
                        WHEN v_pitch < -19     THEN 'cabeca_baixa'
                        WHEN random() < 0.15   THEN 'fechamento_prolongado'
                        WHEN random() < 0.15   THEN 'piscadas_excessivas'
                        ELSE 'sonolencia'
                    END::silver.tipo_alerta;

                    -- Turno atual: metade ainda aberta, metade reconhecida pela
                    -- central (só se o reconhecimento já aconteceu). Turnos
                    -- antigos: tudo resolvido.
                    v_aberto := j = 0 AND (random() < 0.5 OR v_ts + INTERVAL '4 minutes' > now());

                    INSERT INTO silver.alertas (turno_id, motorista_id, veiculo_id, disparado_em, tipo,
                                                gravidade, status, score_fadiga, mensagem,
                                                reconhecido_em, resolvido_em)
                    VALUES (v_turno, v_motoristas[i], v_veiculos[i], v_ts + INTERVAL '2 seconds', v_tipo,
                            CASE WHEN v_score >= 90 THEN 'critica'
                                 WHEN v_score >= 80 THEN 'alta'
                                 ELSE 'media' END::silver.gravidade,
                            CASE WHEN v_aberto THEN 'aberto'
                                 WHEN j = 0 THEN 'reconhecido'
                                 ELSE 'resolvido' END::silver.status_alerta,
                            ROUND(v_score, 2),
                            'P(sono) de ' || ROUND(v_score / 100, 2) || ' após ' || ROUND(v_horas, 1) || 'h ao volante.',
                            CASE WHEN v_aberto THEN NULL ELSE v_ts + INTERVAL '4 minutes' END,
                            CASE WHEN j = 0 THEN NULL ELSE v_ts + INTERVAL '25 minutes' END)
                    ON CONFLICT (motorista_id, disparado_em, tipo) DO NOTHING;
                END IF;

                v_ts := v_ts + v_passo;
                k := k + 1;
            END LOOP;
        END LOOP;
    END LOOP;

    -- ------------------------------------------------------------------ ações
    -- A maior parte dos alertas graves resolvidos tem uma ação registrada
    -- ("atendidos" no ROI); o resto foi resolvido sem registro.
    INSERT INTO silver.acoes_motorista (motorista_id, turno_id, alerta_id, tipo, descricao, realizado_em, eficaz)
    SELECT a.motorista_id, a.turno_id, a.id,
           CASE WHEN a.gravidade = 'critica' THEN 'encerramento_turno'
                ELSE 'pausa_obrigatoria' END::silver.tipo_acao,
           'Ação a partir do alerta de ' || replace(a.tipo::TEXT, '_', ' '),
           a.disparado_em + INTERVAL '6 minutes',
           TRUE
    FROM silver.alertas a
    WHERE a.status = 'resolvido' AND a.gravidade IN ('alta', 'critica') AND random() < 0.85;

    -- ------------------------------------------------- ocorrências internas
    INSERT INTO silver.incidentes (empresa_id, motorista_id, veiculo_id, origem, origem_id_externo,
                                   ocorrido_em, uf, municipio, br, km, causa, tipo_acidente, gravidade,
                                   qtd_mortos, qtd_feridos, qtd_ilesos, relacionado_sonolencia, descricao)
    VALUES
        (c_empresa, v_motoristas[3], v_veiculos[3], 'interno', 'DEMO-OC-1',
         now() - INTERVAL '40 days', 'MG', 'Betim', '381', 492.0, 'Condutor Dormindo', 'Saída de leito carroçável',
         'sem_vitimas', 0, 0, 1, TRUE, 'Saída de pista na madrugada, sem feridos. Motorista relatou cochilo.'),
        (c_empresa, v_motoristas[9], v_veiculos[9], 'interno', 'DEMO-OC-2',
         now() - INTERVAL '75 days', 'PR', 'Curitiba', '116', 102.0, 'Falta de atenção à condução', 'Colisão traseira',
         'com_feridos', 0, 1, 1, FALSE, 'Colisão leve em congestionamento.');

    RAISE NOTICE 'Seed concluido.';
END
$seed$;
