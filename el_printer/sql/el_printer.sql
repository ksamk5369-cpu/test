-- el_printer database schema (MySQL / MariaDB, used through oxmysql).
-- The resource creates these tables automatically when Config.Persistence.AutoCreateTables = true.
-- Import this file manually if your database user is not allowed to create tables.

CREATE TABLE IF NOT EXISTS `el_printer_documents` (
    `id` VARCHAR(16) NOT NULL,
    `doc_type` VARCHAR(40) NOT NULL,
    `title` VARCHAR(96) NOT NULL,
    `owner_cid` VARCHAR(16) NOT NULL,
    `issuer_cid` VARCHAR(16) NOT NULL,
    `issuer_name` VARCHAR(96) NOT NULL,
    `issuer_job` VARCHAR(50) NOT NULL DEFAULT '',
    `issuer_job_label` VARCHAR(80) NOT NULL DEFAULT '',
    `issuer_grade` INT NOT NULL DEFAULT 0,
    `issuer_grade_label` VARCHAR(80) NOT NULL DEFAULT '',
    `recipient_cid` VARCHAR(16) DEFAULT NULL,
    `data` LONGTEXT NOT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'active',
    `print_count` INT NOT NULL DEFAULT 0,
    `created_at` BIGINT NOT NULL,
    `expires_at` BIGINT DEFAULT NULL,
    `printer_id` VARCHAR(48) NOT NULL DEFAULT '',
    PRIMARY KEY (`id`),
    KEY `idx_el_owner` (`owner_cid`),
    KEY `idx_el_issuer` (`issuer_cid`),
    KEY `idx_el_type_created` (`doc_type`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `el_printer_placed` (
    `id` VARCHAR(16) NOT NULL,
    `label` VARCHAR(64) NOT NULL,
    `model` VARCHAR(64) NOT NULL,
    `x` DOUBLE NOT NULL,
    `y` DOUBLE NOT NULL,
    `z` DOUBLE NOT NULL,
    `heading` DOUBLE NOT NULL DEFAULT 0,
    `owner_cid` VARCHAR(16) NOT NULL,
    `owner_job` VARCHAR(50) NOT NULL DEFAULT '',
    `created_at` BIGINT NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_el_placed_owner` (`owner_cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `el_printer_state` (
    `printer_id` VARCHAR(48) NOT NULL,
    `paper` INT NOT NULL DEFAULT 0,
    `ink` INT NOT NULL DEFAULT 0,
    `durability` DOUBLE NOT NULL DEFAULT 100,
    `maintenance` TINYINT(1) NOT NULL DEFAULT 0,
    `updated_at` BIGINT NOT NULL,
    PRIMARY KEY (`printer_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
