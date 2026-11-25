-- The report: the counts per table and action, then every affected row (unchanged rows are only counted).
SELECT tbl AS `table`, action, n AS `rows` FROM gm_report
  ORDER BY FIELD(tbl, 'memory_entities', 'memory_observations', 'memory_relations'),
           FIELD(action, 'new', 'claimed', 'updated', 'unchanged', 'kept_local', 'skipped_link');
SELECT tbl AS `table`, action, target_id AS id, project, entity, detail, changed FROM gm_touched
  ORDER BY FIELD(tbl, 'memory_entities', 'memory_observations', 'memory_relations'),
           FIELD(action, 'new', 'claimed', 'updated', 'unchanged', 'kept_local', 'skipped_link', 'dropped_link'), target_id;
COMMIT;
