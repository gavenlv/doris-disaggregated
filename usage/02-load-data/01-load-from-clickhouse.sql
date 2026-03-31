-- ===============================================
-- 从 ClickHouse 加载数据到 Doris
-- ===============================================
-- Source: ClickHouse
--   Host: localhost:8123
--   User: default
--   Password: (empty)
--   Database: tutorial
-- Target: Doris
-- ===============================================

-- 1. 连接到 ClickHouse 并查看源数据
-- ===============================================

-- 在 Doris 中使用 table_value_function 连接 ClickHouse
-- 语法: curl -u user:password 'http://host:port' 

-- 首先，查看 ClickHouse 中的所有表
-- 使用 clickhouse_table function (需要启用相关配置)

-- 2. 创建 ClickHouse 外部数据源
-- ===============================================

-- 创建 ClickHouse JDBC 资源（需要配置 jdbc_drivers 目录）
-- 注意: 此功能需要 FE 配置 jdbc_drivers_path

-- 方式一: 如果 FE 配置了 JDBC 驱动，可以直接使用 JDBC 表函数
-- 请根据实际情况修改连接信息

-- 3. 从 ClickHouse 读取数据并创建 Doris 表
-- ===============================================

-- 示例: 从 ClickHouse 加载数据
-- 假设 ClickHouse tutorial 数据库中有一个名为 test_table 的表

-- Step 1: 在 Doris 中创建目标表（根据 ClickHouse 表结构）
-- 请根据实际 ClickHouse 表结构修改以下示例

/*
CREATE TABLE IF NOT EXISTS tutorial_doris.test_table (
    id BIGINT,
    name VARCHAR(100),
    created_at DATETIME,
    value DOUBLE
)
ENGINE=OLAP
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10
PROPERTIES (
    "replication_num" = "1"
);
*/

-- Step 2: 从 ClickHouse 读取数据并插入到 Doris
-- 使用 ClickHouse HTTP 接口直接查询

/*
INSERT INTO tutorial_doris.test_table
SELECT * 
FROM clickhouse_table(
    'http://localhost:8123',
    'tutorial',
    'test_table',
    'default',
    ''
);
*/

-- 4. 批量加载多个表
-- ===============================================

-- 如果需要加载 ClickHouse 中的所有表，需要:
-- 1. 先在 ClickHouse 中查询所有表名
-- 2. 获取每个表的结构
-- 3. 在 Doris 中创建对应表
-- 4. 执行数据迁移

-- 5. 使用 S3/对象存储作为中间介质（推荐大数据量场景）
-- ===============================================

-- 5.1 从 ClickHouse 导出数据到本地文件
-- 在 ClickHouse 服务器执行:
/*
clickhouse-client --query "SELECT * FROM tutorial.table_name FORMAT CSV" > data.csv
*/

-- 5.2 上传到对象存储
-- 使用 S3 命令行工具上传

-- 5.3 在 Doris 中创建表
-- CREATE TABLE ... (根据源表结构)

-- 5.4 使用 S3 Table Value Function 加载
/*
INSERT INTO tutorial_doris.target_table
SELECT * 
FROM s3(
    'https://bucket.s3.region.amazonaws.com/path/to/data.csv',
    'your-access-key',
    'your-secret-key',
    'csv',
    'id BIGINT, name VARCHAR(100), created_at DATETIME, value DOUBLE'
);
*/

-- 6. 验证数据加载
-- ===============================================

-- 查看表记录数
-- SELECT COUNT(*) FROM tutorial_doris.test_table;

-- 抽样查看数据
-- SELECT * FROM tutorial_doris.test_table LIMIT 10;

-- 7. 常见问题排查
-- ===============================================

-- Q1: 连接 ClickHouse 失败
-- A: 检查 ClickHouse 服务是否启动，端口是否正确
--    systemctl status clickhouse-server
--    netstat -tlnp | grep 8123

-- Q2: 数据类弄不匹配
-- A: 参考数据类型映射表，确保 Doris 表结构与 ClickHouse 匹配

-- Q3: 导入速度慢
-- A: 调整并发度: SET parallel_fragment_exec_instance_num = 8;
--    调整 batch_size: SET batch_size = 4096;

-- ===============================================
-- 完整示例流程
-- ===============================================

/*
-- 假设 ClickHouse tutorial 数据库中有一个名为 hits 的表

-- 1. 在 ClickHouse 中查看表结构
USE tutorial;
SHOW CREATE TABLE hits;

-- 2. 在 Doris 中创建对应表
CREATE TABLE IF NOT EXISTS tutorial_doris.hits (
    ClickHouseID UInt64,
    Title String,
    URL String,
    CreationDate Date,
    Rating UInt8
)
ENGINE=OLAP
DUPLICATE KEY(ClickHouseID)
DISTRIBUTED BY HASH(ClickHouseID) BUCKETS 10
PROPERTIES (
    "replication_num" = "1"
);

-- 3. 加载数据
INSERT INTO tutorial_doris.hits
SELECT 
    toUInt64(WatchID) as ClickHouseID,
    Title,
    URL,
    CreationDate,
    Rating
FROM clickhouse_table(
    'http://localhost:8123',
    'tutorial',
    'hits',
    'default',
    ''
);

-- 4. 验证
SELECT COUNT(*) FROM tutorial_doris.hits;
*/
