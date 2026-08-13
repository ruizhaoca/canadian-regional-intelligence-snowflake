USE ROLE CRI_DEV_TRANSFORMER_ROLE;
USE WAREHOUSE CRI_DEV_WH;
USE DATABASE CRI_DEV;
USE SCHEMA CORE;

CREATE OR REPLACE PROCEDURE PROCESS_NEW_BATCHES()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    V_RUN_ID VARCHAR DEFAULT UUID_STRING();
    V_BATCH_ID VARCHAR;
    V_TABLE_ID VARCHAR;
    V_SUBJECT VARCHAR;
    V_SOURCE_URL VARCHAR;
    V_INGESTED_AT TIMESTAMP_TZ;
    V_SOURCE_ARCHIVE_SHA256 VARCHAR;
    V_DATA_CSV_SHA256 VARCHAR;
    V_DATA_PATH VARCHAR;
    V_MANIFEST_PATH VARCHAR;
    V_RELATIVE_PATH VARCHAR;
    V_COPY_SQL VARCHAR;
    V_EXPECTED NUMBER;
    V_ACTUAL NUMBER;
    V_VALID NUMBER;
    V_DISTINCT_KEYS NUMBER;
    V_DISTINCT_SOURCE_ROWS NUMBER;
    V_PUBLISHED NUMBER;
    V_RELEASE_TS TIMESTAMP_TZ;
    V_LATEST_RELEASE_TS TIMESTAMP_TZ;
    V_PUBLISHED_BATCHES NUMBER DEFAULT 0;
    V_QUARANTINED_BATCHES NUMBER DEFAULT 0;
    V_BATCHES RESULTSET;
BEGIN
    INSERT INTO OPS.PIPELINE_RUN (RUN_ID, STARTED_AT, STATUS)
    VALUES (:V_RUN_ID, CURRENT_TIMESTAMP(), 'RUNNING');

    CREATE OR REPLACE TEMPORARY TABLE TMP_BATCH_CONTROL LIKE RAW.BATCH_CONTROL;

    BEGIN TRANSACTION;

    -- Reading the stream inside the transaction advances its offset only on COMMIT.
    -- A stream exposes three additional change-tracking metadata columns.
    -- Project only the 14 base-table columns into the table-shaped buffer.
    INSERT INTO TMP_BATCH_CONTROL (
        TABLE_ID,
        BATCH_ID,
        SUBJECT,
        SOURCE_URL,
        SOURCE_LAST_MODIFIED_UTC,
        INGESTED_AT_UTC,
        SOURCE_ARCHIVE_SHA256,
        DATA_CSV_SHA256,
        SOURCE_RECORD_COUNT,
        DATA_PATH,
        MANIFEST_PATH,
        SOURCE_FILE,
        SOURCE_ROW_NUMBER,
        SOURCE_LOADED_AT
    )
    SELECT
        TABLE_ID,
        BATCH_ID,
        SUBJECT,
        SOURCE_URL,
        SOURCE_LAST_MODIFIED_UTC,
        INGESTED_AT_UTC,
        SOURCE_ARCHIVE_SHA256,
        DATA_CSV_SHA256,
        SOURCE_RECORD_COUNT,
        DATA_PATH,
        MANIFEST_PATH,
        SOURCE_FILE,
        SOURCE_ROW_NUMBER,
        SOURCE_LOADED_AT
    FROM CORE.BATCH_CONTROL_STREAM;

    -- Also recover any non-terminal control row if an operator calls the procedure.
    INSERT INTO TMP_BATCH_CONTROL
    SELECT RAW_CONTROL.*
    FROM RAW.BATCH_CONTROL AS RAW_CONTROL
    WHERE NOT EXISTS (
        SELECT 1
        FROM TMP_BATCH_CONTROL AS SIGNAL
        WHERE SIGNAL.BATCH_ID = RAW_CONTROL.BATCH_ID
    )
      AND NOT EXISTS (
          SELECT 1
          FROM OPS.LOAD_BATCH AS LOADED
          WHERE LOADED.BATCH_ID = RAW_CONTROL.BATCH_ID
            AND LOADED.STATUS IN ('PUBLISHED', 'QUARANTINED')
      )
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY RAW_CONTROL.BATCH_ID
        ORDER BY RAW_CONTROL.SOURCE_LOADED_AT DESC
    ) = 1;

    V_BATCHES := (
        SELECT * FROM TMP_BATCH_CONTROL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY BATCH_ID
            ORDER BY SOURCE_LOADED_AT DESC
        ) = 1
        ORDER BY COALESCE(
            TRY_TO_TIMESTAMP_TZ(SOURCE_LAST_MODIFIED_UTC),
            TRY_TO_TIMESTAMP_TZ(INGESTED_AT_UTC)
        ), BATCH_ID
    );

    FOR REC IN V_BATCHES DO
        V_BATCH_ID := REC.BATCH_ID;
        V_TABLE_ID := REC.TABLE_ID;
        V_SUBJECT := REC.SUBJECT;
        V_SOURCE_URL := REC.SOURCE_URL;
        V_INGESTED_AT := TRY_TO_TIMESTAMP_TZ(REC.INGESTED_AT_UTC);
        V_SOURCE_ARCHIVE_SHA256 := REC.SOURCE_ARCHIVE_SHA256;
        V_DATA_CSV_SHA256 := REC.DATA_CSV_SHA256;
        V_DATA_PATH := REC.DATA_PATH;
        V_MANIFEST_PATH := REC.MANIFEST_PATH;
        V_EXPECTED := TRY_TO_NUMBER(REC.SOURCE_RECORD_COUNT);
        V_RELEASE_TS := COALESCE(
            TRY_TO_TIMESTAMP_TZ(REC.SOURCE_LAST_MODIFIED_UTC),
            TRY_TO_TIMESTAMP_TZ(REC.INGESTED_AT_UTC)
        );

        SELECT COUNT_IF(STATUS = 'PUBLISHED')
        INTO :V_PUBLISHED
        FROM OPS.LOAD_BATCH
        WHERE BATCH_ID = :V_BATCH_ID;

        IF (V_PUBLISHED > 0) THEN
            CONTINUE;
        END IF;

        MERGE INTO OPS.LOAD_BATCH AS TARGET
        USING (
            SELECT
                :V_BATCH_ID AS BATCH_ID,
                :V_TABLE_ID AS TABLE_ID,
                :V_SUBJECT AS SUBJECT,
                :V_SOURCE_URL AS SOURCE_URL,
                :V_RELEASE_TS AS SOURCE_RELEASE_TS,
                :V_INGESTED_AT AS INGESTED_AT,
                :V_SOURCE_ARCHIVE_SHA256 AS SOURCE_ARCHIVE_SHA256,
                :V_DATA_CSV_SHA256 AS DATA_CSV_SHA256,
                :V_EXPECTED AS EXPECTED_RECORD_COUNT,
                :V_DATA_PATH AS DATA_PATH,
                :V_MANIFEST_PATH AS MANIFEST_PATH
        ) AS SOURCE
        ON TARGET.BATCH_ID = SOURCE.BATCH_ID
        WHEN NOT MATCHED THEN INSERT (
            BATCH_ID, TABLE_ID, SUBJECT, SOURCE_URL, SOURCE_RELEASE_TS,
            INGESTED_AT, SOURCE_ARCHIVE_SHA256, DATA_CSV_SHA256,
            EXPECTED_RECORD_COUNT, DATA_PATH, MANIFEST_PATH, STATUS,
            FIRST_SEEN_AT, RUN_ID
        ) VALUES (
            SOURCE.BATCH_ID, SOURCE.TABLE_ID, SOURCE.SUBJECT, SOURCE.SOURCE_URL,
            SOURCE.SOURCE_RELEASE_TS, SOURCE.INGESTED_AT,
            SOURCE.SOURCE_ARCHIVE_SHA256, SOURCE.DATA_CSV_SHA256,
            SOURCE.EXPECTED_RECORD_COUNT, SOURCE.DATA_PATH, SOURCE.MANIFEST_PATH,
            'DISCOVERED', CURRENT_TIMESTAMP(), :V_RUN_ID
        )
        WHEN MATCHED THEN UPDATE SET
            TARGET.RUN_ID = :V_RUN_ID,
            TARGET.STATUS = 'PROCESSING',
            TARGET.STATUS_REASON = NULL;

        IF (
            V_EXPECTED IS NULL
            OR V_EXPECTED <= 0
            OR V_RELEASE_TS IS NULL
            OR V_INGESTED_AT IS NULL
            OR V_TABLE_ID NOT IN ('14-10-0461-01', '17-10-0148-01')
            OR NOT REGEXP_LIKE(V_BATCH_ID, '^[0-9]{8}-[a-f0-9]{16}$')
            -- StatsCan table IDs include a two-digit view suffix, while the
            -- product ID used in batch IDs is the first eight digits.
            OR V_BATCH_ID NOT LIKE (
                LEFT(REPLACE(V_TABLE_ID, '-', ''), 8) || '-%'
            )
            OR NOT REGEXP_LIKE(V_SOURCE_ARCHIVE_SHA256, '^[a-f0-9]{64}$')
            OR NOT REGEXP_LIKE(V_DATA_CSV_SHA256, '^[a-f0-9]{64}$')
            OR V_DATA_PATH != (
                'statcan/' || V_TABLE_ID || '/batch_id=' || V_BATCH_ID || '/data.csv'
            )
            OR V_MANIFEST_PATH != (
                'statcan/' || V_TABLE_ID || '/batch_id=' || V_BATCH_ID || '/manifest.json'
            )
        ) THEN
            UPDATE OPS.LOAD_BATCH
            SET STATUS = 'QUARANTINED',
                STATUS_REASON = 'INVALID_CONTROL_METADATA',
                PROCESSED_AT = CURRENT_TIMESTAMP()
            WHERE BATCH_ID = :V_BATCH_ID;

            INSERT INTO OPS.QUARANTINE_BATCH
            SELECT
                :V_RUN_ID,
                :V_BATCH_ID,
                :V_TABLE_ID,
                'INVALID_CONTROL_METADATA',
                OBJECT_CONSTRUCT(*),
                CURRENT_TIMESTAMP()
            FROM TMP_BATCH_CONTROL
            WHERE BATCH_ID = :V_BATCH_ID;

            V_QUARANTINED_BATCHES := V_QUARANTINED_BATCHES + 1;
            CONTINUE;
        END IF;

        SELECT MAX(SOURCE_RELEASE_TS)
        INTO :V_LATEST_RELEASE_TS
        FROM OPS.LOAD_BATCH
        WHERE TABLE_ID = :V_TABLE_ID
          AND STATUS = 'PUBLISHED';

        IF (V_LATEST_RELEASE_TS IS NOT NULL AND V_RELEASE_TS < V_LATEST_RELEASE_TS) THEN
            UPDATE OPS.LOAD_BATCH
            SET STATUS = 'QUARANTINED',
                STATUS_REASON = 'OUT_OF_ORDER_SOURCE_RELEASE',
                PROCESSED_AT = CURRENT_TIMESTAMP()
            WHERE BATCH_ID = :V_BATCH_ID;

            INSERT INTO OPS.QUARANTINE_BATCH
            VALUES (
                :V_RUN_ID,
                :V_BATCH_ID,
                :V_TABLE_ID,
                'OUT_OF_ORDER_SOURCE_RELEASE',
                OBJECT_CONSTRUCT(
                    'source_release_ts', :V_RELEASE_TS,
                    'latest_published_release_ts', :V_LATEST_RELEASE_TS
                ),
                CURRENT_TIMESTAMP()
            );

            V_QUARANTINED_BATCHES := V_QUARANTINED_BATCHES + 1;
            CONTINUE;
        END IF;

        V_RELATIVE_PATH := REGEXP_REPLACE(V_DATA_PATH, '^statcan/', '');
        V_COPY_SQL :=
            'COPY INTO CRI_DEV.RAW.SOURCE_ROW '
            || '(TABLE_ID, BATCH_ID, C01, C02, C03, C04, C05, C06, C07, C08, '
            || 'C09, C10, C11, C12, C13, C14, C15, C16, C17, SOURCE_FILE, '
            || 'SOURCE_ROW_NUMBER, SOURCE_LOADED_AT) FROM (SELECT '''
            || V_TABLE_ID || ''', ''' || V_BATCH_ID
            || ''', T.$1, T.$2, T.$3, T.$4, T.$5, T.$6, T.$7, T.$8, T.$9, '
            || 'T.$10, T.$11, T.$12, T.$13, T.$14, T.$15, T.$16, T.$17, '
            || 'METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, '
            || 'METADATA$START_SCAN_TIME FROM '
            || '@CRI_DEV.RAW.STATCAN_LANDING_STAGE/' || V_RELATIVE_PATH
            || ' T) FILE_FORMAT = (FORMAT_NAME = CRI_DEV.RAW.STATCAN_DATA_CSV) '
            || 'ON_ERROR = ''ABORT_STATEMENT''';

        EXECUTE IMMEDIATE :V_COPY_SQL;

        SELECT COUNT(*)
        INTO :V_ACTUAL
        FROM RAW.SOURCE_ROW
        WHERE BATCH_ID = :V_BATCH_ID;

        SELECT COUNT(DISTINCT SOURCE_FILE || '|' || TO_VARCHAR(SOURCE_ROW_NUMBER))
        INTO :V_DISTINCT_SOURCE_ROWS
        FROM RAW.SOURCE_ROW
        WHERE BATCH_ID = :V_BATCH_ID;

        INSERT INTO OPS.QUALITY_RESULT
        VALUES
            (
                :V_RUN_ID, :V_BATCH_ID, 'SOURCE_RECORD_COUNT', 'ERROR',
                :V_ACTUAL = :V_EXPECTED, TO_VARCHAR(:V_ACTUAL),
                TO_VARCHAR(:V_EXPECTED), CURRENT_TIMESTAMP()
            ),
            (
                :V_RUN_ID, :V_BATCH_ID, 'SOURCE_FILE_UNIQUENESS', 'ERROR',
                :V_DISTINCT_SOURCE_ROWS = :V_ACTUAL,
                TO_VARCHAR(:V_DISTINCT_SOURCE_ROWS), TO_VARCHAR(:V_ACTUAL),
                CURRENT_TIMESTAMP()
            );

        IF (V_ACTUAL != V_EXPECTED) THEN
            UPDATE OPS.LOAD_BATCH
            SET STATUS = 'QUARANTINED',
                STATUS_REASON = 'SOURCE_RECORD_COUNT_MISMATCH',
                ACTUAL_RECORD_COUNT = :V_ACTUAL,
                PROCESSED_AT = CURRENT_TIMESTAMP()
            WHERE BATCH_ID = :V_BATCH_ID;

            INSERT INTO OPS.QUARANTINE_BATCH
            VALUES (
                :V_RUN_ID, :V_BATCH_ID, :V_TABLE_ID,
                'SOURCE_RECORD_COUNT_MISMATCH',
                OBJECT_CONSTRUCT('expected', :V_EXPECTED, 'actual', :V_ACTUAL),
                CURRENT_TIMESTAMP()
            );

            V_QUARANTINED_BATCHES := V_QUARANTINED_BATCHES + 1;
            CONTINUE;
        END IF;

        IF (V_TABLE_ID = '17-10-0148-01') THEN
            SELECT
                COUNT(*),
                COUNT(DISTINCT C03 || '|' || C01)
            INTO :V_VALID, :V_DISTINCT_KEYS
            FROM RAW.SOURCE_ROW
            WHERE BATCH_ID = :V_BATCH_ID
              AND C03 LIKE '2021S0503%'
              AND C04 = 'Total - gender'
              AND C05 = 'All ages'
              AND TRY_TO_NUMBER(C01) IS NOT NULL
              AND TRY_TO_NUMBER(C12) IS NOT NULL;

            INSERT INTO OPS.QUALITY_RESULT
            VALUES (
                :V_RUN_ID, :V_BATCH_ID, 'POPULATION_BUSINESS_KEY_UNIQUENESS',
                'ERROR', :V_VALID = :V_DISTINCT_KEYS,
                TO_VARCHAR(:V_VALID - :V_DISTINCT_KEYS), '0', CURRENT_TIMESTAMP()
            );

            IF (V_VALID = 0 OR V_VALID != V_DISTINCT_KEYS) THEN
                UPDATE OPS.LOAD_BATCH
                SET STATUS = 'QUARANTINED',
                    STATUS_REASON = 'INVALID_POPULATION_GRAIN',
                    ACTUAL_RECORD_COUNT = :V_ACTUAL,
                    VALID_RECORD_COUNT = :V_VALID,
                    PROCESSED_AT = CURRENT_TIMESTAMP()
                WHERE BATCH_ID = :V_BATCH_ID;

                INSERT INTO OPS.QUARANTINE_BATCH
                VALUES (
                    :V_RUN_ID, :V_BATCH_ID, :V_TABLE_ID,
                    'INVALID_POPULATION_GRAIN',
                    OBJECT_CONSTRUCT(
                        'valid_records', :V_VALID,
                        'distinct_business_keys', :V_DISTINCT_KEYS
                    ),
                    CURRENT_TIMESTAMP()
                );

                V_QUARANTINED_BATCHES := V_QUARANTINED_BATCHES + 1;
                CONTINUE;
            END IF;

            UPDATE CORE.FACT_POPULATION_HISTORY AS TARGET
            SET IS_CURRENT = FALSE,
                VALID_TO_TS = :V_RELEASE_TS
            FROM (
                SELECT
                    C03 AS CMA_DGUID,
                    TRY_TO_NUMBER(C01) AS REF_YEAR,
                    SHA2(CONCAT_WS('|', C02, C03, C01, C12, C06), 256) AS RECORD_HASH
                FROM RAW.SOURCE_ROW
                WHERE BATCH_ID = :V_BATCH_ID
                  AND C03 LIKE '2021S0503%'
                  AND C04 = 'Total - gender'
                  AND C05 = 'All ages'
                  AND TRY_TO_NUMBER(C01) IS NOT NULL
                  AND TRY_TO_NUMBER(C12) IS NOT NULL
            ) AS SOURCE
            WHERE TARGET.IS_CURRENT
              AND TARGET.CMA_DGUID = SOURCE.CMA_DGUID
              AND TARGET.REF_YEAR = SOURCE.REF_YEAR
              AND TARGET.RECORD_HASH != SOURCE.RECORD_HASH;

            INSERT INTO CORE.FACT_POPULATION_HISTORY
            SELECT
                SOURCE.CMA_DGUID,
                SOURCE.CMA_NAME,
                SOURCE.PROVINCE_NAME,
                SOURCE.REF_YEAR,
                SOURCE.POPULATION,
                SOURCE.UNIT,
                SOURCE.RECORD_HASH,
                :V_RELEASE_TS,
                :V_BATCH_ID,
                :V_RELEASE_TS,
                NULL,
                TRUE
            FROM (
                SELECT
                    C03 AS CMA_DGUID,
                    C02 AS CMA_NAME,
                    SPLIT_PART(C02, ', ', -1) AS PROVINCE_NAME,
                    TRY_TO_NUMBER(C01) AS REF_YEAR,
                    TRY_TO_NUMBER(C12) AS POPULATION,
                    C06 AS UNIT,
                    SHA2(CONCAT_WS('|', C02, C03, C01, C12, C06), 256) AS RECORD_HASH
                FROM RAW.SOURCE_ROW
                WHERE BATCH_ID = :V_BATCH_ID
                  AND C03 LIKE '2021S0503%'
                  AND C04 = 'Total - gender'
                  AND C05 = 'All ages'
                  AND TRY_TO_NUMBER(C01) IS NOT NULL
                  AND TRY_TO_NUMBER(C12) IS NOT NULL
            ) AS SOURCE
            WHERE NOT EXISTS (
                SELECT 1
                FROM CORE.FACT_POPULATION_HISTORY AS TARGET
                WHERE TARGET.IS_CURRENT
                  AND TARGET.CMA_DGUID = SOURCE.CMA_DGUID
                  AND TARGET.REF_YEAR = SOURCE.REF_YEAR
                  AND TARGET.RECORD_HASH = SOURCE.RECORD_HASH
            );
        ELSE
            SELECT
                COUNT(*),
                COUNT(DISTINCT C03 || '|' || C01 || '|' || C04)
            INTO :V_VALID, :V_DISTINCT_KEYS
            FROM RAW.SOURCE_ROW
            WHERE BATCH_ID = :V_BATCH_ID
              AND C03 LIKE '2021S0503%'
              AND C05 = 'Total - Gender'
              AND C06 = '15 years and over'
              AND C04 IN (
                  'Population', 'Labour force', 'Employment', 'Unemployment',
                  'Unemployment rate', 'Participation rate', 'Employment rate'
              )
              AND TRY_TO_NUMBER(C01) IS NOT NULL
              AND TRY_TO_DECIMAL(C13, 18, 3) IS NOT NULL;

            INSERT INTO OPS.QUALITY_RESULT
            VALUES (
                :V_RUN_ID, :V_BATCH_ID, 'LABOUR_BUSINESS_KEY_UNIQUENESS',
                'ERROR', :V_VALID = :V_DISTINCT_KEYS,
                TO_VARCHAR(:V_VALID - :V_DISTINCT_KEYS), '0', CURRENT_TIMESTAMP()
            );

            IF (V_VALID = 0 OR V_VALID != V_DISTINCT_KEYS) THEN
                UPDATE OPS.LOAD_BATCH
                SET STATUS = 'QUARANTINED',
                    STATUS_REASON = 'INVALID_LABOUR_GRAIN',
                    ACTUAL_RECORD_COUNT = :V_ACTUAL,
                    VALID_RECORD_COUNT = :V_VALID,
                    PROCESSED_AT = CURRENT_TIMESTAMP()
                WHERE BATCH_ID = :V_BATCH_ID;

                INSERT INTO OPS.QUARANTINE_BATCH
                VALUES (
                    :V_RUN_ID, :V_BATCH_ID, :V_TABLE_ID,
                    'INVALID_LABOUR_GRAIN',
                    OBJECT_CONSTRUCT(
                        'valid_records', :V_VALID,
                        'distinct_business_keys', :V_DISTINCT_KEYS
                    ),
                    CURRENT_TIMESTAMP()
                );

                V_QUARANTINED_BATCHES := V_QUARANTINED_BATCHES + 1;
                CONTINUE;
            END IF;

            UPDATE CORE.FACT_LABOUR_HISTORY AS TARGET
            SET IS_CURRENT = FALSE,
                VALID_TO_TS = :V_RELEASE_TS
            FROM (
                SELECT
                    C03 AS CMA_DGUID,
                    TRY_TO_NUMBER(C01) AS REF_YEAR,
                    C04 AS METRIC_NAME,
                    SHA2(CONCAT_WS('|', C02, C03, C01, C04, C13, C07), 256) AS RECORD_HASH
                FROM RAW.SOURCE_ROW
                WHERE BATCH_ID = :V_BATCH_ID
                  AND C03 LIKE '2021S0503%'
                  AND C05 = 'Total - Gender'
                  AND C06 = '15 years and over'
                  AND C04 IN (
                      'Population', 'Labour force', 'Employment', 'Unemployment',
                      'Unemployment rate', 'Participation rate', 'Employment rate'
                  )
                  AND TRY_TO_NUMBER(C01) IS NOT NULL
                  AND TRY_TO_DECIMAL(C13, 18, 3) IS NOT NULL
            ) AS SOURCE
            WHERE TARGET.IS_CURRENT
              AND TARGET.CMA_DGUID = SOURCE.CMA_DGUID
              AND TARGET.REF_YEAR = SOURCE.REF_YEAR
              AND TARGET.METRIC_NAME = SOURCE.METRIC_NAME
              AND TARGET.RECORD_HASH != SOURCE.RECORD_HASH;

            INSERT INTO CORE.FACT_LABOUR_HISTORY
            SELECT
                SOURCE.CMA_DGUID,
                SOURCE.CMA_NAME,
                SOURCE.PROVINCE_NAME,
                SOURCE.REF_YEAR,
                SOURCE.METRIC_NAME,
                SOURCE.METRIC_VALUE,
                SOURCE.UNIT,
                SOURCE.RECORD_HASH,
                :V_RELEASE_TS,
                :V_BATCH_ID,
                :V_RELEASE_TS,
                NULL,
                TRUE
            FROM (
                SELECT
                    C03 AS CMA_DGUID,
                    C02 AS CMA_NAME,
                    SPLIT_PART(C02, ', ', -1) AS PROVINCE_NAME,
                    TRY_TO_NUMBER(C01) AS REF_YEAR,
                    C04 AS METRIC_NAME,
                    TRY_TO_DECIMAL(C13, 18, 3) AS METRIC_VALUE,
                    C07 AS UNIT,
                    SHA2(CONCAT_WS('|', C02, C03, C01, C04, C13, C07), 256) AS RECORD_HASH
                FROM RAW.SOURCE_ROW
                WHERE BATCH_ID = :V_BATCH_ID
                  AND C03 LIKE '2021S0503%'
                  AND C05 = 'Total - Gender'
                  AND C06 = '15 years and over'
                  AND C04 IN (
                      'Population', 'Labour force', 'Employment', 'Unemployment',
                      'Unemployment rate', 'Participation rate', 'Employment rate'
                  )
                  AND TRY_TO_NUMBER(C01) IS NOT NULL
                  AND TRY_TO_DECIMAL(C13, 18, 3) IS NOT NULL
            ) AS SOURCE
            WHERE NOT EXISTS (
                SELECT 1
                FROM CORE.FACT_LABOUR_HISTORY AS TARGET
                WHERE TARGET.IS_CURRENT
                  AND TARGET.CMA_DGUID = SOURCE.CMA_DGUID
                  AND TARGET.REF_YEAR = SOURCE.REF_YEAR
                  AND TARGET.METRIC_NAME = SOURCE.METRIC_NAME
                  AND TARGET.RECORD_HASH = SOURCE.RECORD_HASH
            );
        END IF;

        SELECT COUNT(*)
        INTO :V_PUBLISHED
        FROM (
            SELECT CMA_DGUID, REF_YEAR
            FROM CORE.FACT_POPULATION_HISTORY
            WHERE BATCH_ID = :V_BATCH_ID
            UNION ALL
            SELECT CMA_DGUID, REF_YEAR
            FROM CORE.FACT_LABOUR_HISTORY
            WHERE BATCH_ID = :V_BATCH_ID
        );

        UPDATE OPS.LOAD_BATCH
        SET STATUS = 'PUBLISHED',
            STATUS_REASON = NULL,
            ACTUAL_RECORD_COUNT = :V_ACTUAL,
            VALID_RECORD_COUNT = :V_VALID,
            PROCESSED_AT = CURRENT_TIMESTAMP(),
            RUN_ID = :V_RUN_ID
        WHERE BATCH_ID = :V_BATCH_ID;

        INSERT INTO OPS.RECORD_OUTCOME
        VALUES (
            :V_RUN_ID, :V_BATCH_ID, :V_ACTUAL, :V_VALID, :V_PUBLISHED,
            :V_ACTUAL - :V_VALID, CURRENT_TIMESTAMP()
        );

        V_PUBLISHED_BATCHES := V_PUBLISHED_BATCHES + 1;
    END FOR;

    UPDATE OPS.PIPELINE_RUN
    SET FINISHED_AT = CURRENT_TIMESTAMP(),
        STATUS = IFF(:V_QUARANTINED_BATCHES = 0, 'SUCCEEDED', 'COMPLETED_WITH_QUARANTINE'),
        BATCHES_PUBLISHED = :V_PUBLISHED_BATCHES,
        BATCHES_QUARANTINED = :V_QUARANTINED_BATCHES
    WHERE RUN_ID = :V_RUN_ID;

    COMMIT;

    RETURN OBJECT_CONSTRUCT(
        'run_id', V_RUN_ID,
        'published_batches', V_PUBLISHED_BATCHES,
        'quarantined_batches', V_QUARANTINED_BATCHES
    );
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        UPDATE OPS.PIPELINE_RUN
        SET FINISHED_AT = CURRENT_TIMESTAMP(),
            STATUS = 'FAILED',
            ERROR_MESSAGE = :SQLERRM
        WHERE RUN_ID = :V_RUN_ID;
        RAISE;
END;
$$;
