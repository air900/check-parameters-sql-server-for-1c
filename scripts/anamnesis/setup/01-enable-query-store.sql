-- =============================================================================
-- 01-enable-query-store.sql
-- Включает Query Store на целевой БД с настройками для диагностики
-- ESHN-расчёта: 5-минутные интервалы, 4 GB storage, Auto Plan Correction.
-- Идемпотентно — повторный запуск не ломает существующие настройки.
-- Использование:
--   sqlcmd -S MSSQL-TEST -d master -i 01-enable-query-store.sql -v db=eshn_test1
-- =============================================================================
SET NOCOUNT ON;
DECLARE @db SYSNAME = N'$(db)';
DECLARE @sql NVARCHAR(MAX);

-- Проверка: БД существует и доступна
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @db AND state_desc = N'ONLINE')
BEGIN
    RAISERROR(N'База %s не существует или не online', 16, 1, @db);
    RETURN;
END;

-- 1. Включить Query Store
SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET QUERY_STORE = ON;';
EXEC sp_executesql @sql;

-- 2. Параметры QS
SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = AUTO,
    INTERVAL_LENGTH_MINUTES = 5,
    MAX_STORAGE_SIZE_MB = 4096,
    MAX_PLANS_PER_QUERY = 200,
    DATA_FLUSH_INTERVAL_SECONDS = 60,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30)
);';
EXEC sp_executesql @sql;

-- 3. Auto Plan Correction (доступен только на 2017+)
IF CAST(SERVERPROPERTY(N'ProductMajorVersion') AS INT) >= 14
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) +
        N' SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);';
    EXEC sp_executesql @sql;
END;

-- 4. Сводка результата.
-- NB: sys.database_query_store_options доступна ТОЛЬКО из контекста целевой БД,
-- из master её данные приходят NULL. Поэтому простая проверка через is_query_store_on.
DECLARE @qs_on BIT;
SELECT @qs_on = is_query_store_on FROM sys.databases WHERE name = @db;
IF @qs_on = 1
    PRINT N'Query Store ON для ' + @db + N' (READ_WRITE, MAX_STORAGE_SIZE_MB = 4096, INTERVAL = 5 min)';
ELSE
    PRINT N'ВНИМАНИЕ: Query Store не включён для ' + @db + N' (что-то пошло не так)';
