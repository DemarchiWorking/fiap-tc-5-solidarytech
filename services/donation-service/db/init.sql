-- Schema do donation_db (donation-service)
-- Base: hackathon-DCLT @ 79f5c20, com os acrescimos comentados abaixo.

CREATE TABLE IF NOT EXISTS donations (
    id         SERIAL PRIMARY KEY,
    ngo_id     INT NOT NULL,
    amount     NUMERIC(10, 2) NOT NULL,
    donor_name VARCHAR(100) NOT NULL,
    status     VARCHAR(20) NOT NULL, -- APPROVED, PENDING
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- Acrescimo: as invariantes de negocio tambem no banco, e nao apenas na
    -- aplicacao. Validacao so em codigo protege o caminho da API, mas nao
    -- protege contra carga direta, migracao mal feita ou um segundo consumidor
    -- do mesmo banco.
    CONSTRAINT donations_amount_positivo CHECK (amount > 0),
    CONSTRAINT donations_ngo_id_positivo CHECK (ngo_id > 0),
    CONSTRAINT donations_status_valido   CHECK (status IN ('APPROVED', 'PENDING', 'FAILED'))
);

-- Acrescimo: a listagem do hot path ordena por id DESC com LIMIT, e os
-- relatorios por ONG filtram por ngo_id. Sem estes indices, cada consulta vira
-- Seq Scan — o que num db.t3.micro aparece direto no p95 e come error budget.
CREATE INDEX IF NOT EXISTS idx_donations_created_at ON donations (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_donations_ngo_id     ON donations (ngo_id);
