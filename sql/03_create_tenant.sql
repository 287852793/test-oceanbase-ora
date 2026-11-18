-- Create an Oracle compatibility mode tenant.
CREATE TENANT @ORA_TENANT@
  PRIMARY_ZONE = '@ZONE@',
  RESOURCE_POOL_LIST = ('@ORA_POOL@'),
  COMPATIBILITY_MODE = 'oracle';
