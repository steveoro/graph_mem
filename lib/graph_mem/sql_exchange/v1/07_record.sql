-- The record of this run, written in the same transaction (a rolled-back or dry run leaves none): one
-- audit_logs row per new or updated row in the shape Auditable writes (a snapshot for a create, the
-- {from, to} fields for an update; actor sql_import), and one completed `import` operation_progresses
-- row whose operation_id the app sets in @gm_operation_id (a hand run generates its own).
SET @gm_op = COALESCE(@gm_operation_id, UUID());
INSERT INTO gm_touched (tbl, action, target_id, project, entity, detail, changed)
  SELECT 'memory_entities', m.action, e.id, pr.name, e.name,
         CONCAT(e.entity_type, CASE WHEN m.matched_by = 'alias' THEN CONCAT(', matched by alias: ', s.name)
                                    WHEN m.matched_by = 'ambiguous' THEN ', its name or an alias matches several entities here'
                                    WHEN m.matched_by = 'claim' AND ct.entity_id = ct_top.target_id THEN ', claimed from global'
                                    WHEN m.matched_by = 'claim' THEN CONCAT(', claimed from global with ', top.name)
                                    WHEN m.claim_note IS NOT NULL THEN CONCAT(', a global namesake was not claimed: ', m.claim_note) ELSE '' END),
         NULLIF(m.changed, '{}')
  FROM gm_map_entities m JOIN gm_stage_entities s ON s.sk = m.sk JOIN memory_entities e ON e.id = m.target_id
  LEFT JOIN memory_entities pr ON pr.id = e.project_id
  LEFT JOIN gm_claim_subtree ct ON ct.entity_id = e.id LEFT JOIN gm_claim_candidates ct_top ON ct_top.sk = ct.sk
  LEFT JOIN memory_entities top ON top.id = ct_top.target_id
  WHERE m.action IN ('new', 'updated', 'kept_local', 'claimed') OR m.matched_by IN ('alias', 'ambiguous')
  UNION ALL
  SELECT 'memory_entities', 'claimed', e.id, pr.name, e.name, CONCAT(e.entity_type, ', claimed from global with ', top.name),
         JSON_OBJECT('project_id', JSON_OBJECT('from', NULL, 'to', e.project_id))
  FROM gm_claim_subtree t JOIN memory_entities e ON e.id = t.entity_id LEFT JOIN memory_entities pr ON pr.id = e.project_id
  JOIN gm_claim_candidates c ON c.sk = t.sk JOIN memory_entities top ON top.id = c.target_id
  WHERE NOT EXISTS (SELECT 1 FROM gm_map_entities m WHERE m.target_id = t.entity_id AND m.is_ref = 0)
  UNION ALL
  SELECT 'memory_observations', g.action, o.id, pr.name, e.name, LEFT(o.content, 80), NULLIF(g.changed, '{}')
  FROM gm_map_observations g JOIN memory_observations o ON o.id = g.target_id JOIN memory_entities e ON e.id = o.memory_entity_id
  LEFT JOIN memory_entities pr ON pr.id = e.project_id
  WHERE g.action IN ('new', 'updated', 'kept_local')
  UNION ALL
  SELECT 'memory_relations', IF(g.action = 'moved', 'updated', g.action), g.target_id, pr.name, COALESCE(fe.name, fs.name, fr.name),
         CONCAT(r.relation_type, ' -> ', COALESCE(te.name, CONCAT('(missing) ', COALESCE(ts.name, tr.name)))),
         IF(g.action = 'skipped_link', JSON_OBJECT('reason', g.detail), NULLIF(g.changed, '{}'))
  FROM gm_map_relations g JOIN gm_stage_relations r ON r.sk = g.sk
  LEFT JOIN memory_entities fe ON fe.id = g.from_id LEFT JOIN memory_entities te ON te.id = g.to_id
  LEFT JOIN gm_stage_entities fs ON fs.sk = r.from_sk LEFT JOIN gm_stage_refs fr ON fr.sk = r.from_sk
  LEFT JOIN gm_stage_entities ts ON ts.sk = r.to_sk LEFT JOIN gm_stage_refs tr ON tr.sk = r.to_sk
  LEFT JOIN memory_entities pr ON pr.id = COALESCE(fe.project_id, te.project_id)
  WHERE g.action IN ('new', 'updated', 'moved', 'kept_local', 'skipped_link');
INSERT INTO gm_report (tbl, action, n)
  SELECT 'memory_entities', action, COUNT(*) FROM gm_touched WHERE tbl = 'memory_entities' AND action = 'claimed' GROUP BY action
  UNION ALL SELECT 'memory_entities', action, COUNT(*) FROM gm_map_entities WHERE is_ref = 0 AND action <> 'claimed' GROUP BY action
  UNION ALL SELECT 'memory_observations', action, COUNT(*) FROM gm_map_observations GROUP BY action
  UNION ALL SELECT 'memory_relations', IF(action = 'moved', 'updated', action), COUNT(*) FROM gm_map_relations GROUP BY IF(action = 'moved', 'updated', action);
INSERT INTO audit_logs (auditable_type, auditable_id, action, actor, changed_fields, reason, created_at)
  SELECT 'MemoryEntity', e.id, 'create', 'sql_import',
         JSON_OBJECT('id', e.id, 'name', e.name, 'entity_type', e.entity_type, 'created_at', e.created_at, 'updated_at', e.updated_at,
                     'memory_observations_count', e.memory_observations_count, 'aliases', e.aliases, 'description', e.description,
                     'embedded_at', e.embedded_at, 'project_id', e.project_id, 'project_scope', e.project_scope),
         CONCAT('sql_import:', @gm_op), UTC_TIMESTAMP(6)
  FROM gm_map_entities m JOIN memory_entities e ON e.id = m.target_id WHERE m.is_ref = 0 AND m.action = 'new'
  UNION ALL
  SELECT 'MemoryObservation', o.id, 'create', 'sql_import',
         JSON_OBJECT('id', o.id, 'content', o.content, 'memory_entity_id', o.memory_entity_id, 'created_at', o.created_at,
                     'updated_at', o.updated_at, 'confidence', o.confidence, 'source', o.source, 'valid_from', o.valid_from,
                     'valid_until', o.valid_until, 'tags', JSON_EXTRACT(o.tags, '$'), 'status', o.status, 'obsoleted_at', o.obsoleted_at,
                     'obsolescence_reason', o.obsolescence_reason, 'superseded_by_id', o.superseded_by_id, 'trust_score', o.trust_score,
                     'embedded_at', o.embedded_at, 'perspective', o.perspective, 'outdated_by_id', o.outdated_by_id,
                     'keywords', JSON_EXTRACT(o.keywords, '$'), 'keywords_at', o.keywords_at,
                     'llm_keywords', JSON_EXTRACT(o.llm_keywords, '$'), 'llm_keywords_at', o.llm_keywords_at),
         CONCAT('sql_import:', @gm_op), UTC_TIMESTAMP(6)
  FROM gm_map_observations g JOIN memory_observations o ON o.id = g.target_id WHERE g.action = 'new'
  UNION ALL
  SELECT 'MemoryRelation', l.id, 'create', 'sql_import',
         JSON_OBJECT('id', l.id, 'from_entity_id', l.from_entity_id, 'to_entity_id', l.to_entity_id, 'relation_type', l.relation_type,
                     'created_at', l.created_at, 'updated_at', l.updated_at, 'weight', l.weight, 'confidence', l.confidence,
                     'properties', JSON_EXTRACT(l.properties, '$')),
         CONCAT('sql_import:', @gm_op), UTC_TIMESTAMP(6)
  FROM gm_map_relations g JOIN memory_relations l ON l.id = g.target_id WHERE g.action = 'new'
  UNION ALL
  SELECT CASE tbl WHEN 'memory_entities' THEN 'MemoryEntity' WHEN 'memory_observations' THEN 'MemoryObservation' ELSE 'MemoryRelation' END,
         target_id, 'update', 'sql_import', changed, CONCAT('sql_import:', @gm_op), UTC_TIMESTAMP(6)
  FROM gm_touched WHERE action IN ('updated', 'claimed');
INSERT INTO operation_progresses (operation_id, operation_type, status, phase, message, current_count, total_count, percentage,
                                  counters, details, started_at, finished_at, created_at, updated_at)
  SELECT @gm_op, 'import', 'completed', 'completed', 'graph_mem-sql v{{format}} import', n, n, 100,
         (SELECT JSON_OBJECTAGG(t.tbl, JSON_EXTRACT(t.counts, '$'))
          FROM (SELECT tbl, JSON_OBJECTAGG(action, n) AS counts FROM gm_report GROUP BY tbl) t),
         JSON_OBJECT('format', 'sql', 'format_version', {{format}},
                     'source', (SELECT JSON_OBJECTAGG(k, v) FROM gm_stage_meta WHERE k <> 'roots'),
                     'roots', JSON_EXTRACT((SELECT v FROM gm_stage_meta WHERE k = 'roots'), '$'),
                     'outside_app', JSON_EXTRACT(IF(@gm_operation_id IS NULL, 'true', 'false'), '$'),
                     'affected_count', n,
                     'affected', (SELECT JSON_ARRAYAGG(JSON_OBJECT('table', tbl, 'action', action, 'id', target_id, 'entity', entity,
                                                                   'fields', JSON_EXTRACT(JSON_KEYS(changed), '$'))
                                               ORDER BY tbl, target_id LIMIT 5000) FROM gm_touched)),
         UTC_TIMESTAMP(6), UTC_TIMESTAMP(6), UTC_TIMESTAMP(6), UTC_TIMESTAMP(6)
  FROM (SELECT COUNT(*) AS n FROM gm_touched) total;
