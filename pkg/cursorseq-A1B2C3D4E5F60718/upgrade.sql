CREATE OR REPLACE TABLE cursorseq (
    `key` VARCHAR(255),
    `value` BIGINT DEFAULT 0,
    `mod` TINYINT DEFAULT 0,
    `div` TINYINT DEFAULT 1,

    PRIMARY KEY(`key`, `mod`, `div`),
    CONSTRAINT chk_cursorseq_key CHECK (`key` REGEXP '^[a-zA-Z0-9_]+$')
);

/* MariaDB doesn't supports check constraints with inequalities between columns */
DELIMITER //
CREATE OR REPLACE TRIGGER chk_cursorseq_insert_mod
BEFORE INSERT ON cursorseq
FOR EACH ROW
BEGIN
    DECLARE error_message VARCHAR(255);

    IF NEW.`div` < NEW.`mod` THEN
        SET error_message = 'Constraint violation: cursorseq._mod must be greater than cursorseq.div';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = error_message;
    END IF;
END; //
DELIMITER ;

DELIMITER //
CREATE OR REPLACE TRIGGER chk_cursorseq_update_mod
BEFORE UPDATE ON cursorseq
FOR EACH ROW
BEGIN
    DECLARE error_message VARCHAR(255);

    IF NEW.`div` < NEW.`mod` THEN
        SET error_message = 'Constraint violation: cursorseq._mod must be greater than cursorseq.div';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = error_message;
    END IF;
END; //
DELIMITER ;
