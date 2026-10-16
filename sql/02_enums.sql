-- =============================================================================
-- DriveGuard — Tipos enumerados novos
--
-- Arquivo próprio por uma regra do PostgreSQL: um valor incluído com
-- ALTER TYPE ... ADD VALUE só pode ser usado depois que a transação que o
-- criou faz commit. A Lambda db_migrate roda cada arquivo numa transação, então
-- os tipos precisam nascer aqui, antes dos arquivos que os usam.
--
-- Idempotente: pode rodar várias vezes.
-- =============================================================================

SET search_path TO silver, public;

-- Tipos de alerta que o modelo passa a emitir quando a detecção de piscadas
-- entrar no dispositivo embarcado. Ficam prontos antes, para o ETL não
-- rejeitar o lote quando o primeiro chegar.
ALTER TYPE silver.tipo_alerta ADD VALUE IF NOT EXISTS 'piscadas_excessivas';
ALTER TYPE silver.tipo_alerta ADD VALUE IF NOT EXISTS 'fechamento_prolongado';

DO $$
BEGIN
    CREATE TYPE silver.status_dispositivo AS ENUM ('ativo', 'pendente', 'inativo');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.status_viagem AS ENUM ('planejada', 'em_andamento', 'concluida', 'cancelada');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.tipo_relatorio AS ENUM ('executivo', 'operacional', 'motoristas', 'frota', 'alertas');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.formato_relatorio AS ENUM ('pdf', 'xlsx', 'csv');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.status_relatorio AS ENUM ('pendente', 'gerando', 'pronto', 'erro');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.status_envio AS ENUM ('nao_solicitado', 'pendente', 'enviado', 'falhou');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE silver.frequencia_agendamento AS ENUM ('diaria', 'semanal', 'mensal');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
