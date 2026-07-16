-- PostgreSQL initialization script.
-- Runs once on first container start (mounted at /docker-entrypoint-initdb.d/init.sql).
-- Creates the development and test databases with the configured user.
-- The superuser role (POSTGRES_USER) already owns the default database (POSTGRES_DB);
-- we only need to create the sibling databases here.

-- Enable pgVector extension in both databases (required for AI embedding features in C8+).
-- The extension is bundled in pgvector/pgvector:pg17-alpine.

-- Development database
CREATE DATABASE beai
    WITH
    OWNER = postgres
    ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.utf8'
    LC_CTYPE = 'en_US.utf8'
    TEMPLATE = template0;

-- Test database (used by Pest with RefreshDatabase; never the dev database)
CREATE DATABASE beai_test
    WITH
    OWNER = postgres
    ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.utf8'
    LC_CTYPE = 'en_US.utf8'
    TEMPLATE = template0;

-- Grant full privileges to the application user on both databases.
-- POSTGRES_USER is postgres by default in the compose config.
GRANT ALL PRIVILEGES ON DATABASE beai TO postgres;
GRANT ALL PRIVILEGES ON DATABASE beai_test TO postgres;

-- Enable pgVector in the development database.
\c beai
CREATE EXTENSION IF NOT EXISTS vector;

-- Enable pgVector in the test database.
\c beai_test
CREATE EXTENSION IF NOT EXISTS vector;
