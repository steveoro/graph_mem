-- Relations match on (from, to, relation_type), like the unique key. An end that isn't found here skips
-- the edge. part_of is ownership: one parent per entity, so an incoming part_of for an entity that has
-- another parent here moves the existing row (newer wins, both ends in the export) or is kept local; an
-- edge crossing the export's boundary is only added when its entity has no parent yet and the edge
-- doesn't change that entity's project. A claimed reference stub's park edge is always moved: it
-- becomes the incoming part_of (no row is deleted).
INSERT INTO gm_map_relations (sk, from_id, to_id, crossing, part_of)
  SELECT r.sk, f.target_id, t.target_id, f.is_ref OR t.is_ref, r.relation_type = 'part_of'
  FROM gm_stage_relations r JOIN gm_map_entities f ON f.sk = r.from_sk JOIN gm_map_entities t ON t.sk = r.to_sk;
UPDATE gm_map_relations SET action = 'skipped_link', detail = 'the other end is not found here' WHERE from_id IS NULL OR to_id IS NULL;
UPDATE gm_map_relations SET action = 'skipped_link', detail = 'both ends are one entity here' WHERE action IS NULL AND from_id = to_id;
UPDATE gm_map_relations g JOIN gm_stage_relations r ON r.sk = g.sk
  JOIN memory_relations l ON l.from_entity_id = g.from_id AND l.to_entity_id = g.to_id AND l.relation_type = r.relation_type
  SET g.target_id = l.id WHERE g.action IS NULL;
UPDATE gm_map_relations g
  JOIN (SELECT from_id, MIN(sk) AS keep_sk FROM gm_map_relations WHERE action IS NULL AND part_of = 1 GROUP BY from_id) k ON k.from_id = g.from_id
  SET g.action = 'skipped_link', g.detail = 'a second part_of parent for one entity'
  WHERE g.action IS NULL AND g.part_of = 1 AND g.sk <> k.keep_sk;
UPDATE gm_map_relations g JOIN gm_stage_relations r ON r.sk = g.sk
  JOIN memory_entities c ON c.id = g.from_id JOIN memory_entities p ON p.id = g.to_id
  SET g.action = 'skipped_link', g.detail = 'it would move an entity into another project'
  WHERE g.action IS NULL AND g.target_id IS NULL AND g.part_of = 1 AND g.crossing = 1 AND c.entity_type <> 'Project'
    AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(r.properties, '$.reference_stub')), 'false') <> 'true'
    AND NOT (c.project_id <=> IF(p.entity_type = 'Project', p.id, p.project_id));
UPDATE gm_map_relations g JOIN gm_stage_relations r ON r.sk = g.sk
  JOIN (SELECT from_entity_id, MIN(id) AS id, COUNT(*) AS n FROM memory_relations
        WHERE relation_type = 'part_of' AND from_entity_id IN (SELECT from_id FROM gm_map_relations WHERE part_of = 1)
        GROUP BY from_entity_id) p ON p.from_entity_id = g.from_id
  JOIN memory_relations l ON l.id = p.id
  SET g.action = IF(p.n = 1 AND g.crossing = 0
                     AND (r.updated_at > l.updated_at
                          OR (COALESCE(JSON_UNQUOTE(JSON_EXTRACT(l.properties, '$.reference_stub')), 'false') = 'true'
                              AND EXISTS (SELECT 1 FROM gm_map_entities c WHERE c.target_id = g.from_id AND c.matched_by = 'claim'))),
                     'moved', 'kept_local'),
      g.detail = IF(p.n = 1, 'the entity has another part_of parent here', 'the entity has several part_of parents here'),
      g.target_id = l.id
  WHERE g.action IS NULL AND g.target_id IS NULL AND g.part_of = 1;
UPDATE gm_map_relations g JOIN gm_stage_relations r ON r.sk = g.sk JOIN memory_relations l ON l.id = g.target_id
  SET g.changed = JSON_MERGE_PRESERVE('{}',
    IF(l.to_entity_id <=> g.to_id, '{}', JSON_OBJECT('to_entity_id', JSON_OBJECT('from', l.to_entity_id, 'to', g.to_id))),
    IF(l.weight <=> r.weight, '{}', JSON_OBJECT('weight', JSON_OBJECT('from', l.weight, 'to', r.weight))),
    IF(l.confidence <=> r.confidence, '{}', JSON_OBJECT('confidence', JSON_OBJECT('from', l.confidence, 'to', r.confidence))),
    IF(COALESCE(JSON_EQUALS(l.properties, r.properties), 0) = 1, '{}',
       JSON_OBJECT('properties', JSON_OBJECT('from', JSON_EXTRACT(l.properties, '$'), 'to', JSON_EXTRACT(r.properties, '$')))))
  WHERE g.action IS NULL OR g.action IN ('moved', 'kept_local');
UPDATE gm_map_relations g JOIN gm_stage_relations r ON r.sk = g.sk JOIN memory_relations l ON l.id = g.target_id
  SET g.action = IF(g.changed = '{}', 'unchanged', IF(r.updated_at > l.updated_at, 'updated', 'kept_local'))
  WHERE g.action IS NULL;
UPDATE memory_relations l JOIN gm_map_relations g ON g.target_id = l.id AND g.action IN ('updated', 'moved') JOIN gm_stage_relations r ON r.sk = g.sk
  SET l.to_entity_id = g.to_id, l.weight = r.weight, l.confidence = r.confidence, l.properties = r.properties, l.updated_at = r.updated_at;
UPDATE gm_map_relations SET action = 'new' WHERE action IS NULL AND target_id IS NULL;
INSERT INTO memory_relations (from_entity_id, to_entity_id, relation_type, weight, confidence, properties, created_at, updated_at)
  SELECT g.from_id, g.to_id, r.relation_type, r.weight, r.confidence, r.properties, r.created_at, r.updated_at
  FROM gm_map_relations g JOIN gm_stage_relations r ON r.sk = g.sk WHERE g.action = 'new' ORDER BY r.sk;
UPDATE gm_map_relations g JOIN gm_stage_relations r ON r.sk = g.sk
  JOIN memory_relations l ON l.from_entity_id = g.from_id AND l.to_entity_id = g.to_id AND l.relation_type = r.relation_type
  SET g.target_id = l.id WHERE g.action = 'new';
