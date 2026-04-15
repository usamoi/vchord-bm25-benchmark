-- MS MARCO Passage Ranking - Load and Index (pg_textsearch)
-- Loads the full 8.8M passage collection and creates BM25 index
--
-- Usage:
--   DATA_DIR=/path/to/data psql -f load.sql
--
-- The DATA_DIR environment variable should point to the directory containing:
--   - collection.tsv (passage_id, passage_text)
--   - queries.dev.tsv (query_id, query_text)
--   - qrels.dev.small.tsv (query_id, 0, passage_id, relevance)

\set ON_ERROR_STOP on
\timing on

\echo '=== MS MARCO Passage Ranking - Data Loading ==='
\echo 'Loading ~8.8M passages from MS MARCO collection'
\echo ''

-- Clean up existing functions

DROP TABLE IF EXISTS update_lexicon CASCADE;
DROP TABLE IF EXISTS create_lexicon CASCADE;

-- Create functions

CREATE FUNCTION update_lexicon() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    config regconfig;
    lexicon regclass;
    column_name name;
    old_column_value text;
    new_column_value text;
BEGIN
    config := TG_ARGV[0]::regconfig;
    lexicon := TG_ARGV[1]::regclass;
    column_name := TG_ARGV[2]::name;

    EXECUTE format('SELECT ($1).%I, ($2).%I', column_name, column_name)
    INTO old_column_value, new_column_value
    USING OLD, NEW;

    IF new_column_value IS NOT NULL AND new_column_value IS DISTINCT FROM old_column_value THEN
        EXECUTE format(
            'INSERT INTO %s (token)
            SELECT unnest(tsvector_to_array(to_tsvector($1, $2)))
            ON CONFLICT (token) DO NOTHING',
            lexicon
        )
        USING config, new_column_value;
    END IF;

    RETURN NEW;
END;
$$;

CREATE PROCEDURE create_lexicon(
    lexicon_name text,
    config regconfig,
    relation regclass,
    column_name name,
    trigger regproc
)
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE format('CREATE TABLE %I (id serial PRIMARY KEY, token text)', lexicon_name);

    EXECUTE format(
        'INSERT INTO %I (token)
        SELECT DISTINCT unnest(tsvector_to_array(to_tsvector($1, r.%I)))
        FROM %s AS r',
        lexicon_name,
        column_name,
        relation
    )
    USING config;

    EXECUTE format('ALTER TABLE %I ADD UNIQUE (token)', lexicon_name);
    EXECUTE format('CREATE INDEX %I ON %I USING hash (token)', lexicon_name || '_token_hash_idx', lexicon_name);

    IF trigger IS NOT NULL THEN
        EXECUTE format(
            'CREATE TRIGGER %I
            BEFORE INSERT ON %s
            FOR EACH ROW
            EXECUTE FUNCTION %s(%L, %L, %L)',
            lexicon_name || '_lexicon_insert_trigger',
            relation,
            trigger,
            config::text,
            lexicon_name,
            column_name
        );

        EXECUTE format(
            'CREATE TRIGGER %I
            BEFORE UPDATE OF %I ON %s
            FOR EACH ROW
            EXECUTE FUNCTION %s(%L, %L, %L)',
            lexicon_name || '_lexicon_update_trigger',
            column_name,
            relation,
            trigger,
            config::text,
            lexicon_name,
            column_name
        );
    END IF;

    EXECUTE format(
        'CREATE FUNCTION %I(input text)
        RETURNS int[]
        STABLE STRICT PARALLEL SAFE
        LANGUAGE sql
        AS $function$
            WITH ids AS (
                SELECT (SELECT lexicon.id FROM %I AS lexicon WHERE lexicon.token = t.lexeme) AS id
                FROM unnest(to_tsvector(%L, input)) t(lexeme, positions, weights), unnest(t.positions)
            )
            SELECT COALESCE(array_agg(id) FILTER (WHERE id IS NOT NULL), ARRAY[]::int[])
            FROM ids
        $function$',
        lexicon_name,
        lexicon_name,
        config::text
    );
END;
$$;

-- Clean up existing tables
DROP TABLE IF EXISTS msmarco_passages CASCADE;
DROP TABLE IF EXISTS msmarco_queries CASCADE;
DROP TABLE IF EXISTS msmarco_qrels CASCADE;

-- Create passages table
\echo 'Creating passages table...'
CREATE TABLE msmarco_passages (
    passage_id INTEGER PRIMARY KEY,
    passage_text TEXT NOT NULL,
    embedding bm25vector
);

-- Create queries table
\echo 'Creating queries table...'
CREATE TABLE msmarco_queries (
    query_id INTEGER PRIMARY KEY,
    query_text TEXT NOT NULL
);

-- Create relevance judgments table
\echo 'Creating relevance judgments table...'
CREATE TABLE msmarco_qrels (
    query_id INTEGER NOT NULL,
    passage_id INTEGER NOT NULL,
    relevance INTEGER NOT NULL,
    PRIMARY KEY (query_id, passage_id)
);

-- Load passages (this is the big one - 8.8M rows)
-- Convert TSV to CSV to avoid issues with \. sequences in text format
\echo 'Loading passages (this may take several minutes)...'
\copy msmarco_passages(passage_id, passage_text) FROM PROGRAM 'awk -F"\t" "{OFS=\",\"; gsub(/\"/, \"\\\"\\\"\", \$2); print \$1, \"\\\"\" \$2 \"\\\"\"}" "$DATA_DIR/collection.tsv"' WITH (FORMAT csv);

-- Load queries (use a subset for benchmarking - first 10K queries)
\echo 'Loading queries...'
\copy msmarco_queries(query_id, query_text) FROM PROGRAM 'head -10000 "$DATA_DIR/queries.dev.tsv"' WITH (FORMAT text, DELIMITER E'\t');

-- Load relevance judgments (qrels format: query_id, 0, passage_id, relevance)
\echo 'Loading relevance judgments...'
CREATE TEMP TABLE qrels_raw (
    query_id INTEGER,
    zero INTEGER,
    passage_id INTEGER,
    relevance INTEGER
);
\copy qrels_raw FROM PROGRAM 'cat "$DATA_DIR/qrels.dev.small.tsv"' WITH (FORMAT text, DELIMITER E'\t');
INSERT INTO msmarco_qrels (query_id, passage_id, relevance)
SELECT query_id, passage_id, relevance FROM qrels_raw;
DROP TABLE qrels_raw;

-- Verify data loading
\echo ''
\echo '=== Data Loading Verification ==='
SELECT 'Passages loaded:' as metric, COUNT(*)::text as count FROM msmarco_passages
UNION ALL
SELECT 'Queries loaded:', COUNT(*)::text FROM msmarco_queries
UNION ALL
SELECT 'Relevance judgments:', COUNT(*)::text FROM msmarco_qrels
ORDER BY metric;

-- Show sample data
\echo ''
\echo 'Sample passages:'
SELECT passage_id, LEFT(passage_text, 100) || '...' as passage_preview
FROM msmarco_passages
LIMIT 3;

\echo ''
\echo 'Sample queries:'
SELECT query_id, query_text
FROM msmarco_queries
LIMIT 5;

-- Create BM25 index
\echo ''
\echo '=== Building BM25 Index ==='
\echo 'Creating BM25 index on ~8.8M passages (this will take a while)...'

CALL create_lexicon('intern', 'english', 'msmarco_passages', 'passage_text', 'update_lexicon');

UPDATE msmarco_passages SET embedding = intern(passage_text);

CREATE INDEX msmarco_bm25_idx ON msmarco_passages
    USING bm25 (embedding bm25_ops);

-- Report index and table sizes
\echo ''
\echo '=== Index Size Report ==='
SELECT
    'INDEX_SIZE:' as label,
    pg_size_pretty(pg_relation_size('msmarco_bm25_idx')) as index_size,
    pg_relation_size('msmarco_bm25_idx') as index_bytes;
SELECT
    'TABLE_SIZE:' as label,
    pg_size_pretty(pg_total_relation_size('msmarco_passages')) as table_size,
    pg_total_relation_size('msmarco_passages') as table_bytes;

\echo ''
\echo '=== MS MARCO Load Complete ==='
\echo 'Ready for query benchmarks'
