-- Create resource pool for the Oracle tenant.
CREATE RESOURCE POOL @ORA_POOL@
  UNIT = '@ORA_UNIT@',
  UNIT_NUM = 1,
  ZONE_LIST = ('@ZONE@');
