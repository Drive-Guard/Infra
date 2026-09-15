-- =============================================================================
-- DriveGuard — primeira carga das MATERIALIZED VIEWs
--
-- Roda ao final da migração. As views são criadas vazias em 02 (o seed ainda
-- não tinha rodado) e só seriam preenchidas no próximo ciclo de 5 minutos da
-- Lambda etl_gold. Sem isto, o dashboard abre zerado logo depois do
-- `terraform apply` — ruim justamente na hora da demonstração.
--
-- Usa o refresh bloqueante porque a base acabou de ser criada: não há leitor
-- concorrente para proteger, e assim não dependemos de rodar fora de
-- transação (ver o comentário em 02_views_gold.sql).
-- =============================================================================

SELECT view_name, duracao_ms FROM gold.fn_refresh_bloqueante();
