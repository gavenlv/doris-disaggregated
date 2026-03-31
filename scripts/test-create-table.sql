USE test;
CREATE TABLE IF NOT EXISTS test_table (
  id BIGINT NULL,
  name VARCHAR(256) NULL
) ENGINE=OLAP
UNIQUE KEY(id)
COMMENT "test table"
DISTRIBUTED BY HASH(id) BUCKETS 3
PROPERTIES (
  "replication_num" = "1",
  "storage_vault_name" = "built_in_storage_vault"
);
