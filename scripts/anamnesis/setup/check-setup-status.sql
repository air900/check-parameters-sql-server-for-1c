-- =============================================================================
-- check-setup-status.sql
-- Быстрая проверка состояния первичной настройки SQL Server для Anamnesis Kit.
-- Возвращает 4 числа (0/1) через PRINT:
--   QS:N      — Query Store включён хотя бы на одной user-БД
--   BPT:N     — Blocked Process Threshold (sec), 0 = не настроен
--   RCSI:N    — RCSI включён хотя бы на одной user-БД (кроме system)
--   XE:N      — Extended Events session «_diag_eshn_hang» запущена
--
-- Использование:
--   sqlcmd -S <server> -d master -i check-setup-status.sql
-- =============================================================================
SET NOCOUNT ON;

DECLARE @qs INT, @bpt INT, @rcsi INT, @xe INT;

-- 1. Query Store
SELECT @qs = CASE WHEN EXISTS (
    SELECT 1 FROM sys.databases
    WHERE is_query_store_on = 1
      AND name NOT IN (N'master', N'tempdb', N'model', N'msdb')
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
      AND name NOT IN (N'master', N'tempdb', N'model', N'msdb')
) THEN 1 ELSE 0 END;

-- 4. XE session
SELECT @xe = CASE WHEN EXISTS (
    SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'_diag_eshn_hang'
) THEN 1 ELSE 0 END;

PRINT N'QS:'   + CAST(@qs   AS NVARCHAR(2));
PRINT N'BPT:'  + CAST(@bpt  AS NVARCHAR(10));
PRINT N'RCSI:' + CAST(@rcsi AS NVARCHAR(2));
PRINT N'XE:'   + CAST(@xe   AS NVARCHAR(2));
