<?php
// Per-database grants for `test`: depends on the shared roles package (which
// defines the role) and holds only this database's grants. {{dbname}} is
// filled by gen-team-accounts from the target database name.
return new \Ema\Config\PackageConfig(
    dependencies: ['roles-D04KGFJ8K9F5TFR2'],
);
