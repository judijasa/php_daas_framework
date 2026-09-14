<?php
// Shared team role definitions (instance-level, one copy per team). Consumed
// by gen-grants before the per-database grant package. Nothing else lives
// here: the SQL is in upgrade.sql.
//
// Optional service-account declaration (consumed by gen-service-accounts;
// absent = today's gen-grants team-member shape only). Every key is consumer
// data — no account name, role name or source is hardcoded in the framework:
//
//   $sources   = array('member' => 'developer', 'worker' => 'worker');
//   $accounts  = array('app' => array('member', 'worker', 'db', 'web'));
//   $allowlist = array('daas');
//
// $sources maps a source to the role it grants: `member` resolves to the
// etc/team.ini IPs, any other key is a machines.ini tag (bare or db:<name>).
// $accounts maps an account name to the sources whose hosts it is pinned to;
// its per-host roles are the union of those sources' roles. $allowlist adds
// accounts the closed-world drop must never remove (root, mariadb.sys and
// replication are always protected). See doc/system/service-accounts.md.
$dependencies = array();
?>
