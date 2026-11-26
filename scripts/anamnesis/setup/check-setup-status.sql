-- =============================================================================
-- check-setup-status.sql
-- Быстрая проверка состояния первичной настройки SQL Server для Anamnesis Kit.
-- Проверяет Query Store и RCSI выбранной базы, а также настройки наблюдения.
-- =============================================================================
SET NOCOUNT ON;

DECLARE @database_id INT = DB_ID(CONVERT(nvarchar(128), 0x$(db_hex)));
IF @database_id IS NULL OR @database_id <= 4
    THROW 50000, N'Укажите доступную пользовательскую базу SQL Server.', 1;

DECLARE @qs INT, @bpt INT, @rcsi INT, @xe INT;

-- 1. Query Store
SELECT @qs = CASE WHEN EXISTS (
    SELECT 1 FROM sys.databases
    WHERE is_query_store_on = 1
      AND database_id = @database_id
) THEN 1 ELSE 0 END;

-- 2. Blocked Process Threshold
SELECT @bpt = CAST(value_in_use AS INT)
FROM sys.configurations
WHERE name = N'blocked process threshold (s)';
IF @bpt IS NULL SET @bpt = 0;

-- 3. RCSI
SELECT @rcsi = CASE WHEN EXISTS (
    SELECT 1 FROM sys.databases
    WHERE is_read_committed_snapshot_on = 1
      AND database_id = @database_id
) THEN 1 ELSE 0 END;

-- 4. XE session
SELECT @xe = CASE WHEN EXISTS (
    SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'_diag_1c_anamnesis_' + CONVERT(nvarchar(10), @database_id)
) THEN 1 ELSE 0 END;

-- 5. LQP (Lightweight Query Profiling — TF 7412)
DECLARE @lqp NVARCHAR(4);
DECLARE @major INT = CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);

IF @major <= 12 SET @lqp = N'NA';
ELSE IF @major >= 15 SET @lqp = N'1';
ELSE
BEGIN
    DECLARE @lqp_status TABLE (TraceFlag INT, Status INT, [Global] INT, [Session] INT);
    INSERT INTO @lqp_status EXEC('DBCC TRACESTATUS(7412) WITH NO_INFOMSGS');
    SET @lqp = CASE WHEN (SELECT TOP 1 ISNULL([Global], 0) FROM @lqp_status) = 1 THEN N'1' ELSE N'0' END;
END;

PRINT N'QS:'   + CAST(@qs   AS NVARCHAR(2));
PRINT N'BPT:'  + CAST(@bpt  AS NVARCHAR(10));
PRINT N'RCSI:' + CAST(@rcsi AS NVARCHAR(2));
PRINT N'XE:'   + CAST(@xe   AS NVARCHAR(2));
PRINT N'LQP:'  + @lqp;
