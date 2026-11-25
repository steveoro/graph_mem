-- Post-merge checks on what this run wrote or claimed (each one rolls everything back): an entity with two part_of
-- parents, a part_of cycle, an entity whose project_id is not the one its part_of parent gives (the
-- rule ProjectMembership applies; reference_stub edges don't own), an observation whose lifecycle
-- columns disagree, or a written observation that breaks a source-fact rule of MemoryObservation.
INSERT INTO gm_check_ids (id)
  SELECT target_id FROM gm_map_entities WHERE is_ref = 0 AND action = 'new'
  UNION SELECT from_id FROM gm_map_relations WHERE part_of = 1 AND action IN ('new', 'moved')
  UNION SELECT entity_id FROM gm_claim_subtree;
DELIMITER //
BEGIN NOT ATOMIC
  DECLARE who VARCHAR(255) DEFAULT NULL;
  DECLARE msg VARCHAR(512) DEFAULT NULL;
  SET who = (SELECT e.name FROM gm_check_ids c JOIN memory_entities e ON e.id = c.id
             WHERE (SELECT COUNT(*) FROM memory_relations p WHERE p.from_entity_id = c.id AND p.relation_type = 'part_of') > 1 LIMIT 1);
  IF who IS NOT NULL THEN
    SET msg = CONCAT('graph_mem-sql: "', who, '" would have two part_of parents');
  END IF;
  IF msg IS NULL THEN
    SET who = (WITH RECURSIVE up (start_id, node) AS (
                 SELECT c.id, p.to_entity_id FROM gm_check_ids c JOIN memory_relations p ON p.from_entity_id = c.id AND p.relation_type = 'part_of'
                 UNION SELECT u.start_id, p.to_entity_id FROM up u JOIN memory_relations p ON p.from_entity_id = u.node AND p.relation_type = 'part_of')
               SELECT e.name FROM up JOIN memory_entities e ON e.id = up.start_id WHERE up.node = up.start_id LIMIT 1);
    IF who IS NOT NULL THEN
      SET msg = CONCAT('graph_mem-sql: "', who, '" would be part_of itself (a part_of cycle)');
    END IF;
  END IF;
  IF msg IS NULL THEN
    SET who = (SELECT e.name FROM gm_check_ids c JOIN memory_entities e ON e.id = c.id
               LEFT JOIN memory_relations p ON p.from_entity_id = e.id AND p.relation_type = 'part_of'
                 AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(p.properties, '$.reference_stub')), 'false') <> 'true'
               LEFT JOIN memory_entities pe ON pe.id = p.to_entity_id
               WHERE NOT (e.project_id <=> IF(e.entity_type = 'Project', NULL, IF(pe.entity_type = 'Project', pe.id, pe.project_id))) LIMIT 1);
    IF who IS NOT NULL THEN
      SET msg = CONCAT('graph_mem-sql: the project of "', who, '" would not match its part_of parent');
    END IF;
  END IF;
  IF msg IS NULL AND EXISTS (
      SELECT 1 FROM gm_map_observations g JOIN memory_observations o ON o.id = g.target_id
      LEFT JOIN memory_observations s ON s.id = o.superseded_by_id
      WHERE g.action IN ('new', 'updated')
        AND ((o.status = 'active') <> (o.obsoleted_at IS NULL) OR (o.status = 'superseded') <> (o.superseded_by_id IS NOT NULL)
             OR (s.id IS NOT NULL AND (s.memory_entity_id <> o.memory_entity_id OR s.id = o.id))
             OR (o.status = 'active' AND o.outdated_by_id IS NOT NULL) OR o.outdated_by_id = o.id)) THEN
    SET msg = 'graph_mem-sql: an observation would have inconsistent lifecycle columns';
  END IF;
  -- The source-fact rules of MemoryObservation (SourceFact), on a new row or a changed field as the model
  -- applies them; a fact belongs to the project of its entity (the entity itself for a Project root).
  IF msg IS NULL THEN
    SET who = (SELECT e.name FROM gm_map_observations g JOIN memory_observations o ON o.id = g.target_id
               JOIN memory_entities e ON e.id = o.memory_entity_id
               WHERE (g.action = 'new' OR (g.action = 'updated' AND JSON_CONTAINS_PATH(g.changed, 'one', '$.tags')))
                 AND o.status = 'active' AND JSON_CONTAINS(o.tags, '"source-fact"')
                 AND COALESCE(e.project_id, IF(BINARY e.entity_type = 'Project', e.id, NULL)) IS NULL LIMIT 1);
    IF who IS NOT NULL THEN
      SET msg = CONCAT('graph_mem-sql: memory_observations.tags: a source-fact on "', who, '" needs an entity inside a project');
    END IF;
  END IF;
  IF msg IS NULL THEN
    SET who = (SELECT e.name FROM gm_map_observations g JOIN memory_observations o ON o.id = g.target_id
               JOIN memory_entities e ON e.id = o.memory_entity_id
               JOIN memory_observations f ON f.id = o.outdated_by_id JOIN memory_entities fe ON fe.id = f.memory_entity_id
               WHERE (g.action = 'new' OR (g.action = 'updated' AND JSON_CONTAINS_PATH(g.changed, 'one', '$.outdated_by_id')))
                 AND NOT (JSON_CONTAINS(f.tags, '"source-fact"')
                          AND COALESCE(fe.project_id, IF(BINARY fe.entity_type = 'Project', fe.id, NULL)) IS NOT NULL
                          AND COALESCE(fe.project_id, IF(BINARY fe.entity_type = 'Project', fe.id, NULL))
                              <=> COALESCE(e.project_id, IF(BINARY e.entity_type = 'Project', e.id, NULL))) LIMIT 1);
    IF who IS NOT NULL THEN
      SET msg = CONCAT('graph_mem-sql: memory_observations.outdated_by_id of an observation on "', who, '" must be a source fact in the same project');
    END IF;
  END IF;
  IF msg IS NOT NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
  END IF;
END//
DELIMITER ;
