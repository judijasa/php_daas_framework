<?php
// Default database definition for `test`. Non-secret defaults shared by dev
// and prod (the connection file carries the endpoint). ema creates schema
// only — users/grants are consumer policy and never live here.
$db = array(
    'dbname' => 'test',
    'charset' => 'utf8',
    'collation' => 'utf8_spanish_ci',
    // 'binlog' => true,               // primary only: binary logging (replica source, PITR, CDC)
    // 'binlog_expire_days' => 7,      // retention (days); only applies with 'binlog'
);
// Schema packages this database applies (pkg/<name>-<GUID>), dependency order.
$dependencies = array(
    'demo-8C3A9E1F0D2B4C5D',
);
?>
