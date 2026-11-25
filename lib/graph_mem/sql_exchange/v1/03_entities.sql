-- Entities. A staged row matches by (scope, name), compared like the unique key (utf8mb4_general_ci):
-- Project roots and globals in the global scope (0), members inside their mapped root. Fallback: exactly
-- one same-type entity of that scope whose alias is the incoming name, or whose name is an incoming
-- alias, that no other staged row claims. Anything else is inserted.
INSERT INTO gm_map_entities (sk, is_ref, scope_id) SELECT sk, 0, IF(root_sk = 0, 0, NULL) FROM gm_stage_entities;
INSERT INTO gm_map_entities (sk, is_ref, scope_id) SELECT sk, 1, NULL FROM gm_stage_refs;
UPDATE gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN memory_entities e ON e.project_scope = 0 AND e.name = s.name
  SET m.target_id = e.id, m.matched_by = 'name' WHERE s.root_sk = 0;
DELIMITER //
BEGIN NOT ATOMIC
  DECLARE clash VARCHAR(255) DEFAULT NULL;
  DECLARE msg VARCHAR(512) DEFAULT NULL;
  SET clash = (SELECT s.name FROM gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN memory_entities e ON e.id = m.target_id
               WHERE (s.entity_type = 'Project') <> (e.entity_type = 'Project') ORDER BY s.sk LIMIT 1);
  IF clash IS NOT NULL THEN
    SET msg = CONCAT('graph_mem-sql: "', clash, '" is a Project on one side and not on the other; rename one of them first');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
  END IF;
END//
DELIMITER ;
INSERT INTO gm_alias_candidates (sk, target_id)
  SELECT m.sk, e.id FROM gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk
  JOIN memory_entities e ON e.project_scope = m.scope_id AND e.entity_type = s.entity_type
  WHERE m.is_ref = 0 AND m.target_id IS NULL AND m.scope_id IS NOT NULL AND m.alias_tried = 0
    AND (LOCATE(CONCAT('|', LOWER(TRIM(s.name)), '|'),
                CONCAT('|', REGEXP_REPLACE(LOWER(TRIM(COALESCE(e.aliases, ''))), '[[:space:]]*[,|;][[:space:]]*', '|'), '|')) > 0
         OR EXISTS (SELECT 1 FROM gm_stage_aliases a WHERE a.sk = s.sk AND a.alias = e.name))
    AND NOT EXISTS (SELECT 1 FROM gm_map_entities t WHERE t.target_id = e.id);
UPDATE gm_map_entities m
  JOIN (SELECT sk, MIN(target_id) AS target_id FROM gm_alias_candidates GROUP BY sk HAVING COUNT(*) = 1) c ON c.sk = m.sk
  JOIN (SELECT target_id FROM gm_alias_candidates GROUP BY target_id HAVING COUNT(*) = 1) u ON u.target_id = c.target_id
  SET m.target_id = c.target_id, m.matched_by = 'alias';
UPDATE gm_map_entities m JOIN gm_alias_candidates c ON c.sk = m.sk SET m.matched_by = 'ambiguous' WHERE m.target_id IS NULL;
UPDATE gm_map_entities SET alias_tried = 1 WHERE is_ref = 0 AND scope_id IS NOT NULL;
DELETE FROM gm_alias_candidates;
-- Members of a matched root: by name in its scope, then the same alias fallback.
UPDATE gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN gm_map_entities r ON r.sk = s.root_sk
  SET m.scope_id = r.target_id WHERE s.root_sk <> 0 AND r.target_id IS NOT NULL;
UPDATE gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN memory_entities e ON e.project_scope = m.scope_id AND e.name = s.name
  SET m.target_id = e.id, m.matched_by = 'name' WHERE s.root_sk <> 0 AND m.target_id IS NULL;
INSERT INTO gm_alias_candidates (sk, target_id)
  SELECT m.sk, e.id FROM gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk
  JOIN memory_entities e ON e.project_scope = m.scope_id AND e.entity_type = s.entity_type
  WHERE m.is_ref = 0 AND m.target_id IS NULL AND m.scope_id IS NOT NULL AND m.alias_tried = 0
    AND (LOCATE(CONCAT('|', LOWER(TRIM(s.name)), '|'),
                CONCAT('|', REGEXP_REPLACE(LOWER(TRIM(COALESCE(e.aliases, ''))), '[[:space:]]*[,|;][[:space:]]*', '|'), '|')) > 0
         OR EXISTS (SELECT 1 FROM gm_stage_aliases a WHERE a.sk = s.sk AND a.alias = e.name))
    AND NOT EXISTS (SELECT 1 FROM gm_map_entities t WHERE t.target_id = e.id);
UPDATE gm_map_entities m
  JOIN (SELECT sk, MIN(target_id) AS target_id FROM gm_alias_candidates GROUP BY sk HAVING COUNT(*) = 1) c ON c.sk = m.sk
  JOIN (SELECT target_id FROM gm_alias_candidates GROUP BY target_id HAVING COUNT(*) = 1) u ON u.target_id = c.target_id
  SET m.target_id = c.target_id, m.matched_by = 'alias';
UPDATE gm_map_entities m JOIN gm_alias_candidates c ON c.sk = m.sk SET m.matched_by = 'ambiguous' WHERE m.target_id IS NULL;
-- New rows, the global scope first (a new root's members take its id), with the source timestamps.
-- New rows get the column defaults for everything else (embedded_at NULL, cloud access off).
INSERT INTO memory_entities (name, entity_type, aliases, description, memory_observations_count, project_id, created_at, updated_at)
  SELECT s.name, s.entity_type, s.aliases, s.description, 0, NULL, s.created_at, s.updated_at
  FROM gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk WHERE s.root_sk = 0 AND m.target_id IS NULL ORDER BY s.sk;
UPDATE gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN memory_entities e ON e.project_scope = 0 AND e.name = s.name
  SET m.target_id = e.id, m.action = 'new' WHERE s.root_sk = 0 AND m.target_id IS NULL;
UPDATE gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN gm_map_entities r ON r.sk = s.root_sk
  SET m.scope_id = r.target_id WHERE s.root_sk <> 0 AND m.scope_id IS NULL;
-- Claims (as the JSON import does): a member with no match in its project takes over a global entity
-- of the same name and type that has no owned part_of parent (a reference stub's park edge doesn't
-- own; a stub another project also declares stays shared), with its owned part_of subtree, all of it
-- stamped into the project, unless a name of that subtree is taken there. Otherwise a copy is
-- inserted and claim_note says why. A Project is never claimed.
INSERT INTO gm_claim_candidates (sk, target_id, scope_id, note)
  SELECT m.sk, e.id, m.scope_id,
    CASE WHEN e.entity_type = 'Project' THEN 'it is a Project'
         WHEN e.entity_type <> s.entity_type THEN CONCAT('its type is ', e.entity_type)
         WHEN EXISTS (SELECT 1 FROM memory_relations p WHERE p.from_entity_id = e.id AND p.relation_type = 'part_of'
                        AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(p.properties, '$.reference_stub')), 'false') <> 'true') THEN 'it has a part_of parent'
         WHEN (SELECT COUNT(*) FROM memory_relations p WHERE p.from_entity_id = e.id AND p.relation_type = 'part_of') > 1 THEN 'it has several part_of edges'
         WHEN EXISTS (SELECT 1 FROM memory_relations p WHERE p.from_entity_id = e.id AND p.relation_type = 'part_of')
          AND EXISTS (SELECT 1 FROM memory_entities o WHERE o.name = e.name AND o.entity_type = e.entity_type AND o.project_scope NOT IN (0, m.scope_id))
           THEN 'it is a reference stub another project also declares'
         WHEN EXISTS (SELECT 1 FROM gm_map_entities t WHERE t.target_id = e.id) THEN 'another staged entity matched it' END
  FROM gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN memory_entities e ON e.project_scope = 0 AND e.name = s.name
  WHERE s.root_sk <> 0 AND m.target_id IS NULL AND m.scope_id IS NOT NULL;
UPDATE gm_claim_candidates c JOIN (SELECT target_id FROM gm_claim_candidates GROUP BY target_id HAVING COUNT(*) > 1) d ON d.target_id = c.target_id
  SET c.note = 'two staged entities would claim it' WHERE c.note IS NULL;
INSERT INTO gm_claim_subtree (entity_id, sk, scope_id, name)
  WITH RECURSIVE down (sk, entity_id, scope_id) AS (
    SELECT sk, target_id, scope_id FROM gm_claim_candidates WHERE note IS NULL
    UNION SELECT d.sk, r.from_entity_id, d.scope_id FROM down d
      JOIN memory_relations r ON r.to_entity_id = d.entity_id AND r.relation_type = 'part_of'
       AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(r.properties, '$.reference_stub')), 'false') <> 'true'
      JOIN memory_entities c ON c.id = r.from_entity_id AND c.entity_type <> 'Project')
  SELECT d.entity_id, d.sk, d.scope_id, e.name FROM down d JOIN memory_entities e ON e.id = d.entity_id;
UPDATE gm_claim_candidates c SET c.note = 'a name of its part_of subtree is taken in the project, or the subtree is not global'
  WHERE c.note IS NULL
    AND (EXISTS (SELECT 1 FROM gm_claim_subtree t JOIN memory_entities x ON x.project_scope = t.scope_id AND x.name = t.name WHERE t.sk = c.sk)
         OR EXISTS (SELECT 1 FROM gm_claim_subtree t JOIN gm_claim_subtree u ON u.scope_id = t.scope_id AND u.name = t.name AND u.sk <> t.sk WHERE t.sk = c.sk)
         OR EXISTS (SELECT 1 FROM gm_claim_subtree t JOIN memory_entities x ON x.id = t.entity_id WHERE t.sk = c.sk AND x.project_id IS NOT NULL));
DELETE FROM gm_claim_subtree WHERE sk IN (SELECT sk FROM gm_claim_candidates WHERE note IS NOT NULL);
UPDATE gm_map_entities m JOIN gm_claim_candidates c ON c.sk = m.sk
  SET m.target_id = IF(c.note IS NULL, c.target_id, NULL), m.matched_by = IF(c.note IS NULL, 'claim', m.matched_by), m.claim_note = c.note;
UPDATE memory_entities e JOIN gm_claim_subtree t ON t.entity_id = e.id SET e.project_id = t.scope_id;
UPDATE gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN memory_entities e ON e.project_scope = m.scope_id AND e.name = s.name
  SET m.target_id = e.id, m.matched_by = 'name' WHERE s.root_sk <> 0 AND m.target_id IS NULL;
UPDATE gm_map_entities m JOIN gm_claim_subtree t ON t.entity_id = m.target_id SET m.matched_by = 'claim';
INSERT INTO memory_entities (name, entity_type, aliases, description, memory_observations_count, project_id, created_at, updated_at)
  SELECT s.name, s.entity_type, s.aliases, s.description, 0, m.scope_id, s.created_at, s.updated_at
  FROM gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk WHERE s.root_sk <> 0 AND m.target_id IS NULL ORDER BY s.sk;
UPDATE gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN memory_entities e ON e.project_scope = m.scope_id AND e.name = s.name
  SET m.target_id = e.id, m.action = 'new' WHERE s.root_sk <> 0 AND m.target_id IS NULL;
-- References (the other end of an edge crossing the export's boundary) are only looked up, never written.
UPDATE gm_map_entities m JOIN gm_stage_refs r ON r.sk = m.sk
  LEFT JOIN memory_entities p ON r.project_name IS NOT NULL AND p.project_scope = 0 AND p.name = r.project_name AND p.entity_type = 'Project'
  JOIN memory_entities e ON e.project_scope = IF(r.project_name IS NULL, 0, p.id) AND e.name = r.name AND e.entity_type = r.entity_type
  SET m.target_id = e.id, m.scope_id = e.project_scope, m.action = 'ref';
-- Matched rows: aliases are always unioned (the local ones stay as written, missing ones are appended
-- with |; on an alias match the incoming name is one of them); entity_type and description are taken
-- when the incoming row is newer. Any change clears embedded_at; the vector is left to the backfill.
INSERT INTO gm_stage_aliases (sk, pos, alias)
  SELECT s.sk, -1, s.name FROM gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk WHERE m.matched_by = 'alias';
UPDATE gm_map_entities m JOIN memory_entities e ON e.id = m.target_id
  SET m.alias_suffix = (SELECT GROUP_CONCAT(a.alias ORDER BY a.pos SEPARATOR '|') FROM gm_stage_aliases a
                        WHERE a.sk = m.sk AND a.alias <> e.name
                          AND LOCATE(CONCAT('|', LOWER(TRIM(a.alias)), '|'),
                                     CONCAT('|', REGEXP_REPLACE(LOWER(TRIM(COALESCE(e.aliases, ''))), '[[:space:]]*[,|;][[:space:]]*', '|'), '|')) = 0)
  WHERE m.is_ref = 0 AND m.action IS NULL;
UPDATE gm_map_entities m JOIN memory_entities e ON e.id = m.target_id JOIN gm_stage_entities s ON s.sk = m.sk
  SET m.newer_differs = s.updated_at > e.updated_at AND NOT (BINARY e.entity_type <=> BINARY s.entity_type AND BINARY e.description <=> BINARY s.description),
      m.changed = JSON_MERGE_PRESERVE('{}',
        IF(BINARY e.entity_type <=> BINARY s.entity_type, '{}', JSON_OBJECT('entity_type', JSON_OBJECT('from', e.entity_type, 'to', s.entity_type))),
        IF(BINARY e.description <=> BINARY s.description, '{}', JSON_OBJECT('description', JSON_OBJECT('from', e.description, 'to', s.description))))
  WHERE m.is_ref = 0 AND m.action IS NULL;
-- A claimed row (the claimed entity, or one of its subtree a staged member matched) is "claimed": its
-- project_id change is listed with what newer-wins and the alias union write.
UPDATE gm_map_entities m JOIN memory_entities e ON e.id = m.target_id
  SET m.action = CASE WHEN m.matched_by = 'claim' THEN 'claimed' WHEN m.newer_differs = 1 OR m.alias_suffix IS NOT NULL THEN 'updated'
                      WHEN m.changed <> '{}' THEN 'kept_local' ELSE 'unchanged' END,
      m.changed = JSON_MERGE_PRESERVE(IF(m.newer_differs = 1 OR (m.alias_suffix IS NULL AND m.matched_by <> 'claim'), m.changed, '{}'),
        IF(m.alias_suffix IS NULL, '{}', JSON_OBJECT('aliases', JSON_OBJECT('from', e.aliases, 'to', CONCAT_WS('|', NULLIF(e.aliases, ''), m.alias_suffix)))),
        IF(m.matched_by = 'claim', JSON_OBJECT('project_id', JSON_OBJECT('from', NULL, 'to', e.project_id)), '{}'))
  WHERE m.is_ref = 0 AND m.action IS NULL;
UPDATE memory_entities e JOIN gm_map_entities m ON m.target_id = e.id AND m.is_ref = 0 AND m.action IN ('updated', 'claimed')
  JOIN gm_stage_entities s ON s.sk = m.sk
  SET e.embedded_at = IF(m.newer_differs = 1 OR m.alias_suffix IS NOT NULL, NULL, e.embedded_at),
      e.entity_type = IF(m.newer_differs = 1, s.entity_type, e.entity_type),
      e.description = IF(m.newer_differs = 1, s.description, e.description),
      e.aliases = IF(m.alias_suffix IS NULL, e.aliases, CONCAT_WS('|', NULLIF(e.aliases, ''), m.alias_suffix)),
      e.updated_at = IF(m.newer_differs = 1 OR m.alias_suffix IS NOT NULL, GREATEST(e.updated_at, s.updated_at), e.updated_at);
