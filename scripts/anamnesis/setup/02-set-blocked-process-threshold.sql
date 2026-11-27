-- =============================================================================
-- 02-set-blocked-process-threshold.sql
-- Включает captured blocked process report. Без этого XE event
-- blocked_process_report не работает.
-- Идемпотентно. Server-level изменение, требует sysadmin.
-- =============================================================================
SET NOCOUNT ON;

DECLARE @current INT;
SELECT @current = CAST(value_in_use AS INT)
FROM sys.configurations
WHERE name = N'blocked process threshold (s)';

IF @current = 10
BEGIN
    PRINT N'Порог регистрации длительных блокировок уже установлен на 10 секунд.';
    RETURN;
END;

EXEC sp_configure N'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure N'blocked process threshold (s)', 10;
RECONFIGURE;

PRINT N'Порог регистрации длительных блокировок установлен на 10 секунд.';

-- Сводка
SELECT name, value_in_use
FROM sys.configurations
WHERE name = N'blocked process threshold (s)';
