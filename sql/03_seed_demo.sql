-- =============================================================================
-- DriveGuard — Dados sintéticos de demonstração
--
-- Gera volume suficiente para o dashboard e as views Gold saírem do zero
-- durante a banca. As distribuições das features seguem a literatura usada no
-- TCC (EAR ~0.31/0.24/0.16, MAR ~0.22/0.38/0.51, PERCLOS ~0.08/0.28/0.54,
-- blink rate ~17/13/8, head pitch ~0/-8/-18 para alerta/fadiga/sonolento).
--
-- Guardado por um IF: só roda se o banco estiver vazio, então é seguro
-- reexecutar a migração.
-- =============================================================================

SET search_path TO silver, public;

DO $seed$
DECLARE
    v_empresa   UUID;
    v_gestor    UUID;
    v_motorista UUID;
    v_veiculo   UUID;
    v_turno     UUID;
    v_inicio    TIMESTAMPTZ;
    v_estado    silver.estado_fadiga;
    v_score     NUMERIC(5,2);
    v_ear       NUMERIC(6,4);
    v_mar       NUMERIC(6,4);
    v_perclos   NUMERIC(6,4);
    v_blink     NUMERIC(6,2);
    v_pitch     NUMERIC(6,2);
    v_ts        TIMESTAMPTZ;
    v_dev       TEXT;
    i           INT;
    j           INT;
    k           INT;
    v_ufs       TEXT[]  := ARRAY['SP','RJ','MG','PR','RS','BA','PE','GO'];
    v_cidades   TEXT[]  := ARRAY['Sao Paulo','Rio de Janeiro','Belo Horizonte','Curitiba',
                                 'Porto Alegre','Salvador','Recife','Goiania'];
    v_nomes     TEXT[]  := ARRAY['Carlos Silva','Joao Pereira','Marcos Lima','Roberto Souza',
                                 'Antonio Costa','Paulo Mendes','Ricardo Alves','Eduardo Rocha',
                                 'Fernando Dias','Sergio Ramos','Luiz Gomes','Andre Martins',
                                 'Bruno Cardoso','Felipe Nunes','Gustavo Reis','Henrique Castro'];
    v_tipos     silver.tipo_veiculo[] := ARRAY['caminhao','onibus','van','carro_app']::silver.tipo_veiculo[];
    v_causas    TEXT[]  := ARRAY['sonolencia','velocidade incompativel','ingestao de alcool',
                                 'falta de atencao a conducao','condicoes climaticas',
                                 'defeito mecanico','ultrapassagem indevida'];
    v_motoristas UUID[] := '{}';
    v_veiculos   UUID[] := '{}';
BEGIN
    IF EXISTS (SELECT 1 FROM silver.empresas) THEN
        RAISE NOTICE 'Seed ignorado: o banco ja contem dados.';
        RETURN;
    END IF;

    RAISE NOTICE 'Gerando dados de demonstracao...';

    -- ------------------------------------------------------------------ empresa
    INSERT INTO silver.empresas (cnpj_hash, razao_social, nome_fantasia, uf, cidade)
    VALUES (encode(digest('12345678000199', 'sha256'), 'hex'),
            'Transportadora Rodoviaria Demo LTDA', 'DriveGuard Demo', 'SP', 'Sao Paulo')
    RETURNING id INTO v_empresa;

    -- ------------------------------------------------------------------ usuario
    INSERT INTO silver.usuarios (empresa_id, email_hash, nome, papel)
    VALUES (v_empresa, encode(digest('gestor@demo.driveguard', 'sha256'), 'hex'),
            'Gestor de Frota Demo', 'gestor')
    RETURNING id INTO v_gestor;

    -- ------------------------------------------------------------------ veiculos
    FOR i IN 1..16 LOOP
        INSERT INTO silver.veiculos (empresa_id, placa_hash, tipo, modelo, ano_fabricacao,
                                     capacidade_passageiros)
        VALUES (v_empresa,
                encode(digest('PLACA-' || i::TEXT, 'sha256'), 'hex'),
                v_tipos[1 + (i % 4)],
                (ARRAY['Volvo FH 460','Scania R450','Mercedes O500','Iveco Daily'])[1 + (i % 4)],
                2015 + (i % 9),
                CASE WHEN v_tipos[1 + (i % 4)] = 'onibus' THEN 44 ELSE NULL END)
        RETURNING id INTO v_veiculo;
        v_veiculos := array_append(v_veiculos, v_veiculo);
    END LOOP;

    -- ------------------------------------------------------------------ motoristas
    FOR i IN 1..16 LOOP
        INSERT INTO silver.motoristas (empresa_id, usuario_id, motorista_hash, nome_exibicao,
                                       idade, anos_experiencia, categoria_cnh, cnh_valida_ate,
                                       regiao_uf, status, baseline_ear)
        VALUES (v_empresa, NULL,
                encode(digest('MOTORISTA-' || i::TEXT, 'sha256'), 'hex'),
                v_nomes[i],
                28 + (i * 2) % 32,
                1 + (i * 3) % 25,
                'E',
                CURRENT_DATE + ((i % 24) || ' months')::INTERVAL,
                v_ufs[1 + (i % 8)],
                'ativo',
                0.2900 + (i % 5) * 0.0100)
        RETURNING id INTO v_motorista;
        v_motoristas := array_append(v_motoristas, v_motorista);
    END LOOP;

    -- ------------------------------------------------------------------ turnos + leituras
    -- 16 motoristas x 6 turnos nos ultimos 14 dias x ~24 leituras por turno
    FOR i IN 1..16 LOOP
        v_dev := 'dg-edge-' || lpad(i::TEXT, 4, '0');

        FOR j IN 1..6 LOOP
            v_inicio := now()
                        - ((j * 2 + (i % 3)) || ' days')::INTERVAL
                        - ((6 + (i * j) % 14) || ' hours')::INTERVAL;

            INSERT INTO silver.turnos (motorista_id, veiculo_id, device_id, iniciado_em,
                                       finalizado_em, origem_cidade, origem_uf,
                                       destino_cidade, destino_uf, distancia_km, status)
            VALUES (v_motoristas[i], v_veiculos[i], v_dev,
                    v_inicio,
                    v_inicio + ((6 + (i + j) % 5) || ' hours')::INTERVAL,
                    v_cidades[1 + (i % 8)], v_ufs[1 + (i % 8)],
                    v_cidades[1 + ((i + 3) % 8)], v_ufs[1 + ((i + 3) % 8)],
                    180 + ((i * j * 37) % 620),
                    'concluido')
            RETURNING id INTO v_turno;

            -- Leituras a cada 15 min. A fadiga cresce com o tempo de direcao e
            -- e agravada em turnos que atravessam a madrugada.
            FOR k IN 0..23 LOOP
                v_ts := v_inicio + (k * 15 || ' minutes')::INTERVAL;

                v_score := LEAST(99.0,
                    12                                              -- base
                    + k * 2.4                                       -- desgaste ao longo do turno
                    + CASE WHEN EXTRACT(HOUR FROM v_ts) BETWEEN 0 AND 5
                           THEN 22 ELSE 0 END                       -- janela circadiana critica
                    + (i % 4) * 3                                   -- variacao entre motoristas
                    + (random() * 10 - 5)
                );
                v_score := GREATEST(v_score, 3.0);

                v_estado := CASE
                    WHEN v_score >= 75 THEN 'sonolento'
                    WHEN v_score >= 45 THEN 'fadiga'
                    ELSE 'alerta'
                END::silver.estado_fadiga;

                -- Features coerentes com o estado (medias da literatura + ruido)
                v_ear     := CASE v_estado WHEN 'alerta' THEN 0.31 WHEN 'fadiga' THEN 0.24 ELSE 0.16 END
                             + (random() * 0.04 - 0.02);
                v_mar     := CASE v_estado WHEN 'alerta' THEN 0.22 WHEN 'fadiga' THEN 0.38 ELSE 0.51 END
                             + (random() * 0.06 - 0.03);
                v_perclos := CASE v_estado WHEN 'alerta' THEN 0.08 WHEN 'fadiga' THEN 0.28 ELSE 0.54 END
                             + (random() * 0.06 - 0.03);
                v_blink   := CASE v_estado WHEN 'alerta' THEN 17 WHEN 'fadiga' THEN 13 ELSE 8 END
                             + (random() * 4 - 2);
                v_pitch   := CASE v_estado WHEN 'alerta' THEN 0 WHEN 'fadiga' THEN -8 ELSE -18 END
                             + (random() * 5 - 2.5);

                INSERT INTO silver.leituras_fadiga (
                    turno_id, motorista_id, veiculo_id, device_id, registrado_em,
                    ear, mar, perclos, blink_rate, duracao_olhos_fechados_ms,
                    head_pitch, head_yaw, head_roll,
                    score_fadiga, estado, latitude, longitude, velocidade_kmh,
                    ingest_id, bronze_key
                ) VALUES (
                    v_turno, v_motoristas[i], v_veiculos[i], v_dev, v_ts,
                    GREATEST(v_ear, 0.05), GREATEST(v_mar, 0.05), LEAST(GREATEST(v_perclos, 0), 1),
                    GREATEST(v_blink, 1), (120 + v_perclos * 900)::INT,
                    v_pitch, (random() * 10 - 5), (random() * 6 - 3),
                    ROUND(v_score, 2), v_estado,
                    -23.55 + (random() * 8 - 4), -46.63 + (random() * 8 - 4),
                    CASE WHEN random() < 0.1 THEN 0 ELSE 60 + random() * 45 END,
                    gen_random_uuid(), 'seed/demo'
                )
                ON CONFLICT (device_id, registrado_em) DO NOTHING;

                -- Alerta sempre que cruza o limiar de sonolencia
                IF v_score >= 75 AND random() < 0.55 THEN
                    INSERT INTO silver.alertas (turno_id, motorista_id, veiculo_id, disparado_em,
                                                tipo, gravidade, status, score_fadiga, mensagem,
                                                reconhecido_por, reconhecido_em)
                    VALUES (
                        v_turno, v_motoristas[i], v_veiculos[i], v_ts,
                        CASE WHEN v_perclos > 0.5 THEN 'microssono'
                             WHEN v_mar > 0.5     THEN 'bocejo_excessivo'
                             WHEN v_pitch < -15   THEN 'cabeca_baixa'
                             ELSE 'sonolencia' END::silver.tipo_alerta,
                        CASE WHEN v_score >= 90 THEN 'critica'
                             WHEN v_score >= 82 THEN 'alta'
                             ELSE 'media' END::silver.gravidade,
                        CASE WHEN random() < 0.7 THEN 'resolvido' ELSE 'aberto' END::silver.status_alerta,
                        ROUND(v_score, 2),
                        'Score de fadiga em ' || ROUND(v_score, 0) || ' apos '
                            || ROUND(k * 0.25, 1) || 'h de conducao.',
                        CASE WHEN random() < 0.7 THEN v_gestor ELSE NULL END,
                        CASE WHEN random() < 0.7 THEN v_ts + INTERVAL '4 minutes' ELSE NULL END
                    )
                    ON CONFLICT (motorista_id, disparado_em, tipo) DO NOTHING;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;

    -- ------------------------------------------------------------------ acoes
    INSERT INTO silver.acoes_motorista (motorista_id, alerta_id, tipo, descricao, realizado_por,
                                        realizado_em, eficaz)
    SELECT a.motorista_id, a.id,
           CASE WHEN a.gravidade = 'critica' THEN 'encerramento_turno'
                WHEN a.gravidade = 'alta'    THEN 'pausa_obrigatoria'
                ELSE 'contato_telefonico' END::silver.tipo_acao,
           'Acao disparada a partir do alerta de ' || a.tipo::TEXT,
           v_gestor,
           a.disparado_em + INTERVAL '6 minutes',
           random() < 0.85
    FROM silver.alertas a
    WHERE a.status = 'resolvido' AND random() < 0.4;

    -- ------------------------------------------------------------------ incidentes (proxy PRF)
    FOR i IN 1..900 LOOP
        v_ts := now() - ((random() * 330)::INT || ' days')::INTERVAL
                      - ((random() * 24)::INT || ' hours')::INTERVAL;
        -- Concentra acidentes na madrugada, como no dado real da PRF
        IF random() < 0.35 THEN
            v_ts := date_trunc('day', v_ts) + ((random() * 6)::INT || ' hours')::INTERVAL;
        END IF;

        INSERT INTO silver.incidentes (
            empresa_id, origem, origem_id_externo, ocorrido_em, uf, municipio, br, km,
            latitude, longitude, causa, tipo_acidente, gravidade,
            qtd_mortos, qtd_feridos, qtd_ilesos, fase_dia, condicao_meteorologica,
            tracado_via, relacionado_sonolencia
        )
        SELECT
            v_empresa, 'prf', 'PRF-' || i::TEXT, v_ts,
            v_ufs[1 + (i % 8)], v_cidades[1 + (i % 8)],
            (ARRAY['101','116','153','163','262','381'])[1 + (i % 6)],
            ROUND((random() * 900)::NUMERIC, 2),
            -23.55 + (random() * 16 - 8), -46.63 + (random() * 16 - 8),
            c.causa,
            (ARRAY['colisao traseira','saida de pista','tombamento','colisao frontal'])[1 + (i % 4)],
            (ARRAY['sem_vitimas','com_feridos','com_fatais'])[
                CASE WHEN random() < 0.55 THEN 1 WHEN random() < 0.85 THEN 2 ELSE 3 END
            ]::silver.gravidade_incidente,
            CASE WHEN random() < 0.08 THEN 1 + (random() * 2)::INT ELSE 0 END,
            CASE WHEN random() < 0.40 THEN 1 + (random() * 3)::INT ELSE 0 END,
            (random() * 4)::INT,
            CASE WHEN EXTRACT(HOUR FROM v_ts) BETWEEN 6 AND 17 THEN 'dia' ELSE 'noite' END,
            (ARRAY['ceu claro','chuva','nublado','neblina'])[1 + (i % 4)],
            (ARRAY['reta','curva','outros'])[1 + (i % 3)],
            c.causa = 'sonolencia'
        FROM (SELECT v_causas[1 + (i % 7)] AS causa) c
        ON CONFLICT (origem, origem_id_externo) DO NOTHING;
    END LOOP;

    -- ------------------------------------------------------------------ insights
    INSERT INTO silver.insights_frota (empresa_id, titulo, descricao, severidade, acao_sugerida,
                                       metrica_referencia, origem, valido_ate)
    VALUES
      (v_empresa, 'Pico de fadiga na madrugada',
       'Turnos entre 0h e 5h concentram score medio 38% acima da media geral da frota.',
       'alta', 'Revisar escala noturna e impor pausa a cada 3h',
       jsonb_build_object('janela', '00:00-05:00', 'delta_score_pct', 38), 'regra',
       now() + INTERVAL '7 days'),
      (v_empresa, 'Queda de desempenho apos 5h de direcao',
       'O score de fadiga cresce de forma consistente a partir da quinta hora de conducao continua.',
       'media', 'Programar pausa obrigatoria de 20 min na quinta hora',
       jsonb_build_object('hora_limite', 5), 'modelo',
       now() + INTERVAL '7 days');

    INSERT INTO silver.insights_motorista (motorista_id, titulo, descricao, severidade,
                                           acao_sugerida, metrica_referencia, origem, valido_ate)
    SELECT r.motorista_id,
           'Score de fadiga acima do limite da frota',
           'Media de ' || r.score_medio || ' nos ultimos 30 dias, contra ~45 da frota.',
           'alta',
           'Agendar pausa de 20 min e reavaliar a escala',
           jsonb_build_object('score_medio_30d', r.score_medio),
           'modelo',
           now() + INTERVAL '7 days'
    FROM (
        SELECT motorista_id, ROUND(AVG(score_fadiga), 1) AS score_medio
        FROM silver.leituras_fadiga
        GROUP BY motorista_id
        HAVING AVG(score_fadiga) > 55
        LIMIT 6
    ) r;

    -- ------------------------------------------------------------------ previsoes
    INSERT INTO silver.previsoes_fadiga (motorista_id, turno_id, horizonte_minutos, probabilidade,
                                         score_previsto, classe_prevista, modelo_nome,
                                         modelo_versao, features)
    SELECT t.motorista_id, t.id, 60,
           ROUND((0.25 + random() * 0.7)::NUMERIC, 4),
           ROUND((40 + random() * 55)::NUMERIC, 2),
           (ARRAY['alerta','fadiga','sonolento'])[1 + (random() * 2.99)::INT]::silver.estado_fadiga,
           'xgboost-fadiga', 'v1.0.0',
           jsonb_build_object('ear', 0.22, 'mar', 0.41, 'perclos', 0.31,
                              'blink_rate', 12.4, 'head_pitch', -9.2)
    FROM silver.turnos t
    ORDER BY t.iniciado_em DESC
    LIMIT 40;

    RAISE NOTICE 'Seed concluido.';
END
$seed$;
