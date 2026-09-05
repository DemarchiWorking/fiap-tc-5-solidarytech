-- Schema do ngo_db (ngo-service)
-- Base: hackathon-DCLT @ 79f5c20, com os acrescimos comentados abaixo.

CREATE TABLE IF NOT EXISTS ngos (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(150) NOT NULL,
    email      VARCHAR(100) UNIQUE NOT NULL,
    cause      VARCHAR(100) NOT NULL, -- Ex: Protecao Animal, Educacao, Fome
    city       VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- Acrescimo: invariantes tambem no banco. Validacao so na aplicacao protege
    -- o caminho da API, mas nao protege contra carga direta ou migracao mal
    -- feita.
    CONSTRAINT ngos_name_nao_vazio  CHECK (length(trim(name))  > 0),
    CONSTRAINT ngos_email_nao_vazio CHECK (length(trim(email)) > 0),
    CONSTRAINT ngos_email_formato   CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$')
);

-- Acrescimo: a busca por causa e por cidade e o filtro natural da tela de
-- doadores. Sem indice, cada consulta e Seq Scan num db.t3.micro.
CREATE INDEX IF NOT EXISTS idx_ngos_cause ON ngos (cause);
CREATE INDEX IF NOT EXISTS idx_ngos_city  ON ngos (city);

-- Seed do repositorio original, com ON CONFLICT para tornar o script
-- idempotente: o Job de init do Kubernetes pode reexecutar em um retry, e sem
-- isso o segundo apply falharia com violacao de unique.
INSERT INTO ngos (name, email, cause, city) VALUES
    ('Anjos de Patas', 'contato@anjosdepatas.org', 'Protecao Animal', 'Osasco'),
    ('Educa Mais',     'info@educamais.org',       'Educacao',        'Sao Paulo')
ON CONFLICT (email) DO NOTHING;
