-- PostgreSQL initialization script.
-- Runs once on first container start (mounted at /docker-entrypoint-initdb.d/init.sql).
-- The dev database (POSTGRES_DB, default `beai`) is ALREADY created by the
-- postgres entrypoint before this script runs — do NOT re-create it here, or
-- `CREATE DATABASE beai` fails ("already exists") and, under ON_ERROR_STOP=1,
-- aborts the rest of the script (leaving beai_test uncreated). We only create
-- the sibling test database and enable pgVector in both.
-- The `vector` extension is bundled in pgvector/pgvector:0.8.0-pg17.

-- Test database (used by Pest with RefreshDatabase; never the dev database).
CREATE DATABASE beai_test
    WITH
    OWNER = postgres
    ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.utf8'
    LC_CTYPE = 'en_US.utf8'
    TEMPLATE = template0;

GRANT ALL PRIVILEGES ON DATABASE beai_test TO postgres;

-- Enable pgVector in the development database (beai, already created by POSTGRES_DB).
\c beai
CREATE EXTENSION IF NOT EXISTS vector;

-- Enable pgVector in the test database.
\c beai_test
CREATE EXTENSION IF NOT EXISTS vector;
