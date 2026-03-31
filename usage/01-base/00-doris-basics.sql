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
