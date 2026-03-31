-- ===============================================
-- Doris 基础配置和使用
-- ===============================================
-- Description: Doris 基础操作指南
-- Connection: mysql -h 127.0.0.1 -P 9030 -u root
-- ===============================================

-- 1. 查看集群状态
-- ===============================================

-- 查看 FE 状态
SHOW FRONTENDS;

-- 查看 BE 状态
SHOW BACKENDS;

-- 查看 Compute Node 状态
SHOW COMPUTE GROUPS;

-- 查看数据库
SHOW DATABASES;

-- 2. 创建数据库
-- ===============================================

CREATE DATABASE IF NOT EXISTS tutorial_doris;

USE tutorial_doris;

-- 3. 查看 Doris 表结构
-- ===============================================

SHOW TABLES;

-- 查看表结构
-- DESC table_name;

-- 4. 基础查询示例
-- ===============================================

-- 设置查询超时时间（秒）
SET query_timeout = 300;

-- 开启向量化引擎（提升查询性能）
SET enable_vectorized_engine = true;

-- 5. 常见数据类型映射
-- ===============================================
-- ClickHouse -> Doris
-- -----------------------------------------------
-- UInt8/16/32/64    -> TINYINT/SMALLINT/INT/BIGINT
-- Int8/16/32/64      -> TINYINT/SMALLINT/INT/BIGINT
-- Float32           -> FLOAT
-- Float64           -> DOUBLE
-- Decimal(P,S)       -> DECIMAL(P,S)
-- String             -> VARCHAR
-- FixedString(N)     -> CHAR(N)
-- Date               -> DATE
-- DateTime           -> DATETIME
-- Array(T)           -> ARRAY<T>
-- ===============================================

-- ===============================================
-- 6. CRUD 操作测试
-- ===============================================
-- Doris 支持多种表模型:
-- - DUPLICATE: 允许重复数据，适合日志类场景
-- - UNIQUE: 主键唯一，支持实时更新
-- - AGGREGATE: 预聚合，适合统计类场景
-- ===============================================

DROP TABLE IF EXISTS tutorial_doris.crud_test;

-- 创建测试表 (UNIQUE 模型 - 支持主键唯一和实时更新)
CREATE TABLE crud_test (
    id BIGINT NOT NULL,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(200),
    age INT,
    create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
UNIQUE KEY(id, name)
DISTRIBUTED BY HASH(id) BUCKETS 3
PROPERTIES (
    "replication_num" = "1",
    "storage_vault_name" = "minio_vault"
);

-- ===============================================
-- INSERT - 插入数据
-- ===============================================

-- 单条插入
INSERT INTO crud_test (id, name, email, age) VALUES (1, '张三', 'zhangsan@example.com', 28);

-- 多条插入
INSERT INTO crud_test (id, name, email, age) VALUES
    (2, '李四', 'lisi@example.com', 35),
    (3, '王五', 'wangwu@example.com', 42),
    (4, '赵六', 'zhaoliu@example.com', 25),
    (5, '钱七', 'qianqi@example.com', 31);

-- ===============================================
-- SELECT - 查询数据
-- ===============================================

-- 全表查询
SELECT * FROM crud_test ORDER BY id;

-- 条件查询
SELECT * FROM crud_test WHERE age > 30 ORDER BY age DESC;

-- 聚合查询
SELECT COUNT(*) as total_count, AVG(age) as avg_age FROM crud_test;

-- ===============================================
-- UPDATE - 更新数据
-- UNIQUE 表支持 UPDATE 操作
-- ===============================================

-- 更新单条
UPDATE crud_test SET email = 'updated@example.com' WHERE id = 1;

-- 批量更新
UPDATE crud_test SET age = age + 1 WHERE age < 30;

-- 验证更新
SELECT * FROM crud_test ORDER BY id;

-- ===============================================
-- DELETE - 删除数据
-- ===============================================

-- 删除单条
DELETE FROM crud_test WHERE id = 5;

-- 删除多条
DELETE FROM crud_test WHERE age > 40;

-- 验证删除
SELECT * FROM crud_test ORDER BY id;

-- ===============================================
-- 7. 分区表测试
-- ===============================================
-- Doris 支持多种分区方式: RANGE, LIST, DATE
-- ===============================================

DROP TABLE IF EXISTS tutorial_doris.partition_test;

-- 创建 RANGE 分区表 (按日期)
CREATE TABLE partition_test (
    id BIGINT NOT NULL,
    event_date DATE NOT NULL,
    event_name VARCHAR(100),
    event_type VARCHAR(50),
    amount DECIMAL(10, 2),
    create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
DUPLICATE KEY(id, event_date)
PARTITION BY RANGE(event_date) (
    PARTITION p2026_01 VALUES LESS THAN ('2026-02-01'),
    PARTITION p2026_02 VALUES LESS THAN ('2026-03-01'),
    PARTITION p2026_03 VALUES LESS THAN ('2026-04-01'),
    PARTITION p2026_04 VALUES LESS THAN ('2026-05-01'),
    PARTITION p2026_05 VALUES LESS THAN ('2026-06-01'),
    PARTITION p2026_06 VALUES LESS THAN ('2026-07-01'),
    PARTITION p2026_07 VALUES LESS THAN ('2026-08-01'),
    PARTITION pmax VALUES LESS THAN MAXVALUE
)
DISTRIBUTED BY HASH(id) BUCKETS 3
PROPERTIES (
    "replication_num" = "1",
    "storage_vault_name" = "minio_vault"
);

-- ===============================================
-- 插入分区测试数据
-- ===============================================

INSERT INTO partition_test (id, event_date, event_name, event_type, amount) VALUES
    (1, '2026-01-15', '新年活动', 'promotion', 1500.00),
    (2, '2026-01-20', '春节促销', 'promotion', 3200.50),
    (3, '2026-02-10', '情人节活动', 'marketing', 2800.00),
    (4, '2026-02-28', '元宵节特惠', 'promotion', 1999.00),
    (5, '2026-03-15', '315维权', 'marketing', 4500.00),
    (6, '2026-03-20', '春季新品', 'product', 6800.00),
    (7, '2026-04-05', '清明节活动', 'promotion', 2200.00),
    (8, '2026-04-18', '地球日促销', 'marketing', 1750.00),
    (9, '2026-05-01', '劳动节特惠', 'promotion', 8500.00),
    (10, '2026-05-10', '母亲节活动', 'marketing', 3900.00),
    (11, '2026-06-01', '儿童节促销', 'promotion', 5200.00),
    (12, '2026-07-15', '夏季清凉', 'product', 3100.00);

-- ===============================================
-- 查询分区数据
-- ===============================================

-- 查看所有分区
SHOW PARTITIONS FROM partition_test;

-- 查询特定分区
SELECT * FROM partition_test PARTITION (p2026_03) ORDER BY id;

-- 按分区查询统计
SELECT
    event_date,
    COUNT(*) as event_count,
    SUM(amount) as total_amount
FROM partition_test
GROUP BY event_date
ORDER BY event_date;

-- ===============================================
-- 8. 分桶表测试 (BUCKETING)
-- ===============================================
-- 分桶是将数据进一步拆分到多个桶中
-- 适合高基数列的哈希分布
-- ===============================================

DROP TABLE IF EXISTS tutorial_doris.bucket_test;

-- 创建分桶表 (按用户 ID 分桶)
-- 注意: DUPLICATE KEY 必须与 DISTRIBUTED BY 的列匹配，且列顺序必须一致
CREATE TABLE bucket_test (
    id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    order_id BIGINT NOT NULL,
    user_name VARCHAR(100),
    order_amount DECIMAL(10, 2),
    order_status VARCHAR(20) DEFAULT 'pending',
    create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
DUPLICATE KEY(id, user_id, order_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 8
PROPERTIES (
    "replication_num" = "1",
    "storage_vault_name" = "minio_vault"
);

-- ===============================================
-- 插入分桶测试数据
-- ===============================================

INSERT INTO bucket_test (id, user_id, user_name, order_id, order_amount, order_status) VALUES
    (1, 1001, '用户A', 90001, 299.00, 'completed'),
    (2, 1002, '用户B', 90002, 599.00, 'completed'),
    (3, 1001, '用户A', 90003, 899.00, 'shipped'),
    (4, 1003, '用户C', 90004, 1299.00, 'pending'),
    (5, 1002, '用户B', 90005, 199.00, 'completed'),
    (6, 1004, '用户D', 90006, 2499.00, 'completed'),
    (7, 1001, '用户A', 90007, 399.00, 'shipped'),
    (8, 1005, '用户E', 90008, 799.00, 'pending'),
    (9, 1003, '用户C', 90009, 1599.00, 'completed'),
    (10, 1002, '用户B', 90010, 699.00, 'completed');

-- ===============================================
-- 分桶表查询分析
-- ===============================================

-- 查看分桶信息
SHOW PARTITIONS FROM bucket_test;

-- 按用户统计订单
SELECT
    user_id,
    user_name,
    COUNT(*) as order_count,
    SUM(order_amount) as total_amount,
    AVG(order_amount) as avg_amount
FROM bucket_test
GROUP BY user_id, user_name
ORDER BY total_amount DESC;

-- 订单状态分布
SELECT
    order_status,
    COUNT(*) as count,
    SUM(order_amount) as total
FROM bucket_test
GROUP BY order_status;

-- ===============================================
-- 9. 复合测试 - 分区 + 分桶
-- ===============================================

DROP TABLE IF EXISTS tutorial_doris.partition_bucket_test;

-- 注意: DUPLICATE KEY 必须与 DISTRIBUTED BY 的列匹配
CREATE TABLE partition_bucket_test (
    id BIGINT NOT NULL,
    order_date DATE NOT NULL,
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    order_status VARCHAR(20) DEFAULT 'pending',
    product_name VARCHAR(200),
    quantity INT NOT NULL DEFAULT 1,
    unit_price DECIMAL(10, 2),
    total_amount DECIMAL(10, 2),
    create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
DUPLICATE KEY(id, order_date, user_id)
PARTITION BY RANGE(order_date) (
    PARTITION p2026_Q1 VALUES LESS THAN ('2026-04-01'),
    PARTITION p2026_Q2 VALUES LESS THAN ('2026-07-01'),
    PARTITION p2026_Q3 VALUES LESS THAN ('2026-10-01'),
    PARTITION p2026_Q4 VALUES LESS THAN ('2027-01-01'),
    PARTITION pmax VALUES LESS THAN MAXVALUE
)
DISTRIBUTED BY HASH(user_id, product_id) BUCKETS 16
PROPERTIES (
    "replication_num" = "1",
    "storage_vault_name" = "minio_vault"
);

-- ===============================================
-- 插入复合测试数据
-- ===============================================

INSERT INTO partition_bucket_test (id, order_date, user_id, product_id, product_name, quantity, unit_price, total_amount, order_status) VALUES
    (1, '2026-01-15', 1001, 5001, '笔记本电脑', 1, 5999.00, 5999.00, 'completed'),
    (2, '2026-01-20', 1002, 5002, '无线鼠标', 2, 89.00, 178.00, 'completed'),
    (3, '2026-02-14', 1001, 5003, '机械键盘', 1, 399.00, 399.00, 'shipped'),
    (4, '2026-02-28', 1003, 5004, '显示器', 1, 1899.00, 1899.00, 'completed'),
    (5, '2026-03-10', 1004, 5005, '耳机', 1, 299.00, 299.00, 'pending'),
    (6, '2026-03-25', 1002, 5001, '笔记本电脑', 1, 5999.00, 5999.00, 'shipped'),
    (7, '2026-04-05', 1005, 5006, '平板电脑', 1, 3299.00, 3299.00, 'completed'),
    (8, '2026-04-20', 1001, 5002, '无线鼠标', 3, 89.00, 267.00, 'completed'),
    (9, '2026-05-01', 1003, 5007, '固态硬盘', 2, 599.00, 1198.00, 'completed'),
    (10, '2026-05-15', 1006, 5008, '键盘', 1, 199.00, 199.00, 'pending');

-- ===============================================
-- 复合查询分析
-- ===============================================

-- 按季度统计
SELECT
    CASE
        WHEN order_date < '2026-04-01' THEN 'Q1'
        WHEN order_date < '2026-07-01' THEN 'Q2'
        WHEN order_date < '2026-10-01' THEN 'Q3'
        ELSE 'Q4'
    END as quarter,
    COUNT(*) as order_count,
    SUM(total_amount) as total_revenue,
    AVG(total_amount) as avg_order_value
FROM partition_bucket_test
GROUP BY quarter
ORDER BY quarter;

-- 用户消费排行
SELECT
    user_id,
    COUNT(*) as order_count,
    SUM(total_amount) as total_spent,
    MAX(total_amount) as max_order
FROM partition_bucket_test
WHERE order_status = 'completed'
GROUP BY user_id
ORDER BY total_spent DESC
LIMIT 10;

-- 产品销量排行
SELECT
    product_id,
    product_name,
    SUM(quantity) as total_quantity,
    SUM(total_amount) as total_revenue
FROM partition_bucket_test
GROUP BY product_id, product_name
ORDER BY total_revenue DESC
LIMIT 10;

-- ===============================================
-- 10. 数据验证
-- ===============================================

-- 验证所有表的数据
SELECT 'crud_test' as table_name, COUNT(*) as row_count FROM crud_test
UNION ALL
SELECT 'partition_test', COUNT(*) FROM partition_test
UNION ALL
SELECT 'bucket_test', COUNT(*) FROM bucket_test
UNION ALL
SELECT 'partition_bucket_test', COUNT(*) FROM partition_bucket_test;

-- 查看 MinIO 中的数据文件
-- kubectl exec -it minio-xxx -n doris -- mc ls local/doris/doris-data/data/
