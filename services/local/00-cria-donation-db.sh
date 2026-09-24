#!/bin/bash
# Cria o segundo database na MESMA instancia PostgreSQL.
#
# Espelha o ADR-006 (uma instancia RDS, dois databases) ja no ambiente local,
# para que desenvolvimento e producao tenham a mesma topologia de dados. Rodar
# local com dois servidores separados esconderia justamente os efeitos que a
# consolidacao introduz: contencao de conexoes e vizinho barulhento.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
    CREATE DATABASE donation_db;
SQL

# O schema do donation-service e aplicado AQUI, contra o donation_db, e nao
# montado em /docker-entrypoint-initdb.d. O entrypoint do Postgres executa todo
# .sql daquele diretorio contra o POSTGRES_DB (ngo_db): a tabela `donations`
# nascia no banco ERRADO, o donation-service conectava no donation_db vazio e
# todo POST /donations devolvia 500 ("relation donations does not exist").
#
# Ninguem viu por meses porque o healthcheck do LocalStack estava quebrado e o
# smoke nunca chegava ao hot path — um defeito escondendo o outro. No cluster
# nao acontece: la o db-init-job aplica o schema banco a banco.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname donation_db \
    -f /solidary/donation-init.sql
