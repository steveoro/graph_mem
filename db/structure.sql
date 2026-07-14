/*M!999999\- enable the sandbox mode */ 

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*M!100616 SET @OLD_NOTE_VERBOSITY=@@NOTE_VERBOSITY, NOTE_VERBOSITY=0 */;
DROP TABLE IF EXISTS `agent_contexts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `agent_contexts` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `client_id` varchar(255) NOT NULL,
  `current_project_id` bigint(20) DEFAULT NULL,
  `last_seen_at` datetime(6) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  `last_tool_name` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_agent_contexts_on_client_id` (`client_id`),
  KEY `index_agent_contexts_on_current_project_id` (`current_project_id`)
) ENGINE=InnoDB AUTO_INCREMENT=211 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `ar_internal_metadata`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `ar_internal_metadata` (
  `key` varchar(255) NOT NULL,
  `value` varchar(255) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `audit_logs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `audit_logs` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `auditable_type` varchar(255) NOT NULL,
  `auditable_id` bigint(20) NOT NULL,
  `action` varchar(255) NOT NULL,
  `actor` varchar(255) DEFAULT NULL,
  `changed_fields` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`changed_fields`)),
  `created_at` datetime(6) NOT NULL,
  `reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `index_audit_logs_on_auditable_type_and_auditable_id` (`auditable_type`,`auditable_id`),
  KEY `index_audit_logs_on_created_at` (`created_at`)
) ENGINE=InnoDB AUTO_INCREMENT=7628 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `compaction_runs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `compaction_runs` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `status` varchar(255) NOT NULL DEFAULT 'idle',
  `cursor_entity_id` bigint(20) DEFAULT NULL,
  `phase` varchar(255) DEFAULT NULL,
  `stats` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`stats`)),
  `pause_requested` tinyint(1) NOT NULL DEFAULT 0,
  `started_at` datetime(6) DEFAULT NULL,
  `finished_at` datetime(6) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  `operation_progress_id` bigint(20) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `index_compaction_runs_on_status` (`status`),
  KEY `index_compaction_runs_on_created_at` (`created_at`),
  KEY `index_compaction_runs_on_operation_progress_id` (`operation_progress_id`),
  CONSTRAINT `fk_rails_3c6a427e3c` FOREIGN KEY (`operation_progress_id`) REFERENCES `operation_progresses` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=70 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `entity_type_mappings`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `entity_type_mappings` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `canonical_type` varchar(255) NOT NULL,
  `variant` varchar(255) NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_entity_type_mappings_on_variant` (`variant`),
  KEY `index_entity_type_mappings_on_canonical_type` (`canonical_type`)
) ENGINE=InnoDB AUTO_INCREMENT=113 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `maintenance_reports`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `maintenance_reports` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `report_type` varchar(255) NOT NULL,
  `data` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL CHECK (json_valid(`data`)),
  `created_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_maintenance_reports_on_report_type` (`report_type`),
  KEY `index_maintenance_reports_on_created_at` (`created_at`)
) ENGINE=InnoDB AUTO_INCREMENT=641 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `memory_entities`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `memory_entities` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) DEFAULT NULL,
  `entity_type` varchar(255) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  `memory_observations_count` int(11) DEFAULT NULL,
  `aliases` text DEFAULT NULL,
  `description` text DEFAULT NULL,
  `embedding` vector(768) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_memory_entities_on_name` (`name`),
  KEY `index_memory_entities_on_entity_type` (`entity_type`),
  FULLTEXT KEY `index_memory_entities_fulltext` (`name`,`aliases`)
) ENGINE=InnoDB AUTO_INCREMENT=5331 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `memory_observations`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `memory_observations` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `content` text DEFAULT NULL,
  `memory_entity_id` bigint(20) NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  `embedding` vector(768) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `index_memory_observations_on_memory_entity_id` (`memory_entity_id`),
  CONSTRAINT `fk_rails_675e0d9a7a` FOREIGN KEY (`memory_entity_id`) REFERENCES `memory_entities` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=4633 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `memory_relations`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `memory_relations` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `from_entity_id` bigint(20) NOT NULL,
  `to_entity_id` bigint(20) NOT NULL,
  `relation_type` varchar(255) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_memory_relations_uniqueness` (`from_entity_id`,`to_entity_id`,`relation_type`),
  KEY `index_memory_relations_on_from_entity_id` (`from_entity_id`),
  KEY `index_memory_relations_on_relation_type` (`relation_type`),
  KEY `index_memory_relations_on_to_entity_id` (`to_entity_id`),
  CONSTRAINT `fk_rails_4ecabb48c2` FOREIGN KEY (`from_entity_id`) REFERENCES `memory_entities` (`id`),
  CONSTRAINT `fk_rails_6777b355f4` FOREIGN KEY (`to_entity_id`) REFERENCES `memory_entities` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=2044 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `operation_progresses`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `operation_progresses` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `operation_id` varchar(255) NOT NULL,
  `operation_type` varchar(255) NOT NULL,
  `status` varchar(255) NOT NULL DEFAULT 'pending',
  `phase` varchar(255) DEFAULT NULL,
  `message` varchar(255) DEFAULT NULL,
  `current_count` bigint(20) NOT NULL DEFAULT 0,
  `total_count` bigint(20) NOT NULL DEFAULT 0,
  `percentage` decimal(5,1) NOT NULL DEFAULT 0.0,
  `counters` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`counters`)),
  `details` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`details`)),
  `started_at` datetime(6) DEFAULT NULL,
  `finished_at` datetime(6) DEFAULT NULL,
  `error_class` varchar(255) DEFAULT NULL,
  `error_message` text DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_operation_progresses_on_operation_id` (`operation_id`),
  KEY `index_operation_progresses_on_operation_type_and_status` (`operation_type`,`status`),
  KEY `index_operation_progresses_on_created_at` (`created_at`)
) ENGINE=InnoDB AUTO_INCREMENT=84 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `schema_migrations`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `schema_migrations` (
  `version` varchar(255) NOT NULL,
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `settings`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `settings` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `var` varchar(255) NOT NULL,
  `value` text DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_settings_on_var` (`var`)
) ENGINE=InnoDB AUTO_INCREMENT=169 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*M!100616 SET NOTE_VERBOSITY=@OLD_NOTE_VERBOSITY */;

INSERT INTO `schema_migrations` (version) VALUES
('20260714155706'),
('20260714120100'),
('20260714120000'),
('20260710102000'),
('20260626120000'),
('20260624120000'),
('20260610130000'),
('20260610120000'),
('20260227122158'),
('20260227122157'),
('20260227122156'),
('20260227122155'),
('20260227122154'),
('20260227122153'),
('20260227122152'),
('20250802103116'),
('20250801132700'),
('20250613095029'),
('20250517212808'),
('20250517211743'),
('20250517211234'),
('20250517205110'),
('20250512102820'),
('20250512095346'),
('20250512095341'),
('20250512095340');

