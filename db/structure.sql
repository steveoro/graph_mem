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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
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
  `embedding` vector(768) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_memory_entities_on_name` (`name`),
  KEY `index_memory_entities_on_entity_type` (`entity_type`),
  FULLTEXT KEY `index_memory_entities_fulltext` (`name`,`aliases`),
  VECTOR KEY `idx_memory_entities_embedding` (`embedding`) `DISTANCE`=cosine
) ENGINE=InnoDB AUTO_INCREMENT=654 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
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
  `embedding` vector(768) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_memory_observations_on_memory_entity_id` (`memory_entity_id`),
  VECTOR KEY `idx_memory_observations_embedding` (`embedding`) `DISTANCE`=cosine,
  CONSTRAINT `fk_rails_675e0d9a7a` FOREIGN KEY (`memory_entity_id`) REFERENCES `memory_entities` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=3422 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
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
) ENGINE=InnoDB AUTO_INCREMENT=1090 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `schema_migrations`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `schema_migrations` (
  `version` varchar(255) NOT NULL,
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
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

