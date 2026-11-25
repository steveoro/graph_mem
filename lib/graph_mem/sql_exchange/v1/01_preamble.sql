-- Everything in this file but the staging INSERTs is graph_mem's fixed merge template (format v{{format}}).
-- Recommended: bin/rails graph_mem:import_sql FILE=<this file> [DRY_RUN=1] on the target machine. It
-- validates the file first, runs it in one transaction under the membership lock, canonicalizes the
-- staged relation types with this machine's mappings, and prints the two result tables.
-- By hand, only on a file you exported yourself (a hand run skips the validator):
--   mariadb --table <database> < <this file> > import.log
-- Never with --force: it would keep going past a failed statement and commit a partial merge.
-- A hand run skips the relation-type canonicalization (the next relation-type sweep normalizes those
-- types). Either way the script stamps project membership and checks it before COMMIT; embeddings,
-- keywords and trust scores are filled later by the background jobs. Before writing anything it refuses
-- a staged value the models would refuse (a blank name or content, a confidence outside 0..1, tags that
-- are not an array of strings, ...) and a created_at or updated_at more than a day ahead of the clock
-- here, naming the field and the row.
-- A project member with no match in its project claims a global namesake of the same type that has
-- no owned part_of parent (a reference stub's park edge doesn't own), with its part_of subtree,
-- unless a name of that subtree is taken in the project; otherwise it is inserted as a copy and the
-- report says why the namesake was not claimed.
SET NAMES utf8mb4;
SET time_zone = '+00:00';
SET SESSION sql_mode = '{{sql_mode}}';
SET @gm_lock = GET_LOCK(CONCAT('{{lock_prefix}}', ':', DATABASE()), 60);
START TRANSACTION;
DROP TEMPORARY TABLE IF EXISTS gm_stage_meta, gm_stage_entities, gm_stage_aliases, gm_stage_refs, gm_stage_observations,
  gm_stage_relations, gm_map_entities, gm_alias_candidates, gm_local_observations, gm_map_observations, gm_map_relations,
  gm_claim_candidates, gm_claim_subtree, gm_check_ids, gm_touched, gm_report;
CREATE TEMPORARY TABLE gm_stage_meta (k VARCHAR(32) NOT NULL PRIMARY KEY, v TEXT NOT NULL)
  DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
CREATE TEMPORARY TABLE gm_stage_entities (
  sk INT NOT NULL PRIMARY KEY, root_sk INT NOT NULL, name VARCHAR(255) NOT NULL, entity_type VARCHAR(255) NOT NULL,
  aliases TEXT NULL, description TEXT NULL, created_at DATETIME(6) NOT NULL, updated_at DATETIME(6) NOT NULL,
  UNIQUE KEY gm_scope_name (root_sk, name)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_stage_aliases (sk INT NOT NULL, pos INT NOT NULL, alias VARCHAR(255) NOT NULL, PRIMARY KEY (sk, pos))
  DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_stage_refs (
  sk INT NOT NULL PRIMARY KEY, project_name VARCHAR(255) NULL, name VARCHAR(255) NOT NULL, entity_type VARCHAR(255) NOT NULL
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_stage_observations (
  sk INT NOT NULL PRIMARY KEY, entity_sk INT NOT NULL, content TEXT NOT NULL, confidence FLOAT NULL, source VARCHAR(255) NULL,
  valid_from DATETIME(6) NULL, valid_until DATETIME(6) NULL, tags LONGTEXT COLLATE utf8mb4_bin NOT NULL,
  status VARCHAR(255) NOT NULL, obsoleted_at DATETIME(6) NULL, obsolescence_reason VARCHAR(255) NULL,
  perspective VARCHAR(16) NULL, superseded_by_sk INT NULL, outdated_by_sk INT NULL,
  created_at DATETIME(6) NOT NULL, updated_at DATETIME(6) NOT NULL,
  content_sha CHAR(64) AS (SHA2(content, 256)) STORED, UNIQUE KEY gm_entity_content (entity_sk, content_sha)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_stage_relations (
  sk INT NOT NULL PRIMARY KEY, from_sk INT NOT NULL, to_sk INT NOT NULL, relation_type VARCHAR(255) NOT NULL,
  weight FLOAT NULL, confidence FLOAT NULL, properties LONGTEXT COLLATE utf8mb4_bin NOT NULL,
  created_at DATETIME(6) NOT NULL, updated_at DATETIME(6) NOT NULL, UNIQUE KEY gm_edge (from_sk, to_sk, relation_type)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_map_entities (
  sk INT NOT NULL PRIMARY KEY, is_ref TINYINT NOT NULL, scope_id BIGINT NULL, target_id BIGINT NULL,
  matched_by VARCHAR(16) NULL, alias_tried TINYINT NOT NULL DEFAULT 0, action VARCHAR(16) NULL,
  newer_differs TINYINT NOT NULL DEFAULT 0, alias_suffix TEXT NULL, claim_note VARCHAR(255) NULL, changed LONGTEXT NULL,
  KEY gm_target (target_id)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_alias_candidates (sk INT NOT NULL, target_id BIGINT NOT NULL, PRIMARY KEY (sk, target_id));
CREATE TEMPORARY TABLE gm_claim_candidates (
  sk INT NOT NULL PRIMARY KEY, target_id BIGINT NOT NULL, scope_id BIGINT NOT NULL, note VARCHAR(255) NULL
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_claim_subtree (
  entity_id BIGINT NOT NULL PRIMARY KEY, sk INT NOT NULL, scope_id BIGINT NOT NULL, name VARCHAR(255) NOT NULL, KEY gm_scope_name (scope_id, name)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_local_observations (
  id BIGINT NOT NULL PRIMARY KEY, entity_id BIGINT NOT NULL, content_sha CHAR(64) NOT NULL, active TINYINT NOT NULL,
  KEY gm_entity_content (entity_id, content_sha)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_map_observations (
  sk INT NOT NULL PRIMARY KEY, entity_id BIGINT NOT NULL, target_id BIGINT NULL, action VARCHAR(16) NULL,
  status VARCHAR(255) NULL, obsoleted_at DATETIME(6) NULL, superseded_by_id BIGINT NULL, outdated_by_id BIGINT NULL,
  changed LONGTEXT NULL, KEY gm_target (target_id)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_map_relations (
  sk INT NOT NULL PRIMARY KEY, from_id BIGINT NULL, to_id BIGINT NULL, crossing TINYINT NOT NULL, part_of TINYINT NOT NULL,
  target_id BIGINT NULL, action VARCHAR(16) NULL, detail VARCHAR(255) NULL, changed LONGTEXT NULL,
  KEY gm_target (target_id), KEY gm_from (from_id)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_check_ids (id BIGINT NOT NULL PRIMARY KEY);
CREATE TEMPORARY TABLE gm_touched (
  tbl VARCHAR(32) NOT NULL, action VARCHAR(16) NOT NULL, target_id BIGINT NULL, project VARCHAR(255) NULL,
  entity VARCHAR(255) NULL, detail VARCHAR(600) NULL, changed LONGTEXT NULL
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TEMPORARY TABLE gm_report (tbl VARCHAR(32) NOT NULL, action VARCHAR(16) NOT NULL, n INT NOT NULL, PRIMARY KEY (tbl, action))
  DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
