-- ============================================================================
-- СБОР ДАННЫХ PostgreSQL ДЛЯ РАБОТЫ С 1С:ПРЕДПРИЯТИЕ
-- ============================================================================
--
-- Версия:       1.1
-- Дата:         2026-03-15
-- Совместимость: PostgreSQL 10–17+
-- Тип:          Сбор данных (read-only)
--
-- Назначение:
--   Сбор текущих значений параметров PostgreSQL для оценки конфигурации
--   сервера при работе с 1С:Предприятие. Скрипт выводит только фактические
--   значения без оценок, пороговых сравнений и рекомендаций.
--
-- Колонки:
--   N        — порядковый номер для сортировки
--   Раздел   — группа параметров (для UI)
--   Ключ     — техническое имя параметра (для rule engine / API)
--   Параметр — человекочитаемое описание (для UI)
--   Значение — текущее значение
--
-- Использование:
--   Откройте в pgAdmin или DBeaver, выполните целиком (F5).
--   Все результаты выводятся в одну таблицу.
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
    r."Раздел",
    r."Ключ",
    r."Параметр",
    r."Значение"
FROM (

-- ============================================================================
-- ИНФОРМАЦИЯ О СЕРВЕРЕ
-- ============================================================================

SELECT 1 AS "N", 'ИНФОРМАЦИЯ О СЕРВЕРЕ' AS "Раздел",
    '_info_pg_version' AS "Ключ",
    'Версия PostgreSQL' AS "Параметр",
    version() AS "Значение"

UNION ALL
SELECT 2, 'ИНФОРМАЦИЯ О СЕРВЕРЕ',
    '_info_database',
    'База данных',
    current_database() || ' (' || pg_size_pretty(pg_database_size(current_database())) || ')'

UNION ALL
SELECT 3, 'ИНФОРМАЦИЯ О СЕРВЕРЕ',
    '_info_server_address',
    'Адрес сервера',
    COALESCE(inet_server_addr()::text, 'локальный') || ':' || COALESCE(inet_server_port()::text, '5432')

UNION ALL
SELECT 4, 'ИНФОРМАЦИЯ О СЕРВЕРЕ',
    '_info_uptime',
    'Время работы',
    CASE
        WHEN EXTRACT(DAY FROM (now() - pg_postmaster_start_time())) > 0
        THEN EXTRACT(DAY FROM (now() - pg_postmaster_start_time()))::int::text || ' дн. '
        ELSE ''
    END || to_char(now() - pg_postmaster_start_time(), 'HH24 ч. MI мин.')

UNION ALL
SELECT 5, 'ИНФОРМАЦИЯ О СЕРВЕРЕ',
    '_info_check_date',
    'Дата проверки',
    to_char(current_timestamp, 'DD.MM.YYYY HH24:MI:SS')

UNION ALL

-- ============================================================================
-- ПАМЯТЬ И КЭШ
-- ============================================================================

SELECT 10, 'ПАМЯТЬ И КЭШ',
    'shared_buffers',
    'Кэш данных в памяти',
    pg_size_pretty(pg_size_bytes(current_setting('shared_buffers')))

UNION ALL
SELECT 11, 'ПАМЯТЬ И КЭШ',
    'work_mem',
    'Память для сортировок',
    pg_size_pretty(pg_size_bytes(current_setting('work_mem')))

UNION ALL
SELECT 12, 'ПАМЯТЬ И КЭШ',
    'effective_cache_size',
    'Оценка доступного кэша ОС',
    pg_size_pretty(pg_size_bytes(current_setting('effective_cache_size')))

UNION ALL
SELECT 13, 'ПАМЯТЬ И КЭШ',
    'maintenance_work_mem',
    'Память для обслуживания БД',
    pg_size_pretty(pg_size_bytes(current_setting('maintenance_work_mem')))

UNION ALL
SELECT 14, 'ПАМЯТЬ И КЭШ',
    'huge_pages',
    'Большие страницы памяти',
    current_setting('huge_pages')

UNION ALL

-- ============================================================================
-- ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)
-- ============================================================================

SELECT 20, 'ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)',
    'synchronous_commit',
    'Синхронная запись при фиксации',
    current_setting('synchronous_commit')

UNION ALL
SELECT 21, 'ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)',
    'fsync',
    'Гарантия записи на диск (fsync)',
    current_setting('fsync')

UNION ALL
SELECT 22, 'ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)',
    'checkpoint_timeout',
    'Интервал контрольных точек',
    ((SELECT setting::int FROM pg_settings WHERE name = 'checkpoint_timeout') / 60)::text || ' мин'

UNION ALL
SELECT 23, 'ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)',
    'min_wal_size',
    'Мин. размер журнала',
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_pretty(pg_size_bytes(current_setting('min_wal_size')))
        ELSE 'n/a (PG < 9.5)'
    END

UNION ALL
SELECT 24, 'ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)',
    'max_wal_size',
    'Макс. размер журнала',
    CASE
        WHEN current_setting('server_version_num')::int >= 90500
        THEN pg_size_pretty(pg_size_bytes(current_setting('max_wal_size')))
        ELSE 'n/a (PG < 9.5)'
    END

UNION ALL
SELECT 25, 'ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)',
    'checkpoint_completion_target',
    'Полнота контрольных точек',
    current_setting('checkpoint_completion_target')

UNION ALL
SELECT 26, 'ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)',
    'wal_buffers',
    'Буферы журнала',
    pg_size_pretty(pg_size_bytes(current_setting('wal_buffers')))

UNION ALL
SELECT 27, 'ЖУРНАЛ ТРАНЗАКЦИЙ (WAL)',
    'wal_level',
    'Уровень журналирования',
    current_setting('wal_level')

UNION ALL

-- ============================================================================
-- ОПТИМИЗАЦИЯ ЗАПРОСОВ
-- ============================================================================

SELECT 30, 'ОПТИМИЗАЦИЯ ЗАПРОСОВ',
    'random_page_cost',
    'Стоимость случайного чтения',
    current_setting('random_page_cost')

UNION ALL
SELECT 31, 'ОПТИМИЗАЦИЯ ЗАПРОСОВ',
    'join_collapse_limit',
    'Лимит оптимизации соединений',
    current_setting('join_collapse_limit')

UNION ALL
SELECT 32, 'ОПТИМИЗАЦИЯ ЗАПРОСОВ',
    'from_collapse_limit',
    'Лимит оптимизации подзапросов',
    current_setting('from_collapse_limit')

UNION ALL
SELECT 33, 'ОПТИМИЗАЦИЯ ЗАПРОСОВ',
    'geqo_threshold',
    'Порог генетического оптимизатора',
    current_setting('geqo_threshold')

UNION ALL
SELECT 34, 'ОПТИМИЗАЦИЯ ЗАПРОСОВ',
    'default_statistics_target',
    'Детальность статистики',
    current_setting('default_statistics_target')

UNION ALL
SELECT 35, 'ОПТИМИЗАЦИЯ ЗАПРОСОВ',
    'jit',
    'JIT-компиляция',
    COALESCE(current_setting('jit', true), 'n/a (PG < 11)')

UNION ALL
SELECT 36, 'ОПТИМИЗАЦИЯ ЗАПРОСОВ',
    'max_parallel_workers_per_gather',
    'Параллельная обработка',
    current_setting('max_parallel_workers_per_gather')

UNION ALL

-- ============================================================================
-- ПОДКЛЮЧЕНИЯ И СЕАНСЫ
-- ============================================================================

SELECT 40, 'ПОДКЛЮЧЕНИЯ И СЕАНСЫ',
    'max_connections',
    'Макс. подключений',
    current_setting('max_connections')

UNION ALL
SELECT 41, 'ПОДКЛЮЧЕНИЯ И СЕАНСЫ',
    'idle_in_transaction_session_timeout',
    'Тайм-аут зависших транзакций',
    CASE
        WHEN current_setting('server_version_num')::int >= 90600
        THEN ((SELECT setting::bigint FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout') / 1000)::text || ' сек'
        ELSE 'n/a (PG < 9.6)'
    END

UNION ALL
SELECT 42, 'ПОДКЛЮЧЕНИЯ И СЕАНСЫ',
    'max_locks_per_transaction',
    'Лимит блокировок',
    current_setting('max_locks_per_transaction')

UNION ALL

-- ============================================================================
-- АВТООЧИСТКА (AUTOVACUUM)
-- ============================================================================

SELECT 50, 'АВТООЧИСТКА (AUTOVACUUM)',
    'autovacuum',
    'Автоочистка включена',
    current_setting('autovacuum')

UNION ALL
SELECT 51, 'АВТООЧИСТКА (AUTOVACUUM)',
    'autovacuum_naptime',
    'Интервал проверки',
    (SELECT setting FROM pg_settings WHERE name = 'autovacuum_naptime') || ' сек'

UNION ALL
SELECT 52, 'АВТООЧИСТКА (AUTOVACUUM)',
    'autovacuum_max_workers',
    'Процессов автоочистки',
    current_setting('autovacuum_max_workers')

UNION ALL
SELECT 53, 'АВТООЧИСТКА (AUTOVACUUM)',
    'autovacuum_vacuum_cost_limit',
    'Лимит I/O автоочистки',
    current_setting('autovacuum_vacuum_cost_limit')

UNION ALL

-- ============================================================================
-- ФОНОВАЯ ЗАПИСЬ
-- ============================================================================

SELECT 60, 'ФОНОВАЯ ЗАПИСЬ',
    'bgwriter_delay',
    'Пауза фоновой записи',
    (SELECT setting FROM pg_settings WHERE name = 'bgwriter_delay') || ' мс'

UNION ALL
SELECT 61, 'ФОНОВАЯ ЗАПИСЬ',
    'bgwriter_lru_maxpages',
    'Макс. страниц за цикл',
    current_setting('bgwriter_lru_maxpages')

UNION ALL
SELECT 62, 'ФОНОВАЯ ЗАПИСЬ',
    'effective_io_concurrency',
    'Параллельное чтение с диска',
    current_setting('effective_io_concurrency')

UNION ALL

-- ============================================================================
-- СОВМЕСТИМОСТЬ С 1С
-- ============================================================================

SELECT 70, 'СОВМЕСТИМОСТЬ С 1С',
    'standard_conforming_strings',
    'Режим обработки строк',
    current_setting('standard_conforming_strings')

UNION ALL
SELECT 71, 'СОВМЕСТИМОСТЬ С 1С',
    'escape_string_warning',
    'Предупреждения экранирования',
    current_setting('escape_string_warning')

UNION ALL

-- ============================================================================
-- РЕАЛЬНЫЕ МЕТРИКИ
-- ============================================================================

-- Эффективность кэширования
SELECT 80, 'РЕАЛЬНЫЕ МЕТРИКИ',
    '_metric_cache_hit_ratio',
    'Эффективность кэширования',
    CASE
        WHEN blks_hit + blks_read = 0 THEN 'нет данных'
        ELSE round(100.0 * blks_hit / (blks_hit + blks_read), 2)::text || '%'
    END
FROM pg_stat_database WHERE datname = current_database()

UNION ALL

-- Временные файлы
SELECT 81, 'РЕАЛЬНЫЕ МЕТРИКИ',
    '_metric_temp_files',
    'Временные файлы',
    CASE
        WHEN temp_files = 0 THEN '0'
        ELSE temp_files::text || ' шт. / ' || pg_size_pretty(temp_bytes)
    END
FROM pg_stat_database WHERE datname = current_database()

UNION ALL

-- Контрольные точки (PG10-16: pg_stat_bgwriter; PG17+: колонки отсутствуют → NULL через to_jsonb)
SELECT 82, 'РЕАЛЬНЫЕ МЕТРИКИ',
    '_metric_checkpoints',
    'Контрольные точки (по расписанию / вынужденных)',
    CASE
        WHEN cp.timed IS NULL THEN 'n/a (PG17+: используйте pg_stat_checkpointer)'
        ELSE cp.timed::text || ' / ' || cp.req::text
    END
FROM (
    SELECT
        (to_jsonb(s.*) ->> 'checkpoints_timed')::bigint AS timed,
        (to_jsonb(s.*) ->> 'checkpoints_req')::bigint   AS req
    FROM pg_stat_bgwriter s
) cp

UNION ALL

-- ============================================================================
-- РАЗДУТЫЕ ТАБЛИЦЫ (топ-5)
-- ============================================================================

SELECT bt."N", bt."Раздел", bt."Ключ", bt."Параметр", bt."Значение"
FROM (
    SELECT
        90 + row_number() OVER (ORDER BY n_dead_tup DESC) AS "N",
        'РАЗДУТЫЕ ТАБЛИЦЫ (топ-5)' AS "Раздел",
        '_bloat_' || schemaname || '.' || relname AS "Ключ",
        schemaname || '.' || relname AS "Параметр",
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
            END AS "Значение"
    FROM pg_stat_user_tables
    WHERE n_live_tup + n_dead_tup > 1000
    ORDER BY n_dead_tup DESC
    LIMIT 5
) bt

UNION ALL

-- ============================================================================
-- ЗАВИСШИЕ СЕАНСЫ
-- ============================================================================

SELECT si."N", si."Раздел", si."Ключ", si."Параметр", si."Значение"
FROM (
    SELECT
        100 + row_number() OVER (ORDER BY state_change ASC) AS "N",
        'ЗАВИСШИЕ СЕАНСЫ' AS "Раздел",
        '_idle_txn_' || pid::text AS "Ключ",
        COALESCE(usename, 'неизвестен') ||
            ' (' || COALESCE(client_addr::text, 'локальный') || ')' AS "Параметр",
        'простой: ' || to_char(now() - state_change, 'HH24 ч. MI мин.') AS "Значение"
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
      AND pid <> pg_backend_pid()
    ORDER BY state_change ASC
) si

UNION ALL

-- Если зависших сеансов нет
SELECT 100, 'ЗАВИСШИЕ СЕАНСЫ', '_idle_txn_none', 'Зависших сеансов нет', ''
WHERE NOT EXISTS (
    SELECT 1 FROM pg_stat_activity
    WHERE state = 'idle in transaction' AND pid <> pg_backend_pid()
)

UNION ALL

-- ============================================================================
-- ЗАКЛЮЧЕНИЕ
-- ============================================================================

SELECT 999, 'ЗАКЛЮЧЕНИЕ',
    '_info_total',
    'Итого параметров собрано',
    '34'

UNION ALL
SELECT 1000, 'ЗАКЛЮЧЕНИЕ',
    '_info_contacts',
    'Контакты',
    'audit-reshenie.ru | info@audit-reshenie.ru'

) AS r("N", "Раздел", "Ключ", "Параметр", "Значение")
ORDER BY r."N"
;

-- ============================================================================
-- КОНЕЦ СКРИПТА СБОРА ДАННЫХ
-- ============================================================================
