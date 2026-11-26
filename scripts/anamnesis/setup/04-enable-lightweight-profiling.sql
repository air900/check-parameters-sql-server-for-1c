-- =============================================================================
-- 04-enable-lightweight-profiling.sql
-- Включает Trace Flag 7412 (Lightweight Query Profiling) для качества
-- live-статистики в sys.dm_exec_query_statistics_xml на SQL 2016/2017.
-- На SQL 2019+ TF 7412 включён по умолчанию.
-- На SQL 2014 TF 7412 не поддерживается.
--
-- ВАЖНО: DBCC TRACEON(7412, -1) — runtime-only. После рестарта SQL Server
-- флаг сбрасывается. Для постоянного включения вручную добавьте -T7412
-- в startup parameters через SQL Server Configuration Manager.
-- =============================================================================
SET NOCOUNT ON;

DECLARE @major INT = CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);

IF @major <= 12
BEGIN
    PRINT N'TF 7412 не поддерживается на SQL Server 2014 (major=' + CAST(@major AS NVARCHAR(4)) + N'). Пропуск.';
    RETURN;
END;

IF @major >= 15
BEGIN
    PRINT N'SQL Server 2019+ (major=' + CAST(@major AS NVARCHAR(4)) + N'): TF 7412 включён по умолчанию. Действий не требуется.';
    RETURN;
END;

DBCC TRACEON(7412, -1) WITH NO_INFOMSGS;

DECLARE @status TABLE (TraceFlag INT, Status INT, [Global] INT, [Session] INT);
INSERT INTO @status EXEC('DBCC TRACESTATUS(7412) WITH NO_INFOMSGS');

IF (SELECT TOP 1 ISNULL([Global], 0) FROM @status) = 1
BEGIN
    PRINT N'TF 7412 включён глобально (runtime).';
    PRINT N'';
    PRINT N'ВАЖНО: флаг активен только до перезапуска SQL Server.';
    PRINT N'Для постоянного включения добавьте -T7412 в startup parameters';
    PRINT N'через SQL Server Configuration Manager → свойства службы → Startup Parameters.';
END
ELSE
    PRINT N'ОШИБКА: не удалось включить TF 7412. Проверьте права sysadmin.';
