/*
  Change character set of non utf8mb4 databases
*/

DELIMITER $$;

IF EXISTS(SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'my_table' AND DEFAULT_CHARACTER_SET_NAME != 'utf8mb4')
THEN
    ALTER DATABASE my_table CHARACTER SET = utf8mb4 COLLATE = utf8mb4_spanish_ci;
END IF;

DELIMITER $$;


/*
  Change character set of non utf8mb4 tables

  ONLY IF YOU NOW WHAT YOU ARE DOING...
  if some of this tables hace foreign key constraints,
  you could disable foreign key checks with SET FOREIGN_KEY_CHECKS = 0;
*/

SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_COLLATION, ccsa.character_set_name
     ,CONCAT_WS(' ', 'ALTER TABLE', TABLE_NAME, 'CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;')
FROM information_schema.TABLES AS t
LEFT JOIN information_schema.COLLATION_CHARACTER_SET_APPLICABILITY AS ccsa
    ON t.TABLE_COLLATION = ccsa.COLLATION_NAME
WHERE TABLE_SCHEMA = 'my_table'
  AND character_set_name IS NOT NULL
  AND CHARACTER_SET_NAME != 'utf8mb4';

/*
  Change character set of non utf8mb4 columns
*/
SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, CHARACTER_SET_NAME, COLLATION_NAME
FROM information_schema.COLUMNS AS c
WHERE TABLE_SCHEMA = 'alumni_prod'
AND CHARACTER_SET_NAME IS NOT NULL
AND CHARACTER_SET_NAME != 'utf8mb4';
