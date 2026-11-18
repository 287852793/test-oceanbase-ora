-- Create an Oracle compatibility mode tenant.
-- OceanBase 4.x sets the compatibility mode with a SET clause instead of
-- the COMPATIBILITY_MODE tenant option.
CREATE TENANT @ORA_TENANT@
  PRIMARY_ZONE = '@ZONE@',
  RESOURCE_POOL_LIST = ('@ORA_POOL@')
SET ob_tcp_invited_nodes = '%', ob_compatibility_mode = 'oracle';
