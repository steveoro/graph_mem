-- Observations match on (mapped entity, SHA2(content, 256)), so "abc" and "abc " stay two facts; of
-- several local copies the active one wins, then the highest id. The lifecycle links are mapped
-- through the staging keys; a superseded row whose replacement can't be mapped is stored as obsolete.
INSERT INTO gm_map_observations (sk, entity_id) SELECT o.sk, m.target_id FROM gm_stage_observations o JOIN gm_map_entities m ON m.sk = o.entity_sk;
INSERT INTO gm_local_observations (id, entity_id, content_sha, active)
  SELECT l.id, l.memory_entity_id, SHA2(l.content, 256), l.status = 'active' FROM memory_observations l
  WHERE l.memory_entity_id IN (SELECT target_id FROM gm_map_entities WHERE is_ref = 0 AND action <> 'new');
UPDATE gm_map_observations g JOIN gm_stage_observations o ON o.sk = g.sk
  SET g.target_id = (SELECT l.id FROM gm_local_observations l WHERE l.entity_id = g.entity_id AND l.content_sha = o.content_sha
                     ORDER BY l.active DESC, l.id DESC LIMIT 1);
INSERT INTO memory_observations (memory_entity_id, content, confidence, source, valid_from, valid_until, tags, status,
                                 obsoleted_at, obsolescence_reason, perspective, created_at, updated_at)
  SELECT g.entity_id, o.content, o.confidence, o.source, o.valid_from, o.valid_until, o.tags, o.status,
         o.obsoleted_at, o.obsolescence_reason, o.perspective, o.created_at, o.updated_at
  FROM gm_map_observations g JOIN gm_stage_observations o ON o.sk = g.sk WHERE g.target_id IS NULL ORDER BY o.sk;
UPDATE gm_map_observations g JOIN gm_stage_observations o ON o.sk = g.sk
  SET g.target_id = (SELECT MIN(n.id) FROM memory_observations n
                     WHERE n.memory_entity_id = g.entity_id AND n.id >= LAST_INSERT_ID() AND SHA2(n.content, 256) = o.content_sha),
      g.action = 'new'
  WHERE g.target_id IS NULL;
UPDATE gm_map_observations g JOIN gm_stage_observations o ON o.sk = g.sk
  LEFT JOIN gm_map_observations sup ON sup.sk = o.superseded_by_sk AND sup.entity_id = g.entity_id AND sup.sk <> g.sk
  LEFT JOIN gm_map_observations dep ON dep.sk = o.outdated_by_sk AND dep.sk <> g.sk
  SET g.superseded_by_id = IF(BINARY o.status = 'superseded', sup.target_id, NULL),
      g.status = IF(BINARY o.status = 'superseded' AND sup.target_id IS NULL, 'obsolete', o.status),
      g.obsoleted_at = IF(BINARY o.status = 'active', NULL, COALESCE(o.obsoleted_at, o.updated_at)),
      g.outdated_by_id = IF(BINARY o.status = 'active', NULL, dep.target_id);
-- Matched rows: what differs, then newer wins (a tie is kept local).
UPDATE gm_map_observations g JOIN gm_stage_observations o ON o.sk = g.sk JOIN memory_observations l ON l.id = g.target_id
  SET g.changed = JSON_MERGE_PRESERVE('{}',
    IF(l.confidence <=> o.confidence, '{}', JSON_OBJECT('confidence', JSON_OBJECT('from', l.confidence, 'to', o.confidence))),
    IF(BINARY l.source <=> BINARY o.source, '{}', JSON_OBJECT('source', JSON_OBJECT('from', l.source, 'to', o.source))),
    IF(l.valid_from <=> o.valid_from, '{}', JSON_OBJECT('valid_from', JSON_OBJECT('from', l.valid_from, 'to', o.valid_from))),
    IF(l.valid_until <=> o.valid_until, '{}', JSON_OBJECT('valid_until', JSON_OBJECT('from', l.valid_until, 'to', o.valid_until))),
    IF(COALESCE(JSON_EQUALS(l.tags, o.tags), 0) = 1, '{}',
       JSON_OBJECT('tags', JSON_OBJECT('from', JSON_EXTRACT(l.tags, '$'), 'to', JSON_EXTRACT(o.tags, '$')))),
    IF(BINARY l.perspective <=> BINARY o.perspective, '{}', JSON_OBJECT('perspective', JSON_OBJECT('from', l.perspective, 'to', o.perspective))),
    IF(BINARY l.status <=> BINARY g.status, '{}', JSON_OBJECT('status', JSON_OBJECT('from', l.status, 'to', g.status))),
    IF(l.obsoleted_at <=> g.obsoleted_at, '{}', JSON_OBJECT('obsoleted_at', JSON_OBJECT('from', l.obsoleted_at, 'to', g.obsoleted_at))),
    IF(BINARY l.obsolescence_reason <=> BINARY o.obsolescence_reason, '{}',
       JSON_OBJECT('obsolescence_reason', JSON_OBJECT('from', l.obsolescence_reason, 'to', o.obsolescence_reason))),
    IF(l.superseded_by_id <=> g.superseded_by_id, '{}', JSON_OBJECT('superseded_by_id', JSON_OBJECT('from', l.superseded_by_id, 'to', g.superseded_by_id))),
    IF(l.outdated_by_id <=> g.outdated_by_id, '{}', JSON_OBJECT('outdated_by_id', JSON_OBJECT('from', l.outdated_by_id, 'to', g.outdated_by_id))))
  WHERE g.action IS NULL;
UPDATE gm_map_observations g JOIN gm_stage_observations o ON o.sk = g.sk JOIN memory_observations l ON l.id = g.target_id
  SET g.action = IF(g.changed = '{}', 'unchanged', IF(o.updated_at > l.updated_at, 'updated', 'kept_local'))
  WHERE g.action IS NULL;
-- A changed source or tags (embedded text) clears embedded_at; the content is the key, so it never changes.
UPDATE memory_observations l JOIN gm_map_observations g ON g.target_id = l.id AND g.action = 'updated' JOIN gm_stage_observations o ON o.sk = g.sk
  SET l.embedded_at = IF(JSON_CONTAINS_PATH(g.changed, 'one', '$.source', '$.tags'), NULL, l.embedded_at),
      l.confidence = o.confidence, l.source = o.source, l.valid_from = o.valid_from, l.valid_until = o.valid_until, l.tags = o.tags,
      l.perspective = o.perspective, l.status = g.status, l.obsoleted_at = g.obsoleted_at, l.obsolescence_reason = o.obsolescence_reason,
      l.superseded_by_id = g.superseded_by_id, l.outdated_by_id = g.outdated_by_id, l.updated_at = o.updated_at;
UPDATE memory_observations n JOIN gm_map_observations g ON g.target_id = n.id AND g.action = 'new'
  SET n.status = g.status, n.obsoleted_at = g.obsoleted_at, n.superseded_by_id = g.superseded_by_id, n.outdated_by_id = g.outdated_by_id;
-- The counter cache of the entities that got new observations (a plain UPDATE: updated_at stays).
UPDATE memory_entities e JOIN (SELECT DISTINCT entity_id FROM gm_map_observations WHERE action = 'new') t ON t.entity_id = e.id
  SET e.memory_observations_count = (SELECT COUNT(*) FROM memory_observations c WHERE c.memory_entity_id = e.id);
