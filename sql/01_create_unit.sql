-- Create resource unit for the Oracle tenant.
CREATE RESOURCE UNIT @ORA_UNIT@
  MAX_CPU = @ORA_CPU@,
  MIN_CPU = @ORA_CPU@,
  MEMORY_SIZE = '@ORA_MEMORY@',
  LOG_DISK_SIZE = '@ORA_LOG_DISK@',
  MAX_IOPS = 10000,
  MIN_IOPS = 10000,
  IOPS_WEIGHT = 1;
