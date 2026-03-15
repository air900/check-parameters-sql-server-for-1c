-- ============================================================================
-- СБОР ДАННЫХ PostgreSQL ДЛЯ РАБОТЫ С 1С:ПРЕДПРИЯТИЕ
-- ============================================================================
--
-- Версия:       2.0
-- Дата:         2026-03-15
-- Совместимость: PostgreSQL 10–17+
-- Тип:          Сбор данных (read-only)
--
-- Назначение:
--   Сбор текущих значений параметров PostgreSQL для оценки конфигурации
--   сервера при работе с 1С:Предприятие. Скрипт выводит фактические значения
--   в двух форматах: для отображения (Display) и для машинной обработки (Value).
--
-- Колонки:
--   N       — порядковый номер для сортировки
--   Section — группа параметров (для UI)
--   Key     — техническое имя параметра (для rule engine / API)
--   Label   — человекочитаемое описание (для UI)
--   Display — значение для отображения пользователю ("128 MB", "on")
--   Value   — машиночитаемое значение (байты, секунды, true/false, числа)
--
-- Использование:
--   Откройте в pgAdmin или DBeaver, выполните целиком (F5).
--   PowerShell-скрипт использует колонки Key, Value, Display, Section.
--
-- Важно:
--   Скрипт НЕ создаёт объектов в базе данных.
--   Скрипт НЕ изменяет данные или настройки.
--   Используются только SELECT-запросы к системным представлениям.
--
-- Контакты:
--   audit-reshenie.ru | info@audit-reshenie.ru
--
-- ============================================================================

SELECT
    r."N",
    r."Section",
    r."Key",
    r."Label",
    r."Display",
    r."Value"
FROM (

-- ============================================================================
-- ИНФОРМАЦИЯ О СЕРВЕРЕ (info-параметры, не анализируются rule engine)
-- ============================================================================

SELECT 1 AS "N", 'server_info' AS "Section",
    '_info_pg_version' AS "Key",
    'Версия PostgreSQL' AS "Label",
    version() AS "Display",
    (SELECT setting FROM pg_settings WHERE name = 'server_version') AS "Value"

UNION ALL
SELECT 2, 'server_info',
    '_info_database',
    'База данных',
    current_database() || ' (' || pg_size_pretty(pg_database_size(current_database())) || ')',
    pg_database_size(current_database())::text

UNION ALL
SELECT 3, 'server_info',
    '_info_server_address',
    'Адрес сервера',
    COALESCE(inet_server_addr()::text, 'localhost') || ':' || COALESCE(inet_server_port()::text, '5432'),
    COALESCE(inet_server_port()::text, '5432')

UNION ALL
SELECT 4, 'server_info',
    '_info_uptime',
    'Время работы',
    CASE
        WHEN EXTRACT(DAY FROM (now() - pg_postmaster_start_time())) > 0
        THEN EXTRACT(DAY FROM (now() - pg_postmaster_start_time()))::int::text || ' дн. '
        ELSE ''
    END || to_char(now() - pg_postmaster_start_time(), 'HH24 ч. MI мин.'),
    EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time()))::bigint::text

UNION ALL
SELECT 5, 'server_info',
    '_info_check_date',
    'Дата проверки',
    to_char(current_timestamp, 'DD.MM.YYYY HH24:MI:SS'),
    to_char(current_timestamp, 'YYYY-MM-DD"T"HH24:MI:SS')

UNION ALL

-- ============================================================================
-- ПАМЯТЬ И КЭШ
-- ============================================================================

SELECT 10, 'memory',
    'shared_buffers',
    'Кэш данных в памяти',
    pg_size_pretty(pg_size_bytes(current_setting('shared_buffers'))),
    pg_size_bytes(current_setting('shared_buffers'))::text

UNION ALL
SELECT 11, 'memory',
    'work_mem',
    'Память для сортировок',
    pg_size_pretty(pg_size_bytes(current_setting('work_mem'))),
    pg_size_bytes(current_setting('work_mem'))::text

UNION ALL
SELECT 12, 'memory',
    'effective_cache_size',
    'Оценка доступного кэша ОС',
    pg_size_pretty(pg_size_bytes(current_setting('effective_cache_size'))),
    pg_size_bytes(current_setting('effective_cache_size'))::text

UNION ALL
SELECT 13, 'memory',
    'maintenance_work_mem',
    'Память для обслуживания БД',
    pg_size_pretty(pg_size_bytes(current_setting('maintenance_work_mem'))),
    pg_size_bytes(current_setting('maintenance_work_mem'))::text

UNION ALL
SELECT 14, 'memory',
    'huge_pages',
    'Большие страницы памяти',
    current_setting('huge_pages'),
    current_setting('huge_pages')

UNION ALL

-- ============================================================================
-- ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)
-- ============================================================================

SELECT 20, 'wal',
    'synchronous_commit',
    'Синхронная запись при фиксации',
    current_setting('synchronous_commit'),
    CASE current_setting('synchronous_commit') WHEN 'on' THEN 'true' WHEN 'off' THEN 'false' ELSE current_setting('synchronous_commit') END

UNION ALL
SELECT 21, 'wal',
    'fsync',
    'Гарантия записи на диск (fsync)',
    current_setting('fsync'),
    CASE current_setting('fsync') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL
SELECT 22, 'wal',
    'checkpoint_timeout',
    'Интервал контрольных точек',
    ((SELECT setting::int FROM pg_settings WHERE name = 'checkpoint_timeout') / 60)::text || ' мин',
    (SELECT setting FROM pg_settings WHERE name = 'checkpoint_timeout')

UNION ALL
SELECT 23, 'wal',
    'min_wal_size',
    'Мин. размер журнала',
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_pretty(pg_size_bytes(current_setting('min_wal_size')))
        ELSE 'n/a'
    END,
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_bytes(current_setting('min_wal_size'))::text
        ELSE ''
    END

UNION ALL
SELECT 24, 'wal',
    'max_wal_size',
    'Макс. размер журнала',
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_pretty(pg_size_bytes(current_setting('max_wal_size')))
        ELSE 'n/a'
    END,
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_bytes(current_setting('max_wal_size'))::text
        ELSE ''
    END

UNION ALL
SELECT 25, 'wal',
    'checkpoint_completion_target',
    'Полнота контрольных точек',
    current_setting('checkpoint_completion_target'),
    current_setting('checkpoint_completion_target')

UNION ALL
SELECT 26, 'wal',
    'wal_buffers',
    'Буферы журнала',
    pg_size_pretty(pg_size_bytes(current_setting('wal_buffers'))),
    pg_size_bytes(current_setting('wal_buffers'))::text

UNION ALL
SELECT 27, 'wal',
    'wal_level',
    'Уровень журналирования',
    current_setting('wal_level'),
    current_setting('wal_level')

UNION ALL

-- ============================================================================
-- ОПТИМИЗАЦИЯ ЗАПРОСОВ
-- ============================================================================

SELECT 30, 'planner',
    'random_page_cost',
    'Стоимость случайного чтения',
    current_setting('random_page_cost'),
    current_setting('random_page_cost')

UNION ALL
SELECT 31, 'planner',
    'join_collapse_limit',
    'Лимит оптимизации соединений',
    current_setting('join_collapse_limit'),
    current_setting('join_collapse_limit')

UNION ALL
SELECT 32, 'planner',
    'from_collapse_limit',
    'Лимит оптимизации подзапросов',
    current_setting('from_collapse_limit'),
    current_setting('from_collapse_limit')

UNION ALL
SELECT 33, 'planner',
    'geqo_threshold',
    'Порог генетического оптимизатора',
    current_setting('geqo_threshold'),
    current_setting('geqo_threshold')

UNION ALL
SELECT 34, 'planner',
    'default_statistics_target',
    'Детальность статистики',
    current_setting('default_statistics_target'),
    current_setting('default_statistics_target')

UNION ALL
SELECT 35, 'planner',
    'jit',
    'JIT-компиляция',
    COALESCE(current_setting('jit', true), 'n/a'),
    CASE COALESCE(current_setting('jit', true), '')
        WHEN 'on' THEN 'true' WHEN 'off' THEN 'false' ELSE ''
    END

UNION ALL
SELECT 36, 'planner',
    'max_parallel_workers_per_gather',
    'Параллельная обработка',
    current_setting('max_parallel_workers_per_gather'),
    current_setting('max_parallel_workers_per_gather')

UNION ALL

-- ============================================================================
-- ПОДКЛЮЧЕНИЯ И СЕАНСЫ
-- ============================================================================

SELECT 40, 'connections',
    'max_connections',
    'Макс. подключений',
    current_setting('max_connections'),
    current_setting('max_connections')

UNION ALL
SELECT 41, 'connections',
    'idle_in_transaction_session_timeout',
    'Тайм-аут зависших транзакций',
    CASE
        WHEN current_setting('server_version_num')::int >= 90600
        THEN ((SELECT setting::bigint FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout') / 1000)::text || ' сек'
        ELSE 'n/a'
    END,
    CASE
        WHEN current_setting('server_version_num')::int >= 90600
        THEN (SELECT setting FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout')
        ELSE ''
    END

UNION ALL
SELECT 42, 'connections',
    'max_locks_per_transaction',
    'Лимит блокировок',
    current_setting('max_locks_per_transaction'),
    current_setting('max_locks_per_transaction')

UNION ALL

-- ============================================================================
-- АВТООЧИСТКА (AUTOVACUUM)
-- ============================================================================

SELECT 50, 'autovacuum',
    'autovacuum',
    'Автоочистка включена',
    current_setting('autovacuum'),
    CASE current_setting('autovacuum') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL
SELECT 51, 'autovacuum',
    'autovacuum_naptime',
    'Интервал проверки',
    (SELECT setting FROM pg_settings WHERE name = 'autovacuum_naptime') || ' сек',
    (SELECT setting FROM pg_settings WHERE name = 'autovacuum_naptime')

UNION ALL
SELECT 52, 'autovacuum',
    'autovacuum_max_workers',
    'Процессов автоочистки',
    current_setting('autovacuum_max_workers'),
    current_setting('autovacuum_max_workers')

UNION ALL
SELECT 53, 'autovacuum',
    'autovacuum_vacuum_cost_limit',
    'Лимит I/O автоочистки',
    current_setting('autovacuum_vacuum_cost_limit'),
    current_setting('autovacuum_vacuum_cost_limit')

UNION ALL

-- ============================================================================
-- ФОНОВАЯ ЗАПИСЬ
-- ============================================================================

SELECT 60, 'bgwriter',
    'bgwriter_delay',
    'Пауза фоновой записи',
    (SELECT setting FROM pg_settings WHERE name = 'bgwriter_delay') || ' мс',
    (SELECT setting FROM pg_settings WHERE name = 'bgwriter_delay')

UNION ALL
SELECT 61, 'bgwriter',
    'bgwriter_lru_maxpages',
    'Макс. страниц за цикл',
    current_setting('bgwriter_lru_maxpages'),
    current_setting('bgwriter_lru_maxpages')

UNION ALL
SELECT 62, 'bgwriter',
    'effective_io_concurrency',
    'Параллельное чтение с диска',
    current_setting('effective_io_concurrency'),
    current_setting('effective_io_concurrency')

UNION ALL

-- ============================================================================
-- СОВМЕСТИМОСТЬ С 1С
-- ============================================================================

SELECT 70, 'compat_1c',
    'standard_conforming_strings',
    'Режим обработки строк',
    current_setting('standard_conforming_strings'),
    CASE current_setting('standard_conforming_strings') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL
SELECT 71, 'compat_1c',
    'escape_string_warning',
    'Предупреждения экранирования',
    current_setting('escape_string_warning'),
    CASE current_setting('escape_string_warning') WHEN 'on' THEN 'true' ELSE 'false' END

UNION ALL

-- ============================================================================
-- РЕАЛЬНЫЕ МЕТРИКИ
-- ============================================================================

SELECT 80, 'metrics',
    '_metric_cache_hit_ratio',
    'Эффективность кэширования',
    CASE
        WHEN blks_hit + blks_read = 0 THEN 'нет данных'
        ELSE round(100.0 * blks_hit / (blks_hit + blks_read), 2)::text || '%'
    END,
    CASE
        WHEN blks_hit + blks_read = 0 THEN ''
        ELSE round(100.0 * blks_hit / (blks_hit + blks_read), 4)::text
    END
FROM pg_stat_database WHERE datname = current_database()

UNION ALL

SELECT 81, 'metrics',
    '_metric_temp_files_count',
    'Временные файлы (количество)',
    temp_files::text,
    temp_files::text
FROM pg_stat_database WHERE datname = current_database()

UNION ALL

SELECT 82, 'metrics',
    '_metric_temp_files_bytes',
    'Временные файлы (объём)',
    pg_size_pretty(temp_bytes),
    temp_bytes::text
FROM pg_stat_database WHERE datname = current_database()

UNION ALL

-- Контрольные точки
SELECT 83, 'metrics',
    '_metric_checkpoints_timed',
    'Контрольные точки (по расписанию)',
    COALESCE((to_jsonb(s.*) ->> 'checkpoints_timed'), 'n/a'),
    COALESCE((to_jsonb(s.*) ->> 'checkpoints_timed'), '')
FROM pg_stat_bgwriter s

UNION ALL

SELECT 84, 'metrics',
    '_metric_checkpoints_req',
    'Контрольные точки (вынужденные)',
    COALESCE((to_jsonb(s.*) ->> 'checkpoints_req'), 'n/a'),
    COALESCE((to_jsonb(s.*) ->> 'checkpoints_req'), '')
FROM pg_stat_bgwriter s

UNION ALL

-- ============================================================================
-- РАЗДУТЫЕ ТАБЛИЦЫ (топ-5)
-- ============================================================================

SELECT bt."N", bt."Section", bt."Key", bt."Label", bt."Display", bt."Value"
FROM (
    SELECT
        90 + row_number() OVER (ORDER BY n_dead_tup DESC) AS "N",
        'bloat' AS "Section",
        '_bloat_' || schemaname || '.' || relname AS "Key",
        schemaname || '.' || relname AS "Label",
        pg_size_pretty(pg_total_relation_size(relid)) ||
            ' / мусор: ' ||
            CASE
                WHEN n_live_tup + n_dead_tup = 0 THEN '0%'
                ELSE round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1)::text || '%'
            END ||
            ' / autovacuum: ' ||
            CASE
                WHEN last_autovacuum IS NULL THEN 'не выполнялся'
                ELSE to_char(last_autovacuum, 'DD.MM.YYYY HH24:MI')
            END AS "Display",
        json_build_object(
            'size_bytes', pg_total_relation_size(relid),
            'dead_ratio', CASE WHEN n_live_tup + n_dead_tup = 0 THEN 0
                ELSE round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1) END,
            'dead_tuples', n_dead_tup,
            'live_tuples', n_live_tup
        )::text AS "Value"
    FROM pg_stat_user_tables
    WHERE n_live_tup + n_dead_tup > 1000
    ORDER BY n_dead_tup DESC
    LIMIT 5
) bt

UNION ALL

-- ============================================================================
-- ЗАВИСШИЕ СЕАНСЫ
-- ============================================================================

SELECT si."N", si."Section", si."Key", si."Label", si."Display", si."Value"
FROM (
    SELECT
        100 + row_number() OVER (ORDER BY state_change ASC) AS "N",
        'idle_sessions' AS "Section",
        '_idle_txn_' || pid::text AS "Key",
        COALESCE(usename, 'неизвестен') ||
            ' (' || COALESCE(client_addr::text, 'localhost') || ')' AS "Label",
        'простой: ' || to_char(now() - state_change, 'HH24 ч. MI мин.') AS "Display",
        EXTRACT(EPOCH FROM (now() - state_change))::bigint::text AS "Value"
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
      AND pid <> pg_backend_pid()
    ORDER BY state_change ASC
) si

UNION ALL

SELECT 100, 'idle_sessions', '_idle_txn_none', 'Зависших сеансов нет', '', '0'
WHERE NOT EXISTS (
    SELECT 1 FROM pg_stat_activity
    WHERE state = 'idle in transaction' AND pid <> pg_backend_pid()
)

) AS r("N", "Section", "Key", "Label", "Display", "Value")
ORDER BY r."N"
;

-- ============================================================================
-- КОНЕЦ СКРИПТА СБОРА ДАННЫХ v2.0
-- ============================================================================
