<?php

namespace Utils\DatabaseOps;

use PDO;

class CursorSeq
{
    private $conn;
    private $key;

    // Pass both dependencies into the constructor
    public function __construct(PDO $conn, string $key)
    {
        $this->conn = $conn;
        $this->key = $key;
    }

    public function set_cursor(int $value, int $mod = 0, int $div = 1)
    {
        $query = <<<EOD
            INSERT INTO cursorseq(`key`, `value`, `mod`, `div`)
            VALUES (:key, :value, :mod, :div)
            ON DUPLICATE KEY UPDATE `value` = VALUES(`value`);
        EOD;

        $stmt = $this->conn->prepare($query);
        $stmt->bindValue(':key', $this->key, PDO::PARAM_STR);
        $stmt->bindValue(':value', $value, PDO::PARAM_INT);
        $stmt->bindValue(':mod', $mod, PDO::PARAM_INT);
        $stmt->bindValue(':div', $div, PDO::PARAM_INT);
        $stmt->execute();

        return $this->_get_cursor($mod, $div);
    }

    public function get_cursor(int $init_value = 1, int $mod = 0, int $div = 1)
    {
        $value = $this->_get_cursor($mod, $div);

        if ($value !== false) {
            return $value;
        }

        return $this->set_cursor($init_value, $mod, $div);
    }

    private function _get_cursor(int $mod = 0, int $div = 1)
    {
        $query = <<<EOD
            SELECT value FROM cursorseq
            WHERE `key` = :key
                AND `mod` = :mod
                AND `div` = :div;
        EOD;

        $stmt = $this->conn->prepare($query);
        $stmt->bindValue(':key', $this->key, PDO::PARAM_STR);
        $stmt->bindValue(':mod', $mod, PDO::PARAM_INT);
        $stmt->bindValue(':div', $div, PDO::PARAM_INT);
        $stmt->execute();

        return $stmt->fetchColumn();
    }
}
