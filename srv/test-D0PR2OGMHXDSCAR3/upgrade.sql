-- php_daas_framework database bootstrap for test, consumed by
-- `ema sandbox srv/test-D0PR2OGMHXDSCAR3` (dev) and
-- `ema create srv/test-D0PR2OGMHXDSCAR3` (prod). Placeholders are filled from
-- default.php defaults: {{dbname}}, {{charset}}, {{collation}}.
SET check_constraint_checks = OFF;
DROP DATABASE IF EXISTS {{dbname}};
CREATE OR REPLACE DATABASE {{dbname}}
COMMENT 'php_daas_framework test database'
CHARACTER SET = '{{charset}}'
COLLATE = '{{collation}}';
