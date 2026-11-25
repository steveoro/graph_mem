-- Guards: each one stops the script before anything is written (SIGNAL rolls the transaction back).
DELIMITER //
BEGIN NOT ATOMIC
  DECLARE here VARCHAR(255) DEFAULT NULL;
  DECLARE theirs VARCHAR(255) DEFAULT NULL;
  DECLARE msg VARCHAR(512) DEFAULT NULL;
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
  ELSEIF EXISTS (SELECT 1 FROM gm_stage_observations o LEFT JOIN gm_stage_entities s ON s.sk = o.entity_sk WHERE s.sk IS NULL)
      OR EXISTS (SELECT 1 FROM gm_stage_observations WHERE BINARY status NOT IN ('active', 'obsolete', 'superseded')) THEN
    SET msg = 'graph_mem-sql: a staged observation has no staged entity or an unknown status';
  ELSEIF EXISTS (SELECT 1 FROM gm_stage_relations r
                 LEFT JOIN gm_stage_entities fe ON fe.sk = r.from_sk LEFT JOIN gm_stage_refs fr ON fr.sk = r.from_sk
                 LEFT JOIN gm_stage_entities te ON te.sk = r.to_sk LEFT JOIN gm_stage_refs tr ON tr.sk = r.to_sk
                 WHERE (fe.sk IS NULL AND fr.sk IS NULL) OR (te.sk IS NULL AND tr.sk IS NULL) OR (fe.sk IS NULL AND te.sk IS NULL)) THEN
    SET msg = 'graph_mem-sql: a staged relation has an end that is not staged, or two references as ends';
  END IF;
  IF msg IS NOT NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
  END IF;
END//
DELIMITER ;
