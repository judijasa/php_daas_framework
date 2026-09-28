<?php
// Shared team role definitions (instance-level, one copy per team). Consumed
// by gen-team-accounts before the per-database grant package. Nothing else lives
// here: the SQL is in upgrade.sql.
//
// Optional service-account declaration (consumed by gen-service-accounts;
// absent = today's gen-team-accounts team-member shape only). Every key is consumer
// data — no account name, role name or source is hardcoded in the framework:
//
//   roles: new \Ema\Config\RolesConfig(
//       sources:   ['member' => 'developer', 'worker' => 'worker', 'web' => 'webapp'],
//       accounts:  ['app' => ['member', 'worker', 'web']],
//       allowlist: ['daas'],
//   ),
//
// sources maps a source to the role it grants: `member` resolves to the
// etc/team.ini IPs, any other key is a machines.ini tag (bare or db:<name>).
// accounts maps an account name to the sources whose hosts it is pinned to;
// its per-host roles are the union of those sources' roles. allowlist adds
// accounts the closed-world drop must never remove (root, mariadb.sys and
// replication are always protected). See doc/system/service-accounts.md.
return new \Ema\Config\PackageConfig(
    roles: new \Ema\Config\RolesConfig(),
);
