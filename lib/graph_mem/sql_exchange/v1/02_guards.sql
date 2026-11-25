-- Guards: each one stops the script before anything is written (SIGNAL rolls the transaction back).
-- After the structure, the staged values: this path skips the validations of the models, so a value that
-- MemoryEntity, MemoryObservation or MemoryRelation would refuse is refused here, the message naming the
-- field and the row (blank as Rails reads it: empty or only whitespace, Unicode spaces included). Tags or
-- properties that are not JSON at all are left to the json_valid CHECK of the tables, which refuses the write.
-- The lifecycle links are mapped by the merge and checked after it (06).
DELIMITER //
BEGIN NOT ATOMIC
  DECLARE here VARCHAR(255) DEFAULT NULL;
  DECLARE theirs VARCHAR(255) DEFAULT NULL;
  DECLARE msg VARCHAR(512) DEFAULT NULL;
  DECLARE blank VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci
    DEFAULT '^[[:space:]\\x{85}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}]*$';
  SET here = (SELECT MAX(version) FROM schema_migrations);
  SET theirs = (SELECT v FROM gm_stage_meta WHERE k = 'schema');
  IF COALESCE(@gm_lock, 0) <> 1 THEN
    SET msg = 'graph_mem-sql: the membership lock stayed busy for 60 s (an import, backfill, move or merge holds it); try again shortly';
  ELSEIF theirs IS NULL OR here < theirs THEN
    SET msg = CONCAT('graph_mem-sql: this database is at schema ', here, ', older than the schema of the script (', COALESCE(theirs, 'none'), '); upgrade graph_mem here first');
  ELSEIF here > '{{max_schema}}' THEN
    SET msg = CONCAT('graph_mem-sql v{{format}} supports schemas up to {{max_schema}}, this database is at schema ', here, '; upgrade graph_mem on the source machine and export again');
  ELSEIF EXISTS (SELECT 1 FROM gm_stage_entities s LEFT JOIN gm_stage_entities r ON r.sk = s.root_sk
                 WHERE s.root_sk <> 0 AND (r.sk IS NULL OR r.root_sk <> 0 OR r.entity_type <> 'Project' OR s.entity_type = 'Project')) THEN
    SET msg = 'graph_mem-sql: a staged member has no staged Project root, or a Project is staged as a member';
  ELSEIF EXISTS (SELECT 1 FROM gm_stage_refs r JOIN gm_stage_entities s ON s.sk = r.sk) THEN
    SET msg = 'graph_mem-sql: a staging key names both an entity and a reference';
  ELSEIF EXISTS (SELECT 1 FROM gm_stage_observations o LEFT JOIN gm_stage_entities s ON s.sk = o.entity_sk WHERE s.sk IS NULL) THEN
    SET msg = 'graph_mem-sql: a staged observation has no staged entity';
  ELSEIF EXISTS (SELECT 1 FROM gm_stage_relations r
                 LEFT JOIN gm_stage_entities fe ON fe.sk = r.from_sk LEFT JOIN gm_stage_refs fr ON fr.sk = r.from_sk
                 LEFT JOIN gm_stage_entities te ON te.sk = r.to_sk LEFT JOIN gm_stage_refs tr ON tr.sk = r.to_sk
                 WHERE (fe.sk IS NULL AND fr.sk IS NULL) OR (te.sk IS NULL AND tr.sk IS NULL) OR (fe.sk IS NULL AND te.sk IS NULL)) THEN
    SET msg = 'graph_mem-sql: a staged relation has an end that is not staged, or two references as ends';
  END IF;
  -- MemoryEntity: name and entity_type present; a Project as membership reads it (under the collation)
  -- must be exactly Project, the type the project_id of its members must point at.
  IF msg IS NULL THEN
    SET msg = LEFT((SELECT CONCAT('graph_mem-sql: memory_entities.', problem, ' (staged entity ', sk, ')') FROM (
                      SELECT sk, CASE WHEN name REGEXP blank THEN 'name is blank'
                                      WHEN entity_type REGEXP blank THEN CONCAT('entity_type is blank for "', name, '"')
                                      WHEN entity_type = 'Project' AND BINARY entity_type <> 'Project'
                                        THEN CONCAT('entity_type "', entity_type, '" of "', name, '" is not exactly Project')
                                 END AS problem
                      FROM gm_stage_entities) v
                    WHERE problem IS NOT NULL ORDER BY sk LIMIT 1), 512);
  END IF;
  -- MemoryObservation: status one of STATUSES, content present, confidence 0..1 or NULL, perspective one
  -- of PERSPECTIVES or NULL, valid_until not before valid_from, tags an array of strings.
  IF msg IS NULL THEN
    SET msg = LEFT((SELECT CONCAT('graph_mem-sql: memory_observations.', problem, ' (staged observation ', sk, ' on "', name, '")') FROM (
                      SELECT o.sk, e.name,
                             CASE WHEN BINARY o.status NOT IN ('active', 'obsolete', 'superseded')
                                    THEN CONCAT('status "', o.status, '" is not active, obsolete or superseded')
                                  WHEN o.content REGEXP blank THEN 'content is blank'
                                  WHEN o.confidence < 0 OR o.confidence > 1 THEN CONCAT('confidence ', o.confidence, ' is not between 0 and 1')
                                  WHEN BINARY o.perspective NOT IN ('world', 'experience')
                                    THEN CONCAT('perspective "', o.perspective, '" is not world or experience')
                                  WHEN o.valid_until < o.valid_from THEN CONCAT('valid_until ', o.valid_until, ' is before valid_from ', o.valid_from)
                                  WHEN JSON_VALID(o.tags) AND (JSON_TYPE(o.tags) <> 'ARRAY' OR EXISTS (
                                         SELECT 1 FROM JSON_TABLE(IF(JSON_VALID(o.tags), o.tags, '[]'), '$[*]' COLUMNS (i FOR ORDINALITY)) t
                                         WHERE JSON_TYPE(JSON_EXTRACT(o.tags, CONCAT('$[', t.i - 1, ']'))) <> 'STRING'))
                                    THEN 'tags is not an array of strings'
                             END AS problem
                      FROM gm_stage_observations o JOIN gm_stage_entities e ON e.sk = o.entity_sk) v
                    WHERE problem IS NOT NULL ORDER BY sk LIMIT 1), 512);
  END IF;
  -- MemoryRelation: relation_type present, weight 0 or more or NULL, confidence 0..1 or NULL, properties
  -- a JSON object.
  IF msg IS NULL THEN
    SET msg = LEFT((SELECT CONCAT('graph_mem-sql: memory_relations.', problem, ' (staged relation ', sk, ' from "', from_name, '" to "', to_name, '")') FROM (
                      SELECT r.sk, COALESCE(fe.name, fr.name) AS from_name, COALESCE(te.name, tr.name) AS to_name,
                             CASE WHEN r.relation_type REGEXP blank THEN 'relation_type is blank'
                                  WHEN r.weight < 0 THEN CONCAT('weight ', r.weight, ' is below 0')
                                  WHEN r.confidence < 0 OR r.confidence > 1 THEN CONCAT('confidence ', r.confidence, ' is not between 0 and 1')
                                  WHEN JSON_VALID(r.properties) AND JSON_TYPE(r.properties) <> 'OBJECT' THEN 'properties is not a JSON object'
                             END AS problem
                      FROM gm_stage_relations r
                      LEFT JOIN gm_stage_entities fe ON fe.sk = r.from_sk LEFT JOIN gm_stage_refs fr ON fr.sk = r.from_sk
                      LEFT JOIN gm_stage_entities te ON te.sk = r.to_sk LEFT JOIN gm_stage_refs tr ON tr.sk = r.to_sk) v
                    WHERE problem IS NOT NULL ORDER BY sk LIMIT 1), 512);
  END IF;
  IF msg IS NOT NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
  END IF;
END//
DELIMITER ;
