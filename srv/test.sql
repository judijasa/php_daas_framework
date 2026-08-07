SET check_constraint_checks = OFF;
DROP DATABASE IF EXISTS {{dbname}};
CREATE OR REPLACE DATABASE {{dbname}}
COMMENT 'php_daas_framework test database'
CHARACTER SET = 'utf8'
COLLATE = 'utf8_spanish_ci';

DROP USER IF EXISTS 'admin'@'{{servername}}';
CREATE USER 'admin'@'{{servername}}' IDENTIFIED BY '{{admin_password}}';

DROP USER IF EXISTS 'reader'@'{{servername}}';
CREATE USER 'reader'@'{{servername}}' IDENTIFIED BY '{{reader_password}}';

DROP USER IF EXISTS 'public'@'{{servername}}';
CREATE USER 'public'@'{{servername}}' IDENTIFIED BY '';

GRANT SELECT ON {{dbname}}.* TO 'reader'@'{{servername}}';
GRANT SELECT, INSERT, UPDATE, DELETE ON {{dbname}}.* TO 'admin'@'{{servername}}';
