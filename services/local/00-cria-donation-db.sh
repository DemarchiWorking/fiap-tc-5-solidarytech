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
