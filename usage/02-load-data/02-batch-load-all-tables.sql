-- ===============================================
-- 自动化加载 ClickHouse 所有表到 Doris
-- ===============================================
-- Description: 自动发现 ClickHouse 中的所有表并加载到 Doris
-- Source: ClickHouse (localhost:8123, database: tutorial)
-- Target: Doris
-- ===============================================

-- 在 ClickHouse 中执行以下命令获取表结构:
/*
clickhouse-client --query "
SELECT 
    'CREATE TABLE IF NOT EXISTS tutorial_doris.' || name || ' ('
    || arrayStringConcat(arrayMap(x -> x[1] || ' ' || x[2], 
        arrayFilter(x -> NOT startsWith(x[1], '_'), 
            arrayMap(x -> [x[1], 
                case when x[1] = 'UInt64' then 'BIGINT'
                     when x[1] = 'Int64' then 'BIGINT'  
                     when x[1] = 'UInt32' then 'INT'
                     when x[1] = 'Int32' then 'INT'
                     when x[1] = 'UInt16' then 'SMALLINT'
                     when x[1] = 'Int16' then 'SMALLINT'
                     when x[1] = 'UInt8' then 'TINYINT'
                     when x[1] = 'Int8' then 'TINYINT'
                     when x[1] = 'Float32' then 'FLOAT'
                     when x[1] = 'Float64' then 'DOUBLE'
                     when x[1] = 'String' then 'VARCHAR'
                     when x[1] = 'Date' then 'DATE'
                     when x[1] = 'DateTime' then 'DATETIME'
                     else x[1] END], columns))), ', '))
    || ') ENGINE=OLAP DUPLICATE KEY('
    || (SELECT arrayStringConcat(arraySlice(arrayMap(x -> x[1], 
        arrayFilter(x -> NOT startsWith(x[1], '_'), columns)), 1, 1), ', '))
    || ') DISTRIBUTED BY HASH('
    || (SELECT arrayStringConcat(arraySlice(arrayMap(x -> x[1], 
        arrayFilter(x -> NOT startsWith(x[1], '_'), columns)), 1, 1), ', '))
    || ') BUCKETS 10 PROPERTIES (\"replication_num\" = \"1\");'
FROM system.tables 
WHERE database = 'tutorial' AND name = 'your_table_name'
" > create_table.sql
*/

-- ===============================================
-- 批量加载脚本示例
-- ===============================================

-- Step 1: 在 ClickHouse 中获取所有表名
/*
clickhouse-client --query "SELECT name FROM system.tables WHERE database = 'tutorial'" > tables.txt
*/

-- Step 2: 循环加载每个表
/*
#!/bin/bash
DORIS_HOST="127.0.0.1"
DORIS_PORT="9030"
CH_HOST="localhost:8123"

while read table_name; do
    echo "Loading table: $table_name"
    
    # 创建表（如已存在可跳过）
    # mysql -h $DORIS_HOST -P $DORIS_PORT -u root < "create_${table_name}.sql"
    
    # 加载数据
    # INSERT INTO tutorial_doris.$table_name SELECT * FROM clickhouse_table(...);
    
done < tables.txt
*/

-- ===============================================
-- 使用 INSERT FROM SELECT 加载数据
-- ===============================================

-- 方式一: 使用 ClickHouse 表函数 (需要 FE 配置支持)
/*
INSERT INTO tutorial_doris.hits
SELECT * 
FROM clickhouse_table(
    'http://localhost:8123',
    'tutorial',
    'hits',
    'default',
    ''
);
*/

-- 方式二: 使用 CSV 文件中间格式
/*
-- 2.1 ClickHouse 端导出
clickhouse-client --query "SELECT * FROM tutorial.hits FORMAT CSV" > hits.csv

-- 2.2 上传到 S3 (示例)
aws s3 cp hits.csv s3://your-bucket/hits.csv

-- 2.3 Doris 端加载
INSERT INTO tutorial_doris.hits
SELECT * 
FROM s3(
    's3://your-bucket/hits.csv',
    'your-access-key',
    'your-secret-key',
    'csv'
);
*/

-- ===============================================
-- 性能优化建议
-- ===============================================

-- 1. 调整并发度
SET parallel_fragment_exec_instance_num = 16;

-- 2. 调整批处理大小
SET batch_size = 8192;

-- 3. 调整查询超时 (大数据量需要更长)
SET query_timeout = 3600;

-- 4. 关闭不必要的功能加速导入
SET enable_vectorized_engine = true;
SET enable_pipeline_engine = true;

-- ===============================================
-- 数据验证
-- ===============================================

-- 对比源表和目标表记录数
/*
-- ClickHouse 端
SELECT 'ClickHouse', table, count() FROM system.tables WHERE database = 'tutorial' GROUP BY table
UNION ALL
-- Doris 端
SELECT 'Doris', table_name, table_rows FROM information_schema.tables WHERE table_schema = 'tutorial_doris'
ORDER BY table;
*/

-- ===============================================
-- 增量加载 (如果需要)
-- ===============================================

-- 对于增量数据，可以使用 WHERE 条件过滤
/*
INSERT INTO tutorial_doris.hits
SELECT * 
FROM clickhouse_table(
    'http://localhost:8123',
    'tutorial',
    'hits',
    'default',
    ''
)
WHERE CreationDate >= '2024-01-01';
*/
