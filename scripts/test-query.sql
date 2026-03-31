USE test;
SHOW TABLES;
DESC test_table;
INSERT INTO test_table VALUES (1, 'hello'), (2, 'doris'), (3, 'cloud');
SELECT * FROM test_table ORDER BY id;
