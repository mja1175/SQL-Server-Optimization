USE DBA_Utilities;
GO

/*
================================================================================
  INDEX OPTIMIZATION SUITE - INSTALLATION SCRIPT

  Installs or updates all optimization suite objects in the indexing schema.
  Safe to re-run - tables are created only if missing, procs are always updated.

  Tools included:
    1. Duplicate Index Detection
    2. Key Lookup Elimination
    3. Unused Index Detection
    4. Missing Index Recommendations (optimize-index)
    5. Expensive Query Plan Analysis
    6. Column Access Pattern Analysis
    + Orchestrator (sp_IndexOptimizationSuite)
    + Suite Summary (sp_IndexingSuiteSummary)
    + Shared Utility (sp_BuildIndexScript)
================================================================================
*/

-- Create schema if it doesn't exist
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'indexing')
    EXEC('CREATE SCHEMA indexing');
GO

PRINT 'Installing Index Optimization Suite...';
GO


-- ==========================================================================
-- DUPLICATE INDEX DETECTION
-- ==========================================================================

-- ==========================================================================
-- Table: indexing.IndexOptimizationResults
-- ==========================================================================
IF OBJECT_ID('indexing.IndexOptimizationResults', 'U') IS NULL
BEGIN
  CREATE TABLE indexing.IndexOptimizationResults
    (IndexOptimizationId INT            IDENTITY(1, 1)
    ,ServerName          NVARCHAR(128)  NULL
    ,DatabaseName        NVARCHAR(128)  NOT NULL
    ,SchemaName          NVARCHAR(128)  NOT NULL
    ,TableName           NVARCHAR(128)  NOT NULL
    ,ActionType          VARCHAR(20)    NOT NULL
    ,Index1Id            INT            NOT NULL
    ,Index1Name          NVARCHAR(256)  NOT NULL
    ,Index1Keys          NVARCHAR(MAX)  NOT NULL
    ,Index1Includes      NVARCHAR(MAX)  NULL
    ,Index1SizeKB        BIGINT         NULL
    ,Index1UserSeeks     BIGINT         NULL
    ,Index1UserScans     BIGINT         NULL
    ,Index2Id            INT            NULL
    ,Index2Name          NVARCHAR(256)  NULL
    ,Index2Keys          NVARCHAR(MAX)  NULL
    ,Index2Includes      NVARCHAR(MAX)  NULL
    ,Index2SizeKB        BIGINT         NULL
    ,Index2UserSeeks     BIGINT         NULL
    ,Index2UserScans     BIGINT         NULL
    ,NewIndexName        NVARCHAR(500)  NULL
    ,NewIndexKeys        NVARCHAR(MAX)  NULL
    ,NewIncludeColumns   NVARCHAR(MAX)  NULL
    ,NewIndexNameExists  BIT            NOT NULL CONSTRAINT DF_IndexOptimizationResults_NewIndexNameExists DEFAULT ((0))
    ,CreateStatement     NVARCHAR(MAX)  NULL
    ,EstimatedSizeGB     DECIMAL(18,2)  NULL
    ,DropStatement1      NVARCHAR(1000) NOT NULL
    ,DropStatement2      NVARCHAR(1000) NULL
    ,IndexUsageCommand   NVARCHAR(500)  NULL
    ,ProcessedDate       DATETIME2(3)   NOT NULL CONSTRAINT DF_IndexOptimizationResults_ProcessedDate DEFAULT ((SYSDATETIME()))
    ,ResolvedDate        DATETIME2(3)   NULL
    ,CONSTRAINT PKC_IndexOptimizationResults PRIMARY KEY CLUSTERED (IndexOptimizationId DESC) WITH(FILLFACTOR = 100)) ON [PRIMARY];
END
GO

-- ==========================================================================
-- Proc: indexing.IndexOptimization_Insert
-- ==========================================================================
CREATE OR ALTER PROCEDURE indexing.IndexOptimization_Insert
  @DatabaseName NVARCHAR(MAX) = NULL
AS
  BEGIN
    SET NOCOUNT ON;
    SET QUOTED_IDENTIFIER ON;
    SET ANSI_NULLS ON;

    DELETE FROM indexing.IndexOptimizationResults WHERE ResolvedDate IS NULL;

    /* Collect live index data from all databases */
    DECLARE @d       INT
           ,@dbName  NVARCHAR(128)
           ,@sql     NVARCHAR(MAX);

    DROP TABLE IF EXISTS #DBs;
    CREATE TABLE #DBs (DatabaseName NVARCHAR(128), rn INT);

    IF @DatabaseName IS NULL
    BEGIN
      INSERT INTO #DBs (DatabaseName, rn)
      SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
      FROM sys.databases d
      WHERE d.state_desc = 'ONLINE'
        AND d.database_id > 4;
    END
    ELSE IF @DatabaseName LIKE '%[%]%'
    BEGIN
      INSERT INTO #DBs (DatabaseName, rn)
      SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
      FROM sys.databases d
      WHERE d.state_desc = 'ONLINE'
        AND d.name LIKE @DatabaseName;
    END
    ELSE
    BEGIN
      INSERT INTO #DBs (DatabaseName, rn)
      SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
      FROM sys.databases d
      INNER JOIN STRING_SPLIT(@DatabaseName, ',') s ON d.name = LTRIM(RTRIM(s.value))
      WHERE d.state_desc = 'ONLINE';
    END;

    DROP TABLE IF EXISTS #ServerIndexes;
    CREATE TABLE #ServerIndexes
      (ServerName       NVARCHAR(128)  NOT NULL
      ,DatabaseName     NVARCHAR(128)  NOT NULL
      ,SchemaName       NVARCHAR(128)  NOT NULL
      ,TableName        NVARCHAR(128)  NOT NULL
      ,IndexId          INT            NOT NULL
      ,IndexName        NVARCHAR(256)  NOT NULL
      ,IndexDescription NVARCHAR(256)  NOT NULL
      ,IndexKeys        NVARCHAR(MAX)  NOT NULL
      ,IncludedColumns  NVARCHAR(MAX)  NULL
      ,FilterDefinition NVARCHAR(MAX)  NULL
      ,IsDisabled       BIT            NOT NULL);

    SELECT @d = MAX(rn) FROM #DBs;

    WHILE @d > 0
    BEGIN
      SELECT @dbName = DatabaseName FROM #DBs WHERE rn = @d;

      SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
      INSERT INTO #ServerIndexes (ServerName, DatabaseName, SchemaName, TableName, IndexId, IndexName
                                 ,IndexDescription, IndexKeys, IncludedColumns, FilterDefinition, IsDisabled)
      SELECT @@SERVERNAME
            ,DB_NAME()
            ,SCHEMA_NAME(t.schema_id) COLLATE DATABASE_DEFAULT
            ,t.name COLLATE DATABASE_DEFAULT
            ,i.index_id
            ,i.name COLLATE DATABASE_DEFAULT
            ,i.type_desc COLLATE DATABASE_DEFAULT
             + CASE WHEN i.is_unique = 1 THEN '', unique'' ELSE '''' END
             + CASE WHEN i.is_primary_key = 1 THEN '', primary key'' ELSE '''' END
             + '' located on '' + ds.name COLLATE DATABASE_DEFAULT
            ,STUFF((SELECT '', ['' + c.name + '']'' + CASE WHEN ic.is_descending_key = 1 THEN ''(-)'' ELSE '''' END
                    FROM sys.index_columns ic
                    JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                    ORDER BY ic.key_ordinal
                    FOR XML PATH(''''), TYPE).value(''.'',''NVARCHAR(MAX)''), 1, 2, '''')
            ,STUFF((SELECT '', ['' + c.name + '']''
                    FROM sys.index_columns ic
                    JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
                    ORDER BY c.name
                    FOR XML PATH(''''), TYPE).value(''.'',''NVARCHAR(MAX)''), 1, 2, '''')
            ,i.filter_definition
            ,i.is_disabled
      FROM sys.tables t
      JOIN sys.indexes i ON t.object_id = i.object_id
      JOIN sys.data_spaces ds ON i.data_space_id = ds.data_space_id
      WHERE i.type > 0
        AND t.name NOT LIKE ''zds%''
        AND t.name NOT LIKE ''ds%''
        AND t.name NOT LIKE ''dataset%''
        AND t.name NOT LIKE ''z_deprecated%''
        AND t.name NOT LIKE ''templateMap[_]%''
        AND SCHEMA_NAME(t.schema_id) <> ''cdc'';';

      BEGIN TRY
        EXEC sp_executesql @sql;
      END TRY
      BEGIN CATCH
        PRINT 'Error collecting indexes from ' + @dbName + ': ' + ERROR_MESSAGE();
      END CATCH;

      SET @d = @d - 1;
    END;

    /* PART 1: Detecting duplicate and redundant indexes */

    DROP TABLE IF EXISTS #BaseIndexes;
    SELECT ServerName
          ,DatabaseName
          ,SchemaName
          ,TableName
          ,IndexId
          ,IndexName
          ,IndexKeys
          ,IncludedColumns
    INTO #BaseIndexes
    FROM #ServerIndexes
    WHERE IsDisabled = 0
          AND FilterDefinition IS NULL
          AND IndexDescription = 'nonclustered located on PRIMARY';

    /* Find DUPLICATE indexes (same keys, superset of includes)*/
    DROP TABLE IF EXISTS #DuplicateIndexes;
    SELECT a.ServerName
          ,a.DatabaseName
          ,a.SchemaName AS SchemaName_Drop
          ,a.TableName AS TableName_Drop
          ,a.IndexName AS IndexName_Drop
          ,a.IndexKeys AS IndexKeys_Drop
          ,ISNULL(a.IncludedColumns, '') AS IncludedColumns_Drop
          ,a.IndexId AS IndexId_Drop
          ,b.SchemaName AS SchemaName_Keep
          ,b.TableName AS TableName_Keep
          ,b.IndexName AS IndexName_Keep
          ,b.IndexKeys AS IndexKeys_Keep
          ,ISNULL(b.IncludedColumns, '') AS IncludedColumns_Keep
          ,b.IndexId AS IndexId_Keep
          ,'DUPLICATE' AS IndexType
    INTO #DuplicateIndexes
    FROM #BaseIndexes a
         INNER JOIN #BaseIndexes b ON a.ServerName = b.ServerName
                                      AND a.DatabaseName = b.DatabaseName
                                      AND a.TableName = b.TableName
                                      AND a.SchemaName = b.SchemaName
                                      AND a.IndexKeys = b.IndexKeys
                                      AND a.IndexId <> b.IndexId
    WHERE ( ( a.IncludedColumns IS NULL
              AND b.IncludedColumns IS NOT NULL)
            OR ( a.IncludedColumns IS NOT NULL
                 AND b.IncludedColumns IS NOT NULL
                 AND (SELECT COUNT(*)FROM STRING_SPLIT(a.IncludedColumns, ',')) < (SELECT COUNT(*)FROM STRING_SPLIT(b.IncludedColumns, ','))))
          AND NOT EXISTS ( SELECT value
                           FROM STRING_SPLIT(ISNULL(a.IncludedColumns, ''), ',')
                           WHERE LTRIM(RTRIM(value)) <> ''
                                 AND LTRIM(RTRIM(value)) NOT IN ( SELECT LTRIM(RTRIM(value))
                                                                  FROM STRING_SPLIT(ISNULL(b.IncludedColumns, ''), ',')));

    /* Find REDUNDANT indexes (keys are prefix, includes are subset or in keys)*/
    DROP TABLE IF EXISTS #RedundantIndexes;
    SELECT a.ServerName
          ,a.DatabaseName
          ,a.SchemaName AS SchemaName_Drop
          ,a.TableName AS TableName_Drop
          ,a.IndexName AS IndexName_Drop
          ,a.IndexKeys AS IndexKeys_Drop
          ,ISNULL(a.IncludedColumns, '') AS IncludedColumns_Drop
          ,a.IndexId AS IndexId_Drop
          ,b.SchemaName AS SchemaName_Keep
          ,b.TableName AS TableName_Keep
          ,b.IndexName AS IndexName_Keep
          ,b.IndexKeys AS IndexKeys_Keep
          ,ISNULL(b.IncludedColumns, '') AS IncludedColumns_Keep
          ,b.IndexId AS IndexId_Keep
          ,'REDUNDANT' AS IndexType
    INTO #RedundantIndexes
    FROM #BaseIndexes AS a
         INNER JOIN #BaseIndexes AS b ON a.ServerName = b.ServerName
                                         AND a.DatabaseName = b.DatabaseName
                                         AND a.TableName = b.TableName
                                         AND a.IndexId <> b.IndexId
                                         AND a.IndexKeys <> b.IndexKeys
                                         AND ( LEFT(b.IndexKeys, LEN(a.IndexKeys) + 1) = a.IndexKeys + ','
                                               OR LEFT(b.IndexKeys, LEN(a.IndexKeys) + 2) = a.IndexKeys + ', ')
    WHERE NOT EXISTS ( SELECT value
                       FROM STRING_SPLIT(ISNULL(a.IncludedColumns, ''), ',')
                       WHERE LTRIM(RTRIM(value)) <> ''
                             AND LTRIM(RTRIM(value)) NOT IN ( SELECT LTRIM(RTRIM(value))
                                                              FROM STRING_SPLIT(ISNULL(b.IncludedColumns, ''), ',')
                                                              UNION
                                                              SELECT LTRIM(RTRIM(value))
                                                              FROM STRING_SPLIT(b.IndexKeys, ',')));

    /* Find DUPLICATE of PK (nonclustered duplicates clustered PK)*/
    DROP TABLE IF EXISTS #PKDuplicates;
    WITH IndexGroups
    AS (SELECT ServerName
              ,DatabaseName
              ,SchemaName
              ,TableName
              ,IndexKeys
              ,IndexId
              ,IndexName
              ,IndexDescription
              ,IncludedColumns
              ,CASE WHEN IndexDescription LIKE 'clustered, unique, primary key%'
                    THEN 1
                    WHEN IndexDescription = 'nonclustered located on PRIMARY'
                    THEN 2
                    ELSE 3
               END AS IndexPriority
              ,COUNT(*) OVER (PARTITION BY ServerName, DatabaseName, SchemaName, TableName, IndexKeys) AS DuplicateCount
        FROM #ServerIndexes
        WHERE IsDisabled = 0
              AND FilterDefinition IS NULL
              AND IncludedColumns IS NULL
              AND (IndexDescription = 'nonclustered located on PRIMARY'
                   OR IndexDescription LIKE 'clustered, unique, primary key%'))
    SELECT ig.ServerName
          ,ig.DatabaseName
          ,ig.SchemaName
          ,ig.TableName
          ,ig.IndexId AS IndexId_Drop
          ,ig.IndexName AS IndexName_Drop
          ,ig.IndexKeys AS IndexKeys_Drop
          ,ig.IncludedColumns AS IncludedColumns_Drop
          ,pk.IndexId AS IndexId_Keep
          ,pk.IndexName AS IndexName_Keep
          ,pk.IndexKeys AS IndexKeys_Keep
          ,pk.IncludedColumns AS IncludedColumns_Keep
          ,'DUPLICATE of PK' AS IndexType
    INTO #PKDuplicates
    FROM IndexGroups ig
         INNER JOIN IndexGroups AS pk ON pk.ServerName = ig.ServerName
                                         AND pk.DatabaseName = ig.DatabaseName
                                         AND pk.SchemaName = ig.SchemaName
                                         AND pk.TableName = ig.TableName
                                         AND pk.IndexKeys = ig.IndexKeys
                                         AND pk.IndexPriority = 1
    WHERE ig.DuplicateCount > 1
          AND ig.IndexPriority = 2;

    /* Combine all duplicates/redundants with deduplication*/
    DROP TABLE IF EXISTS #AllDuplicates;

    SELECT ServerName
          ,DatabaseName
          ,SchemaName_Drop AS SchemaName
          ,TableName_Drop AS TableName
          ,IndexId_Drop
          ,IndexName_Drop
          ,IndexKeys_Drop
          ,IncludedColumns_Drop
          ,IndexId_Keep
          ,IndexName_Keep
          ,IndexKeys_Keep
          ,IncludedColumns_Keep
          ,IndexType
          ,ROW_NUMBER() OVER (PARTITION BY ServerName,DatabaseName,SchemaName_Drop,TableName_Drop,IndexName_Drop
                              ORDER BY CASE IndexType WHEN 'DUPLICATE' THEN 1
                                                      WHEN 'DUPLICATE of PK' THEN 2
                                            ELSE 3
                                       END) AS RowNum
    INTO #AllDuplicates
    FROM ( SELECT *
           FROM #DuplicateIndexes
           UNION ALL
           SELECT *
           FROM #RedundantIndexes
           UNION ALL
           SELECT ServerName
                 ,DatabaseName
                 ,SchemaName
                 ,TableName
                 ,IndexName_Drop
                 ,IndexKeys_Drop
                 ,IncludedColumns_Drop
                 ,IndexId_Drop
                 ,SchemaName
                 ,TableName
                 ,IndexName_Keep
                 ,IndexKeys_Keep
                 ,IncludedColumns_Keep
                 ,IndexId_Keep
                 ,IndexType
           FROM #PKDuplicates) AS AllDups;

    /* Insert duplicates/redundants into results table*/
    INSERT INTO indexing.IndexOptimizationResults (ServerName
                                             ,DatabaseName
                                             ,SchemaName
                                             ,TableName
                                             ,ActionType
                                             ,Index1Id
                                             ,Index1Name
                                             ,Index1Keys
                                             ,Index1Includes
                                             ,Index2Id
                                             ,Index2Name
                                             ,Index2Keys
                                             ,Index2Includes
                                             ,DropStatement1
                                             ,IndexUsageCommand)
    SELECT ServerName
          ,DatabaseName
          ,SchemaName
          ,TableName
          ,IndexType
          ,IndexId_Drop
          ,IndexName_Drop
          ,IndexKeys_Drop
          ,IncludedColumns_Drop
          ,IndexId_Keep
          ,IndexName_Keep
          ,IndexKeys_Keep
          ,IncludedColumns_Keep
          ,'DROP INDEX IF EXISTS [' + REPLACE(REPLACE(IndexName_Drop, '[', ''), ']', '') + '] ON [' + SchemaName
           + '].[' + TableName + '];'
          ,'EXEC sp_helpIndexUsage ''' + SchemaName + '.' + TableName + ''';'
    FROM #AllDuplicates
    WHERE RowNum = 1;

    /* PART 2: Detecting combinable indexes (excluding duplicates) */

    /* Create exclusion list of indexes to drop*/
    DROP TABLE IF EXISTS #ExcludedIndexes;
    SELECT DISTINCT
           ServerName
          ,DatabaseName
          ,TableName
          ,IndexId_Drop AS IndexId
    INTO #ExcludedIndexes
    FROM #AllDuplicates
    WHERE RowNum = 1;

    /* Get all indexes excluding those marked for drop*/
    DROP TABLE IF EXISTS #AllIndexes;
    SELECT ServerName
          ,DatabaseName
          ,SchemaName
          ,TableName
          ,IndexId
          ,IndexName
          ,IndexKeys
          ,ISNULL(IncludedColumns, '') AS IncludedColumns
          ,IndexDescription
    INTO #AllIndexes
    FROM #ServerIndexes
    WHERE IsDisabled = 0
          AND FilterDefinition IS NULL
          AND ( IndexDescription = 'nonclustered located on PRIMARY'
                OR IndexId = 1)
          AND NOT EXISTS ( SELECT 1
                           FROM #ExcludedIndexes ex
                           WHERE ex.ServerName = #ServerIndexes.ServerName
                                 AND ex.DatabaseName = #ServerIndexes.DatabaseName
                                 AND ex.TableName = #ServerIndexes.TableName
                                 AND ex.IndexId = #ServerIndexes.IndexId);

    /* Find combinable index pairs*/
    DROP TABLE IF EXISTS #RawCombinations;
    WITH NonClusteredIndexes
    AS (SELECT ServerName
              ,DatabaseName
              ,SchemaName
              ,TableName
              ,IndexId
              ,IndexName
              ,IndexKeys
              ,IncludedColumns
        FROM #AllIndexes
        WHERE IndexDescription = 'nonclustered located on PRIMARY')
        ,ClusteredIndexKeys
    AS (SELECT ServerName
              ,DatabaseName
              ,TableName
              ,IndexKeys AS ClusteredKeys
        FROM #AllIndexes
        WHERE IndexId = 1)
        ,Combinations
    AS (SELECT i1.ServerName
              ,i1.DatabaseName
              ,i1.SchemaName
              ,i1.TableName
              ,i1.IndexId AS ShorterIndexId
              ,i1.IndexName AS ShorterIndexName
              ,i1.IndexKeys AS ShorterKeys
              ,i1.IncludedColumns AS ShorterIncludes
              ,i2.IndexId AS LongerIndexId
              ,i2.IndexName AS LongerIndexName
              ,i2.IndexKeys AS LongerKeys
              ,i2.IncludedColumns AS LongerIncludes
              ,ISNULL(ck.ClusteredKeys, '') AS ClusteredKeys
        FROM NonClusteredIndexes i1
             INNER JOIN NonClusteredIndexes i2 ON i1.ServerName = i2.ServerName
                                                  AND i1.DatabaseName = i2.DatabaseName
                                                  AND i1.TableName = i2.TableName
                                                  AND i1.IndexId < i2.IndexId
                                                  AND LEFT(i2.IndexKeys, LEN(i1.IndexKeys) + 2) = i1.IndexKeys + ', '
                                                  AND LEN(i2.IndexKeys) > LEN(i1.IndexKeys)
             LEFT JOIN ClusteredIndexKeys ck ON i1.ServerName = ck.ServerName
                                                AND i1.DatabaseName = ck.DatabaseName
                                                AND i1.TableName = ck.TableName
        UNION ALL
        SELECT i2.ServerName
              ,i2.DatabaseName
              ,i2.SchemaName
              ,i2.TableName
              ,i2.IndexId AS ShorterIndexId
              ,i2.IndexName AS ShorterIndexName
              ,i2.IndexKeys AS ShorterKeys
              ,i2.IncludedColumns AS ShorterIncludes
              ,i1.IndexId AS LongerIndexId
              ,i1.IndexName AS LongerIndexName
              ,i1.IndexKeys AS LongerKeys
              ,i1.IncludedColumns AS LongerIncludes
              ,ISNULL(ck.ClusteredKeys, '') AS ClusteredKeys
        FROM NonClusteredIndexes i1
             INNER JOIN NonClusteredIndexes i2 ON i1.ServerName = i2.ServerName
                                                  AND i1.DatabaseName = i2.DatabaseName
                                                  AND i1.TableName = i2.TableName
                                                  AND i1.IndexId < i2.IndexId
                                                  AND LEFT(i1.IndexKeys, LEN(i2.IndexKeys) + 2) = i2.IndexKeys + ', '
                                                  AND LEN(i1.IndexKeys) > LEN(i2.IndexKeys)
             LEFT JOIN ClusteredIndexKeys ck ON i1.ServerName = ck.ServerName
                                                AND i1.DatabaseName = ck.DatabaseName
                                                AND i1.TableName = ck.TableName
        UNION ALL
        /* Same keys, different includes — merge into one */
        SELECT i1.ServerName
              ,i1.DatabaseName
              ,i1.SchemaName
              ,i1.TableName
              ,i1.IndexId AS ShorterIndexId
              ,i1.IndexName AS ShorterIndexName
              ,i1.IndexKeys AS ShorterKeys
              ,i1.IncludedColumns AS ShorterIncludes
              ,i2.IndexId AS LongerIndexId
              ,i2.IndexName AS LongerIndexName
              ,i2.IndexKeys AS LongerKeys
              ,i2.IncludedColumns AS LongerIncludes
              ,ISNULL(ck.ClusteredKeys, '') AS ClusteredKeys
        FROM NonClusteredIndexes i1
             INNER JOIN NonClusteredIndexes i2 ON i1.ServerName = i2.ServerName
                                                  AND i1.DatabaseName = i2.DatabaseName
                                                  AND i1.TableName = i2.TableName
                                                  AND i1.IndexId < i2.IndexId
                                                  AND i1.IndexKeys = i2.IndexKeys
                                                  AND ISNULL(i1.IncludedColumns, '') <> ISNULL(i2.IncludedColumns, '')
             LEFT JOIN ClusteredIndexKeys ck ON i1.ServerName = ck.ServerName
                                                AND i1.DatabaseName = ck.DatabaseName
                                                AND i1.TableName = ck.TableName)
    SELECT ROW_NUMBER() OVER (ORDER BY DatabaseName, TableName, ShorterIndexId, LongerIndexId) AS CombinationId
          ,ServerName
          ,DatabaseName
          ,SchemaName
          ,TableName
          ,ShorterIndexId
          ,ShorterIndexName
          ,ShorterKeys
          ,ShorterIncludes
          ,LongerIndexId
          ,LongerIndexName
          ,LongerKeys
          ,LongerIncludes
          ,ClusteredKeys
    INTO #RawCombinations
    FROM Combinations;

    /* Build combined include columns*/
    DROP TABLE IF EXISTS #AllIncludeColumns;
    SELECT CombinationId
          ,LTRIM(RTRIM(value)) AS ColumnName
    INTO #AllIncludeColumns
    FROM ( SELECT CombinationId
                 ,ShorterIncludes AS IncludeList
           FROM #RawCombinations
           WHERE ShorterIncludes <> ''
           UNION ALL
           SELECT CombinationId
                 ,LongerIncludes AS IncludeList
           FROM #RawCombinations
           WHERE LongerIncludes <> '') AS AllIncludes
         CROSS APPLY STRING_SPLIT(IncludeList, ',')
    WHERE value <> '';

    DROP TABLE IF EXISTS #FilteredIncludes;
    SELECT DISTINCT
           ic.CombinationId
          ,ic.ColumnName
    INTO #FilteredIncludes
    FROM #AllIncludeColumns ic
         INNER JOIN #RawCombinations rc ON ic.CombinationId = rc.CombinationId
    WHERE CHARINDEX(ic.ColumnName, ', ' + rc.LongerKeys) = 0
          AND ( CHARINDEX(ic.ColumnName, ', ' + rc.ClusteredKeys) = 0
                OR rc.ClusteredKeys = '');

    /* Build final combinations*/
    DROP TABLE IF EXISTS #FinalCombinations;
    SELECT rc.CombinationId
          ,rc.ServerName
          ,rc.DatabaseName
          ,rc.SchemaName
          ,rc.TableName
          ,rc.ShorterIndexId
          ,rc.ShorterIndexName
          ,rc.ShorterKeys
          ,rc.ShorterIncludes
          ,rc.LongerIndexId
          ,rc.LongerIndexName
          ,rc.LongerKeys
          ,rc.LongerIncludes
          ,ISNULL(STUFF(( SELECT ', ' + ColumnName
                          FROM #FilteredIncludes fi
                          WHERE fi.CombinationId = rc.CombinationId
                          ORDER BY ColumnName
                          FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'),1,2,'')
                 ,'') AS CombinedIncludes
          ,'IX_' + rc.TableName + '_' + REPLACE(REPLACE(REPLACE(REPLACE(rc.LongerKeys, '(-)', ''), '[', ''), ']', ''), ', ', '_')
           + CASE WHEN ISNULL(STUFF(( SELECT ', ' + ColumnName
                                      FROM #FilteredIncludes fi
                                      WHERE fi.CombinationId = rc.CombinationId
                                      FOR XML PATH('')),1,2,''),'') = ''
                  THEN ''
                  WHEN ISNULL(STUFF(( SELECT ', ' + ColumnName
                                      FROM #FilteredIncludes fi
                                      WHERE fi.CombinationId = rc.CombinationId
                                      FOR XML PATH('')),1,2,''),'')NOT LIKE '%,%'
                  THEN '_INCLUDE'
                  ELSE '_INCLUDES'
             END AS BaseIndexName
    INTO #FinalCombinations
    FROM #RawCombinations rc;

    /* Check for name collisions*/
    UPDATE fc
    SET BaseIndexName = BaseIndexName + '_NEW'
    FROM #FinalCombinations fc
    WHERE EXISTS ( SELECT 1
                   FROM ( SELECT REPLACE(REPLACE(ShorterIndexName, '[', ''), ']', '') AS CleanName
                          FROM #FinalCombinations
                          UNION ALL
                          SELECT REPLACE(REPLACE(LongerIndexName, '[', ''), ']', '')
                          FROM #FinalCombinations) AS names
                   WHERE names.CleanName = fc.BaseIndexName);

    /* Insert combinations into results table*/
    INSERT INTO indexing.IndexOptimizationResults (ServerName
                                             ,DatabaseName
                                             ,SchemaName
                                             ,TableName
                                             ,ActionType
                                             ,Index1Id
                                             ,Index1Name
                                             ,Index1Keys
                                             ,Index1Includes
                                             ,Index2Id
                                             ,Index2Name
                                             ,Index2Keys
                                             ,Index2Includes
                                             ,NewIndexName
                                             ,NewIndexKeys
                                             ,NewIncludeColumns
                                             ,NewIndexNameExists
                                             ,CreateStatement
                                             ,DropStatement1
                                             ,DropStatement2
                                             ,IndexUsageCommand)
    SELECT fc.ServerName
          ,fc.DatabaseName
          ,fc.SchemaName
          ,fc.TableName
          ,'COMBINE'
          ,fc.ShorterIndexId
          ,fc.ShorterIndexName
          ,fc.ShorterKeys
          ,fc.ShorterIncludes
          ,fc.LongerIndexId
          ,fc.LongerIndexName
          ,fc.LongerKeys
          ,fc.LongerIncludes
          ,fc.BaseIndexName
          ,REPLACE(fc.LongerKeys, '(-)', ' DESC')
          ,fc.CombinedIncludes
          ,CASE WHEN fc.BaseIndexName LIKE '%_NEW' THEN 1 ELSE 0 END
          ,'CREATE NONCLUSTERED INDEX [' + fc.BaseIndexName + ']' + CHAR(13) + CHAR(10) + 'ON [' + fc.SchemaName
           + '].[' + fc.TableName + '] (' + REPLACE(fc.LongerKeys, '(-)', ' DESC') + ')'
           + CASE WHEN fc.CombinedIncludes <> ''
                  THEN CHAR(13) + CHAR(10) + 'INCLUDE (' + fc.CombinedIncludes + ');'
                  ELSE ';'
             END
          ,'DROP INDEX IF EXISTS [' + REPLACE(REPLACE(fc.ShorterIndexName, '[', ''), ']', '') + '] ON ['
           + fc.SchemaName + '].[' + fc.TableName + '];'
          ,'DROP INDEX IF EXISTS [' + REPLACE(REPLACE(fc.LongerIndexName, '[', ''), ']', '') + '] ON [' + fc.SchemaName
           + '].[' + fc.TableName + '];'
          ,'EXEC sp_helpIndexUsage ''' + fc.SchemaName + '.' + fc.TableName + ''';'
    FROM #FinalCombinations fc;

    /* Estimate size for COMBINE new indexes */
    DECLARE @cmbId INT, @cmbDB NVARCHAR(128), @cmbSchema NVARCHAR(128), @cmbTable NVARCHAR(128);
    DECLARE @cmbKeys NVARCHAR(MAX), @cmbInc NVARCHAR(MAX);
    DECLARE @cmbWarning NVARCHAR(MAX), @cmbEstGB DECIMAL(18,2), @cmbGBPos INT, @cmbGBEnd INT;
    DECLARE @cmbSchemaTable NVARCHAR(256);

    DECLARE cmb_size_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT IndexOptimizationId, DatabaseName, SchemaName, TableName, NewIndexKeys, NewIncludeColumns
        FROM indexing.IndexOptimizationResults
        WHERE ResolvedDate IS NULL AND ActionType = 'COMBINE';

    OPEN cmb_size_cursor;
    FETCH NEXT FROM cmb_size_cursor INTO @cmbId, @cmbDB, @cmbSchema, @cmbTable, @cmbKeys, @cmbInc;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @cmbWarning = NULL;
        SET @cmbEstGB = NULL;

        SET @cmbSchemaTable = QUOTENAME(@cmbSchema) + '.' + QUOTENAME(@cmbTable);

        BEGIN TRY
            EXEC indexing.sp_GetHybridIndexSizeEstimate
                @DatabaseName      = @cmbDB,
                @SchemaTable       = @cmbSchemaTable,
                @RecKeyColumns     = @cmbKeys,
                @RecIncludeColumns = @cmbInc,
                @Warning           = @cmbWarning OUTPUT;

            IF @cmbWarning IS NOT NULL
            BEGIN
                SET @cmbGBPos = CHARINDEX('~', @cmbWarning);
                SET @cmbGBEnd = CHARINDEX(' GB', @cmbWarning, @cmbGBPos);
                IF @cmbGBPos > 0 AND @cmbGBEnd > @cmbGBPos
                    SET @cmbEstGB = TRY_CAST(SUBSTRING(@cmbWarning, @cmbGBPos + 1, @cmbGBEnd - @cmbGBPos - 1) AS DECIMAL(18,2));
            END
        END TRY
        BEGIN CATCH
            SET @cmbEstGB = NULL;
        END CATCH

        IF @cmbEstGB IS NOT NULL
            UPDATE indexing.IndexOptimizationResults SET EstimatedSizeGB = @cmbEstGB WHERE IndexOptimizationId = @cmbId;

        FETCH NEXT FROM cmb_size_cursor INTO @cmbId, @cmbDB, @cmbSchema, @cmbTable, @cmbKeys, @cmbInc;
    END

    CLOSE cmb_size_cursor;
    DEALLOCATE cmb_size_cursor;

    /* Populate size and usage stats from DMVs for results only*/
    DECLARE @statsSQL NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
      SELECT DISTINCT DatabaseName FROM indexing.IndexOptimizationResults
      WHERE ResolvedDate IS NULL
        AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @dbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
      SET @statsSQL = N'USE ' + QUOTENAME(@dbName) + N';

        ;WITH IndexStats AS (
          SELECT SCHEMA_NAME(o.schema_id) AS SchemaName
                ,o.name AS TableName
                ,i.index_id
                ,SUM(ps.used_page_count) * 8 AS SizeKB
                ,MAX(us.user_seeks) AS UserSeeks
                ,MAX(us.user_scans) AS UserScans
          FROM sys.objects o
          INNER JOIN sys.indexes i ON o.object_id = i.object_id
          INNER JOIN sys.dm_db_partition_stats ps ON i.object_id = ps.object_id AND i.index_id = ps.index_id
          LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID()
          WHERE o.type = ''U''
            AND EXISTS (
              SELECT 1 FROM DBA_Utilities.indexing.IndexOptimizationResults r
              WHERE r.DatabaseName = DB_NAME()
                AND r.SchemaName = SCHEMA_NAME(o.schema_id)
                AND r.TableName = o.name
                AND (r.Index1Id = i.index_id OR r.Index2Id = i.index_id)
                AND r.ResolvedDate IS NULL
            )
          GROUP BY SCHEMA_NAME(o.schema_id), o.name, i.index_id
        )
        UPDATE r
        SET Index1SizeKB    = s1.SizeKB
           ,Index1UserSeeks = ISNULL(s1.UserSeeks, 0)
           ,Index1UserScans = ISNULL(s1.UserScans, 0)
           ,Index2SizeKB    = s2.SizeKB
           ,Index2UserSeeks = ISNULL(s2.UserSeeks, 0)
           ,Index2UserScans = ISNULL(s2.UserScans, 0)
        FROM DBA_Utilities.indexing.IndexOptimizationResults r
        LEFT JOIN IndexStats s1 ON s1.SchemaName = r.SchemaName AND s1.TableName = r.TableName AND s1.index_id = r.Index1Id
        LEFT JOIN IndexStats s2 ON s2.SchemaName = r.SchemaName AND s2.TableName = r.TableName AND s2.index_id = r.Index2Id
        WHERE r.DatabaseName = DB_NAME()
          AND r.ResolvedDate IS NULL;';

      EXEC sp_executesql @statsSQL;

      FETCH NEXT FROM db_cursor INTO @dbName;
    END;

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

  END;
GO

-- ==========================================================================
-- Proc: indexing.sp_DuplicateIndexOptimizationRecommendations
-- ==========================================================================
CREATE OR ALTER PROCEDURE indexing.sp_DuplicateIndexOptimizationRecommendations
  @DatabaseName  NVARCHAR(MAX)  = NULL
 ,@TableName     NVARCHAR(128)  = NULL
 ,@ActionType    VARCHAR(20)    = NULL
 ,@RunnableUnder VARCHAR(20)    = NULL
 ,@RunAnalysis   BIT            = 0
AS
BEGIN
  SET NOCOUNT ON;

  IF @RunAnalysis = 1
    EXEC DBA_Utilities.indexing.IndexOptimization_Insert @DatabaseName = @DatabaseName;

  DECLARE @ScriptText NVARCHAR(MAX) = '';
  DECLARE @CRLF       CHAR(2)       = CHAR(13) + CHAR(10);
  DECLARE @Separator   VARCHAR(60)  = '/*****************************************************/';

  -- Parse @RunnableUnder: NULL=off, '2'=2GB both, '1,5e'=1GB Standard/5GB Enterprise
  DECLARE @ThresholdStd DECIMAL(10,2) = NULL;
  DECLARE @ThresholdEnt DECIMAL(10,2) = NULL;
  DECLARE @ActiveThreshold DECIMAL(10,2) = NULL;

  IF @RunnableUnder IS NOT NULL AND LTRIM(RTRIM(@RunnableUnder)) <> ''
  BEGIN
      IF @RunnableUnder LIKE '%,%e'
      BEGIN
          SET @ThresholdStd = TRY_CAST(LEFT(@RunnableUnder, CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
          SET @ThresholdEnt = TRY_CAST(SUBSTRING(@RunnableUnder, CHARINDEX(',', @RunnableUnder) + 1,
              LEN(@RunnableUnder) - CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
      END
      ELSE
      BEGIN
          SET @ThresholdStd = TRY_CAST(@RunnableUnder AS DECIMAL(10,2));
          SET @ThresholdEnt = @ThresholdStd;
      END
  END

  DECLARE @TotalDuplicate    INT = 0;
  DECLARE @TotalRedundant    INT = 0;
  DECLARE @TotalDuplicatePK  INT = 0;
  DECLARE @TotalCombine      INT = 0;
  DECLARE @TotalDatabases    INT = 0;
  DECLARE @TotalTables       INT = 0;

  SELECT @TotalDuplicate   = SUM(CASE WHEN ActionType = 'DUPLICATE'       THEN 1 ELSE 0 END)
        ,@TotalRedundant   = SUM(CASE WHEN ActionType = 'REDUNDANT'       THEN 1 ELSE 0 END)
        ,@TotalDuplicatePK = SUM(CASE WHEN ActionType = 'DUPLICATE of PK' THEN 1 ELSE 0 END)
        ,@TotalCombine     = SUM(CASE WHEN ActionType = 'COMBINE'         THEN 1 ELSE 0 END)
  FROM indexing.IndexOptimizationResults
  WHERE (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
    AND (@TableName    IS NULL OR TableName    = @TableName)
    AND (@ActionType   IS NULL OR ActionType   = @ActionType)
    AND ResolvedDate IS NULL
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SELECT @TotalDatabases = COUNT(DISTINCT DatabaseName)
        ,@TotalTables    = COUNT(DISTINCT DatabaseName + '.' + SchemaName + '.' + TableName)
  FROM indexing.IndexOptimizationResults
  WHERE (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
    AND (@TableName    IS NULL OR TableName    = @TableName)
    AND (@ActionType   IS NULL OR ActionType   = @ActionType)
    AND ResolvedDate IS NULL
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SET @ScriptText =
    '/*' + @CRLF
    + '==============================================================================' + @CRLF
    + '  DUPLICATE INDEX OPTIMIZATION RECOMMENDATIONS' + @CRLF
    + '  Server: ' + @@SERVERNAME + @CRLF
    + '  Generated: ' + CONVERT(VARCHAR(30), GETDATE(), 120) + @CRLF
    + '==============================================================================' + @CRLF
    + 'Statistics:' + @CRLF
    + '    Databases:       ' + CAST(@TotalDatabases AS VARCHAR(10)) + @CRLF
    + '    Tables:          ' + CAST(@TotalTables AS VARCHAR(10)) + @CRLF
    + '    DUPLICATE:       ' + CAST(@TotalDuplicate AS VARCHAR(10)) + @CRLF
    + '    REDUNDANT:       ' + CAST(@TotalRedundant AS VARCHAR(10)) + @CRLF
    + '    DUPLICATE of PK: ' + CAST(@TotalDuplicatePK AS VARCHAR(10)) + @CRLF
    + '    COMBINE:         ' + CAST(@TotalCombine AS VARCHAR(10)) + @CRLF
    + @CRLF
    + 'Filters:' + @CRLF
    + '    @DatabaseName   = ' + ISNULL('''' + @DatabaseName + '''', 'ALL') + @CRLF
    + '    @TableName      = ' + ISNULL('''' + @TableName + '''', 'ALL') + @CRLF
    + '    @ActionType     = ' + ISNULL('''' + @ActionType + '''', 'ALL') + @CRLF
    + '    @RunnableUnder  = ' + ISNULL('''' + @RunnableUnder + '''', 'NULL (all uncommented)') + @CRLF
    + '*/' + @CRLF;

  IF @ActiveThreshold IS NOT NULL
    SET @ScriptText = @ScriptText
      + '-- @RunnableUnder = ' + @RunnableUnder
      + CASE WHEN @ThresholdStd <> @ThresholdEnt
          THEN ' (Standard: ' + CAST(@ThresholdStd AS VARCHAR(10)) + ' GB, Enterprise: ' + CAST(@ThresholdEnt AS VARCHAR(10)) + ' GB)'
          ELSE ' (' + CAST(@ActiveThreshold AS VARCHAR(10)) + ' GB)'
        END
      + ', sp_helpindexusage commented out, COMBINE operations >= threshold commented out' + @CRLF;

  DECLARE @CurrentDB     NVARCHAR(128) = '';
  DECLARE @CurrentTable  NVARCHAR(400) = '';
  DECLARE @IsFirstDB     BIT = 1;

  DECLARE @Id             INT;
  DECLARE @DB             NVARCHAR(128);
  DECLARE @Schema         NVARCHAR(128);
  DECLARE @Table          NVARCHAR(128);
  DECLARE @Action         VARCHAR(20);
  DECLARE @Idx1Id         INT;
  DECLARE @Idx1Name       NVARCHAR(256);
  DECLARE @Idx1Keys       NVARCHAR(MAX);
  DECLARE @Idx1Includes   NVARCHAR(MAX);
  DECLARE @Idx2Id         INT;
  DECLARE @Idx2Name       NVARCHAR(256);
  DECLARE @Idx2Keys       NVARCHAR(MAX);
  DECLARE @Idx2Includes   NVARCHAR(MAX);
  DECLARE @NewIdxName     NVARCHAR(500);
  DECLARE @NewIdxKeys     NVARCHAR(MAX);
  DECLARE @NewIncludes    NVARCHAR(MAX);
  DECLARE @NewNameExists  BIT;
  DECLARE @CreateStmt     NVARCHAR(MAX);
  DECLARE @EstSizeGB      DECIMAL(18,2);
  DECLARE @DropStmt1      NVARCHAR(1000);
  DECLARE @DropStmt2      NVARCHAR(1000);
  DECLARE @UsageCmd       NVARCHAR(500);
  DECLARE @ProcessedDate  DATETIME2(3);
  DECLARE @Idx1SizeKB     BIGINT;
  DECLARE @Idx1UserSeeks  BIGINT;
  DECLARE @Idx1UserScans  BIGINT;
  DECLARE @Idx2SizeKB     BIGINT;
  DECLARE @Idx2UserSeeks  BIGINT;
  DECLARE @Idx2UserScans  BIGINT;
  DECLARE @IsEnterprise   BIT = 0;
  DECLARE @ShouldComment  BIT;
  DECLARE @CheckSizeKB    BIGINT;
  DECLARE @RunnableCount  INT = 0;

  IF CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Enterprise%'
    OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Developer%'
    SET @IsEnterprise = 1;

  SET @ActiveThreshold = CASE WHEN @IsEnterprise = 1 THEN @ThresholdEnt ELSE @ThresholdStd END;

  DECLARE rec_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT IndexOptimizationId, DatabaseName, SchemaName, TableName, ActionType
          ,Index1Id, Index1Name, Index1Keys, Index1Includes
          ,Index1SizeKB, Index1UserSeeks, Index1UserScans
          ,Index2Id, Index2Name, Index2Keys, Index2Includes
          ,Index2SizeKB, Index2UserSeeks, Index2UserScans
          ,NewIndexName, NewIndexKeys, NewIncludeColumns, NewIndexNameExists
          ,CreateStatement, EstimatedSizeGB, DropStatement1, DropStatement2
          ,IndexUsageCommand, ProcessedDate
    FROM indexing.IndexOptimizationResults
    WHERE (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
      AND (@TableName    IS NULL OR TableName    = @TableName)
      AND (@ActionType   IS NULL OR ActionType   = @ActionType)
      AND ResolvedDate IS NULL
      AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName)
    ORDER BY DatabaseName, TableName,
      CASE ActionType
        WHEN 'DUPLICATE'       THEN 1
        WHEN 'DUPLICATE of PK' THEN 2
        WHEN 'REDUNDANT'       THEN 3
        WHEN 'COMBINE'         THEN 4
      END;

  OPEN rec_cursor;
  FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table, @Action
    ,@Idx1Id, @Idx1Name, @Idx1Keys, @Idx1Includes
    ,@Idx1SizeKB, @Idx1UserSeeks, @Idx1UserScans
    ,@Idx2Id, @Idx2Name, @Idx2Keys, @Idx2Includes
    ,@Idx2SizeKB, @Idx2UserSeeks, @Idx2UserScans
    ,@NewIdxName, @NewIdxKeys, @NewIncludes, @NewNameExists
    ,@CreateStmt, @EstSizeGB, @DropStmt1, @DropStmt2
    ,@UsageCmd, @ProcessedDate;

  WHILE @@FETCH_STATUS = 0
  BEGIN

    IF @DB <> @CurrentDB
    BEGIN
      IF @IsFirstDB = 0
        SET @ScriptText = @ScriptText + @CRLF;

      SET @CurrentDB    = @DB;
      SET @CurrentTable = '';
      SET @IsFirstDB    = 0;

      SET @ScriptText = @ScriptText
        + '-- ============================================================================' + @CRLF
        + '-- Database: ' + @DB + @CRLF
        + '-- ============================================================================' + @CRLF
        + 'USE ' + QUOTENAME(@DB) + @CRLF
        + 'GO' + @CRLF;
    END;

    DECLARE @TableKey NVARCHAR(400) = @DB + '.' + @Schema + '.' + @Table;
    IF @TableKey <> @CurrentTable
    BEGIN
      SET @CurrentTable = @TableKey;
      SET @ScriptText = @ScriptText
        + @CRLF
        + @Separator + @CRLF
        + '-- Table: ' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + @CRLF
        + @Separator + @CRLF;
    END;

    SET @ScriptText = @ScriptText + @CRLF;

    IF @Action IN ('DUPLICATE', 'DUPLICATE of PK', 'REDUNDANT')
    BEGIN
      SET @ScriptText = @ScriptText
        + '-- ' + @Action + @CRLF
        + '--   DROP:  ' + @Idx1Name + ' (Id: ' + CAST(@Idx1Id AS VARCHAR(10)) + ')' + @CRLF
        + '--     Key Columns:     ' + @Idx1Keys + @CRLF
        + '--     Include Columns: ' + ISNULL(NULLIF(@Idx1Includes, ''), '(none)') + @CRLF
        + '--     Size: ' + ISNULL(FORMAT(CAST(@Idx1SizeKB / 1024.0 AS DECIMAL(10,1)), 'N1'), '?') + ' MB'
        + '  |  Seeks: ' + ISNULL(FORMAT(@Idx1UserSeeks, 'N0'), '?')
        + '  |  Scans: ' + ISNULL(FORMAT(@Idx1UserScans, 'N0'), '?') + @CRLF
        + '--   KEEP:  ' + ISNULL(@Idx2Name, 'CLUSTERED PK') + ISNULL(' (Id: ' + CAST(@Idx2Id AS VARCHAR(10)) + ')', '') + @CRLF
        + '--     Key Columns:     ' + ISNULL(@Idx2Keys, '(clustered key)') + @CRLF
        + '--     Include Columns: ' + ISNULL(NULLIF(@Idx2Includes, ''), '(none)') + @CRLF
        + '--     Size: ' + ISNULL(FORMAT(CAST(@Idx2SizeKB / 1024.0 AS DECIMAL(10,1)), 'N1'), '?') + ' MB'
        + '  |  Seeks: ' + ISNULL(FORMAT(@Idx2UserSeeks, 'N0'), '?')
        + '  |  Scans: ' + ISNULL(FORMAT(@Idx2UserScans, 'N0'), '?') + @CRLF
        + @CRLF;

      IF @UsageCmd IS NOT NULL
      BEGIN
        IF @ActiveThreshold IS NOT NULL
          SET @ScriptText = @ScriptText + '-- ' + @UsageCmd + @CRLF + @CRLF;
        ELSE
          SET @ScriptText = @ScriptText + @UsageCmd + @CRLF + @CRLF;
      END;

      SET @ScriptText = @ScriptText + @DropStmt1 + @CRLF
        + @CRLF + 'UPDATE DBA_Utilities.indexing.IndexOptimizationResults SET ResolvedDate = GETDATE() WHERE IndexOptimizationId = ' + CAST(@Id AS VARCHAR(10)) + ';' + @CRLF;
      SET @RunnableCount = @RunnableCount + 1;
    END;

    IF @Action = 'COMBINE'
    BEGIN
      SET @CheckSizeKB = ISNULL(CASE WHEN ISNULL(@Idx1SizeKB, 0) > ISNULL(@Idx2SizeKB, 0) THEN @Idx1SizeKB ELSE @Idx2SizeKB END, 0);
      SET @ShouldComment = CASE WHEN @ActiveThreshold IS NOT NULL
          AND (@CheckSizeKB >= CAST(@ActiveThreshold * 1048576 AS BIGINT) OR ISNULL(@EstSizeGB, 0) >= @ActiveThreshold) THEN 1 ELSE 0 END;

      SET @ScriptText = @ScriptText
        + '-- COMBINE' + @CRLF
        + '--   Index 1: ' + @Idx1Name + ' (Id: ' + CAST(@Idx1Id AS VARCHAR(10)) + ')' + @CRLF
        + '--     Key Columns:     ' + @Idx1Keys + @CRLF
        + '--     Include Columns: ' + ISNULL(NULLIF(@Idx1Includes, ''), '(none)') + @CRLF
        + '--     Size: ' + ISNULL(FORMAT(CAST(@Idx1SizeKB / 1024.0 AS DECIMAL(10,1)), 'N1'), '?') + ' MB'
        + '  |  Seeks: ' + ISNULL(FORMAT(@Idx1UserSeeks, 'N0'), '?')
        + '  |  Scans: ' + ISNULL(FORMAT(@Idx1UserScans, 'N0'), '?') + @CRLF
        + '--   Index 2: ' + @Idx2Name + ' (Id: ' + CAST(@Idx2Id AS VARCHAR(10)) + ')' + @CRLF
        + '--     Key Columns:     ' + ISNULL(@Idx2Keys, '') + @CRLF
        + '--     Include Columns: ' + ISNULL(NULLIF(@Idx2Includes, ''), '(none)') + @CRLF
        + '--     Size: ' + ISNULL(FORMAT(CAST(@Idx2SizeKB / 1024.0 AS DECIMAL(10,1)), 'N1'), '?') + ' MB'
        + '  |  Seeks: ' + ISNULL(FORMAT(@Idx2UserSeeks, 'N0'), '?')
        + '  |  Scans: ' + ISNULL(FORMAT(@Idx2UserScans, 'N0'), '?') + @CRLF
        + '--   New Index: ' + ISNULL(@NewIdxName, '') + @CRLF
        + '--     Key Columns:     ' + ISNULL(@NewIdxKeys, '') + @CRLF
        + '--     Include Columns: ' + ISNULL(NULLIF(@NewIncludes, ''), '(none)') + @CRLF;

      DECLARE @CoveredByCK NVARCHAR(MAX) = NULL;
      SELECT @CoveredByCK = STUFF((
        SELECT ', ' + LTRIM(RTRIM(c.value))
        FROM (
          SELECT value FROM STRING_SPLIT(ISNULL(@Idx1Includes, ''), ',')
          UNION
          SELECT value FROM STRING_SPLIT(ISNULL(@Idx2Includes, ''), ',')
        ) c
        WHERE LTRIM(RTRIM(c.value)) <> ''
          AND CHARINDEX(LTRIM(RTRIM(c.value)), ISNULL(@NewIdxKeys, '')) = 0
          AND CHARINDEX(LTRIM(RTRIM(c.value)), ISNULL(@NewIncludes, '') + ',') = 0
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

      IF @CoveredByCK IS NOT NULL AND @CoveredByCK <> ''
        SET @ScriptText = @ScriptText + '--     Covered by clustered key (implicit): ' + @CoveredByCK + @CRLF;

      IF @NewNameExists = 1
        SET @ScriptText = @ScriptText + '--   WARNING: New index name already exists' + @CRLF;

      IF @EstSizeGB IS NOT NULL
        SET @ScriptText = @ScriptText + '--   Estimated Size: ~' + FORMAT(@EstSizeGB * 1024, 'N1') + ' MB' + @CRLF;

      SET @ScriptText = @ScriptText + @CRLF;

      IF @UsageCmd IS NOT NULL
      BEGIN
        IF @ActiveThreshold IS NOT NULL
          SET @ScriptText = @ScriptText + '-- ' + @UsageCmd + @CRLF + @CRLF;
        ELSE
          SET @ScriptText = @ScriptText + @UsageCmd + @CRLF + @CRLF;
      END;

      IF @ShouldComment = 1
        SET @ScriptText = @ScriptText + '/*' + @CRLF;

      IF @CreateStmt IS NOT NULL
      BEGIN
        IF @IsEnterprise = 1
          SET @ScriptText = @ScriptText + REPLACE(@CreateStmt, ';', ' WITH (ONLINE = ON);') + @CRLF;
        ELSE
          SET @ScriptText = @ScriptText + @CreateStmt + @CRLF;
      END;

      SET @ScriptText = @ScriptText + @CRLF + @DropStmt1 + @CRLF;

      IF @DropStmt2 IS NOT NULL
        SET @ScriptText = @ScriptText + @DropStmt2 + @CRLF;

      IF @NewNameExists = 1
        SET @ScriptText = @ScriptText + @CRLF
          + 'EXEC sp_rename N''' + @Schema + '.' + @Table + '.' + @NewIdxName + ''', N''' + REPLACE(@NewIdxName, '_NEW', '') + ''', N''INDEX''' + @CRLF;

      SET @ScriptText = @ScriptText
        + @CRLF + 'UPDATE DBA_Utilities.indexing.IndexOptimizationResults SET ResolvedDate = GETDATE() WHERE IndexOptimizationId = ' + CAST(@Id AS VARCHAR(10)) + ';' + @CRLF;

      IF @ShouldComment = 1
        SET @ScriptText = @ScriptText + '*/' + @CRLF;
      ELSE
        SET @RunnableCount = @RunnableCount + 1;
    END;

    FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table, @Action
      ,@Idx1Id, @Idx1Name, @Idx1Keys, @Idx1Includes
      ,@Idx1SizeKB, @Idx1UserSeeks, @Idx1UserScans
      ,@Idx2Id, @Idx2Name, @Idx2Keys, @Idx2Includes
      ,@Idx2SizeKB, @Idx2UserSeeks, @Idx2UserScans
      ,@NewIdxName, @NewIdxKeys, @NewIncludes, @NewNameExists
      ,@CreateStmt, @EstSizeGB, @DropStmt1, @DropStmt2
      ,@UsageCmd, @ProcessedDate;
  END;

  CLOSE rec_cursor;
  DEALLOCATE rec_cursor;

  DECLARE @Statistics NVARCHAR(500) =
    'Databases: ' + CAST(@TotalDatabases AS VARCHAR(10))
    + ', DUPLICATE: ' + CAST(@TotalDuplicate AS VARCHAR(10))
    + ', REDUNDANT: ' + CAST(@TotalRedundant AS VARCHAR(10))
    + ', DUPLICATE of PK: ' + CAST(@TotalDuplicatePK AS VARCHAR(10))
    + ', COMBINE: ' + CAST(@TotalCombine AS VARCHAR(10));

  DECLARE @TotalRecs INT = @TotalDuplicate + @TotalRedundant + @TotalDuplicatePK + @TotalCombine;

  DECLARE @TotalUnfiltered INT;
  SELECT @TotalUnfiltered = COUNT(*)
  FROM indexing.IndexOptimizationResults
  WHERE ResolvedDate IS NULL
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SELECT @@SERVERNAME                                AS ServerName
        ,ISNULL(@DatabaseName, 'ALL')                AS DatabaseName
        ,GETDATE()                                   AS GeneratedDate
        ,(SELECT MAX(ProcessedDate) FROM indexing.IndexOptimizationResults) AS LastAnalysisDate
        ,@Statistics                                 AS [Statistics]
        ,CASE WHEN @RunnableCount > 0
              THEN 'Has Recommendations'
              WHEN @TotalRecs > 0 AND @RunnableCount = 0
              THEN 'Nothing To Run Under Parameter'
              WHEN @TotalRecs = 0 AND @TotalUnfiltered > 0
              THEN 'Nothing To Run Under Parameter'
              ELSE 'No Recommendations'
         END                                         AS [Status]
        ,CASE WHEN @TotalRecs > 0
              THEN @ScriptText
              ELSE NULL
         END                                         AS ScriptText;
END;
GO


-- ==========================================================================
-- KEY LOOKUP ELIMINATION
-- ==========================================================================

-- =========================================================================
-- Table: indexing.KeyLookupResults
-- =========================================================================
IF OBJECT_ID('indexing.KeyLookupResults', 'U') IS NULL
BEGIN
    CREATE TABLE indexing.KeyLookupResults
      (KeyLookupId          INT            IDENTITY(1, 1)
      ,ServerName           NVARCHAR(128)  NOT NULL
      ,DatabaseName         NVARCHAR(128)  NOT NULL
      ,SchemaName           NVARCHAR(128)  NOT NULL
      ,TableName            NVARCHAR(128)  NOT NULL
      ,NCIndexName          NVARCHAR(256)  NOT NULL
      ,NCIndexKeys          NVARCHAR(MAX)  NULL
      ,NCIndexIncludes      NVARCHAR(MAX)  NULL
      ,LookupColumns        NVARCHAR(MAX)  NOT NULL
      ,RecommendedIncludes  NVARCHAR(MAX)  NOT NULL
      ,TotalExecutions      BIGINT         NOT NULL
      ,TotalLogicalReads    BIGINT         NOT NULL
      ,AvgLogicalReads      BIGINT         NULL
      ,PlanCount            INT            NOT NULL
      ,SampleQueryText      NVARCHAR(MAX)  NULL
      ,NCIndexSizeKB        BIGINT         NULL
      ,EstimatedSizeGB      DECIMAL(18,2)  NULL
      ,CreateStatement      NVARCHAR(MAX)  NULL
      ,ProcessedDate        DATETIME2(3)   NOT NULL CONSTRAINT DF_KeyLookupResults_ProcessedDate DEFAULT (SYSDATETIME())
      ,ResolvedDate         DATETIME2(3)   NULL
      ,CONSTRAINT PKC_KeyLookupResults PRIMARY KEY CLUSTERED (KeyLookupId DESC) WITH (FILLFACTOR = 100)
      ) ON [PRIMARY];
END
GO

-- =========================================================================
-- Proc: indexing.sp_KeyLookupAnalysis
-- =========================================================================
CREATE OR ALTER PROCEDURE indexing.sp_KeyLookupAnalysis
  @DatabaseName   NVARCHAR(MAX) = NULL
 ,@MinExecutions  BIGINT        = 100
 ,@TopPlans       INT           = 1000
AS
BEGIN
  SET NOCOUNT ON;

  DELETE FROM indexing.KeyLookupResults WHERE ResolvedDate IS NULL;

  -- Step 1: Collect all cached plans with Key Lookups (server-wide, one pass)
  DROP TABLE IF EXISTS #PlansWithLookups;
  SELECT TOP (@TopPlans)
         qs.plan_handle
        ,qs.sql_handle
        ,qp.query_plan AS plan_xml
        ,qs.execution_count AS total_executions
        ,qs.total_logical_reads
        ,st.text AS query_sql_text
  INTO #PlansWithLookups
  FROM sys.dm_exec_query_stats qs
  CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
  CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
  WHERE qp.query_plan IS NOT NULL
    AND qp.query_plan.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //IndexScan[@Lookup="1"]') = 1
    AND qs.execution_count >= @MinExecutions
  ORDER BY qs.total_logical_reads DESC;

  -- Step 2: Parse XML — extract database, schema, table, index, and lookup columns
  DROP TABLE IF EXISTS #RawLookups;
  ;WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
  SELECT p.plan_handle
        ,p.query_sql_text
        ,p.total_executions
        ,p.total_logical_reads
        ,REPLACE(REPLACE(
           nl.node.value('(RelOp[IndexScan[not(@Lookup="1")]]/IndexScan/Object/@Database)[1]','NVARCHAR(128)')
         , '[', ''), ']', '') AS DatabaseName
        ,REPLACE(REPLACE(
           nl.node.value('(RelOp[IndexScan[not(@Lookup="1")]]/IndexScan/Object/@Index)[1]','NVARCHAR(256)')
         , '[', ''), ']', '') AS NCIndexName
        ,REPLACE(REPLACE(
           nl.node.value('(RelOp[IndexScan[not(@Lookup="1")]]/IndexScan/Object/@Schema)[1]','NVARCHAR(128)')
         , '[', ''), ']', '') AS SchemaName
        ,REPLACE(REPLACE(
           nl.node.value('(RelOp[IndexScan[not(@Lookup="1")]]/IndexScan/Object/@Table)[1]','NVARCHAR(128)')
         , '[', ''), ']', '') AS TableName
        ,kl_col.value('@Column','NVARCHAR(128)') AS LookupColumn
  INTO #RawLookups
  FROM #PlansWithLookups p
  CROSS APPLY p.plan_xml.nodes('//RelOp[@PhysicalOp="Nested Loops"]/NestedLoops') AS nl(node)
  CROSS APPLY nl.node.nodes('RelOp[IndexScan[@Lookup="1"]]/OutputList/ColumnReference') AS kl(kl_col)
  WHERE nl.node.exist('RelOp[IndexScan[@Lookup="1"]]') = 1
    AND nl.node.exist('RelOp[IndexScan[not(@Lookup="1")]]') = 1;

  -- Step 3: Filter to target databases and consolidate
  DROP TABLE IF EXISTS #DBs;
  CREATE TABLE #DBs (DatabaseName NVARCHAR(128));

  IF @DatabaseName IS NULL
  BEGIN
    INSERT INTO #DBs (DatabaseName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.database_id > 4;
  END
  ELSE IF @DatabaseName LIKE '%[%]%'
  BEGIN
    INSERT INTO #DBs (DatabaseName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.name LIKE @DatabaseName;
  END
  ELSE
  BEGIN
    INSERT INTO #DBs (DatabaseName)
    SELECT d.name
    FROM sys.databases d
    INNER JOIN STRING_SPLIT(@DatabaseName, ',') s ON d.name = LTRIM(RTRIM(s.value))
    WHERE d.state_desc = 'ONLINE';
  END;

  INSERT INTO indexing.KeyLookupResults
    (ServerName, DatabaseName, SchemaName, TableName, NCIndexName
    ,LookupColumns, RecommendedIncludes, TotalExecutions, TotalLogicalReads
    ,AvgLogicalReads, PlanCount, SampleQueryText)
  SELECT @@SERVERNAME
        ,rl.DatabaseName
        ,rl.SchemaName
        ,rl.TableName
        ,rl.NCIndexName
        ,STUFF((SELECT DISTINCT ', [' + rl2.LookupColumn + ']'
                FROM #RawLookups rl2
                WHERE rl2.DatabaseName = rl.DatabaseName AND rl2.SchemaName = rl.SchemaName
                  AND rl2.TableName = rl.TableName AND rl2.NCIndexName = rl.NCIndexName
                ORDER BY ', [' + rl2.LookupColumn + ']'
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 2, '')
        ,STUFF((SELECT DISTINCT ', [' + rl2.LookupColumn + ']'
                FROM #RawLookups rl2
                WHERE rl2.DatabaseName = rl.DatabaseName AND rl2.SchemaName = rl.SchemaName
                  AND rl2.TableName = rl.TableName AND rl2.NCIndexName = rl.NCIndexName
                ORDER BY ', [' + rl2.LookupColumn + ']'
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 2, '')
        ,SUM(rl.total_executions)
        ,SUM(rl.total_logical_reads)
        ,CASE WHEN SUM(rl.total_executions) > 0 THEN SUM(rl.total_logical_reads) / SUM(rl.total_executions) ELSE 0 END
        ,COUNT(DISTINCT rl.plan_handle)
        ,(SELECT TOP 1 LEFT(rl3.query_sql_text, 4000) FROM #RawLookups rl3
          WHERE rl3.DatabaseName = rl.DatabaseName AND rl3.SchemaName = rl.SchemaName
            AND rl3.TableName = rl.TableName AND rl3.NCIndexName = rl.NCIndexName
          ORDER BY rl3.total_logical_reads DESC)
  FROM #RawLookups rl
  INNER JOIN #DBs db ON rl.DatabaseName = db.DatabaseName
  WHERE rl.NCIndexName IS NOT NULL
    AND rl.DatabaseName IS NOT NULL
    AND rl.SchemaName <> 'cdc'
  GROUP BY rl.DatabaseName, rl.SchemaName, rl.TableName, rl.NCIndexName;

  DROP TABLE IF EXISTS #PlansWithLookups;
  DROP TABLE IF EXISTS #RawLookups;
  DROP TABLE IF EXISTS #DBs;

  -- Post-processing: look up current index definition, filter already-covered columns, generate CREATE statements
  DECLARE @id            INT
         ,@schema        NVARCHAR(128)
         ,@table         NVARCHAR(128)
         ,@ncIndex       NVARCHAR(256)
         ,@db            NVARCHAR(128)
         ,@ncKeys        NVARCHAR(MAX)
         ,@ncIncludes    NVARCHAR(MAX)
         ,@lookupCols    NVARCHAR(MAX)
         ,@recommended   NVARCHAR(MAX)
         ,@sizeKB        BIGINT
         ,@postSql       NVARCHAR(MAX)
         ,@newIndexName  NVARCHAR(256)
         ,@mergedIncludes NVARCHAR(MAX)
         ,@cleanKeys     NVARCHAR(MAX)
         ,@klEstGB       DECIMAL(18,6)
         ,@klSchemaTable NVARCHAR(256)
         ,@klAvgRow      FLOAT
         ,@klNewDeclared FLOAT
         ,@klPhysSQL     NVARCHAR(MAX);

  DECLARE post_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT KeyLookupId, DatabaseName, SchemaName, TableName, NCIndexName, LookupColumns
    FROM indexing.KeyLookupResults
    WHERE ResolvedDate IS NULL;

  OPEN post_cursor;
  FETCH NEXT FROM post_cursor INTO @id, @db, @schema, @table, @ncIndex, @lookupCols;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @ncKeys = NULL;
    SET @ncIncludes = NULL;
    SET @sizeKB = NULL;

    DROP TABLE IF EXISTS #IdxInfo;
    CREATE TABLE #IdxInfo (IndexKeys NVARCHAR(MAX), IncludedColumns NVARCHAR(MAX), SizeKB BIGINT, IsUnique BIT, HasFilter BIT);

    SET @postSql = N'USE ' + QUOTENAME(@db) + N';
    SELECT
      STUFF((SELECT '', ['' + c.name + '']'' + CASE WHEN ic.is_descending_key = 1 THEN '' DESC'' ELSE '''' END
             FROM sys.index_columns ic
             JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
             WHERE ic.object_id = OBJECT_ID(''' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + N''')
               AND ic.index_id = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID(''' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + N''') AND name = ''' + REPLACE(@ncIndex, '''', '''''') + N''')
               AND ic.is_included_column = 0
             ORDER BY ic.key_ordinal
             FOR XML PATH('''')), 1, 2, '''')
     ,STUFF((SELECT '', ['' + c.name + '']''
             FROM sys.index_columns ic
             JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
             WHERE ic.object_id = OBJECT_ID(''' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + N''')
               AND ic.index_id = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID(''' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + N''') AND name = ''' + REPLACE(@ncIndex, '''', '''''') + N''')
               AND ic.is_included_column = 1
             ORDER BY c.name
             FOR XML PATH('''')), 1, 2, '''')
     ,ISNULL((SELECT SUM(ps.used_page_count) * 8
              FROM sys.indexes i
              JOIN sys.dm_db_partition_stats ps ON i.object_id = ps.object_id AND i.index_id = ps.index_id
              WHERE i.object_id = OBJECT_ID(''' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + N''')
                AND i.name = ''' + REPLACE(@ncIndex, '''', '''''') + N'''), 0)
     ,(SELECT i.is_unique FROM sys.indexes i WHERE i.object_id = OBJECT_ID(''' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + N''') AND i.name = ''' + REPLACE(@ncIndex, '''', '''''') + N''')
     ,(SELECT CASE WHEN i.filter_definition IS NOT NULL THEN 1 ELSE 0 END FROM sys.indexes i WHERE i.object_id = OBJECT_ID(''' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + N''') AND i.name = ''' + REPLACE(@ncIndex, '''', '''''') + N''');';

    DECLARE @isUnique BIT = 0;
    DECLARE @hasFilter BIT = 0;

    BEGIN TRY
      INSERT INTO #IdxInfo EXEC sp_executesql @postSql;

      SELECT @ncKeys = IndexKeys, @ncIncludes = IncludedColumns, @sizeKB = SizeKB
            ,@isUnique = ISNULL(IsUnique, 0), @hasFilter = ISNULL(HasFilter, 0)
      FROM #IdxInfo;
    END TRY
    BEGIN CATCH
      SET @ncKeys = NULL;
    END CATCH;

    -- Skip unique and filtered indexes — cannot be safely modified
    IF @isUnique = 1 OR @hasFilter = 1
    BEGIN
      DELETE FROM indexing.KeyLookupResults WHERE KeyLookupId = @id;
      FETCH NEXT FROM post_cursor INTO @id, @db, @schema, @table, @ncIndex, @lookupCols;
      CONTINUE;
    END;

    -- Skip if index was not found (dropped/renamed since plan was compiled)
    IF @ncKeys IS NULL
    BEGIN
      DELETE FROM indexing.KeyLookupResults WHERE KeyLookupId = @id;
      FETCH NEXT FROM post_cursor INTO @id, @db, @schema, @table, @ncIndex, @lookupCols;
      CONTINUE;
    END;

    -- Filter lookup columns: remove any already in NC keys or includes
    SET @recommended = NULL;
    SELECT @recommended = STUFF((
      SELECT ', ' + LTRIM(RTRIM(col.value))
      FROM STRING_SPLIT(REPLACE(REPLACE(@lookupCols, '[', ''), ']', ''), ',') col
      WHERE LTRIM(RTRIM(col.value)) <> ''
        AND CHARINDEX('[' + LTRIM(RTRIM(col.value)) + ']', ISNULL(@ncKeys, '')) = 0
        AND CHARINDEX('[' + LTRIM(RTRIM(col.value)) + ']', ISNULL(@ncIncludes, '')) = 0
      ORDER BY LTRIM(RTRIM(col.value))
      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

    IF @recommended IS NOT NULL AND @recommended <> ''
    BEGIN
      SET @recommended = REPLACE(REPLACE(@recommended, '[', ''), ']', '');
      SELECT @recommended = STUFF((
        SELECT ', [' + LTRIM(RTRIM(col.value)) + ']'
        FROM STRING_SPLIT(@recommended, ',') col
        WHERE LTRIM(RTRIM(col.value)) <> ''
        ORDER BY LTRIM(RTRIM(col.value))
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

      -- Build merged includes
      SET @mergedIncludes = CASE WHEN ISNULL(@ncIncludes, '') <> '' AND @recommended <> ''
                                 THEN @ncIncludes + ', ' + @recommended
                                 WHEN ISNULL(@ncIncludes, '') <> ''
                                 THEN @ncIncludes
                                 ELSE @recommended
                            END;

      -- Generate proper index name: IX_TableName_Keys[_INCLUDE[S]]
      SET @cleanKeys = REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(@ncKeys, ''), '(-)', ''), '[', ''), ']', ''), ', ', '_');
      SET @newIndexName = 'IX_' + @table + '_' + @cleanKeys
        + CASE WHEN ISNULL(@mergedIncludes, '') = '' THEN ''
               WHEN @mergedIncludes NOT LIKE '%,%' THEN '_INCLUDE'
               ELSE '_INCLUDES'
          END;

      -- Truncate to 128 chars if needed
      IF LEN(@newIndexName) > 128
        SET @newIndexName = LEFT(@newIndexName, 128);

      -- Check for name collision with a different existing index on the same table
      DECLARE @nameExists BIT = 0;
      DECLARE @nameCheckSql NVARCHAR(MAX) = N'USE ' + QUOTENAME(@db) + N';
        SELECT @exists = CASE WHEN EXISTS (
          SELECT 1 FROM sys.indexes
          WHERE object_id = OBJECT_ID(''' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + N''')
            AND name = ''' + REPLACE(@newIndexName, '''', '''''') + N'''
            AND name <> ''' + REPLACE(@ncIndex, '''', '''''') + N'''
        ) THEN 1 ELSE 0 END;';
      BEGIN TRY
        EXEC sp_executesql @nameCheckSql, N'@exists BIT OUTPUT', @exists = @nameExists OUTPUT;
      END TRY
      BEGIN CATCH
        SET @nameExists = 0;
      END CATCH;

      IF @nameExists = 1
        SET @newIndexName = @newIndexName + '_2';

      SET @klEstGB = NULL;

      -- Proportional scaling: use actual avg_record_size from DMV + sampled AVG(DATALENGTH) for new columns
      IF @sizeKB IS NOT NULL AND @sizeKB > 0
      BEGIN
          SET @klAvgRow = NULL;
          SET @klNewDeclared = NULL;
          SET @klSchemaTable = QUOTENAME(@schema) + '.' + QUOTENAME(@table);

          -- Step 1: Get actual avg row size from the existing index
          SET @klPhysSQL = N'USE ' + QUOTENAME(@db) + N';
              DECLARE @ObjId INT = OBJECT_ID(''' + REPLACE(@klSchemaTable, '''', '''''') + N''');
              DECLARE @IdxId INT;
              SELECT @IdxId = i.index_id FROM sys.indexes i
              WHERE i.object_id = @ObjId AND i.name = ''' + REPLACE(@ncIndex, '''', '''''') + N''';

              SELECT TOP 1 @p1 = avg_record_size_in_bytes
              FROM sys.dm_db_index_physical_stats(DB_ID(''' + REPLACE(@db, '''', '''''') + N'''), @ObjId, @IdxId, NULL, ''SAMPLED'')
              WHERE avg_record_size_in_bytes > 0;';

          BEGIN TRY
              EXEC sp_executesql @klPhysSQL,
                  N'@p1 FLOAT OUTPUT',
                  @p1 = @klAvgRow OUTPUT;
          END TRY
          BEGIN CATCH
              SET @klAvgRow = NULL;
          END CATCH

          -- Step 2: Sample AVG(DATALENGTH) for each new column being added
          IF @klAvgRow IS NOT NULL AND @klAvgRow > 0
          BEGIN
              DECLARE @klSampleSQL NVARCHAR(MAX);
              DECLARE @klColName NVARCHAR(128);
              DECLARE @klColList NVARCHAR(MAX);
              DECLARE @klPos INT;
              DECLARE @klTotalNewBytes FLOAT = 0;
              DECLARE @klColAvg FLOAT;

              SET @klColList = REPLACE(REPLACE(@recommended, '[', ''), ']', '');

              WHILE LEN(@klColList) > 0
              BEGIN
                  SET @klPos = CHARINDEX(',', @klColList);
                  IF @klPos = 0
                  BEGIN
                      SET @klColName = LTRIM(RTRIM(@klColList));
                      SET @klColList = '';
                  END
                  ELSE
                  BEGIN
                      SET @klColName = LTRIM(RTRIM(LEFT(@klColList, @klPos - 1)));
                      SET @klColList = SUBSTRING(@klColList, @klPos + 1, LEN(@klColList));
                  END

                  IF @klColName <> ''
                  BEGIN
                      SET @klColAvg = NULL;
                      SET @klSampleSQL = N'USE ' + QUOTENAME(@db) + N';
                          SELECT @out = AVG(CAST(ISNULL(DATALENGTH(' + QUOTENAME(@klColName) + N'), 0) AS FLOAT))
                          FROM (SELECT TOP (10000) ' + QUOTENAME(@klColName) + N'
                                FROM ' + @klSchemaTable + N' WITH (NOLOCK)) x;';

                      BEGIN TRY
                          EXEC sp_executesql @klSampleSQL, N'@out FLOAT OUTPUT', @out = @klColAvg OUTPUT;
                      END TRY
                      BEGIN CATCH
                          SET @klColAvg = NULL;
                      END CATCH

                      SET @klTotalNewBytes = @klTotalNewBytes + ISNULL(@klColAvg, 8);
                  END
              END

              -- new_size = current_size * (avg_row + avg_new_bytes) / avg_row
              SET @klEstGB = @sizeKB / 1024.0 * (@klAvgRow + @klTotalNewBytes) / @klAvgRow / 1024.0;
              IF @klEstGB < @sizeKB / 1024.0 / 1024.0
                  SET @klEstGB = @sizeKB / 1024.0 / 1024.0 * 1.05;
          END
      END

      UPDATE indexing.KeyLookupResults
      SET NCIndexKeys         = @ncKeys
         ,NCIndexIncludes     = @ncIncludes
         ,NCIndexSizeKB       = @sizeKB
         ,RecommendedIncludes = @recommended
         ,EstimatedSizeGB     = @klEstGB
         ,CreateStatement     = CASE
            WHEN @newIndexName = @ncIndex THEN
              'CREATE NONCLUSTERED INDEX [' + @ncIndex + ']'
              + CHAR(13) + CHAR(10) + 'ON [' + @schema + '].[' + @table + '] (' + ISNULL(@ncKeys, '') + ')'
              + CASE WHEN ISNULL(@mergedIncludes, '') <> ''
                     THEN CHAR(13) + CHAR(10) + 'INCLUDE (' + @mergedIncludes + ')'
                     ELSE ''
                END
              + CHAR(13) + CHAR(10) + 'WITH (DROP_EXISTING = ON);'
            ELSE
              '-- Old index: ' + @ncIndex + CHAR(13) + CHAR(10)
              + 'CREATE NONCLUSTERED INDEX [' + @newIndexName + ']'
              + CHAR(13) + CHAR(10) + 'ON [' + @schema + '].[' + @table + '] (' + ISNULL(@ncKeys, '') + ')'
              + CASE WHEN ISNULL(@mergedIncludes, '') <> ''
                     THEN CHAR(13) + CHAR(10) + 'INCLUDE (' + @mergedIncludes + ')'
                     ELSE ''
                END + ';'
              + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
              + 'DROP INDEX IF EXISTS [' + @ncIndex + '] ON [' + @schema + '].[' + @table + '];'
            END
      WHERE KeyLookupId = @id;
    END
    ELSE
    BEGIN
      DELETE FROM indexing.KeyLookupResults WHERE KeyLookupId = @id;
    END;

    FETCH NEXT FROM post_cursor INTO @id, @db, @schema, @table, @ncIndex, @lookupCols;
  END;

  CLOSE post_cursor;
  DEALLOCATE post_cursor;

END;
GO

-- =========================================================================
-- Proc: indexing.sp_KeyLookupRecommendations
-- =========================================================================
CREATE OR ALTER PROCEDURE indexing.sp_KeyLookupRecommendations
  @DatabaseName   NVARCHAR(MAX) = NULL
 ,@TableName      NVARCHAR(128) = NULL
 ,@RunnableUnder  VARCHAR(20)   = NULL  -- NULL=all uncommented, '2'=2GB both, '1,5e'=1GB Std/5GB Ent
 ,@RunAnalysis    BIT           = 0
 ,@MinExecutions  BIGINT        = 10
AS
BEGIN
  SET NOCOUNT ON;

  IF @RunAnalysis = 1
    EXEC indexing.sp_KeyLookupAnalysis
        @DatabaseName  = @DatabaseName
       ,@MinExecutions = @MinExecutions;

  DECLARE @ScriptText  NVARCHAR(MAX) = '';
  DECLARE @CRLF        CHAR(2)       = CHAR(13) + CHAR(10);
  DECLARE @Separator    VARCHAR(60)  = '/*****************************************************/';

  -- Parse @RunnableUnder: NULL=off, '2'=2GB both, '1,5e'=1GB Standard/5GB Enterprise
  DECLARE @ThresholdStd DECIMAL(10,2) = NULL;
  DECLARE @ThresholdEnt DECIMAL(10,2) = NULL;
  DECLARE @ActiveThreshold DECIMAL(10,2) = NULL;

  IF @RunnableUnder IS NOT NULL AND LTRIM(RTRIM(@RunnableUnder)) <> ''
  BEGIN
      IF @RunnableUnder LIKE '%,%e'
      BEGIN
          SET @ThresholdStd = TRY_CAST(LEFT(@RunnableUnder, CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
          SET @ThresholdEnt = TRY_CAST(SUBSTRING(@RunnableUnder, CHARINDEX(',', @RunnableUnder) + 1,
              LEN(@RunnableUnder) - CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
      END
      ELSE
      BEGIN
          SET @ThresholdStd = TRY_CAST(@RunnableUnder AS DECIMAL(10,2));
          SET @ThresholdEnt = @ThresholdStd;
      END
  END

  DECLARE @TotalRecs     INT = 0;
  DECLARE @TotalDatabases INT = 0;
  DECLARE @TotalTables    INT = 0;

  SELECT @TotalRecs      = COUNT(*)
        ,@TotalDatabases  = COUNT(DISTINCT DatabaseName)
        ,@TotalTables     = COUNT(DISTINCT DatabaseName + '.' + SchemaName + '.' + TableName)
  FROM indexing.KeyLookupResults
  WHERE ResolvedDate IS NULL
    AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
    AND (@TableName    IS NULL OR TableName    = @TableName)
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SET @ScriptText =
    '/*' + @CRLF
    + '==============================================================================' + @CRLF
    + '  KEY LOOKUP ELIMINATION RECOMMENDATIONS' + @CRLF
    + '  Server: ' + @@SERVERNAME + @CRLF
    + '  Generated: ' + CONVERT(VARCHAR(30), GETDATE(), 120) + @CRLF
    + '==============================================================================' + @CRLF
    + 'Statistics:' + @CRLF
    + '    Databases:         ' + FORMAT(@TotalDatabases, 'N0') + @CRLF
    + '    Tables:            ' + FORMAT(@TotalTables, 'N0') + @CRLF
    + '    Recommendations:   ' + FORMAT(@TotalRecs, 'N0') + @CRLF
    + @CRLF
    + 'Filters:' + @CRLF
    + '    @DatabaseName   = ' + ISNULL('''' + @DatabaseName + '''', 'ALL') + @CRLF
    + '    @TableName      = ' + ISNULL('''' + @TableName + '''', 'ALL') + @CRLF
    + '    @RunnableUnder  = ' + ISNULL('''' + @RunnableUnder + '''', 'NULL (all uncommented)') + @CRLF
    + '    @MinExecutions  = ' + CAST(@MinExecutions AS VARCHAR(20)) + @CRLF
    + '*/' + @CRLF;

  IF @ActiveThreshold IS NOT NULL
    SET @ScriptText = @ScriptText
      + '-- @RunnableUnder = ' + @RunnableUnder
      + CASE WHEN @ThresholdStd <> @ThresholdEnt
          THEN ' (Standard: ' + CAST(@ThresholdStd AS VARCHAR(10)) + ' GB, Enterprise: ' + CAST(@ThresholdEnt AS VARCHAR(10)) + ' GB)'
          ELSE ' (' + CAST(@ActiveThreshold AS VARCHAR(10)) + ' GB)'
        END
      + ', indexes >= threshold commented out' + @CRLF;

  DECLARE @CurrentDB     NVARCHAR(128) = '';
  DECLARE @CurrentTable  NVARCHAR(400) = '';
  DECLARE @IsFirstDB     BIT = 1;

  DECLARE @Id              INT;
  DECLARE @DB              NVARCHAR(128);
  DECLARE @Schema          NVARCHAR(128);
  DECLARE @Table           NVARCHAR(128);
  DECLARE @NCIndex         NVARCHAR(256);
  DECLARE @NCKeys          NVARCHAR(MAX);
  DECLARE @NCIncludes      NVARCHAR(MAX);
  DECLARE @LookupCols      NVARCHAR(MAX);
  DECLARE @Recommended     NVARCHAR(MAX);
  DECLARE @TotalExec       BIGINT;
  DECLARE @TotalReads      BIGINT;
  DECLARE @AvgReads        BIGINT;
  DECLARE @Plans           INT;
  DECLARE @SizeKB          BIGINT;
  DECLARE @EstSizeGB       DECIMAL(18,2);
  DECLARE @CreateStmt      NVARCHAR(MAX);
  DECLARE @SampleQuery     NVARCHAR(MAX);
  DECLARE @IsEnterprise    BIT = 0;
  DECLARE @ShouldComment   BIT;
  DECLARE @RunnableCount   INT = 0;

  IF CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Enterprise%'
    OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Developer%'
    SET @IsEnterprise = 1;

  SET @ActiveThreshold = CASE WHEN @IsEnterprise = 1 THEN @ThresholdEnt ELSE @ThresholdStd END;

  DECLARE rec_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT KeyLookupId, DatabaseName, SchemaName, TableName
          ,NCIndexName, NCIndexKeys, NCIndexIncludes
          ,LookupColumns, RecommendedIncludes
          ,TotalExecutions, TotalLogicalReads, AvgLogicalReads
          ,PlanCount, NCIndexSizeKB, EstimatedSizeGB, CreateStatement, SampleQueryText
    FROM indexing.KeyLookupResults
    WHERE ResolvedDate IS NULL
      AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
      AND (@TableName    IS NULL OR TableName    = @TableName)
      AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName)
    ORDER BY DatabaseName, TableName, TotalLogicalReads DESC;

  OPEN rec_cursor;
  FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table
    ,@NCIndex, @NCKeys, @NCIncludes
    ,@LookupCols, @Recommended
    ,@TotalExec, @TotalReads, @AvgReads
    ,@Plans, @SizeKB, @EstSizeGB, @CreateStmt, @SampleQuery;

  WHILE @@FETCH_STATUS = 0
  BEGIN

    IF @DB <> @CurrentDB
    BEGIN
      IF @IsFirstDB = 0
        SET @ScriptText = @ScriptText + @CRLF;

      SET @CurrentDB    = @DB;
      SET @CurrentTable = '';
      SET @IsFirstDB    = 0;

      SET @ScriptText = @ScriptText
        + '-- ============================================================================' + @CRLF
        + '-- Database: ' + @DB + @CRLF
        + '-- ============================================================================' + @CRLF
        + 'USE ' + QUOTENAME(@DB) + @CRLF
        + 'GO' + @CRLF;
    END;

    DECLARE @TableKey NVARCHAR(400) = @DB + '.' + @Schema + '.' + @Table;
    IF @TableKey <> @CurrentTable
    BEGIN
      SET @CurrentTable = @TableKey;
      SET @ScriptText = @ScriptText
        + @CRLF
        + @Separator + @CRLF
        + '-- Table: ' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + @CRLF
        + @Separator + @CRLF;
    END;

    SET @ScriptText = @ScriptText + @CRLF
      + '-- KEY LOOKUP ELIMINATION' + @CRLF
      + '--   Index: ' + @NCIndex + @CRLF
      + '--     Key Columns:         ' + ISNULL(@NCKeys, '?') + @CRLF
      + '--     Current Includes:    ' + ISNULL(NULLIF(@NCIncludes, ''), '(none)') + @CRLF
      + '--     Size: ' + ISNULL(FORMAT(CAST(@SizeKB / 1024.0 AS DECIMAL(10,1)), 'N1'), '?') + ' MB' + @CRLF
      + '--   Add Includes:          ' + @Recommended + @CRLF
      + CASE WHEN @EstSizeGB IS NOT NULL THEN '--   Estimated New Size: ~' + FORMAT(@EstSizeGB * 1024, 'N1') + ' MB' + @CRLF ELSE '' END
      + '--   Impact: ' + FORMAT(@TotalReads, 'N0') + ' total reads'
      + '  |  ' + FORMAT(@TotalExec, 'N0') + ' executions'
      + '  |  ' + FORMAT(@AvgReads, 'N0') + ' avg reads/exec'
      + '  |  ' + FORMAT(@Plans, 'N0') + ' plan(s)' + @CRLF;

    SET @ScriptText = @ScriptText
      + '-- EXEC sp_helpIndexUsage ''' + @Schema + '.' + @Table + ''';' + @CRLF + @CRLF;

    SET @ShouldComment = CASE WHEN @ActiveThreshold IS NOT NULL
        AND (ISNULL(@EstSizeGB, 0) >= @ActiveThreshold OR (ISNULL(@SizeKB, 0) >= CAST(@ActiveThreshold * 1048576 AS BIGINT)))
        THEN 1 ELSE 0 END;

    IF @ShouldComment = 1
      SET @ScriptText = @ScriptText + '/*' + @CRLF;

    IF @CreateStmt IS NOT NULL
    BEGIN
      IF @IsEnterprise = 1
        SET @ScriptText = @ScriptText
          + REPLACE(REPLACE(@CreateStmt
            , 'WITH (DROP_EXISTING = ON);', 'WITH (DROP_EXISTING = ON, ONLINE = ON);')
            , ');' + @CRLF + @CRLF + 'DROP INDEX', ') WITH (ONLINE = ON);' + @CRLF + @CRLF + 'DROP INDEX')
          + @CRLF;
      ELSE
        SET @ScriptText = @ScriptText + @CreateStmt + @CRLF;
    END;

    SET @ScriptText = @ScriptText
      + @CRLF + 'UPDATE DBA_Utilities.indexing.KeyLookupResults SET ResolvedDate = GETDATE() WHERE KeyLookupId = ' + CAST(@Id AS VARCHAR(10)) + ';' + @CRLF;

    IF @ShouldComment = 1
      SET @ScriptText = @ScriptText + '*/' + @CRLF;
    ELSE
      SET @RunnableCount = @RunnableCount + 1;

    FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table
      ,@NCIndex, @NCKeys, @NCIncludes
      ,@LookupCols, @Recommended
      ,@TotalExec, @TotalReads, @AvgReads
      ,@Plans, @SizeKB, @EstSizeGB, @CreateStmt, @SampleQuery;
  END;

  CLOSE rec_cursor;
  DEALLOCATE rec_cursor;

  DECLARE @TotalUnfiltered INT;
  SELECT @TotalUnfiltered = COUNT(*)
  FROM indexing.KeyLookupResults
  WHERE ResolvedDate IS NULL
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SELECT @@SERVERNAME                                AS ServerName
        ,ISNULL(@DatabaseName, 'ALL')                AS DatabaseName
        ,GETDATE()                                   AS GeneratedDate
        ,FORMAT(@TotalRecs, 'N0') + ' recommendations, '
         + FORMAT(ISNULL((SELECT SUM(TotalLogicalReads) FROM indexing.KeyLookupResults
                          WHERE ResolvedDate IS NULL
                            AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
                            AND (@TableName IS NULL OR TableName = @TableName)), 0), 'N0')
         + ' total lookup reads'                     AS [Statistics]
        ,CASE WHEN @RunnableCount > 0
              THEN 'Has Recommendations'
              WHEN @TotalRecs > 0 AND @RunnableCount = 0
              THEN 'Nothing To Run Under Parameter'
              WHEN @TotalRecs = 0 AND @TotalUnfiltered > 0
              THEN 'Nothing To Run Under Parameter'
              ELSE 'No Recommendations'
         END                                         AS [Status]
        ,CASE WHEN @TotalRecs > 0
              THEN @ScriptText
              ELSE NULL
         END                                         AS ScriptText;
END;
GO


-- ==========================================================================
-- UNUSED INDEX DETECTION
-- ==========================================================================

-- =========================================================================
-- Table: indexing.UnusedIndexResults
-- =========================================================================
IF OBJECT_ID('indexing.UnusedIndexResults', 'U') IS NULL
BEGIN
    CREATE TABLE indexing.UnusedIndexResults
      (UnusedIndexId        INT            IDENTITY(1, 1)
      ,ServerName           NVARCHAR(128)  NOT NULL
      ,DatabaseName         NVARCHAR(128)  NOT NULL
      ,SchemaName           NVARCHAR(128)  NOT NULL
      ,TableName            NVARCHAR(128)  NOT NULL
      ,IndexName            NVARCHAR(256)  NOT NULL
      ,IndexKeys            NVARCHAR(MAX)  NULL
      ,IndexIncludes        NVARCHAR(MAX)  NULL
      ,IndexSizeKB          BIGINT         NULL
      ,IndexType            NVARCHAR(60)   NULL
      ,IsUnique             BIT            NULL
      ,HasFilter            BIT            NULL
      ,FilterDefinition     NVARCHAR(MAX)  NULL
      ,UserSeeks            BIGINT         NULL
      ,UserScans            BIGINT         NULL
      ,UserLookups          BIGINT         NULL
      ,UserUpdates          BIGINT         NULL
      ,DMVStatsResetDate    DATETIME       NULL
      ,QueryStoreDays       INT            NULL
      ,QueryStorePlanCount  INT            NULL
      ,ObservationSource    VARCHAR(20)    NOT NULL
      ,ObservationDays      INT            NULL
      ,Confidence           VARCHAR(10)    NULL
      ,DropStatement        NVARCHAR(MAX)  NULL
      ,RecreateStatement    NVARCHAR(MAX)  NULL
      ,ProcessedDate        DATETIME2(3)   NOT NULL CONSTRAINT DF_UnusedIndexResults_ProcessedDate DEFAULT (SYSDATETIME())
      ,ResolvedDate         DATETIME2(3)   NULL
      ,CONSTRAINT PKC_UnusedIndexResults PRIMARY KEY CLUSTERED (UnusedIndexId DESC) WITH (FILLFACTOR = 100)
      ) ON [PRIMARY];
END
GO

-- =========================================================================
-- Proc: indexing.sp_UnusedIndexAnalysis
-- =========================================================================
CREATE OR ALTER PROCEDURE indexing.sp_UnusedIndexAnalysis
  @DatabaseName       NVARCHAR(MAX)  = NULL
 ,@WithQueryStore     BIT            = 0
 ,@Action             VARCHAR(10)    = 'DISABLE'
AS
BEGIN
  SET NOCOUNT ON;

  SET @Action = UPPER(@Action);
  IF @Action NOT IN ('DISABLE', 'DROP')
    SET @Action = 'DISABLE';

  DELETE FROM indexing.UnusedIndexResults WHERE ResolvedDate IS NULL;

  DROP TABLE IF EXISTS #DBs;
  CREATE TABLE #DBs (DatabaseName NVARCHAR(128), rn INT);

  IF @DatabaseName IS NULL
  BEGIN
    INSERT INTO #DBs (DatabaseName, rn)
    SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.database_id > 4;
  END
  ELSE IF @DatabaseName LIKE '%[%]%'
  BEGIN
    INSERT INTO #DBs (DatabaseName, rn)
    SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.name LIKE @DatabaseName;
  END
  ELSE
  BEGIN
    INSERT INTO #DBs (DatabaseName, rn)
    SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
    FROM sys.databases d
    INNER JOIN STRING_SPLIT(@DatabaseName, ',') s ON d.name = LTRIM(RTRIM(s.value))
    WHERE d.state_desc = 'ONLINE';
  END;

  DECLARE @ServerStartTime DATETIME;
  SELECT @ServerStartTime = sqlserver_start_time FROM sys.dm_os_sys_info;

  DECLARE @DMVDays INT = DATEDIFF(DAY, @ServerStartTime, GETDATE());

  DECLARE @i      INT;
  DECLARE @db     NVARCHAR(128);
  DECLARE @sql    NVARCHAR(MAX);

  SELECT @i = MAX(rn) FROM #DBs;

  WHILE @i > 0
  BEGIN
    SELECT @db = DatabaseName FROM #DBs WHERE rn = @i;

    IF OBJECT_ID('tempdb..#QSPlanText') IS NOT NULL DROP TABLE #QSPlanText;
    IF OBJECT_ID('tempdb..#UnusedWork') IS NOT NULL DROP TABLE #UnusedWork;

    SET @sql = N'USE ' + QUOTENAME(@db) + N';

    -- Query Store availability
    DECLARE @qsDays     INT = NULL;
    DECLARE @qsEnabled  BIT = 0;

    SELECT @qsEnabled = CASE WHEN actual_state IN (1, 2) THEN 1 ELSE 0 END
          ,@qsDays    = CASE WHEN actual_state IN (1, 2) THEN stale_query_threshold_days END
    FROM sys.database_query_store_options;

    -- Phase 1: collect all unused nonclustered indexes
    CREATE TABLE #UnusedWork
      (RowId           INT IDENTITY(1,1)
      ,ObjectId        INT
      ,IndexId         INT
      ,SchemaName      NVARCHAR(128)
      ,TableName       NVARCHAR(128)
      ,IndexName       NVARCHAR(256)
      ,IndexKeys       NVARCHAR(MAX)
      ,IndexIncludes   NVARCHAR(MAX)
      ,IndexSizeKB     BIGINT
      ,IndexType       NVARCHAR(60)
      ,IsUnique        BIT
      ,HasFilter       BIT
      ,FilterDef       NVARCHAR(MAX)
      ,IdxFillFactor   INT
      ,UserSeeks       BIGINT
      ,UserScans       BIGINT
      ,UserLookups     BIGINT
      ,UserUpdates     BIGINT
      ,QSPlanCount     INT);

    INSERT INTO #UnusedWork
      (ObjectId, IndexId, SchemaName, TableName, IndexName
      ,IndexKeys, IndexIncludes, IndexSizeKB, IndexType
      ,IsUnique, HasFilter, FilterDef, IdxFillFactor
      ,UserSeeks, UserScans, UserLookups, UserUpdates)
    SELECT
       i.object_id
      ,i.index_id
      ,s.name
      ,o.name
      ,i.name
      ,STUFF((SELECT '', ['' + c.name + '']'' + CASE WHEN ic2.is_descending_key = 1 THEN '' DESC'' ELSE '''' END
              FROM sys.index_columns ic2
              JOIN sys.columns c ON ic2.object_id = c.object_id AND ic2.column_id = c.column_id
              WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id AND ic2.is_included_column = 0
              ORDER BY ic2.key_ordinal
              FOR XML PATH('''')), 1, 2, '''')
      ,STUFF((SELECT '', ['' + c.name + '']''
              FROM sys.index_columns ic2
              JOIN sys.columns c ON ic2.object_id = c.object_id AND ic2.column_id = c.column_id
              WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id AND ic2.is_included_column = 1
              ORDER BY c.name
              FOR XML PATH('''')), 1, 2, '''')
      ,ISNULL((SELECT SUM(ps.used_page_count) * 8
               FROM sys.dm_db_partition_stats ps
               WHERE ps.object_id = i.object_id AND ps.index_id = i.index_id), 0)
      ,i.type_desc
      ,i.is_unique
      ,CASE WHEN i.filter_definition IS NOT NULL THEN 1 ELSE 0 END
      ,i.filter_definition
      ,i.fill_factor
      ,ISNULL(us.user_seeks, 0)
      ,ISNULL(us.user_scans, 0)
      ,ISNULL(us.user_lookups, 0)
      ,ISNULL(us.user_updates, 0)
    FROM sys.indexes i
    INNER JOIN sys.objects o ON i.object_id = o.object_id
    INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
    LEFT JOIN sys.dm_db_index_usage_stats us
      ON i.object_id = us.object_id
      AND i.index_id = us.index_id
      AND us.database_id = DB_ID()
    WHERE i.type IN (2, 6, 7)
      AND i.is_primary_key = 0
      AND i.is_unique_constraint = 0
      AND i.is_unique = 0
      AND i.filter_definition IS NULL
      AND i.is_hypothetical = 0
      AND i.is_disabled = 0
      AND o.is_ms_shipped = 0
      AND o.type = ''U''
      AND s.name <> ''cdc''
      AND o.name NOT LIKE ''zds%''
      AND o.name NOT LIKE ''ds%''
      AND ISNULL(us.user_seeks, 0) = 0
      AND ISNULL(us.user_scans, 0) = 0
      AND ISNULL(us.user_lookups, 0) = 0
      AND ISNULL(us.user_updates, 0) > 0;

    -- Phase 2: Query Store confirmation (only if enabled with >= 30 days retention and not bypassed)
    IF @pWithQS = 1 AND @qsEnabled = 1 AND @qsDays >= 30
    BEGIN
      -- Cast all plan XML once into a temp table
      CREATE TABLE #QSPlanText (plan_id BIGINT, plan_text NVARCHAR(MAX));
      BEGIN TRY
        INSERT INTO #QSPlanText (plan_id, plan_text)
        SELECT plan_id, CAST(query_plan AS NVARCHAR(MAX))
        FROM sys.query_store_plan
        WHERE is_natively_compiled = 0;
      END TRY
      BEGIN CATCH
        PRINT ''  QS plan cast error: '' + ERROR_MESSAGE();
      END CATCH;

      -- Update each unused index with its QS plan count
      UPDATE w
      SET w.QSPlanCount = ISNULL(qs.cnt, 0)
      FROM #UnusedWork w
      OUTER APPLY (
        SELECT COUNT(DISTINCT p.plan_id) AS cnt
        FROM #QSPlanText p
        WHERE CHARINDEX(''['' + w.IndexName + '']'', p.plan_text) > 0
      ) qs;

    END;

    -- Phase 3: insert into results with computed confidence
    INSERT INTO DBA_Utilities.indexing.UnusedIndexResults
      (ServerName, DatabaseName, SchemaName, TableName, IndexName
      ,IndexKeys, IndexIncludes, IndexSizeKB, IndexType
      ,IsUnique, HasFilter, FilterDefinition
      ,UserSeeks, UserScans, UserLookups, UserUpdates
      ,DMVStatsResetDate, QueryStoreDays, QueryStorePlanCount
      ,ObservationSource, ObservationDays, Confidence
      ,DropStatement, RecreateStatement)
    SELECT
       @@SERVERNAME
      ,DB_NAME()
      ,w.SchemaName
      ,w.TableName
      ,w.IndexName
      ,w.IndexKeys
      ,w.IndexIncludes
      ,w.IndexSizeKB
      ,w.IndexType
      ,w.IsUnique
      ,w.HasFilter
      ,w.FilterDef
      ,w.UserSeeks
      ,w.UserScans
      ,w.UserLookups
      ,w.UserUpdates
      ,@pStartTime
      ,@qsDays
      ,w.QSPlanCount
      ,CASE
        WHEN @pWithQS = 1 AND @qsEnabled = 1 AND @qsDays >= 30 AND w.QSPlanCount IS NOT NULL THEN
          CASE WHEN @pDMVDays >= 7 THEN ''BOTH'' ELSE ''QUERY_STORE'' END
        ELSE ''DMV_ONLY''
       END
      ,CASE
        WHEN @pWithQS = 1 AND @qsEnabled = 1 AND @qsDays >= 30 AND w.QSPlanCount IS NOT NULL THEN
          CASE WHEN @qsDays > @pDMVDays THEN @qsDays ELSE @pDMVDays END
        ELSE @pDMVDays
       END
      ,CASE
        WHEN @pWithQS = 1 AND @qsEnabled = 1 AND @qsDays >= 30 AND w.QSPlanCount IS NOT NULL AND w.QSPlanCount = 0 THEN ''HIGH''
        WHEN (@pWithQS = 0 OR @qsEnabled = 0) AND @pDMVDays >= 30 THEN ''HIGH''
        WHEN (@pWithQS = 0 OR @qsEnabled = 0) AND @pDMVDays >= 14 THEN ''MEDIUM''
        WHEN (@pWithQS = 0 OR @qsEnabled = 0) AND @pDMVDays < 14 THEN ''LOW''
        WHEN @pWithQS = 1 AND @qsEnabled = 1 AND @qsDays >= 30 AND w.QSPlanCount > 0 THEN ''LOW''
        ELSE ''LOW''
       END
      ,CASE WHEN @pAction = ''DROP''
            THEN ''DROP INDEX IF EXISTS '' + QUOTENAME(w.IndexName) + '' ON '' + QUOTENAME(w.SchemaName) + ''.'' + QUOTENAME(w.TableName) + '';''
            ELSE ''ALTER INDEX '' + QUOTENAME(w.IndexName) + '' ON '' + QUOTENAME(w.SchemaName) + ''.'' + QUOTENAME(w.TableName) + '' DISABLE;''
       END
      ,''CREATE NONCLUSTERED INDEX '' + QUOTENAME(w.IndexName)
        + CHAR(13) + CHAR(10) + ''ON '' + QUOTENAME(w.SchemaName) + ''.'' + QUOTENAME(w.TableName) + '' ('' + ISNULL(w.IndexKeys, '''') + '')''
        + CASE WHEN w.IndexIncludes IS NOT NULL
               THEN CHAR(13) + CHAR(10) + ''INCLUDE ('' + w.IndexIncludes + '')''
               ELSE ''''
          END
        + CASE WHEN w.HasFilter = 1 AND w.FilterDef IS NOT NULL
               THEN CHAR(13) + CHAR(10) + ''WHERE '' + w.FilterDef
               ELSE ''''
          END
        + CASE WHEN w.IdxFillFactor > 0 AND w.IdxFillFactor < 100
               THEN CHAR(13) + CHAR(10) + ''WITH (FILLFACTOR = '' + CAST(w.IdxFillFactor AS VARCHAR(3)) + '')''
               ELSE ''''
          END + '';''
    FROM #UnusedWork w;

    ';

    BEGIN TRY
      EXEC sp_executesql @sql
        ,N'@pStartTime DATETIME, @pDMVDays INT, @pWithQS BIT, @pAction VARCHAR(10)'
        ,@pStartTime = @ServerStartTime
        ,@pDMVDays   = @DMVDays
        ,@pWithQS    = @WithQueryStore
        ,@pAction    = @Action;
    END TRY
    BEGIN CATCH
      PRINT 'Error processing ' + @db + ': ' + ERROR_MESSAGE();
    END CATCH;

    SET @i = @i - 1;
  END;

  DROP TABLE IF EXISTS #DBs;
END;
GO

-- =========================================================================
-- Proc: indexing.sp_UnusedIndexRecommendations
-- =========================================================================
CREATE OR ALTER PROCEDURE indexing.sp_UnusedIndexRecommendations
  @DatabaseName    NVARCHAR(MAX)  = NULL
 ,@TableName       NVARCHAR(128)  = NULL
 ,@RunAnalysis       BIT            = 0
 ,@MinUpdateCount    BIGINT         = 100
 ,@MinObservDays     INT            = 7
 ,@WithQueryStore    BIT            = 0
 ,@Action            VARCHAR(10)    = 'DISABLE'
 ,@Confidence        VARCHAR(10)    = 'HIGH'
AS
BEGIN
  SET NOCOUNT ON;

  SET @Action = UPPER(@Action);
  IF @Action NOT IN ('DISABLE', 'DROP')
    SET @Action = 'DISABLE';

  SET @Confidence = UPPER(@Confidence);
  IF @Confidence NOT IN ('HIGH', 'MEDIUM', 'LOW')
    SET @Confidence = 'HIGH';

  DECLARE @ConfidenceRank INT = CASE @Confidence WHEN 'LOW' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'HIGH' THEN 3 END;

  IF @RunAnalysis = 1
    EXEC indexing.sp_UnusedIndexAnalysis
        @DatabaseName     = @DatabaseName
       ,@WithQueryStore   = @WithQueryStore
       ,@Action           = @Action;

  DECLARE @ScriptText  NVARCHAR(MAX) = '';
  DECLARE @CRLF        CHAR(2)       = CHAR(13) + CHAR(10);
  DECLARE @Separator   VARCHAR(60)   = '/*****************************************************/';

  DECLARE @TotalRecs      INT = 0;
  DECLARE @TotalDatabases  INT = 0;
  DECLARE @TotalTables     INT = 0;
  DECLARE @TotalSizeKB     BIGINT = 0;
  DECLARE @ActiveRecs      INT = 0;
  DECLARE @CommentedRecs   INT = 0;

  SELECT @TotalRecs      = COUNT(*)
        ,@TotalDatabases  = COUNT(DISTINCT DatabaseName)
        ,@TotalTables     = COUNT(DISTINCT DatabaseName + '.' + SchemaName + '.' + TableName)
        ,@TotalSizeKB     = ISNULL(SUM(IndexSizeKB), 0)
  FROM indexing.UnusedIndexResults
  WHERE ResolvedDate IS NULL
    AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
    AND (@TableName    IS NULL OR TableName    = @TableName)
    AND UserUpdates   >= @MinUpdateCount
    AND ObservationDays >= @MinObservDays
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  DECLARE @ServerStartTime DATETIME;
  SELECT @ServerStartTime = sqlserver_start_time FROM sys.dm_os_sys_info;
  DECLARE @DMVDays INT = DATEDIFF(DAY, @ServerStartTime, GETDATE());

  SET @ScriptText =
    '/*' + @CRLF
    + '==============================================================================' + @CRLF
    + '  UNUSED INDEX DETECTION RECOMMENDATIONS' + @CRLF
    + '  Server: ' + @@SERVERNAME + @CRLF
    + '  Generated: ' + CONVERT(VARCHAR(30), GETDATE(), 120) + @CRLF
    + '  Server Uptime: ' + CAST(@DMVDays AS VARCHAR(10)) + ' days (DMV stats since ' + CONVERT(VARCHAR(30), @ServerStartTime, 120) + ')' + @CRLF
    + '==============================================================================' + @CRLF
    + 'Statistics:' + @CRLF
    + '    Databases:         ' + CAST(@TotalDatabases AS VARCHAR(10)) + @CRLF
    + '    Tables:            ' + CAST(@TotalTables AS VARCHAR(10)) + @CRLF
    + '    Unused Indexes:    ' + CAST(@TotalRecs AS VARCHAR(10)) + @CRLF
    + '    Total Size:        ' + FORMAT(CAST(@TotalSizeKB / 1024.0 AS DECIMAL(10,1)), 'N1') + ' MB (' + FORMAT(@TotalSizeKB / 1048576.0, 'N2') + ' GB)' + @CRLF
    + @CRLF
    + 'Filters:' + @CRLF
    + '    @DatabaseName    = ' + ISNULL('''' + @DatabaseName + '''', 'ALL') + @CRLF
    + '    @TableName       = ' + ISNULL('''' + @TableName + '''', 'ALL') + @CRLF
    + '    @MinUpdateCount  = ' + CAST(@MinUpdateCount AS VARCHAR(20)) + @CRLF
    + '    @MinObservDays   = ' + CAST(@MinObservDays AS VARCHAR(10)) + @CRLF
    + '    @Confidence      = ' + @Confidence + ' (indexes below this level are commented out)' + @CRLF
    + @CRLF
    + 'Confidence Levels:' + @CRLF
    + '    HIGH   = QS confirms zero plan references (30+ days), or DMV-only with uptime >= 30 days' + @CRLF
    + '    MEDIUM = DMV-only, server uptime 14-29 days' + @CRLF
    + '    LOW    = DMV-only, server uptime < 14 days, or QS found plan references' + @CRLF
    + @CRLF
    + CASE WHEN @Action = 'DISABLE'
           THEN 'NOTE: Indexes are DISABLED, not dropped. A disabled index remains in metadata' + @CRLF
              + 'and can be re-enabled with ALTER INDEX ... REBUILD.'
           ELSE 'WARNING: Indexes are DROPPED. This cannot be undone. The RecreateStatement' + @CRLF
              + 'for each index is included as a comment for rollback.'
      END + @CRLF
    + 'Action: ' + @Action + @CRLF
    + '*/' + @CRLF;

  DECLARE @CurrentDB     NVARCHAR(128) = '';
  DECLARE @CurrentTable  NVARCHAR(400) = '';
  DECLARE @IsFirstDB     BIT = 1;

  DECLARE @Id              INT;
  DECLARE @DB              NVARCHAR(128);
  DECLARE @Schema          NVARCHAR(128);
  DECLARE @Table           NVARCHAR(128);
  DECLARE @IdxName         NVARCHAR(256);
  DECLARE @IdxKeys         NVARCHAR(MAX);
  DECLARE @IdxIncludes     NVARCHAR(MAX);
  DECLARE @SizeKB          BIGINT;
  DECLARE @IdxType         NVARCHAR(60);
  DECLARE @IsUnique        BIT;
  DECLARE @HasFilter       BIT;
  DECLARE @FilterDef       NVARCHAR(MAX);
  DECLARE @UserUpdates     BIGINT;
  DECLARE @QSDays          INT;
  DECLARE @QSPlanCount     INT;
  DECLARE @ObsSource       VARCHAR(20);
  DECLARE @ObsDays         INT;
  DECLARE @RowConfidence   VARCHAR(10);
  DECLARE @RowConfRank     INT;
  DECLARE @DropStmt        NVARCHAR(MAX);
  DECLARE @RecreateStmt    NVARCHAR(MAX);

  DECLARE rec_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT UnusedIndexId, DatabaseName, SchemaName, TableName
          ,IndexName, IndexKeys, IndexIncludes, IndexSizeKB
          ,IndexType, IsUnique, HasFilter, FilterDefinition
          ,UserUpdates, QueryStoreDays, QueryStorePlanCount
          ,ObservationSource, ObservationDays, Confidence
          ,DropStatement, RecreateStatement
    FROM indexing.UnusedIndexResults
    WHERE ResolvedDate IS NULL
      AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
      AND (@TableName    IS NULL OR TableName    = @TableName)
      AND UserUpdates   >= @MinUpdateCount
      AND ObservationDays >= @MinObservDays
      AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName)
    ORDER BY DatabaseName, TableName, IndexSizeKB DESC;

  OPEN rec_cursor;
  FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table
    ,@IdxName, @IdxKeys, @IdxIncludes, @SizeKB
    ,@IdxType, @IsUnique, @HasFilter, @FilterDef
    ,@UserUpdates, @QSDays, @QSPlanCount
    ,@ObsSource, @ObsDays, @RowConfidence
    ,@DropStmt, @RecreateStmt;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @RowConfRank = CASE @RowConfidence WHEN 'LOW' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'HIGH' THEN 3 ELSE 0 END;

    IF @DB <> @CurrentDB
    BEGIN
      IF @IsFirstDB = 0
        SET @ScriptText = @ScriptText + @CRLF;

      SET @CurrentDB    = @DB;
      SET @CurrentTable = '';
      SET @IsFirstDB    = 0;

      SET @ScriptText = @ScriptText
        + '-- ============================================================================' + @CRLF
        + '-- Database: ' + @DB + @CRLF
        + '-- ============================================================================' + @CRLF
        + 'USE ' + QUOTENAME(@DB) + @CRLF
        + 'GO' + @CRLF;
    END;

    DECLARE @TableKey NVARCHAR(400) = @DB + '.' + @Schema + '.' + @Table;
    IF @TableKey <> @CurrentTable
    BEGIN
      SET @CurrentTable = @TableKey;
      SET @ScriptText = @ScriptText
        + @CRLF
        + @Separator + @CRLF
        + '-- Table: ' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + @CRLF
        + @Separator + @CRLF;
    END;

    SET @ScriptText = @ScriptText + @CRLF
      + '-- UNUSED INDEX' + @CRLF
      + '--   Index: ' + @IdxName + ' (' + ISNULL(@IdxType, '?') + ')' + @CRLF
      + '--     Size: ' + ISNULL(FORMAT(@SizeKB / 1024.0, 'N1'), '?') + ' MB' + @CRLF
      + '--   Usage (since ' + CONVERT(VARCHAR(10), @ServerStartTime, 120) + '):' + @CRLF
      + '--     Seeks: 0  |  Scans: 0  |  Lookups: 0  |  Updates: ' + FORMAT(@UserUpdates, 'N0') + @CRLF
      + '--   Observation:' + @CRLF
      + '--     Source: ' + @ObsSource
      + '  |  Days: ' + FORMAT(@ObsDays, 'N0')
      + CASE WHEN @QSPlanCount IS NOT NULL
             THEN '  |  QS Plans: ' + CAST(@QSPlanCount AS VARCHAR(10))
             ELSE ''
        END + @CRLF
      + '--     Confidence: ' + @RowConfidence
      + CASE WHEN @RowConfRank < @ConfidenceRank THEN '  ** BELOW THRESHOLD (' + @Confidence + ') - COMMENTED OUT **' ELSE '' END + @CRLF;

    IF @RowConfRank >= @ConfidenceRank
    BEGIN
      SET @ActiveRecs = @ActiveRecs + 1;

      -- Action statement
      IF @DropStmt IS NOT NULL
        SET @ScriptText = @ScriptText + @CRLF + @DropStmt + @CRLF;

      -- Mark resolved
      SET @ScriptText = @ScriptText
        + @CRLF + 'UPDATE DBA_Utilities.indexing.UnusedIndexResults SET ResolvedDate = GETDATE() WHERE UnusedIndexId = ' + CAST(@Id AS VARCHAR(10)) + ';' + @CRLF;
    END
    ELSE
    BEGIN
      SET @CommentedRecs = @CommentedRecs + 1;

      -- Below confidence threshold: comment out
      IF @DropStmt IS NOT NULL
        SET @ScriptText = @ScriptText + @CRLF + '-- ' + @DropStmt + @CRLF;

      SET @ScriptText = @ScriptText
        + @CRLF + '-- UPDATE DBA_Utilities.indexing.UnusedIndexResults SET ResolvedDate = GETDATE() WHERE UnusedIndexId = ' + CAST(@Id AS VARCHAR(10)) + ';' + @CRLF;
    END

    FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table
      ,@IdxName, @IdxKeys, @IdxIncludes, @SizeKB
      ,@IdxType, @IsUnique, @HasFilter, @FilterDef
      ,@UserUpdates, @QSDays, @QSPlanCount
      ,@ObsSource, @ObsDays, @RowConfidence
      ,@DropStmt, @RecreateStmt;
  END;

  CLOSE rec_cursor;
  DEALLOCATE rec_cursor;

  DECLARE @TotalUnfiltered INT;
  SELECT @TotalUnfiltered = COUNT(*)
  FROM indexing.UnusedIndexResults
  WHERE ResolvedDate IS NULL
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SELECT @@SERVERNAME                                AS ServerName
        ,ISNULL(@DatabaseName, 'ALL')                AS DatabaseName
        ,GETDATE()                                   AS GeneratedDate
        ,CAST(@TotalRecs AS VARCHAR(10)) + ' unused indexes, '
         + FORMAT(@TotalSizeKB, 'N0') + ' KB reclaimable'
                                                     AS [Statistics]
        ,CASE WHEN @TotalRecs > 0 AND @ActiveRecs > 0
              THEN 'Has Recommendations (' + CAST(@ActiveRecs AS VARCHAR(10)) + ' active'
                   + CASE WHEN @CommentedRecs > 0 THEN ', ' + CAST(@CommentedRecs AS VARCHAR(10)) + ' below ' + @Confidence + ' commented out' ELSE '' END + ')'
              WHEN @TotalRecs > 0 AND @ActiveRecs = 0
              THEN 'Nothing Under Confidence (' + CAST(@CommentedRecs AS VARCHAR(10)) + ' below ' + @Confidence + ', all commented out)'
              WHEN @TotalRecs = 0 AND @TotalUnfiltered > 0
              THEN 'Nothing To Run'
              ELSE 'No Recommendations'
         END                                         AS [Status]
        ,CASE WHEN @TotalRecs > 0
              THEN @ScriptText
              ELSE NULL
         END                                         AS ScriptText;
END;
GO


-- ==========================================================================
-- MISSING INDEX RECOMMENDATIONS (optimize-index)
-- ==========================================================================

-- =============================================
-- REMOTE DEPLOYMENT: All-In-One Installation Script
-- =============================================
-- This script contains ALL stored procedures, functions, and tables
-- in a single file for easy remote deployment via linked servers.
--
-- Generated: 2026-03-30 11:29:21
-- Source: Modular files from T-SQL/sps/ directory
-- Version: 5.0 - Generic database targeting (no MCVersion dependency)
--
-- FEATURES:
--   - @DatabaseName = NULL targets all user databases (database_id > 4)
--   - @DatabaseName supports comma-delimited list of specific databases
--   - @RunnableUnder parameter for auto-executable scripts
--   - Smart table size estimation (structural similarity)
--   - Basic, Prefix, and Super-consolidation
--   - Strategy analysis (CREATE, UPDATE, EXTEND, REBUILD)
--   - Enterprise edition detection (WITH(ONLINE=ON))
--   - Filtered index protection
--
-- Usage via linked server:
--   EXEC('USE [DBA_Utilities]; EXEC sp_executesql N''... paste this script ...''') AT [LinkedServerName]
-- =============================================
USE [DBA_Utilities]
GO

PRINT '=============================================='
PRINT 'Installing T-SQL Index Optimization System'
PRINT 'All-In-One Installation'
PRINT '=============================================='
PRINT ''

-- =============================================

-- Create schema if it doesn't exist
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'indexing')
BEGIN
    EXEC('CREATE SCHEMA indexing');
    PRINT 'Schema [indexing] created successfully.';
END
ELSE
    PRINT 'Schema [indexing] already exists.';
GO

-- Table: IndexRecommendations (loaded from CSV)
IF OBJECT_ID('indexing.IndexRecommendations', 'U') IS NOT NULL
    DROP TABLE indexing.IndexRecommendations;

CREATE TABLE indexing.IndexRecommendations (
    RecommendationID INT IDENTITY(1,1) PRIMARY KEY,
    ServerName NVARCHAR(128),
    DatabaseName NVARCHAR(128),
    SchemaTable NVARCHAR(256),
    KeyColumns NVARCHAR(MAX),
    IncludedColumns NVARCHAR(MAX),
    IndexAdvantage DECIMAL(18,2),
    EstimatedQueryTime NVARCHAR(20),
    UserSeeks BIGINT,
    UserScans BIGINT,
    PercentImprovement DECIMAL(10,2),
    AvgTotalUserCost FLOAT,
    Impact DECIMAL(18,2)
);
PRINT 'Table indexing.IndexRecommendations created successfully.';
GO

-- Table: CurrentIndexes (loaded from CSV)
IF OBJECT_ID('indexing.CurrentIndexes', 'U') IS NOT NULL
    DROP TABLE indexing.CurrentIndexes;

CREATE TABLE indexing.CurrentIndexes (
    IndexID INT IDENTITY(1,1) PRIMARY KEY,
    ServerName NVARCHAR(128),
    DatabaseName NVARCHAR(128),
    SchemaTable NVARCHAR(256),
    IndexName NVARCHAR(128),
    KeyColumns NVARCHAR(MAX),
    IncludedColumns NVARCHAR(MAX),
    IsDisabled BIT,
    IsPrimaryKey BIT,
    IsUnique BIT,
    HasFilter BIT,
    IndexSizeMB DECIMAL(18,2)
);
PRINT 'Table indexing.CurrentIndexes created successfully.';
GO

-- Table: ServerInfo (loaded from CSV)
IF OBJECT_ID('indexing.ServerInfo', 'U') IS NOT NULL
    DROP TABLE indexing.ServerInfo;

CREATE TABLE indexing.ServerInfo (
    ServerID INT IDENTITY(1,1) PRIMARY KEY,
    ServerName NVARCHAR(128),
    Edition NVARCHAR(128),
    IsEnterprise BIT DEFAULT 0
);
PRINT 'Table indexing.ServerInfo created successfully.';
GO

-- Table: ConsolidatedRecommendations (output from consolidation)
IF OBJECT_ID('indexing.ConsolidatedRecommendations', 'U') IS NOT NULL
    DROP TABLE indexing.ConsolidatedRecommendations;

CREATE TABLE indexing.ConsolidatedRecommendations (
    GroupID INT IDENTITY(1,1) PRIMARY KEY,
    ServerName NVARCHAR(128),
    DatabaseName NVARCHAR(128),
    SchemaTable NVARCHAR(256),
    KeyColumns NVARCHAR(MAX),
    IncludedColumns NVARCHAR(MAX),
    OriginalRecommendationIDs NVARCHAR(MAX),
    RecommendationCount INT,
    TotalIndexAdvantage DECIMAL(18,2)
);
PRINT 'Table indexing.ConsolidatedRecommendations created successfully.';
GO

-- Table: PrefixConsolidatedGroups (output from prefix consolidation)
IF OBJECT_ID('indexing.PrefixConsolidatedGroups', 'U') IS NOT NULL
    DROP TABLE indexing.PrefixConsolidatedGroups;

CREATE TABLE indexing.PrefixConsolidatedGroups (
    GroupID INT IDENTITY(1,1) PRIMARY KEY,
    ServerName NVARCHAR(128),
    DatabaseName NVARCHAR(128),
    SchemaTable NVARCHAR(256),
    KeyColumns NVARCHAR(MAX),
    IncludedColumns NVARCHAR(MAX),
    OriginalRecommendationIDs NVARCHAR(MAX),
    RecommendationCount INT,
    TotalIndexAdvantage DECIMAL(18,2),
    IsPrefixConsolidated BIT DEFAULT 0,
    OriginalGroupCount INT DEFAULT 1
);
PRINT 'Table indexing.PrefixConsolidatedGroups created successfully.';
GO

-- Table: SuperConsolidatedGroups (output from super-consolidation)
IF OBJECT_ID('indexing.SuperConsolidatedGroups', 'U') IS NOT NULL
    DROP TABLE indexing.SuperConsolidatedGroups;

CREATE TABLE indexing.SuperConsolidatedGroups (
    GroupID INT IDENTITY(1,1) PRIMARY KEY,
    ServerName NVARCHAR(128),
    DatabaseName NVARCHAR(128),
    SchemaTable NVARCHAR(256),
    KeyColumns NVARCHAR(MAX),
    IncludedColumns NVARCHAR(MAX),
    OriginalRecommendationIDs NVARCHAR(MAX),
    RecommendationCount INT,
    TotalIndexAdvantage DECIMAL(18,2),
    IsSuperConsolidated BIT DEFAULT 0,
    OriginalGroupCount INT DEFAULT 1
);
PRINT 'Table indexing.SuperConsolidatedGroups created successfully.';
GO

-- Table: CleanedConsolidatedGroups (output after redundancy removal)
IF OBJECT_ID('indexing.CleanedConsolidatedGroups', 'U') IS NOT NULL
    DROP TABLE indexing.CleanedConsolidatedGroups;

CREATE TABLE indexing.CleanedConsolidatedGroups (
    GroupID INT IDENTITY(1,1) PRIMARY KEY,
    ServerName NVARCHAR(128),
    DatabaseName NVARCHAR(128),
    SchemaTable NVARCHAR(256),
    KeyColumns NVARCHAR(MAX),
    IncludedColumns NVARCHAR(MAX),
    OriginalRecommendationIDs NVARCHAR(MAX),
    RecommendationCount INT,
    TotalIndexAdvantage DECIMAL(18,2),
    IsSuperConsolidated BIT DEFAULT 0,
    OriginalGroupCount INT DEFAULT 1
);
PRINT 'Table indexing.CleanedConsolidatedGroups created successfully.';
GO

-- Table: AnalysisResults (final analysis with strategies)
IF OBJECT_ID('indexing.AnalysisResults', 'U') IS NOT NULL
    DROP TABLE indexing.AnalysisResults;

CREATE TABLE indexing.AnalysisResults (
    ResultID INT IDENTITY(1,1) PRIMARY KEY,
    ServerName NVARCHAR(128),
    DatabaseName NVARCHAR(128),
    SchemaTable NVARCHAR(256),
    Strategy NVARCHAR(50),
    ExistingIndexName NVARCHAR(128),
    ExistingKeyColumns NVARCHAR(MAX),
    ExistingIncludeColumns NVARCHAR(MAX),
    NewIndexName NVARCHAR(128),
    KeyColumns NVARCHAR(MAX),
    IncludedColumns NVARCHAR(MAX),
    RecommendationIDs NVARCHAR(MAX),
    RecommendationCount INT,
    IsDisabled BIT,
    IndexAdvantage DECIMAL(18,2),
    MatchScore INT,
    IsSuperConsolidated BIT DEFAULT 0,
    OriginalGroupCount INT DEFAULT 1
);
PRINT 'Table indexing.AnalysisResults created successfully.';
GO

-- Table: GeneratedScripts (final output)
IF OBJECT_ID('indexing.GeneratedScripts', 'U') IS NOT NULL
    DROP TABLE indexing.GeneratedScripts;

CREATE TABLE indexing.GeneratedScripts (
    ScriptID INT IDENTITY(1,1) PRIMARY KEY,
    ServerName NVARCHAR(128),
    DatabaseName NVARCHAR(128),
    GeneratedDate DATETIME DEFAULT GETDATE(),
    ScriptText NVARCHAR(MAX),
    [Statistics] NVARCHAR(500),
    [Status] NVARCHAR(100)  -- Status: "No Recommendations", "Has Recommendations", "Nothing To Run Under Parameter"
);
PRINT 'Table indexing.GeneratedScripts created successfully.';
GO

-- Table: MissingIndexResults (persistent per-finding results with ResolvedDate tracking)
IF OBJECT_ID('indexing.MissingIndexResults', 'U') IS NULL
BEGIN
    CREATE TABLE indexing.MissingIndexResults (
        MissingIndexId        INT            IDENTITY(1, 1),
        ServerName            NVARCHAR(128)  NOT NULL,
        DatabaseName          NVARCHAR(128)  NOT NULL,
        SchemaName            NVARCHAR(128)  NOT NULL,
        TableName             NVARCHAR(128)  NOT NULL,
        Strategy              NVARCHAR(50)   NOT NULL,
        ExistingIndexName     NVARCHAR(128)  NULL,
        ExistingKeyColumns    NVARCHAR(MAX)  NULL,
        ExistingIncludeColumns NVARCHAR(MAX) NULL,
        KeyColumns            NVARCHAR(MAX)  NULL,
        IncludedColumns       NVARCHAR(MAX)  NULL,
        IndexAdvantage        DECIMAL(18, 2) NULL,
        RecommendationCount   INT            NULL,
        RecommendationIDs     NVARCHAR(MAX)  NULL,
        IsDisabled            BIT            NULL,
        IsSuperConsolidated   BIT            NULL,
        OriginalGroupCount    INT            NULL,
        EstimatedSizeGB       DECIMAL(18, 2) NULL,
        CreateStatement       NVARCHAR(MAX)  NULL,
        ProcessedDate         DATETIME2(3)   NOT NULL DEFAULT (SYSDATETIME()),
        ResolvedDate          DATETIME2(3)   NULL,
        CONSTRAINT PKC_MissingIndexResults PRIMARY KEY CLUSTERED (MissingIndexId DESC) WITH (FILLFACTOR = 100)
    );
    PRINT 'Table indexing.MissingIndexResults created successfully.';
END
ELSE
    PRINT 'Table indexing.MissingIndexResults already exists - skipping.';
GO

PRINT '';
PRINT '========================================';
PRINT 'All tables created successfully!';
PRINT '========================================';

GO

-- =============================================

IF OBJECT_ID('indexing.fn_ContainsAllColumns', 'FN') IS NOT NULL
    DROP FUNCTION indexing.fn_ContainsAllColumns;
GO

CREATE FUNCTION indexing.fn_ContainsAllColumns
(
    @SupersetColumns NVARCHAR(MAX),  -- e.g., '[col1], [col2], [col3]'
    @SubsetColumns NVARCHAR(MAX)     -- e.g., '[col1], [col3]'
)
RETURNS BIT
AS
BEGIN
    DECLARE @Result BIT = 1;

    -- Handle NULL cases
    IF @SubsetColumns IS NULL OR @SubsetColumns = ''
        RETURN 1;  -- Empty subset is always contained

    IF @SupersetColumns IS NULL OR @SupersetColumns = ''
        RETURN 0;  -- Non-empty subset cannot be in empty superset

    -- Parse subset columns and check if each exists in superset
    DECLARE @Column NVARCHAR(256);
    DECLARE @Pos INT;
    DECLARE @SubsetCopy NVARCHAR(MAX) = @SubsetColumns;

    -- Remove brackets and spaces for easier comparison
    SET @SupersetColumns = REPLACE(REPLACE(REPLACE(@SupersetColumns, '[', ''), ']', ''), ' ', '');
    SET @SubsetCopy = REPLACE(REPLACE(REPLACE(@SubsetCopy, '[', ''), ']', ''), ' ', '');

    -- Check each column in subset
    WHILE LEN(@SubsetCopy) > 0
    BEGIN
        SET @Pos = CHARINDEX(',', @SubsetCopy);

        IF @Pos > 0
        BEGIN
            SET @Column = LTRIM(RTRIM(SUBSTRING(@SubsetCopy, 1, @Pos - 1)));
            SET @SubsetCopy = SUBSTRING(@SubsetCopy, @Pos + 1, LEN(@SubsetCopy));
        END
        ELSE
        BEGIN
            SET @Column = LTRIM(RTRIM(@SubsetCopy));
            SET @SubsetCopy = '';
        END

        -- Check if this column exists in superset
        IF CHARINDEX(@Column, @SupersetColumns) = 0
        BEGIN
            SET @Result = 0;
            BREAK;
        END
    END

    RETURN @Result;
END
GO

PRINT 'Function fn_ContainsAllColumns created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.fn_AreIncludesCompatible', 'FN') IS NOT NULL
    DROP FUNCTION indexing.fn_AreIncludesCompatible;
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE FUNCTION indexing.fn_AreIncludesCompatible(
    @Includes1 NVARCHAR(MAX),
    @Includes2 NVARCHAR(MAX)
)
RETURNS BIT
AS
BEGIN
    -- If both are null or empty, they're compatible
    IF (@Includes1 IS NULL OR @Includes1 = '') AND (@Includes2 IS NULL OR @Includes2 = '')
        RETURN 1;

    -- If one is empty and the other isn't, they're still compatible (one is subset of other)
    IF (@Includes1 IS NULL OR @Includes1 = '') OR (@Includes2 IS NULL OR @Includes2 = '')
        RETURN 1;

    -- Parse both include sets into normalized forms (remove brackets, lowercase, trim)
    DECLARE @Set1 NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(LOWER(@Includes1), '[', ''), ']', ''), ' ', '');
    DECLARE @Set2 NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(LOWER(@Includes2), '[', ''), ']', ''), ' ', '');

    -- Split into individual columns for comparison
    DECLARE @Cols1 TABLE (ColName NVARCHAR(128));
    DECLARE @Cols2 TABLE (ColName NVARCHAR(128));

    -- Split Set1
    INSERT INTO @Cols1 (ColName)
    SELECT TRIM(value) FROM STRING_SPLIT(@Set1, ',') WHERE TRIM(value) != '';

    -- Split Set2
    INSERT INTO @Cols2 (ColName)
    SELECT TRIM(value) FROM STRING_SPLIT(@Set2, ',') WHERE TRIM(value) != '';

    -- Count columns in each set
    DECLARE @Count1 INT = (SELECT COUNT(*) FROM @Cols1);
    DECLARE @Count2 INT = (SELECT COUNT(*) FROM @Cols2);

    -- Check if sets are identical
    DECLARE @IntersectionCount INT = (
        SELECT COUNT(*)
        FROM @Cols1 c1
        INNER JOIN @Cols2 c2 ON c1.ColName = c2.ColName
    );

    -- Sets are compatible if:
    -- 1. They're identical (intersection = both counts)
    -- 2. Set1 is subset of Set2 (intersection = Set1 count)
    -- 3. Set2 is subset of Set1 (intersection = Set2 count)
    IF @IntersectionCount = @Count1 AND @IntersectionCount = @Count2
        RETURN 1;  -- Identical

    IF @IntersectionCount = @Count1 OR @IntersectionCount = @Count2
        RETURN 1;  -- One is subset of other

    RETURN 0;  -- Not compatible
END
GO

PRINT 'Function fn_AreIncludesCompatible created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.fn_CanSuperConsolidateGroups', 'FN') IS NOT NULL
    DROP FUNCTION indexing.fn_CanSuperConsolidateGroups;
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE FUNCTION indexing.fn_CanSuperConsolidateGroups(
    @SuperGroupIncludes NVARCHAR(MAX),
    @SuperGroupFirstKey NVARCHAR(128),
    @CandidateIncludes NVARCHAR(MAX),
    @CandidateFirstKey NVARCHAR(128)
)
RETURNS BIT
AS
BEGIN
    -- Must have compatible includes (same or subset/superset relationship)
    IF indexing.fn_AreIncludesCompatible(@SuperGroupIncludes, @CandidateIncludes) = 0
        RETURN 0;

    -- NEW LOGIC (2026-02-27): No first-key matching requirement!
    -- The procedure sp_ApplySuperConsolidation already checks for high impact (>100K)
    -- and blocks those groups from super-consolidation.
    -- For low-impact groups (<100K), we allow flexible key positioning as long as:
    --   - Column ordering within each recommendation is preserved (handled by merge logic)
    --   - Include columns are compatible (checked above)

    RETURN 1;  -- Groups can be super-consolidated (impact checking done at procedure level)
END
GO

PRINT 'Function fn_CanSuperConsolidateGroups (V2 with 100K threshold support) created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.fn_SuperGroupCoversIndividual', 'FN') IS NOT NULL
    DROP FUNCTION indexing.fn_SuperGroupCoversIndividual;
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE FUNCTION indexing.fn_SuperGroupCoversIndividual(
    @SuperGroupKeys NVARCHAR(MAX),
    @SuperGroupIncludes NVARCHAR(MAX),
    @IndividualKeys NVARCHAR(MAX),
    @IndividualIncludes NVARCHAR(MAX)
)
RETURNS BIT
AS
BEGIN
    -- Parse super-group columns
    DECLARE @SuperKeyCols TABLE (ColName NVARCHAR(128));
    DECLARE @SuperIncludeCols TABLE (ColName NVARCHAR(128));
    DECLARE @SuperAllCols TABLE (ColName NVARCHAR(128));

    -- Normalize and split super-group keys
    DECLARE @NormSuperKeys NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(LOWER(@SuperGroupKeys), '[', ''), ']', ''), ' ', '');
    INSERT INTO @SuperKeyCols (ColName)
    SELECT TRIM(value) FROM STRING_SPLIT(@NormSuperKeys, ',') WHERE TRIM(value) != '';

    -- Insert keys into all columns table
    INSERT INTO @SuperAllCols (ColName)
    SELECT ColName FROM @SuperKeyCols;

    -- Normalize and split super-group includes
    IF @SuperGroupIncludes IS NOT NULL AND @SuperGroupIncludes != ''
    BEGIN
        DECLARE @NormSuperIncludes NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(LOWER(@SuperGroupIncludes), '[', ''), ']', ''), ' ', '');
        INSERT INTO @SuperIncludeCols (ColName)
        SELECT TRIM(value) FROM STRING_SPLIT(@NormSuperIncludes, ',') WHERE TRIM(value) != '';

        -- Insert includes into all columns table
        INSERT INTO @SuperAllCols (ColName)
        SELECT ColName FROM @SuperIncludeCols;
    END

    -- Parse individual group columns
    DECLARE @IndivKeyCols TABLE (ColName NVARCHAR(128));
    DECLARE @IndivIncludeCols TABLE (ColName NVARCHAR(128));

    -- Normalize and split individual keys
    DECLARE @NormIndivKeys NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(LOWER(@IndividualKeys), '[', ''), ']', ''), ' ', '');
    INSERT INTO @IndivKeyCols (ColName)
    SELECT TRIM(value) FROM STRING_SPLIT(@NormIndivKeys, ',') WHERE TRIM(value) != '';

    -- Check if super-group's key columns contain all individual's key columns
    DECLARE @IndivKeyCount INT = (SELECT COUNT(*) FROM @IndivKeyCols);
    DECLARE @MatchingKeyCount INT = (
        SELECT COUNT(*)
        FROM @IndivKeyCols ik
        INNER JOIN @SuperKeyCols sk ON ik.ColName = sk.ColName
    );

    IF @MatchingKeyCount != @IndivKeyCount
        RETURN 0;  -- Super-group doesn't contain all individual's key columns

    -- Normalize and split individual includes
    IF @IndividualIncludes IS NOT NULL AND @IndividualIncludes != ''
    BEGIN
        DECLARE @NormIndivIncludes NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(LOWER(@IndividualIncludes), '[', ''), ']', ''), ' ', '');
        INSERT INTO @IndivIncludeCols (ColName)
        SELECT TRIM(value) FROM STRING_SPLIT(@NormIndivIncludes, ',') WHERE TRIM(value) != '';

        -- Check if super-group contains all individual's include columns (in key or include)
        DECLARE @IndivIncludeCount INT = (SELECT COUNT(*) FROM @IndivIncludeCols);
        DECLARE @MatchingIncludeCount INT = (
            SELECT COUNT(*)
            FROM @IndivIncludeCols ii
            INNER JOIN @SuperAllCols sa ON ii.ColName = sa.ColName
        );

        IF @MatchingIncludeCount != @IndivIncludeCount
            RETURN 0;  -- Super-group doesn't contain all individual's include columns
    END

    RETURN 1;  -- Super-group covers individual
END
GO

PRINT 'Function fn_SuperGroupCoversIndividual created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.fn_KeyIncludeCoversGroup', 'FN') IS NOT NULL
    DROP FUNCTION indexing.fn_KeyIncludeCoversGroup;
GO

CREATE FUNCTION indexing.fn_KeyIncludeCoversGroup(
    @CoveringKeys NVARCHAR(MAX),
    @CoveringIncludes NVARCHAR(MAX),
    @CoveredKeys NVARCHAR(MAX),
    @CoveredIncludes NVARCHAR(MAX)
)
RETURNS BIT
AS
BEGIN
    /*
    Determine if covering_group can cover covered_group via key-include cross-coverage.

    Criteria for coverage:
    1. All columns needed by covered group must be available in covering group (keys + includes)
    2. At least one key column from covered group must appear in covering group's keys
    3. Covered group's key columns should be efficiently usable in covering's index

    Example:
    - Covering: Key=[access_category_id, lifecycle_phase] Include=[info_card_id, document_num]
    - Covered: Key=[lifecycle_phase] Include=[info_card_id, document_num, access_category_id]

    Covering covers Covered because:
    - lifecycle_phase (covered's key) appears in covering's key
    - access_category_id (covered's include) appears in covering's key (even better)
    - info_card_id, document_num appear in both includes
    */

    -- Parse all columns into sets
    DECLARE @CoveringKeySet TABLE (ColName NVARCHAR(128));
    DECLARE @CoveringIncludeSet TABLE (ColName NVARCHAR(128));
    DECLARE @CoveredKeySet TABLE (ColName NVARCHAR(128));
    DECLARE @CoveredIncludeSet TABLE (ColName NVARCHAR(128));

    -- Parse covering group's keys
    INSERT INTO @CoveringKeySet (ColName)
    SELECT DISTINCT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
    FROM STRING_SPLIT(@CoveringKeys, ',')
    WHERE TRIM(value) != '';

    -- Parse covering group's includes
    IF @CoveringIncludes IS NOT NULL AND @CoveringIncludes != ''
    BEGIN
        INSERT INTO @CoveringIncludeSet (ColName)
        SELECT DISTINCT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
        FROM STRING_SPLIT(@CoveringIncludes, ',')
        WHERE TRIM(value) != '';
    END

    -- Parse covered group's keys
    INSERT INTO @CoveredKeySet (ColName)
    SELECT DISTINCT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
    FROM STRING_SPLIT(@CoveredKeys, ',')
    WHERE TRIM(value) != '';

    -- Parse covered group's includes
    IF @CoveredIncludes IS NOT NULL AND @CoveredIncludes != ''
    BEGIN
        INSERT INTO @CoveredIncludeSet (ColName)
        SELECT DISTINCT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
        FROM STRING_SPLIT(@CoveredIncludes, ',')
        WHERE TRIM(value) != '';
    END

    -- Check condition 1: All columns needed by covered group must be in covering group
    -- Covered needs = covered keys + covered includes
    -- Covering has = covering keys + covering includes
    IF EXISTS (
        SELECT ColName FROM @CoveredKeySet
        EXCEPT
        (
            SELECT ColName FROM @CoveringKeySet
            UNION ALL
            SELECT ColName FROM @CoveringIncludeSet
        )
    )
    BEGIN
        RETURN 0; -- Covering group doesn't have all columns needed
    END

    IF EXISTS (
        SELECT ColName FROM @CoveredIncludeSet
        EXCEPT
        (
            SELECT ColName FROM @CoveringKeySet
            UNION ALL
            SELECT ColName FROM @CoveringIncludeSet
        )
    )
    BEGIN
        RETURN 0; -- Covering group doesn't have all columns needed
    END

    -- Check condition 2: At least one of covered's key columns must be in covering's keys
    -- This ensures the covering index can be used for queries that would use covered index
    IF NOT EXISTS (
        SELECT 1
        FROM @CoveredKeySet ck
        WHERE EXISTS (SELECT 1 FROM @CoveringKeySet WHERE ColName = ck.ColName)
    )
    BEGIN
        RETURN 0; -- No key column overlap for efficient index usage
    END

    -- Check condition 3: If covered has only one key and it's in covering's keys, that's sufficient
    -- NOTE: This function is ONLY called for LOW-IMPACT queries (< 100k impact)
    -- For low-impact queries, we allow COVERAGE-BASED consolidation (key can be in any position)
    -- Example: [step_id] can use index on [packet_id],[step_id],[completion_date] for low-impact queries
    -- High-impact queries (>= 100k) are blocked at the caller level (sp_ApplyPrefixConsolidation)
    DECLARE @CoveredKeyCount INT = (SELECT COUNT(*) FROM @CoveredKeySet);
    IF @CoveredKeyCount = 1
    BEGIN
        -- Already verified in condition 2 that this key exists in covering keys
        RETURN 1;
    END

    -- For multiple keys, check if they form a usable subset (leftmost prefix or contiguous)
    -- For now, if conditions 1 and 2 pass, allow it (can be refined later)
    RETURN 1;
END
GO

PRINT 'Function fn_KeyIncludeCoversGroup created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.fn_IsLeftmostPrefix', 'FN') IS NOT NULL
    DROP FUNCTION indexing.fn_IsLeftmostPrefix;
GO

CREATE FUNCTION indexing.fn_IsLeftmostPrefix(
    @PrefixKeys NVARCHAR(MAX),
    @FullKeys NVARCHAR(MAX)
)
RETURNS BIT
AS
BEGIN
    /*
    Check if PrefixKeys is a leftmost prefix of FullKeys.

    Examples:
    - IsLeftmostPrefix('[status]', '[status], [site_id]') = 1 (TRUE)
    - IsLeftmostPrefix('[status], [type]', '[status], [type], [date]') = 1 (TRUE)
    - IsLeftmostPrefix('[status]', '[entity_id], [status]') = 0 (FALSE - not leftmost)
    - IsLeftmostPrefix('[status], [site]', '[status], [type]') = 0 (FALSE - different second column)
    */

    -- Parse both key sets into ordered arrays
    DECLARE @PrefixArray TABLE (Position INT, ColName NVARCHAR(128));
    DECLARE @FullArray TABLE (Position INT, ColName NVARCHAR(128));

    DECLARE @Position INT = 1;
    DECLARE @Value NVARCHAR(128);

    -- Parse prefix keys
    DECLARE prefix_cursor CURSOR FOR
        SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
        FROM STRING_SPLIT(@PrefixKeys, ',')
        WHERE TRIM(value) != '';

    OPEN prefix_cursor;
    FETCH NEXT FROM prefix_cursor INTO @Value;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT INTO @PrefixArray (Position, ColName) VALUES (@Position, @Value);
        SET @Position = @Position + 1;
        FETCH NEXT FROM prefix_cursor INTO @Value;
    END

    CLOSE prefix_cursor;
    DEALLOCATE prefix_cursor;

    -- Parse full keys
    SET @Position = 1;
    DECLARE full_cursor CURSOR FOR
        SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
        FROM STRING_SPLIT(@FullKeys, ',')
        WHERE TRIM(value) != '';

    OPEN full_cursor;
    FETCH NEXT FROM full_cursor INTO @Value;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT INTO @FullArray (Position, ColName) VALUES (@Position, @Value);
        SET @Position = @Position + 1;
        FETCH NEXT FROM full_cursor INTO @Value;
    END

    CLOSE full_cursor;
    DEALLOCATE full_cursor;

    -- Check if prefix is longer than full (can't be a prefix)
    DECLARE @PrefixCount INT = (SELECT COUNT(*) FROM @PrefixArray);
    DECLARE @FullCount INT = (SELECT COUNT(*) FROM @FullArray);

    IF @PrefixCount > @FullCount
        RETURN 0;

    -- Check if every column in prefix matches the corresponding position in full
    IF EXISTS (
        SELECT 1
        FROM @PrefixArray p
        LEFT JOIN @FullArray f ON p.Position = f.Position AND p.ColName = f.ColName
        WHERE f.ColName IS NULL  -- Mismatch found
    )
    BEGIN
        RETURN 0;  -- Not a leftmost prefix
    END

    -- All positions match
    RETURN 1;
END
GO

PRINT 'Function fn_IsLeftmostPrefix created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.fn_ContainsAllKeys', 'FN') IS NOT NULL
    DROP FUNCTION indexing.fn_ContainsAllKeys;
GO

CREATE FUNCTION indexing.fn_ContainsAllKeys(
    @ExistingKeys NVARCHAR(MAX),  -- Comma-separated key columns: '[col1], [col2], [col3]'
    @NeededKeys NVARCHAR(MAX)     -- Comma-separated key columns: '[col2]' or '[col2], [col3]'
)
RETURNS BIT
AS
BEGIN
    -- Handle NULL cases
    IF @ExistingKeys IS NULL OR @NeededKeys IS NULL
        RETURN 0;

    -- Normalize: add comma+space at start and end, this handles all edge cases
    -- Also ensures consistent comma+space separators
    SET @ExistingKeys = ', ' + LTRIM(RTRIM(@ExistingKeys)) + ', ';
    SET @NeededKeys = ', ' + LTRIM(RTRIM(@NeededKeys)) + ', ';

    -- Split needed keys by comma and check if each exists in existing
    DECLARE @Start INT = 1;
    DECLARE @End INT;
    DECLARE @Key NVARCHAR(256);

    WHILE @Start <= LEN(@NeededKeys)
    BEGIN
        -- Find next comma (skip the leading comma+space we added)
        IF @Start = 1
        BEGIN
            SET @Start = 3;  -- Skip ', ' at start
        END

        -- Find next comma
        SET @End = CHARINDEX(',', @NeededKeys, @Start);
        IF @End = 0
            BREAK;  -- No more keys

        -- Extract key (trim spaces)
        SET @Key = LTRIM(RTRIM(SUBSTRING(@NeededKeys, @Start, @End - @Start)));

        -- Skip empty keys
        IF LEN(@Key) > 0
        BEGIN
            -- Check if key exists in existing (search for ', key, ' pattern)
            IF CHARINDEX(', ' + @Key + ', ', @ExistingKeys) = 0
            BEGIN
                RETURN 0;  -- Key not found
            END
        END

        -- Move past the comma
        SET @Start = @End + 1;
    END

    RETURN 1;  -- All keys found
END
GO

PRINT 'Function fn_ContainsAllKeys created successfully.';
GO

GO

-- =============================================

IF OBJECT_ID('indexing.fn_FindRedundantDisabledIndexes', 'TF') IS NOT NULL
    DROP FUNCTION indexing.fn_FindRedundantDisabledIndexes;
GO

CREATE FUNCTION indexing.fn_FindRedundantDisabledIndexes(
    @DatabaseName NVARCHAR(128),
    @SchemaTable NVARCHAR(512),
    @NewKeyColumns NVARCHAR(MAX),
    @NewIncludedColumns NVARCHAR(MAX)
)
RETURNS @RedundantIndexes TABLE (
    IndexName NVARCHAR(256),
    KeyColumns NVARCHAR(MAX),
    IncludedColumns NVARCHAR(MAX),
    IsPrimaryKey BIT,
    IsUnique BIT,
    HasFilter BIT
)
AS
BEGIN
    -- Find disabled indexes on the same table where:
    -- 1. Disabled index key columns are a leftmost prefix of the new index key columns
    -- 2. Disabled index included columns are covered by (new keys + new includes)

    INSERT INTO @RedundantIndexes (IndexName, KeyColumns, IncludedColumns, IsPrimaryKey, IsUnique, HasFilter)
    SELECT
        ci.IndexName,
        ci.KeyColumns,
        ci.IncludedColumns,
        ci.IsPrimaryKey,
        ci.IsUnique,
        ci.HasFilter
    FROM indexing.CurrentIndexes ci
    WHERE ci.DatabaseName = @DatabaseName
      AND ci.SchemaTable = @SchemaTable
      AND ci.IsDisabled = 1  -- Only disabled indexes
      AND ci.IsPrimaryKey = 0  -- Never drop primary keys
      AND ci.IndexName NOT LIKE '%_FILTERED%'  -- Never drop filtered indexes
      -- Check if disabled index keys are covered by new index keys (leftmost prefix)
      AND (
          -- Exact match
          ci.KeyColumns = @NewKeyColumns
          OR
          -- Leftmost prefix match
          (
              LEN(ci.KeyColumns) < LEN(@NewKeyColumns)
              AND SUBSTRING(@NewKeyColumns, 1, LEN(ci.KeyColumns)) = ci.KeyColumns
              AND SUBSTRING(@NewKeyColumns, LEN(ci.KeyColumns) + 1, 2) = ', '
          )
      )
      -- Check if disabled index includes are covered by new index (keys + includes)
      AND (
          -- No includes on disabled index
          ci.IncludedColumns IS NULL
          OR
          ci.IncludedColumns = ''
          OR
          -- All includes are covered by new index's keys
          indexing.fn_ContainsAllColumns(@NewKeyColumns, ci.IncludedColumns) = 1
          OR
          -- All includes are covered by new index's includes
          indexing.fn_ContainsAllColumns(@NewIncludedColumns, ci.IncludedColumns) = 1
          OR
          -- All includes are covered by combination of keys + includes
          indexing.fn_ContainsAllColumns(@NewKeyColumns + ISNULL(', ' + @NewIncludedColumns, ''), ci.IncludedColumns) = 1
      );

    RETURN;
END
GO

PRINT 'Function indexing.fn_FindRedundantDisabledIndexes created successfully.';
GO

GO

-- =============================================
--
-- Created: 2026-03-12
-- Version: 1.0
-- =============================================

IF OBJECT_ID('indexing.sp_GetSmartTableSizeEstimate', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_GetSmartTableSizeEstimate;
GO

CREATE PROCEDURE indexing.sp_GetSmartTableSizeEstimate
    @DatabaseName NVARCHAR(128),
    @SchemaTable NVARCHAR(256),
    @RecKeyColumns NVARCHAR(MAX),
    @RecIncludeColumns NVARCHAR(MAX),
    @Warning NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Warning = NULL;

    DECLARE @AvgSizeMB DECIMAL(18,2);
    DECLARE @AvgSizeGB DECIMAL(18,2);

    -- Normalize recommendation columns for comparison
    DECLARE @NormalizedRecKeys NVARCHAR(MAX);
    SET @NormalizedRecKeys = REPLACE(REPLACE(@RecKeyColumns, ', ', ','), ',', ', ');
    SET @NormalizedRecKeys = LOWER(@NormalizedRecKeys);

    -- Count recommendation columns
    DECLARE @RecKeyCount INT = 0;
    DECLARE @RecIncludeCount INT = 0;

    IF @RecKeyColumns IS NOT NULL AND @RecKeyColumns != ''
        SET @RecKeyCount = LEN(@RecKeyColumns) - LEN(REPLACE(@RecKeyColumns, ',', '')) + 1;

    IF @RecIncludeColumns IS NOT NULL AND @RecIncludeColumns != ''
        SET @RecIncludeCount = LEN(@RecIncludeColumns) - LEN(REPLACE(@RecIncludeColumns, ',', '')) + 1;

    -- Get all valid indexes for this table
    IF OBJECT_ID('tempdb..#ValidIndexes') IS NOT NULL DROP TABLE #ValidIndexes;
    SELECT
        IndexName,
        KeyColumns,
        IncludedColumns,
        IndexSizeMB,
        -- Normalize for comparison
        LOWER(REPLACE(REPLACE(KeyColumns, ', ', ','), ',', ', ')) AS NormalizedKeys,
        LOWER(REPLACE(REPLACE(ISNULL(IncludedColumns, ''), ', ', ','), ',', ', ')) AS NormalizedIncludes,
        -- Count columns
        CASE
            WHEN KeyColumns IS NULL OR KeyColumns = '' THEN 0
            ELSE LEN(KeyColumns) - LEN(REPLACE(KeyColumns, ',', '')) + 1
        END AS KeyCount,
        CASE
            WHEN IncludedColumns IS NULL OR IncludedColumns = '' THEN 0
            ELSE LEN(IncludedColumns) - LEN(REPLACE(IncludedColumns, ',', '')) + 1
        END AS IncludeCount
    INTO #ValidIndexes
    FROM indexing.CurrentIndexes
    WHERE DatabaseName = @DatabaseName
        AND SchemaTable = @SchemaTable
        AND IsDisabled != 1
        AND IndexSizeMB IS NOT NULL
        AND IndexSizeMB > 0;

    -- Check if we have any valid indexes
    IF NOT EXISTS (SELECT 1 FROM #ValidIndexes)
    BEGIN
        RETURN;
    END

    -- Strategy 1 & 2: Look for exact key match
    DECLARE @ExactMatchName NVARCHAR(128);
    DECLARE @ExactMatchSize DECIMAL(18,2);
    DECLARE @ExactMatchIncludeCount INT;

    SELECT TOP 1
        @ExactMatchName = IndexName,
        @ExactMatchSize = IndexSizeMB,
        @ExactMatchIncludeCount = IncludeCount
    FROM #ValidIndexes
    WHERE NormalizedKeys = @NormalizedRecKeys
    ORDER BY
        -- Prefer closest include count match
        ABS(IncludeCount - @RecIncludeCount),
        IndexSizeMB DESC;

    IF @ExactMatchName IS NOT NULL
    BEGIN
        DECLARE @EstimatedGB DECIMAL(18,2);
        DECLARE @IncludeDiff INT = @RecIncludeCount - @ExactMatchIncludeCount;

        IF @IncludeDiff = 0 OR @IncludeDiff < 0
        BEGIN
            -- Perfect match or fewer includes — use existing size as estimate
            SET @EstimatedGB = @ExactMatchSize / 1024.0;
            IF @EstimatedGB >= 0.5
                SET @Warning = '-- WARNING: ~' + CAST(@EstimatedGB AS VARCHAR(10)) + ' GB estimate, based on ' + @ExactMatchName +
                    CASE WHEN @IncludeDiff = 0 THEN ' (exact key + include match)' ELSE ' (exact key, more includes)' END;
            RETURN;
        END

        -- We need more includes: use proportional scaling from the actual existing index
        -- Get avg_record_size from sys.dm_db_index_physical_stats and column widths via dynamic SQL
        DECLARE @AvgRowBytes FLOAT, @DeclaredWidth FLOAT, @NewColsDeclaredWidth FLOAT;
        DECLARE @PhysSQL NVARCHAR(MAX);

        SET @PhysSQL = N'
            DECLARE @ObjId INT = OBJECT_ID(''' + REPLACE(@SchemaTable, '''', '''''') + N''');
            DECLARE @IdxId INT;
            SELECT @IdxId = i.index_id FROM ' + QUOTENAME(@DatabaseName) + N'.sys.indexes i WHERE i.object_id = @ObjId AND i.name = ''' + REPLACE(@ExactMatchName, '''', '''''') + N''';

            SELECT TOP 1 @p1 = avg_record_size_in_bytes
            FROM sys.dm_db_index_physical_stats(DB_ID(''' + REPLACE(@DatabaseName, '''', '''''') + N'''), @ObjId, @IdxId, NULL, ''SAMPLED'')
            WHERE avg_record_size_in_bytes > 0;

            SELECT @p2 = SUM(CASE WHEN c.max_length = -1 THEN 200 ELSE c.max_length END)
            FROM ' + QUOTENAME(@DatabaseName) + N'.sys.index_columns ic
            JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = @ObjId AND ic.index_id = @IdxId;

            SELECT @p3 = SUM(CASE WHEN c.max_length = -1 THEN 200 ELSE c.max_length END)
            FROM ' + QUOTENAME(@DatabaseName) + N'.sys.columns c
            WHERE c.object_id = @ObjId
              AND ''['' + c.name + '']'' IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@p4, '','') WHERE LTRIM(RTRIM(value)) <> '''')
              AND ''['' + c.name + '']'' NOT IN (
                  SELECT ''['' + c2.name + '']'' FROM ' + QUOTENAME(@DatabaseName) + N'.sys.index_columns ic2
                  JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.columns c2 ON ic2.object_id = c2.object_id AND ic2.column_id = c2.column_id
                  WHERE ic2.object_id = @ObjId AND ic2.index_id = @IdxId);';

        BEGIN TRY
            EXEC sp_executesql @PhysSQL,
                N'@p1 FLOAT OUTPUT, @p2 FLOAT OUTPUT, @p3 FLOAT OUTPUT, @p4 NVARCHAR(MAX)',
                @p1 = @AvgRowBytes OUTPUT, @p2 = @DeclaredWidth OUTPUT, @p3 = @NewColsDeclaredWidth OUTPUT, @p4 = @RecIncludeColumns;
        END TRY
        BEGIN CATCH
            SET @AvgRowBytes = NULL;
        END CATCH

        IF @AvgRowBytes IS NOT NULL AND @DeclaredWidth IS NOT NULL AND @DeclaredWidth > 0 AND @NewColsDeclaredWidth IS NOT NULL
        BEGIN
            -- Fill ratio: how much of declared max_length is actually used in this index
            DECLARE @FillRatio FLOAT = @AvgRowBytes / @DeclaredWidth;
            IF @FillRatio > 1.0 SET @FillRatio = 1.0;

            -- Estimated additional bytes per row for new columns
            DECLARE @NewColBytes FLOAT = @NewColsDeclaredWidth * @FillRatio;

            -- Scale existing index size proportionally
            SET @EstimatedGB = CAST(@ExactMatchSize * (@AvgRowBytes + @NewColBytes) / @AvgRowBytes / 1024.0 AS DECIMAL(18,2));

            IF @EstimatedGB >= 0.5
                SET @Warning = '-- WARNING: ~' + CAST(@EstimatedGB AS VARCHAR(10)) + ' GB estimate, based on ' + @ExactMatchName +
                    ' (exact key, ' + CAST(@ExactMatchIncludeCount AS VARCHAR) + ' includes, ' +
                    CAST(CAST(@ExactMatchSize AS INT) AS VARCHAR) + ' MB) + ' +
                    CAST(@IncludeDiff AS VARCHAR) + ' more includes (~' +
                    CAST(CAST(@NewColBytes AS INT) AS VARCHAR) + ' bytes/row)';
        END
        ELSE
        BEGIN
            -- Fallback: proportional scaling by column count
            DECLARE @ExistingTotalCols INT = @ExactMatchIncludeCount + @RecKeyCount;
            IF @ExistingTotalCols > 0
                SET @EstimatedGB = CAST(@ExactMatchSize * CAST(@ExistingTotalCols + @IncludeDiff AS FLOAT) / @ExistingTotalCols / 1024.0 AS DECIMAL(18,2));
            ELSE
                SET @EstimatedGB = @ExactMatchSize / 1024.0;

            IF @EstimatedGB >= 0.5
                SET @Warning = '-- WARNING: ~' + CAST(@EstimatedGB AS VARCHAR(10)) + ' GB estimate, based on ' + @ExactMatchName +
                    ' (exact key, ' + CAST(@ExactMatchIncludeCount AS VARCHAR) + ' includes, ' +
                    CAST(CAST(@ExactMatchSize AS INT) AS VARCHAR) + ' MB) + ' +
                    CAST(@IncludeDiff AS VARCHAR) + ' more includes (proportional)';
        END

        RETURN;
    END

    -- Strategy 3: Structural similarity (no exact key match)
    IF EXISTS (SELECT 1 FROM #ValidIndexes WHERE IncludeCount > 0)
    BEGIN
        -- Calculate similarity scores
        IF OBJECT_ID('tempdb..#ScoredIndexes') IS NOT NULL DROP TABLE #ScoredIndexes;
        SELECT TOP 3
            IndexName,
            IndexSizeMB,
            -- Similarity score (lower is better)
            (ABS(KeyCount - @RecKeyCount) * 2) + ABS(IncludeCount - @RecIncludeCount) AS SimilarityScore
        INTO #ScoredIndexes
        FROM #ValidIndexes
        WHERE IncludeCount > 0
        ORDER BY
            (ABS(KeyCount - @RecKeyCount) * 2) + ABS(IncludeCount - @RecIncludeCount),
            IndexSizeMB DESC;

        IF EXISTS (SELECT 1 FROM #ScoredIndexes)
        BEGIN
            -- Calculate weighted average
            DECLARE @TotalWeight DECIMAL(18,6) = 0;
            DECLARE @WeightedSize DECIMAL(18,6) = 0;

            SELECT
                @TotalWeight = SUM(1.0 / (SimilarityScore + 1)),
                @WeightedSize = SUM((IndexSizeMB / (SimilarityScore + 1)))
            FROM #ScoredIndexes;

            IF @TotalWeight > 0
            BEGIN
                SET @EstimatedGB = (@WeightedSize / @TotalWeight) / 1024.0;

                IF @EstimatedGB >= 0.5
                BEGIN
                    DECLARE @TopIndexNames NVARCHAR(500);
                    SELECT @TopIndexNames = STRING_AGG(IndexName, ', ')
                    FROM (SELECT TOP 2 IndexName FROM #ScoredIndexes ORDER BY SimilarityScore) AS TopTwo;

                    SET @Warning = '-- WARNING: ~' + CAST(@EstimatedGB AS VARCHAR(10)) + ' GB estimate, based on structurally similar indexes (' +
                        @TopIndexNames + '...)';
                END
            END

            IF @Warning IS NOT NULL
                RETURN;
        END
    END

    -- Strategy 4: Fallback to average
    SELECT @AvgSizeMB = AVG(IndexSizeMB)
    FROM #ValidIndexes;

    IF @AvgSizeMB >= 512.0  -- 0.5 GB
    BEGIN
        SET @AvgSizeGB = @AvgSizeMB / 1024.0;
        SET @Warning = '-- WARNING: ~' + CAST(@AvgSizeGB AS VARCHAR(10)) + ' GB estimate, based on table average (no similar indexes found)';
    END
END;
GO

-- Test the procedure
/*
DECLARE @SizeWarning NVARCHAR(MAX);
EXEC indexing.sp_GetSmartTableSizeEstimate
    'mc_npp_7779',
    '[dbo].[training_data]',
    '[complete_date]',
    '[course_id], [jobcode_id], [packet_id], [launch_date], [status], [retrain_date], [origin]',
    @SizeWarning OUTPUT;
SELECT @SizeWarning;
*/

GO

-- =============================================

IF OBJECT_ID('indexing.sp_ConsolidateRecommendations', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_ConsolidateRecommendations;
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE indexing.sp_ConsolidateRecommendations
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @OriginalCount INT;
    DECLARE @ConsolidatedCount INT;

    BEGIN TRY
        IF @Debug = 1 PRINT 'Starting consolidation of recommendations...';

        -- Get original count
        SELECT @OriginalCount = COUNT(*) FROM indexing.IndexRecommendations;
        IF @Debug = 1 PRINT '  > Original recommendations: ' + CAST(@OriginalCount AS VARCHAR(10));

        -- Clear consolidated table
        TRUNCATE TABLE indexing.ConsolidatedRecommendations;

        -- Step 1: Group by SchemaTable + KeyColumns
        -- Step 2: Combine INCLUDE columns (merge unique columns)
        -- Step 3: Sum index advantages
        IF @Debug = 1 PRINT '  > Grouping by key columns and merging includes...';

        ;WITH GroupedRecs AS (
            SELECT
                ServerName,
                DatabaseName,
                SchemaTable,
                KeyColumns,
                COUNT(*) AS RecCount,
                SUM(IndexAdvantage) AS TotalAdvantage,
                -- Collect all recommendation IDs in group
                STRING_AGG(CAST(RecommendationID AS VARCHAR(10)), ',')
                    WITHIN GROUP (ORDER BY IndexAdvantage DESC) AS RecIDs
            FROM indexing.IndexRecommendations
            GROUP BY ServerName, DatabaseName, SchemaTable, KeyColumns
        ),
        IncludeMerge AS (
            SELECT
                g.ServerName,
                g.DatabaseName,
                g.SchemaTable,
                g.KeyColumns,
                g.RecCount,
                g.TotalAdvantage,
                g.RecIDs,
                -- Merge includes: Use column order from FIRST (highest advantage) recommendation, then append others
                -- CRITICAL: This preserves the exact column order from the primary recommendation
                (
                    SELECT TOP 1 ir.IncludedColumns
                    FROM indexing.IndexRecommendations ir
                    WHERE ir.ServerName = g.ServerName
                        AND ir.DatabaseName = g.DatabaseName
                        AND ir.SchemaTable = g.SchemaTable
                        AND ir.KeyColumns = g.KeyColumns
                        AND ir.IncludedColumns IS NOT NULL
                    ORDER BY ir.IndexAdvantage DESC, ir.RecommendationID
                ) AS MergedIncludes
            FROM GroupedRecs g
        )
        INSERT INTO indexing.ConsolidatedRecommendations (
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            RecommendationCount, TotalIndexAdvantage, OriginalRecommendationIDs
        )
        SELECT
            ServerName,
            DatabaseName,
            SchemaTable,
            KeyColumns,
            -- MergedIncludes already has correct formatting with brackets from source recommendation
            -- No cleanup needed - use as-is to preserve exact formatting
            MergedIncludes AS IncludedColumns,
            RecCount,
            TotalAdvantage,
            RecIDs
        FROM IncludeMerge;

        SELECT @ConsolidatedCount = @@ROWCOUNT;

        IF @Debug = 1
        BEGIN
            PRINT '  > Consolidated recommendations: ' + CAST(@ConsolidatedCount AS VARCHAR(10));
            PRINT '  > Reduction: ' + CAST(@OriginalCount - @ConsolidatedCount AS VARCHAR(10)) +
                  ' (' + CAST(CAST(100.0 * (@OriginalCount - @ConsolidatedCount) / @OriginalCount AS DECIMAL(5,1)) AS VARCHAR(10)) + '%)';
        END

        -- Show consolidation summary
        IF @Debug = 1
        BEGIN
            PRINT '';
            PRINT 'Top consolidations (covering most recommendations):';

            SELECT TOP 5
                RecommendationCount AS Covers,
                LEFT(SchemaTable, 40) AS [Table],
                LEFT(KeyColumns, 30) AS [Keys],
                CAST(TotalIndexAdvantage AS DECIMAL(10,2)) AS TotalAdv,
                LEFT(IncludedColumns, 40) AS [Includes]
            FROM indexing.ConsolidatedRecommendations
            WHERE RecommendationCount > 1
            ORDER BY RecommendationCount DESC, TotalIndexAdvantage DESC;
        END

        IF @Debug = 1 PRINT 'Consolidation complete.';

    END TRY
    BEGIN CATCH
        SET @ErrorMessage = ERROR_MESSAGE();
        PRINT 'ERROR during consolidation: ' + @ErrorMessage;
        ;THROW;
    END CATCH
END
GO

PRINT 'Stored procedure sp_ConsolidateRecommendations created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.sp_ApplyPrefixConsolidation', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_ApplyPrefixConsolidation;
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE indexing.sp_ApplyPrefixConsolidation
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Debug = 1 PRINT '[PREFIX-CONSOLIDATION] Starting prefix and cross-coverage consolidation...';

    -- Create output table
    IF OBJECT_ID('indexing.PrefixConsolidatedGroups', 'U') IS NOT NULL
        DROP TABLE indexing.PrefixConsolidatedGroups;

    CREATE TABLE indexing.PrefixConsolidatedGroups (
        GroupID INT IDENTITY(1,1) PRIMARY KEY,
        ServerName NVARCHAR(128),
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(256),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX),
        OriginalRecommendationIDs NVARCHAR(MAX),
        RecommendationCount INT,
        TotalIndexAdvantage DECIMAL(18,2),
        IsPrefixConsolidated BIT DEFAULT 0,
        OriginalGroupCount INT DEFAULT 1
    );

    -- Track which groups have been absorbed
    DECLARE @AbsorbedGroups TABLE (
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(256),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX)
    );

    -- Create reusable temp tables for cross-coverage merging
    -- Position column preserves original order from covering recommendation
    CREATE TABLE #CrossKeys (KeyCol NVARCHAR(128), Position INT IDENTITY(1,1));
    CREATE TABLE #CrossIncludes (IncludeCol NVARCHAR(128), Position INT IDENTITY(1,1));

    -- Process each group to find prefix and cross-coverage consolidation opportunities
    DECLARE @CurrentServer NVARCHAR(128);
    DECLARE @CurrentDB NVARCHAR(128);
    DECLARE @CurrentTable NVARCHAR(256);
    DECLARE @CurrentKeys NVARCHAR(MAX);
    DECLARE @CurrentIncludes NVARCHAR(MAX);
    DECLARE @CurrentRecIDs NVARCHAR(MAX);
    DECLARE @CurrentRecCount INT;
    DECLARE @CurrentAdvantage DECIMAL(18,2);

    -- Variables for JSON parsing (reusable throughout procedure)
    DECLARE @CurrIncNorm NVARCHAR(MAX);
    DECLARE @CurrIncJSON NVARCHAR(MAX);
    DECLARE @CandIncNorm NVARCHAR(MAX);
    DECLARE @CandIncJSON NVARCHAR(MAX);

    DECLARE group_cursor CURSOR FOR
        SELECT ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
               OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage
        FROM indexing.ConsolidatedRecommendations
        ORDER BY TotalIndexAdvantage DESC;

    OPEN group_cursor;
    FETCH NEXT FROM group_cursor INTO @CurrentServer, @CurrentDB, @CurrentTable, @CurrentKeys, @CurrentIncludes,
                                       @CurrentRecIDs, @CurrentRecCount, @CurrentAdvantage;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Check if this group was already absorbed
        IF EXISTS (SELECT 1 FROM @AbsorbedGroups
                   WHERE DatabaseName = @CurrentDB
                     AND SchemaTable = @CurrentTable
                     AND KeyColumns = @CurrentKeys
                     AND ISNULL(IncludedColumns, '') = ISNULL(@CurrentIncludes, ''))
        BEGIN
            FETCH NEXT FROM group_cursor INTO @CurrentServer, @CurrentDB, @CurrentTable, @CurrentKeys, @CurrentIncludes,
                                               @CurrentRecIDs, @CurrentRecCount, @CurrentAdvantage;
            CONTINUE;
        END

        -- Look for groups that can be merged with this one
        DECLARE @MergeHappened BIT = 0;
        DECLARE @CandidateServer NVARCHAR(128);
        DECLARE @CandidateDB NVARCHAR(128);
        DECLARE @CandidateTable NVARCHAR(256);
        DECLARE @CandidateKeys NVARCHAR(MAX);
        DECLARE @CandidateIncludes NVARCHAR(MAX);
        DECLARE @CandidateRecIDs NVARCHAR(MAX);
        DECLARE @CandidateRecCount INT;
        DECLARE @CandidateAdvantage DECIMAL(18,2);

        DECLARE candidate_cursor CURSOR FOR
            SELECT ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
                   OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage
            FROM indexing.ConsolidatedRecommendations
            WHERE ServerName = @CurrentServer
              AND DatabaseName = @CurrentDB
              AND SchemaTable = @CurrentTable
              AND NOT (KeyColumns = @CurrentKeys AND ISNULL(IncludedColumns, '') = ISNULL(@CurrentIncludes, ''))
            ORDER BY TotalIndexAdvantage DESC;

        OPEN candidate_cursor;
        FETCH NEXT FROM candidate_cursor INTO @CandidateServer, @CandidateDB, @CandidateTable, @CandidateKeys, @CandidateIncludes,
                                               @CandidateRecIDs, @CandidateRecCount, @CandidateAdvantage;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- Skip if already absorbed
            IF EXISTS (SELECT 1 FROM @AbsorbedGroups
                       WHERE DatabaseName = @CandidateDB
                         AND SchemaTable = @CandidateTable
                         AND KeyColumns = @CandidateKeys
                         AND ISNULL(IncludedColumns, '') = ISNULL(@CandidateIncludes, ''))
            BEGIN
                FETCH NEXT FROM candidate_cursor INTO @CandidateServer, @CandidateDB, @CandidateTable, @CandidateKeys, @CandidateIncludes,
                                                       @CandidateRecIDs, @CandidateRecCount, @CandidateAdvantage;
                CONTINUE;
            END

            -- HIGH IMPACT RULE: Check if current group has high-impact recommendations that would lose their position
            DECLARE @CurrentMaxImpact DECIMAL(18,2) = 0;
            SELECT @CurrentMaxImpact = MAX(Impact)
            FROM indexing.IndexRecommendations
            WHERE ServerName = @CurrentServer
              AND DatabaseName = @CurrentDB
              AND SchemaTable = @CurrentTable
              AND KeyColumns = @CurrentKeys;

            DECLARE @CandidateMaxImpact DECIMAL(18,2) = 0;
            SELECT @CandidateMaxImpact = MAX(Impact)
            FROM indexing.IndexRecommendations
            WHERE ServerName = @CandidateServer
              AND DatabaseName = @CandidateDB
              AND SchemaTable = @CandidateTable
              AND KeyColumns = @CandidateKeys;

            -- Check for leftmost prefix consolidation (higher priority than cross-coverage)
            IF indexing.fn_IsLeftmostPrefix(@CurrentKeys, @CandidateKeys) = 1
            BEGIN
                -- Current is a prefix of candidate - merge current into candidate (candidate is broader)
                -- HIGH IMPACT CHECK: If current has high impact (>100000), keys must stay at position 1
                -- This is already guaranteed by leftmost prefix check, but verify
                IF @CurrentMaxImpact > 100000
                BEGIN
                    IF @Debug = 1
                        PRINT '[HIGH-IMPACT] Current impact: ' + CAST(@CurrentMaxImpact AS VARCHAR(20)) +
                              ' - verifying keys remain at position 1';
                END

                IF @Debug = 1
                    PRINT '[PREFIX-CONSOLIDATION] Leftmost prefix: ' + @CurrentKeys +
                          ' -> ' + @CandidateKeys + ' (current is prefix)';

                -- Use candidate's keys (broader), combine includes
                SET @CurrentKeys = @CandidateKeys;

                -- Combine includes
                DECLARE @CombinedIncludes NVARCHAR(MAX) = '';
                IF @CurrentIncludes IS NOT NULL OR @CandidateIncludes IS NOT NULL
                BEGIN
                    TRUNCATE TABLE #CrossIncludes;

                    IF @CurrentIncludes IS NOT NULL AND @CurrentIncludes != ''
                    BEGIN
                        SET @CurrIncNorm = REPLACE(REPLACE(@CurrentIncludes, ', ', '|'), ',', '|');
                        SET @CurrIncJSON = '["' + REPLACE(@CurrIncNorm, '|', '","') + '"]';
                        INSERT INTO #CrossIncludes (IncludeCol)
                        SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                        FROM OPENJSON(@CurrIncJSON);
                    END

                    IF @CandidateIncludes IS NOT NULL AND @CandidateIncludes != ''
                    BEGIN
                        SET @CandIncNorm = REPLACE(REPLACE(@CandidateIncludes, ', ', '|'), ',', '|');
                        SET @CandIncJSON = '["' + REPLACE(@CandIncNorm, '|', '","') + '"]';
                        INSERT INTO #CrossIncludes (IncludeCol)
                        SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                        FROM OPENJSON(@CandIncJSON)
                        WHERE NOT EXISTS (SELECT 1 FROM #CrossIncludes WHERE IncludeCol = TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')));
                    END

                    -- CRITICAL: Remove any includes that are now in the final key list
                    -- Parse final keys into temp table for comparison
                    TRUNCATE TABLE #CrossKeys;
                    INSERT INTO #CrossKeys (KeyCol)
                    SELECT DISTINCT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@CurrentKeys, ',')
                    WHERE TRIM(value) != '';

                    -- Remove includes that are already in keys
                    DELETE FROM #CrossIncludes
                    WHERE IncludeCol IN (SELECT KeyCol FROM #CrossKeys);

                    SELECT @CurrentIncludes = STRING_AGG('[' + IncludeCol + ']', ', ') WITHIN GROUP (ORDER BY Position) FROM #CrossIncludes;
                END

                -- Combine stats
                SET @CurrentRecIDs = @CurrentRecIDs + ',' + @CandidateRecIDs;
                SET @CurrentRecCount = @CurrentRecCount + @CandidateRecCount;
                SET @CurrentAdvantage = @CurrentAdvantage + @CandidateAdvantage;

                -- Mark candidate as absorbed
                INSERT INTO @AbsorbedGroups (DatabaseName, SchemaTable, KeyColumns, IncludedColumns)
                VALUES (@CandidateDB, @CandidateTable, @CandidateKeys, @CandidateIncludes);

                SET @MergeHappened = 1;
            END
            ELSE IF indexing.fn_IsLeftmostPrefix(@CandidateKeys, @CurrentKeys) = 1
            BEGIN
                -- Candidate is a prefix of current - merge candidate into current (current is broader)
                -- HIGH IMPACT CHECK: If candidate has high impact (>100000), keys must stay at position 1
                -- This is already guaranteed by leftmost prefix check, but verify
                IF @CandidateMaxImpact > 100000
                BEGIN
                    IF @Debug = 1
                        PRINT '[HIGH-IMPACT] Candidate impact: ' + CAST(@CandidateMaxImpact AS VARCHAR(20)) +
                              ' - verifying keys remain at position 1';
                END

                IF @Debug = 1
                    PRINT '[PREFIX-CONSOLIDATION] Leftmost prefix: ' + @CandidateKeys +
                          ' -> ' + @CurrentKeys + ' (candidate is prefix)';

                -- Keep current's keys (broader), combine includes
                IF @CandidateIncludes IS NOT NULL OR @CurrentIncludes IS NOT NULL
                BEGIN
                    TRUNCATE TABLE #CrossIncludes;

                    IF @CurrentIncludes IS NOT NULL AND @CurrentIncludes != ''
                    BEGIN
                        SET @CurrIncNorm = REPLACE(REPLACE(@CurrentIncludes, ', ', '|'), ',', '|');
                        SET @CurrIncJSON = '["' + REPLACE(@CurrIncNorm, '|', '","') + '"]';
                        INSERT INTO #CrossIncludes (IncludeCol)
                        SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                        FROM OPENJSON(@CurrIncJSON);
                    END

                    IF @CandidateIncludes IS NOT NULL AND @CandidateIncludes != ''
                    BEGIN
                        SET @CandIncNorm = REPLACE(REPLACE(@CandidateIncludes, ', ', '|'), ',', '|');
                        SET @CandIncJSON = '["' + REPLACE(@CandIncNorm, '|', '","') + '"]';
                        INSERT INTO #CrossIncludes (IncludeCol)
                        SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                        FROM OPENJSON(@CandIncJSON)
                        WHERE NOT EXISTS (SELECT 1 FROM #CrossIncludes WHERE IncludeCol = TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')));
                    END

                    -- CRITICAL: Remove any includes that are now in the final key list
                    -- Parse final keys into temp table for comparison
                    TRUNCATE TABLE #CrossKeys;
                    INSERT INTO #CrossKeys (KeyCol)
                    SELECT DISTINCT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@CurrentKeys, ',')
                    WHERE TRIM(value) != '';

                    -- Remove includes that are already in keys
                    DELETE FROM #CrossIncludes
                    WHERE IncludeCol IN (SELECT KeyCol FROM #CrossKeys);

                    SELECT @CurrentIncludes = STRING_AGG('[' + IncludeCol + ']', ', ') WITHIN GROUP (ORDER BY Position) FROM #CrossIncludes;
                END

                -- Combine stats
                SET @CurrentRecIDs = @CurrentRecIDs + ',' + @CandidateRecIDs;
                SET @CurrentRecCount = @CurrentRecCount + @CandidateRecCount;
                SET @CurrentAdvantage = @CurrentAdvantage + @CandidateAdvantage;

                -- Mark candidate as absorbed
                INSERT INTO @AbsorbedGroups (DatabaseName, SchemaTable, KeyColumns, IncludedColumns)
                VALUES (@CandidateDB, @CandidateTable, @CandidateKeys, @CandidateIncludes);

                SET @MergeHappened = 1;
            END
            -- Check for cross-coverage consolidation opportunity
            -- IMPACT CONSTRAINT: Only allow cross-coverage if BOTH groups have low impact (<100k)
            -- High-impact queries need keys at position 1 to avoid table scans
            ELSE IF (@CurrentMaxImpact < 100000 AND @CandidateMaxImpact < 100000) AND
                    indexing.fn_KeyIncludeCoversGroup(@CurrentKeys, @CurrentIncludes,
                                                  @CandidateKeys, @CandidateIncludes) = 1
            BEGIN
                -- Current group can cover candidate - merge candidate into current (low-impact, coverage-based)
                IF @Debug = 1
                    PRINT '[PREFIX-CONSOLIDATION] Cross-coverage: ' + @CandidateKeys +
                          ' can be covered by ' + @CurrentKeys;

                -- Combine all columns from both groups
                -- Clear reusable temp tables
                TRUNCATE TABLE #CrossKeys;
                TRUNCATE TABLE #CrossIncludes;

                -- Add current group's keys (preserve original order using JSON array parsing)
                -- First normalize spacing: replace both ", " and "," with "|" delimiter
                DECLARE @CurrentKeysNorm NVARCHAR(MAX) = REPLACE(REPLACE(@CurrentKeys, ', ', '|'), ',', '|');
                DECLARE @CurrentKeysJSON NVARCHAR(MAX) = '["' + REPLACE(@CurrentKeysNorm, '|', '","') + '"]';
                INSERT INTO #CrossKeys (KeyCol)
                SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                FROM OPENJSON(@CurrentKeysJSON);

                -- Add candidate's keys (promote to keys if not already there)
                INSERT INTO #CrossKeys (KeyCol)
                SELECT DISTINCT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                FROM STRING_SPLIT(@CandidateKeys, ',')
                WHERE TRIM(value) != ''
                  AND NOT EXISTS (SELECT 1 FROM #CrossKeys WHERE KeyCol = TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')));

                -- Add current group's includes (preserve order using JSON array parsing)
                IF @CurrentIncludes IS NOT NULL AND @CurrentIncludes != ''
                BEGIN
                    SET @CurrIncNorm = REPLACE(REPLACE(@CurrentIncludes, ', ', '|'), ',', '|');
                    SET @CurrIncJSON = '["' + REPLACE(@CurrIncNorm, '|', '","') + '"]';
                    INSERT INTO #CrossIncludes (IncludeCol)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM OPENJSON(@CurrIncJSON);
                END

                -- Add candidate's includes (only new ones, preserving their order)
                IF @CandidateIncludes IS NOT NULL AND @CandidateIncludes != ''
                BEGIN
                    SET @CandIncNorm = REPLACE(REPLACE(@CandidateIncludes, ', ', '|'), ',', '|');
                    SET @CandIncJSON = '["' + REPLACE(@CandIncNorm, '|', '","') + '"]';
                    INSERT INTO #CrossIncludes (IncludeCol)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM OPENJSON(@CandIncJSON)
                    WHERE NOT EXISTS (SELECT 1 FROM #CrossIncludes WHERE IncludeCol = TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')));
                END

                -- Remove includes that are now in keys
                DELETE FROM #CrossIncludes
                WHERE IncludeCol IN (SELECT KeyCol FROM #CrossKeys);

                -- Build merged column lists (preserve original key order from covering recommendation)
                SELECT @CurrentKeys = STRING_AGG('[' + KeyCol + ']', ', ') WITHIN GROUP (ORDER BY Position) FROM #CrossKeys;
                SELECT @CurrentIncludes = STRING_AGG('[' + IncludeCol + ']', ', ') WITHIN GROUP (ORDER BY Position) FROM #CrossIncludes;

                -- Combine recommendation IDs and stats
                SET @CurrentRecIDs = @CurrentRecIDs + ',' + @CandidateRecIDs;
                SET @CurrentRecCount = @CurrentRecCount + @CandidateRecCount;
                SET @CurrentAdvantage = @CurrentAdvantage + @CandidateAdvantage;

                -- Mark candidate as absorbed
                INSERT INTO @AbsorbedGroups (DatabaseName, SchemaTable, KeyColumns, IncludedColumns)
                VALUES (@CandidateDB, @CandidateTable, @CandidateKeys, @CandidateIncludes);

                SET @MergeHappened = 1;
            END
            ELSE IF (@CurrentMaxImpact < 100000 AND @CandidateMaxImpact < 100000) AND
                    indexing.fn_KeyIncludeCoversGroup(@CandidateKeys, @CandidateIncludes,
                                                       @CurrentKeys, @CurrentIncludes) = 1
            BEGIN
                -- Candidate can cover current - merge current into candidate (low-impact, coverage-based)
                IF @Debug = 1
                    PRINT '[PREFIX-CONSOLIDATION] Cross-coverage: ' + @CurrentKeys +
                          ' can be covered by ' + @CandidateKeys;

                -- Combine all columns (candidate becomes the master)
                -- Clear reusable temp tables
                TRUNCATE TABLE #CrossKeys;
                TRUNCATE TABLE #CrossIncludes;

                -- Add candidate's keys first (preserve original order using JSON array parsing)
                -- First normalize spacing: replace both ", " and "," with "|" delimiter
                DECLARE @CandidateKeysNorm NVARCHAR(MAX) = REPLACE(REPLACE(@CandidateKeys, ', ', '|'), ',', '|');
                DECLARE @CandidateKeysJSON NVARCHAR(MAX) = '["' + REPLACE(@CandidateKeysNorm, '|', '","') + '"]';
                INSERT INTO #CrossKeys (KeyCol)
                SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                FROM OPENJSON(@CandidateKeysJSON);

                -- Add current's keys (promote if not there)
                INSERT INTO #CrossKeys (KeyCol)
                SELECT DISTINCT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                FROM STRING_SPLIT(@CurrentKeys, ',')
                WHERE TRIM(value) != ''
                  AND NOT EXISTS (SELECT 1 FROM #CrossKeys WHERE KeyCol = TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')));

                -- Add candidate's includes first (preserve order using JSON array parsing)
                IF @CandidateIncludes IS NOT NULL AND @CandidateIncludes != ''
                BEGIN
                    SET @CandIncNorm = REPLACE(REPLACE(@CandidateIncludes, ', ', '|'), ',', '|');
                    SET @CandIncJSON = '["' + REPLACE(@CandIncNorm, '|', '","') + '"]';
                    INSERT INTO #CrossIncludes (IncludeCol)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM OPENJSON(@CandIncJSON);
                END

                -- Add current's includes (only new ones, preserving their order)
                IF @CurrentIncludes IS NOT NULL AND @CurrentIncludes != ''
                BEGIN
                    SET @CurrIncNorm = REPLACE(REPLACE(@CurrentIncludes, ', ', '|'), ',', '|');
                    SET @CurrIncJSON = '["' + REPLACE(@CurrIncNorm, '|', '","') + '"]';
                    INSERT INTO #CrossIncludes (IncludeCol)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM OPENJSON(@CurrIncJSON)
                    WHERE NOT EXISTS (SELECT 1 FROM #CrossIncludes WHERE IncludeCol = TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')));
                END

                -- Remove includes in keys
                DELETE FROM #CrossIncludes
                WHERE IncludeCol IN (SELECT KeyCol FROM #CrossKeys);

                -- Build merged column lists (preserve original key order from covering recommendation)
                SELECT @CurrentKeys = STRING_AGG('[' + KeyCol + ']', ', ') WITHIN GROUP (ORDER BY Position) FROM #CrossKeys;
                SELECT @CurrentIncludes = STRING_AGG('[' + IncludeCol + ']', ', ') WITHIN GROUP (ORDER BY Position) FROM #CrossIncludes;

                -- Combine stats
                SET @CurrentRecIDs = @CurrentRecIDs + ',' + @CandidateRecIDs;
                SET @CurrentRecCount = @CurrentRecCount + @CandidateRecCount;
                SET @CurrentAdvantage = @CurrentAdvantage + @CandidateAdvantage;

                -- Mark candidate as absorbed
                INSERT INTO @AbsorbedGroups (DatabaseName, SchemaTable, KeyColumns, IncludedColumns)
                VALUES (@CandidateDB, @CandidateTable, @CandidateKeys, @CandidateIncludes);

                SET @MergeHappened = 1;
            END

            FETCH NEXT FROM candidate_cursor INTO @CandidateServer, @CandidateDB, @CandidateTable, @CandidateKeys, @CandidateIncludes,
                                                   @CandidateRecIDs, @CandidateRecCount, @CandidateAdvantage;
        END

        CLOSE candidate_cursor;
        DEALLOCATE candidate_cursor;

        -- Insert the (possibly merged) current group into output
        INSERT INTO indexing.PrefixConsolidatedGroups (
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
            IsPrefixConsolidated, OriginalGroupCount
        )
        VALUES (
            @CurrentServer, @CurrentDB, @CurrentTable, @CurrentKeys, @CurrentIncludes,
            @CurrentRecIDs, @CurrentRecCount, @CurrentAdvantage,
            CASE WHEN @MergeHappened = 1 THEN 1 ELSE 0 END,
            CASE WHEN @MergeHappened = 1 THEN 2 ELSE 1 END  -- At least 2 if merged
        );

        FETCH NEXT FROM group_cursor INTO @CurrentServer, @CurrentDB, @CurrentTable, @CurrentKeys, @CurrentIncludes,
                                           @CurrentRecIDs, @CurrentRecCount, @CurrentAdvantage;
    END

    CLOSE group_cursor;
    DEALLOCATE group_cursor;

    -- Temp tables will be automatically dropped at procedure end

    -- Report results
    DECLARE @OriginalCount INT = (SELECT COUNT(*) FROM indexing.ConsolidatedRecommendations);
    DECLARE @PrefixCount INT = (SELECT COUNT(*) FROM indexing.PrefixConsolidatedGroups);
    DECLARE @MergedCount INT = (SELECT COUNT(*) FROM indexing.PrefixConsolidatedGroups WHERE IsPrefixConsolidated = 1);

    IF @Debug = 1
    BEGIN
        PRINT '[PREFIX-CONSOLIDATION] Result: ' + CAST(@OriginalCount AS VARCHAR(10)) +
              ' groups -> ' + CAST(@PrefixCount AS VARCHAR(10)) + ' prefix-consolidated groups';
        PRINT '[PREFIX-CONSOLIDATION] Cross-coverage merges applied: ' + CAST(@MergedCount AS VARCHAR(10));
    END
END
GO

PRINT 'Stored procedure sp_ApplyPrefixConsolidation created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.sp_ApplySuperConsolidation', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_ApplySuperConsolidation;
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE indexing.sp_ApplySuperConsolidation
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Create super-consolidated groups table
    IF OBJECT_ID('indexing.SuperConsolidatedGroups', 'U') IS NOT NULL DROP TABLE indexing.SuperConsolidatedGroups;

    CREATE TABLE indexing.SuperConsolidatedGroups (
        GroupID INT IDENTITY(1,1) PRIMARY KEY,
        ServerName NVARCHAR(128),
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(256),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX),
        OriginalRecommendationIDs NVARCHAR(MAX),
        RecommendationCount INT,
        TotalIndexAdvantage DECIMAL(18,2),
        IsSuperConsolidated BIT DEFAULT 0,
        OriginalGroupCount INT DEFAULT 1
    );

    IF @Debug = 1 PRINT '[SUPER-CONSOLIDATION] Starting super-consolidation analysis...';

    -- Track which groups have been processed (by unique identifier, not RowID)
    DECLARE @ProcessedGroups TABLE (
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(256),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX)
    );

    -- Get count of prefix-consolidated groups to process
    DECLARE @TotalGroups INT = (SELECT COUNT(*) FROM indexing.PrefixConsolidatedGroups);
    IF @Debug = 1 PRINT '[SUPER-CONSOLIDATION] Analyzing ' + CAST(@TotalGroups AS VARCHAR(10)) + ' groups for super-consolidation';

    IF @TotalGroups <= 1
    BEGIN
        -- Nothing to super-consolidate, just copy to output table
        INSERT INTO indexing.SuperConsolidatedGroups (
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
            IsSuperConsolidated, OriginalGroupCount
        )
        SELECT
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
            0, 1
        FROM indexing.PrefixConsolidatedGroups;

        IF @Debug = 1 PRINT '[SUPER-CONSOLIDATION] Not enough groups to consolidate';
        RETURN;
    END

    -- Process each group to find super-consolidation opportunities
    DECLARE @CurrentID INT;
    DECLARE @CurrentServer NVARCHAR(128);
    DECLARE @DatabaseName NVARCHAR(128);
    DECLARE @SchemaTable NVARCHAR(256);
    DECLARE @KeyColumns NVARCHAR(MAX);
    DECLARE @IncludedColumns NVARCHAR(MAX);
    DECLARE @RecIDs NVARCHAR(MAX);
    DECLARE @RecCount INT;
    DECLARE @Advantage DECIMAL(18,2);

    DECLARE group_cursor CURSOR FOR
        SELECT
            ROW_NUMBER() OVER (ORDER BY TotalIndexAdvantage DESC) AS RowID,
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage
        FROM indexing.PrefixConsolidatedGroups
        ORDER BY TotalIndexAdvantage DESC;

    OPEN group_cursor;
    FETCH NEXT FROM group_cursor INTO @CurrentID, @CurrentServer, @DatabaseName, @SchemaTable, @KeyColumns,
                                       @IncludedColumns, @RecIDs, @RecCount, @Advantage;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Check if this group has already been processed
        IF EXISTS (SELECT 1 FROM @ProcessedGroups
                   WHERE DatabaseName = @DatabaseName
                     AND SchemaTable = @SchemaTable
                     AND KeyColumns = @KeyColumns
                     AND ISNULL(IncludedColumns, '') = ISNULL(@IncludedColumns, ''))
        BEGIN
            FETCH NEXT FROM group_cursor INTO @CurrentID, @CurrentServer, @DatabaseName, @SchemaTable, @KeyColumns,
                                               @IncludedColumns, @RecIDs, @RecCount, @Advantage;
            CONTINUE;
        END

        -- Mark this group as processed
        INSERT INTO @ProcessedGroups (DatabaseName, SchemaTable, KeyColumns, IncludedColumns)
        VALUES (@DatabaseName, @SchemaTable, @KeyColumns, @IncludedColumns);

        -- Start a potential super-group with this group
        -- CRITICAL: Use temp table, not table variable, to ensure clean slate each iteration
        IF OBJECT_ID('tempdb..#SuperGroupCandidates') IS NOT NULL DROP TABLE #SuperGroupCandidates;
        CREATE TABLE #SuperGroupCandidates (
            GroupID INT,
            KeyColumns NVARCHAR(MAX),
            IncludedColumns NVARCHAR(MAX),
            RecIDs NVARCHAR(MAX),
            RecCount INT,
            Advantage DECIMAL(18,2)
        );

        INSERT INTO #SuperGroupCandidates VALUES (@CurrentID, @KeyColumns, @IncludedColumns, @RecIDs, @RecCount, @Advantage);

        -- HIGH IMPACT CHECK: Skip super-consolidation if current group has high-impact recommendations
        DECLARE @CurrentHasHighImpact BIT = 0;
        IF EXISTS (
            SELECT 1 FROM indexing.IndexRecommendations
            WHERE ServerName = @CurrentServer
              AND DatabaseName = @DatabaseName
              AND SchemaTable = @SchemaTable
              AND KeyColumns = @KeyColumns
              AND Impact > 100000
        )
        BEGIN
            SET @CurrentHasHighImpact = 1;
            IF @Debug = 1 PRINT '[HIGH-IMPACT BLOCK] Current group with keys ' + @KeyColumns +
                                ' has high impact - skipping super-consolidation';

            -- Skip super-consolidation for this group, add it as-is to output
            INSERT INTO indexing.SuperConsolidatedGroups (
                ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
                OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
                IsSuperConsolidated, OriginalGroupCount
            )
            VALUES (@CurrentServer, @DatabaseName, @SchemaTable, @KeyColumns, @IncludedColumns,
                    @RecIDs, @RecCount, @Advantage, 0, 1);

            FETCH NEXT FROM group_cursor INTO @CurrentID, @CurrentServer, @DatabaseName, @SchemaTable, @KeyColumns,
                                               @IncludedColumns, @RecIDs, @RecCount, @Advantage;
            CONTINUE;
        END

        -- Get first key column from current group for comparison
        DECLARE @CurrentFirstKey NVARCHAR(128);
        SET @CurrentFirstKey = CASE
            WHEN CHARINDEX(',', @KeyColumns) > 0
            THEN SUBSTRING(@KeyColumns, 1, CHARINDEX(',', @KeyColumns) - 1)
            ELSE @KeyColumns
        END;

        -- Look for other groups that can be merged with this one
        DECLARE @CandidateID INT;
        DECLARE @CandidateKeys NVARCHAR(MAX);
        DECLARE @CandidateIncludes NVARCHAR(MAX);
        DECLARE @CandidateRecIDs NVARCHAR(MAX);
        DECLARE @CandidateRecCount INT;
        DECLARE @CandidateAdvantage DECIMAL(18,2);

        -- Create temp table with row IDs for candidates
        IF OBJECT_ID('tempdb..#CandidateGroups') IS NOT NULL DROP TABLE #CandidateGroups;

        CREATE TABLE #CandidateGroups (
            RowID INT,
            KeyColumns NVARCHAR(MAX),
            IncludedColumns NVARCHAR(MAX),
            RecIDs NVARCHAR(MAX),
            RecCount INT,
            Advantage DECIMAL(18,2)
        );

        INSERT INTO #CandidateGroups (RowID, KeyColumns, IncludedColumns, RecIDs, RecCount, Advantage)
        SELECT
            ROW_NUMBER() OVER (ORDER BY TotalIndexAdvantage DESC) AS RowID,
            KeyColumns, IncludedColumns, OriginalRecommendationIDs,
            RecommendationCount, TotalIndexAdvantage
        FROM indexing.PrefixConsolidatedGroups
        WHERE ServerName = @CurrentServer
          AND DatabaseName = @DatabaseName
          AND SchemaTable = @SchemaTable
        ORDER BY TotalIndexAdvantage DESC;

        DECLARE candidate_cursor CURSOR FOR
            SELECT RowID, KeyColumns, IncludedColumns, RecIDs, RecCount, Advantage
            FROM #CandidateGroups
            ORDER BY Advantage DESC;

        OPEN candidate_cursor;
        FETCH NEXT FROM candidate_cursor INTO @CandidateID, @CandidateKeys, @CandidateIncludes,
                                               @CandidateRecIDs, @CandidateRecCount, @CandidateAdvantage;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- Skip if already processed
            IF EXISTS (SELECT 1 FROM @ProcessedGroups
                       WHERE DatabaseName = @DatabaseName
                         AND SchemaTable = @SchemaTable
                         AND KeyColumns = @CandidateKeys
                         AND ISNULL(IncludedColumns, '') = ISNULL(@CandidateIncludes, ''))
            BEGIN
                FETCH NEXT FROM candidate_cursor INTO @CandidateID, @CandidateKeys, @CandidateIncludes,
                                                       @CandidateRecIDs, @CandidateRecCount, @CandidateAdvantage;
                CONTINUE;
            END

            -- Get first key column from candidate for comparison
            DECLARE @CandidateFirstKey NVARCHAR(128);
            SET @CandidateFirstKey = CASE
                WHEN CHARINDEX(',', @CandidateKeys) > 0
                THEN SUBSTRING(@CandidateKeys, 1, CHARINDEX(',', @CandidateKeys) - 1)
                ELSE @CandidateKeys
            END;

            -- HIGH IMPACT CHECK: Verify candidate doesn't have high-impact recommendations
            -- that would lose their key column position
            DECLARE @CandidateHasHighImpact BIT = 0;
            IF EXISTS (
                SELECT 1 FROM indexing.IndexRecommendations
                WHERE ServerName = @CurrentServer
                  AND DatabaseName = @DatabaseName
                  AND SchemaTable = @SchemaTable
                  AND KeyColumns = @CandidateKeys
                  AND Impact > 100000
            )
            BEGIN
                SET @CandidateHasHighImpact = 1;
            END

            -- Check if this candidate can be super-consolidated with current group
            IF indexing.fn_CanSuperConsolidateGroups(@IncludedColumns, @CurrentFirstKey,
                                                      @CandidateIncludes, @CandidateFirstKey) = 1
            BEGIN
                -- HIGH IMPACT BLOCK: Don't super-consolidate if candidate has high impact
                -- and its keys might be reordered
                IF @CandidateHasHighImpact = 1
                BEGIN
                    IF @Debug = 1 PRINT '[HIGH-IMPACT BLOCK] Candidate with keys ' + @CandidateKeys +
                                        ' has high impact - cannot super-consolidate to avoid key reordering';
                END
                ELSE
                BEGIN
                    -- Add to super-group candidates
                    INSERT INTO #SuperGroupCandidates VALUES (@CandidateID, @CandidateKeys, @CandidateIncludes,
                                                              @CandidateRecIDs, @CandidateRecCount, @CandidateAdvantage);
                    INSERT INTO @ProcessedGroups (DatabaseName, SchemaTable, KeyColumns, IncludedColumns)
                    VALUES (@DatabaseName, @SchemaTable, @CandidateKeys, @CandidateIncludes);

                    IF @Debug = 1 PRINT '[SUPER-CONSOLIDATION] Group with keys ' + @CandidateKeys +
                                        ' can be merged with super-group';
                END
            END

            FETCH NEXT FROM candidate_cursor INTO @CandidateID, @CandidateKeys, @CandidateIncludes,
                                                   @CandidateRecIDs, @CandidateRecCount, @CandidateAdvantage;
        END

        CLOSE candidate_cursor;
        DEALLOCATE candidate_cursor;

        -- Check if we found multiple groups to merge
        DECLARE @CandidateCount INT = (SELECT COUNT(*) FROM #SuperGroupCandidates);

        IF @CandidateCount > 1
        BEGIN
            -- Create super-consolidated group
            DECLARE @SuperKeys NVARCHAR(MAX) = '';
            DECLARE @SuperIncludes NVARCHAR(MAX) = '';
            DECLARE @SuperRecIDs NVARCHAR(MAX) = '';
            DECLARE @SuperRecCount INT = 0;
            DECLARE @SuperAdvantage DECIMAL(18,2) = 0;

            -- Use temp tables instead of table variables to ensure they're fresh each iteration
            IF OBJECT_ID('tempdb..#SuperKeys') IS NOT NULL DROP TABLE #SuperKeys;
            IF OBJECT_ID('tempdb..#SuperIncludes') IS NOT NULL DROP TABLE #SuperIncludes;

            CREATE TABLE #SuperKeys (Position INT IDENTITY(1,1), KeyCol NVARCHAR(128));
            CREATE TABLE #SuperIncludes (Position INT IDENTITY(1,1), IncludeCol NVARCHAR(128));

            -- CRITICAL FIX (2026-02-27): Rebuild keys from ORIGINAL recommendations ordered by IMPACT DESC
            -- This matches Python's approach: highest-impact recommendation becomes master
            -- Get ALL original recommendations from ALL groups being merged
            IF OBJECT_ID('tempdb..#OriginalRecs') IS NOT NULL DROP TABLE #OriginalRecs;
            CREATE TABLE #OriginalRecs (
                RecommendationID INT,
                Impact DECIMAL(18,2),
                IndexAdvantage DECIMAL(18,2),
                KeyColumns NVARCHAR(MAX),
                IncludedColumns NVARCHAR(MAX)
            );

            -- Collect all recommendation IDs from all candidate groups
            INSERT INTO #OriginalRecs (RecommendationID, Impact, IndexAdvantage, KeyColumns, IncludedColumns)
            SELECT DISTINCT
                ir.RecommendationID,
                ir.Impact,
                ir.IndexAdvantage,
                ir.KeyColumns,
                ir.IncludedColumns
            FROM indexing.IndexRecommendations ir
            INNER JOIN #SuperGroupCandidates sc
                ON ir.ServerName = @CurrentServer
                AND ir.DatabaseName = @DatabaseName
                AND ir.SchemaTable = @SchemaTable
                AND ir.RecommendationID IN (
                    SELECT CAST(value AS INT)
                    FROM STRING_SPLIT(sc.RecIDs, ',')
                )
            ORDER BY ir.Impact DESC, ir.IndexAdvantage DESC;

            -- Process original recommendations in IMPACT order (DESC)
            -- Start with highest-impact recommendation's key order as master
            DECLARE @OrigRecID INT;
            DECLARE @OrigRecKeys NVARCHAR(MAX);
            DECLARE @OrigRecIncludes NVARCHAR(MAX);

            DECLARE orig_rec_cursor CURSOR FOR
                SELECT KeyColumns, IncludedColumns
                FROM #OriginalRecs
                ORDER BY Impact DESC, IndexAdvantage DESC;

            OPEN orig_rec_cursor;
            FETCH NEXT FROM orig_rec_cursor INTO @OrigRecKeys, @OrigRecIncludes;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Add key columns from this recommendation (preserving its order)
                INSERT INTO #SuperKeys (KeyCol)
                SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                FROM STRING_SPLIT(@OrigRecKeys, ',')
                WHERE TRIM(value) != ''
                  AND NOT EXISTS (SELECT 1 FROM #SuperKeys WHERE KeyCol = TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')));

                FETCH NEXT FROM orig_rec_cursor INTO @OrigRecKeys, @OrigRecIncludes;
            END

            CLOSE orig_rec_cursor;
            DEALLOCATE orig_rec_cursor;

            -- Collect include columns from original recommendations (same IMPACT order as keys)
            -- Process by Impact DESC to preserve highest-impact recommendation's include order
            DECLARE orig_inc_cursor CURSOR FOR
                SELECT IncludedColumns
                FROM #OriginalRecs
                WHERE IncludedColumns IS NOT NULL
                ORDER BY Impact DESC, IndexAdvantage DESC;

            OPEN orig_inc_cursor;
            FETCH NEXT FROM orig_inc_cursor INTO @CandidateIncludes;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                INSERT INTO #SuperIncludes (IncludeCol)
                SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                FROM STRING_SPLIT(@CandidateIncludes, ',')
                WHERE TRIM(value) != ''
                  AND NOT EXISTS (SELECT 1 FROM #SuperIncludes WHERE IncludeCol = TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')));

                FETCH NEXT FROM orig_inc_cursor INTO @CandidateIncludes;
            END

            CLOSE orig_inc_cursor;
            DEALLOCATE orig_inc_cursor;

            -- Remove any columns from includes that are already in keys (avoid duplicates)
            DELETE FROM #SuperIncludes
            WHERE IncludeCol IN (SELECT KeyCol FROM #SuperKeys);

            -- Build super key columns (preserving insertion order via Position)
            SELECT @SuperKeys = STRING_AGG('[' + KeyCol + ']', ', ') WITHIN GROUP (ORDER BY Position)
            FROM #SuperKeys;

            -- Build super include columns (preserving insertion order via Position)
            SELECT @SuperIncludes = STRING_AGG('[' + IncludeCol + ']', ', ') WITHIN GROUP (ORDER BY Position)
            FROM #SuperIncludes;

            -- Combine recommendation IDs and counts
            SELECT
                @SuperRecIDs = STRING_AGG(RecIDs, ','),
                @SuperRecCount = SUM(RecCount),
                @SuperAdvantage = SUM(Advantage)
            FROM #SuperGroupCandidates;

            -- Insert super-consolidated group
            INSERT INTO indexing.SuperConsolidatedGroups (
                ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
                OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
                IsSuperConsolidated, OriginalGroupCount
            )
            VALUES (
                @CurrentServer, @DatabaseName, @SchemaTable, @SuperKeys, @SuperIncludes,
                @SuperRecIDs, @SuperRecCount, @SuperAdvantage,
                1, @CandidateCount
            );

            IF @Debug = 1 PRINT '[SUPER-CONSOLIDATION] Created super-group covering ' +
                                CAST(@CandidateCount AS VARCHAR(10)) + ' original groups';

            -- Clean up temp tables for this super-group
            IF OBJECT_ID('tempdb..#SuperKeys') IS NOT NULL DROP TABLE #SuperKeys;
            IF OBJECT_ID('tempdb..#SuperIncludes') IS NOT NULL DROP TABLE #SuperIncludes;
        END
        ELSE
        BEGIN
            -- Single group, no consolidation possible
            INSERT INTO indexing.SuperConsolidatedGroups (
                ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
                OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
                IsSuperConsolidated, OriginalGroupCount
            )
            VALUES (
                @CurrentServer, @DatabaseName, @SchemaTable, @KeyColumns, @IncludedColumns,
                @RecIDs, @RecCount, @Advantage,
                0, 1
            );
        END

        -- Clean up temp table for next iteration (SuperGroupCandidates is dropped at start of loop)
        IF OBJECT_ID('tempdb..#CandidateGroups') IS NOT NULL DROP TABLE #CandidateGroups;

        FETCH NEXT FROM group_cursor INTO @CurrentID, @CurrentServer, @DatabaseName, @SchemaTable, @KeyColumns,
                                           @IncludedColumns, @RecIDs, @RecCount, @Advantage;
    END

    CLOSE group_cursor;
    DEALLOCATE group_cursor;

    -- Final cleanup of temp tables
    IF OBJECT_ID('tempdb..#SuperGroupCandidates') IS NOT NULL DROP TABLE #SuperGroupCandidates;
    IF OBJECT_ID('tempdb..#CandidateGroups') IS NOT NULL DROP TABLE #CandidateGroups;
    IF OBJECT_ID('tempdb..#SuperKeys') IS NOT NULL DROP TABLE #SuperKeys;
    IF OBJECT_ID('tempdb..#SuperIncludes') IS NOT NULL DROP TABLE #SuperIncludes;

    -- Report results
    DECLARE @OriginalCount INT = @TotalGroups;
    DECLARE @SuperCount INT = (SELECT COUNT(*) FROM indexing.SuperConsolidatedGroups);
    DECLARE @SuperConsCount INT = (SELECT COUNT(*) FROM indexing.SuperConsolidatedGroups WHERE IsSuperConsolidated = 1);

    IF @Debug = 1
    BEGIN
        PRINT '[SUPER-CONSOLIDATION] Result: ' + CAST(@OriginalCount AS VARCHAR(10)) +
              ' groups -> ' + CAST(@SuperCount AS VARCHAR(10)) + ' super-groups';
        PRINT '[SUPER-CONSOLIDATION] Super-consolidated groups created: ' + CAST(@SuperConsCount AS VARCHAR(10));
    END
END
GO

PRINT 'Stored procedure sp_ApplySuperConsolidation created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.sp_RemoveRedundantAfterSuperConsolidation', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_RemoveRedundantAfterSuperConsolidation;
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE indexing.sp_RemoveRedundantAfterSuperConsolidation
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Create cleaned groups table
    IF OBJECT_ID('indexing.CleanedConsolidatedGroups', 'U') IS NOT NULL DROP TABLE indexing.CleanedConsolidatedGroups;

    CREATE TABLE indexing.CleanedConsolidatedGroups (
        GroupID INT IDENTITY(1,1) PRIMARY KEY,
        ServerName NVARCHAR(128),
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(256),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX),
        OriginalRecommendationIDs NVARCHAR(MAX),
        RecommendationCount INT,
        TotalIndexAdvantage DECIMAL(18,2),
        IsSuperConsolidated BIT DEFAULT 0,
        OriginalGroupCount INT DEFAULT 1
    );

    DECLARE @TotalGroups INT = (SELECT COUNT(*) FROM indexing.SuperConsolidatedGroups);

    IF @Debug = 1 PRINT '[POST-SUPER-CLEANUP] Analyzing ' + CAST(@TotalGroups AS VARCHAR(10)) + ' groups for redundancy cleanup';

    IF @TotalGroups <= 1
    BEGIN
        -- Nothing to clean up, just copy to output
        INSERT INTO indexing.CleanedConsolidatedGroups (
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
            IsSuperConsolidated, OriginalGroupCount
        )
        SELECT
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
            IsSuperConsolidated, OriginalGroupCount
        FROM indexing.SuperConsolidatedGroups;

        IF @Debug = 1 PRINT '[POST-SUPER-CLEANUP] Not enough groups to analyze for cleanup';
        RETURN;
    END

    -- Separate super-consolidated groups from individual groups
    DECLARE @SuperGroups TABLE (
        GroupID INT,
        ServerName NVARCHAR(128),
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(256),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX),
        OriginalRecommendationIDs NVARCHAR(MAX),
        RecommendationCount INT,
        TotalIndexAdvantage DECIMAL(18,2),
        OriginalGroupCount INT
    );

    DECLARE @IndividualGroups TABLE (
        GroupID INT,
        ServerName NVARCHAR(128),
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(256),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX),
        OriginalRecommendationIDs NVARCHAR(MAX),
        RecommendationCount INT,
        TotalIndexAdvantage DECIMAL(18,2)
    );

    -- Populate super-groups
    INSERT INTO @SuperGroups (
        GroupID, ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
        OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage, OriginalGroupCount
    )
    SELECT
        GroupID, ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
        OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage, OriginalGroupCount
    FROM indexing.SuperConsolidatedGroups
    WHERE IsSuperConsolidated = 1;

    -- Populate individual groups
    INSERT INTO @IndividualGroups (
        GroupID, ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
        OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage
    )
    SELECT
        GroupID, ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
        OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage
    FROM indexing.SuperConsolidatedGroups
    WHERE IsSuperConsolidated = 0;

    DECLARE @SuperGroupCount INT = (SELECT COUNT(*) FROM @SuperGroups);
    DECLARE @IndividualGroupCount INT = (SELECT COUNT(*) FROM @IndividualGroups);

    IF @Debug = 1 PRINT '[POST-SUPER-CLEANUP] Found ' + CAST(@SuperGroupCount AS VARCHAR(10)) +
                        ' super-groups and ' + CAST(@IndividualGroupCount AS VARCHAR(10)) + ' individual groups';

    IF @SuperGroupCount = 0
    BEGIN
        -- No super-groups, just copy all to output
        INSERT INTO indexing.CleanedConsolidatedGroups (
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
            IsSuperConsolidated, OriginalGroupCount
        )
        SELECT
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
            IsSuperConsolidated, OriginalGroupCount
        FROM indexing.SuperConsolidatedGroups;

        IF @Debug = 1 PRINT '[POST-SUPER-CLEANUP] No super-consolidated groups found, nothing to clean';
        RETURN;
    END

    -- First, check super-groups against each other for redundancy
    DECLARE @NonRedundantSuperGroups TABLE (
        GroupID INT,
        ServerName NVARCHAR(128),
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(256),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX),
        OriginalRecommendationIDs NVARCHAR(MAX),
        RecommendationCount INT,
        TotalIndexAdvantage DECIMAL(18,2),
        OriginalGroupCount INT
    );

    -- Check each super-group to see if it's covered by another (larger) super-group
    -- Mark covered groups and accumulate their recommendations into covering groups
    DECLARE @SuperID INT;
    DECLARE @SuperServer NVARCHAR(128);
    DECLARE @SuperDB NVARCHAR(128);
    DECLARE @SuperTable NVARCHAR(256);
    DECLARE @SuperKeys NVARCHAR(MAX);
    DECLARE @SuperIncludes NVARCHAR(MAX);
    DECLARE @SuperRecIDs NVARCHAR(MAX);
    DECLARE @SuperRecCount INT;
    DECLARE @SuperAdvantage DECIMAL(18,2);
    DECLARE @SuperOriginalCount INT;

    -- Track which groups are covered (to be removed)
    DECLARE @CoveredGroups TABLE (GroupID INT);

    DECLARE super_cursor CURSOR FOR
        SELECT GroupID, ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
               OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage, OriginalGroupCount
        FROM @SuperGroups
        ORDER BY LEN(KeyColumns) ASC;  -- Process smaller groups first, so they get absorbed into larger ones

    OPEN super_cursor;
    FETCH NEXT FROM super_cursor INTO @SuperID, @SuperServer, @SuperDB, @SuperTable, @SuperKeys, @SuperIncludes,
                                       @SuperRecIDs, @SuperRecCount, @SuperAdvantage, @SuperOriginalCount;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Check if this super-group is covered by any OTHER super-group
        DECLARE @CoveringGroupID INT = NULL;

        SELECT TOP 1 @CoveringGroupID = covering.GroupID
        FROM @SuperGroups covering
        WHERE covering.GroupID != @SuperID
          AND covering.ServerName = @SuperServer
          AND covering.DatabaseName = @SuperDB
          AND covering.SchemaTable = @SuperTable
          AND indexing.fn_SuperGroupCoversIndividual(
                covering.KeyColumns, covering.IncludedColumns,
                @SuperKeys, @SuperIncludes
              ) = 1
        ORDER BY LEN(covering.KeyColumns) DESC;  -- Prefer the most comprehensive covering group

        IF @CoveringGroupID IS NOT NULL
        BEGIN
            IF @Debug = 1 PRINT '[POST-SUPER-CLEANUP] Super-group ' + @SuperKeys + ' is covered by GroupID ' + CAST(@CoveringGroupID AS VARCHAR(10));

            -- Merge this covered group's recommendations into the covering group
            UPDATE @SuperGroups
            SET OriginalRecommendationIDs = OriginalRecommendationIDs + ',' + @SuperRecIDs,
                RecommendationCount = RecommendationCount + @SuperRecCount,
                TotalIndexAdvantage = TotalIndexAdvantage + @SuperAdvantage,
                OriginalGroupCount = OriginalGroupCount + @SuperOriginalCount
            WHERE GroupID = @CoveringGroupID;

            -- Mark this group as covered (to be excluded from final output)
            INSERT INTO @CoveredGroups (GroupID) VALUES (@SuperID);

            IF @Debug = 1 PRINT '[POST-SUPER-CLEANUP] Merged ' + CAST(@SuperRecCount AS VARCHAR(10)) +
                                ' recommendations into covering group';
        END

        FETCH NEXT FROM super_cursor INTO @SuperID, @SuperServer, @SuperDB, @SuperTable, @SuperKeys, @SuperIncludes,
                                           @SuperRecIDs, @SuperRecCount, @SuperAdvantage, @SuperOriginalCount;
    END

    CLOSE super_cursor;
    DEALLOCATE super_cursor;

    -- Insert all non-covered super-groups (now with accumulated recommendation counts)
    INSERT INTO @NonRedundantSuperGroups (
        GroupID, ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
        OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage, OriginalGroupCount
    )
    SELECT
        GroupID, ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
        OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage, OriginalGroupCount
    FROM @SuperGroups
    WHERE GroupID NOT IN (SELECT GroupID FROM @CoveredGroups);

    -- Copy non-redundant super-groups to cleaned groups
    INSERT INTO indexing.CleanedConsolidatedGroups (
        ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
        OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
        IsSuperConsolidated, OriginalGroupCount
    )
    SELECT
        ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
        OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
        1, OriginalGroupCount
    FROM @NonRedundantSuperGroups;

    -- Check each individual group to see if it's covered by any super-group
    DECLARE @RemovedCount INT = 0;
    DECLARE @IndivID INT;
    DECLARE @IndivServer NVARCHAR(128);
    DECLARE @IndivDB NVARCHAR(128);
    DECLARE @IndivTable NVARCHAR(256);
    DECLARE @IndivKeys NVARCHAR(MAX);
    DECLARE @IndivIncludes NVARCHAR(MAX);
    DECLARE @IndivRecIDs NVARCHAR(MAX);
    DECLARE @IndivRecCount INT;
    DECLARE @IndivAdvantage DECIMAL(18,2);

    DECLARE individual_cursor CURSOR FOR
        SELECT GroupID, ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
               OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage
        FROM @IndividualGroups;

    OPEN individual_cursor;
    FETCH NEXT FROM individual_cursor INTO @IndivID, @IndivServer, @IndivDB, @IndivTable, @IndivKeys,
                                            @IndivIncludes, @IndivRecIDs, @IndivRecCount, @IndivAdvantage;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @CoveredBySuper BIT = 0;

        -- Check if any super-group covers this individual (reuse variables declared above)

        DECLARE super_cursor CURSOR FOR
            SELECT KeyColumns, IncludedColumns
            FROM @SuperGroups
            WHERE ServerName = @IndivServer
              AND DatabaseName = @IndivDB
              AND SchemaTable = @IndivTable;

        OPEN super_cursor;
        FETCH NEXT FROM super_cursor INTO @SuperKeys, @SuperIncludes;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF indexing.fn_SuperGroupCoversIndividual(@SuperKeys, @SuperIncludes, @IndivKeys, @IndivIncludes) = 1
            BEGIN
                SET @CoveredBySuper = 1;
                IF @Debug = 1 PRINT '[POST-SUPER-CLEANUP] Individual group with key ' + @IndivKeys + ' covered by super-group';
                SET @RemovedCount = @RemovedCount + 1;
                BREAK;
            END

            FETCH NEXT FROM super_cursor INTO @SuperKeys, @SuperIncludes;
        END

        CLOSE super_cursor;
        DEALLOCATE super_cursor;

        -- If not covered by any super-group, keep it
        IF @CoveredBySuper = 0
        BEGIN
            INSERT INTO indexing.CleanedConsolidatedGroups (
                ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
                OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
                IsSuperConsolidated, OriginalGroupCount
            )
            VALUES (
                @IndivServer, @IndivDB, @IndivTable, @IndivKeys, @IndivIncludes,
                @IndivRecIDs, @IndivRecCount, @IndivAdvantage,
                0, 1
            );
        END

        FETCH NEXT FROM individual_cursor INTO @IndivID, @IndivServer, @IndivDB, @IndivTable, @IndivKeys,
                                                @IndivIncludes, @IndivRecIDs, @IndivRecCount, @IndivAdvantage;
    END

    CLOSE individual_cursor;
    DEALLOCATE individual_cursor;

    -- Report results
    DECLARE @CleanedCount INT = (SELECT COUNT(*) FROM indexing.CleanedConsolidatedGroups);
    IF @Debug = 1 PRINT '[POST-SUPER-CLEANUP] Result: ' + CAST(@TotalGroups AS VARCHAR(10)) +
                        ' groups -> ' + CAST(@CleanedCount AS VARCHAR(10)) + ' groups (' +
                        CAST(@RemovedCount AS VARCHAR(10)) + ' redundant removed)';
END
GO

PRINT 'Stored procedure sp_RemoveRedundantAfterSuperConsolidation created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.sp_AnalyzeIndexStrategies', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_AnalyzeIndexStrategies;
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE indexing.sp_AnalyzeIndexStrategies
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Drop and recreate analysis results table
    IF OBJECT_ID('indexing.AnalysisResults', 'U') IS NOT NULL DROP TABLE indexing.AnalysisResults;

    CREATE TABLE indexing.AnalysisResults (
        ResultID INT IDENTITY(1,1) PRIMARY KEY,
        ServerName NVARCHAR(128),
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(256),
        Strategy NVARCHAR(50),  -- CREATE, CREATE_CONSOLIDATED, REBUILD, EXTEND, UPDATE, PREFIX_MATCH, SUPERSET_COVERED
        ExistingIndexName NVARCHAR(128) NULL,
        ExistingKeyColumns NVARCHAR(MAX) NULL,
        ExistingIncludeColumns NVARCHAR(MAX) NULL,
        NewIndexName NVARCHAR(128) NULL,
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX) NULL,
        RecommendationIDs NVARCHAR(MAX),
        RecommendationCount INT,
        IsDisabled BIT DEFAULT 0,
        IndexAdvantage DECIMAL(18,2),
        MatchScore INT DEFAULT 0,
        IsSuperConsolidated BIT DEFAULT 0,
        OriginalGroupCount INT DEFAULT 1
    );

    IF @Debug = 1 PRINT 'Analyzing index strategies with SUPER-CONSOLIDATION...';

    -- Step 1: Consolidate recommendations first (group by key columns)
    EXEC indexing.sp_ConsolidateRecommendations @Debug = @Debug;

    -- Step 2: Apply prefix and cross-coverage consolidation (Python equivalent)
    IF @Debug = 1 PRINT '  > Applying prefix and cross-coverage consolidation...';
    EXEC indexing.sp_ApplyPrefixConsolidation @Debug = @Debug;

    -- Step 2.5: Apply super-consolidation (merge multiple groups into super-indexes)
    IF @Debug = 1 PRINT '  > Applying super-consolidation...';
    EXEC indexing.sp_ApplySuperConsolidation @Debug = @Debug;

    -- Step 2.7: Remove redundant operations covered by super-consolidated indexes
    IF @Debug = 1 PRINT '  > Removing redundant operations...';
    EXEC indexing.sp_RemoveRedundantAfterSuperConsolidation @Debug = @Debug;

    -- Step 3: For each cleaned consolidated recommendation, find matching existing indexes
    DECLARE @SchemaTable NVARCHAR(256);
    DECLARE @KeyCols NVARCHAR(MAX);
    DECLARE @IncludeCols NVARCHAR(MAX);
    DECLARE @RecIDs NVARCHAR(MAX);
    DECLARE @RecCount INT;
    DECLARE @Advantage DECIMAL(18,2);
    DECLARE @DBName NVARCHAR(128);
    DECLARE @IsSuperConsolidated BIT;
    DECLARE @OriginalGroupCount INT;

    DECLARE @ServerNameVar NVARCHAR(128);

    DECLARE cons_cursor CURSOR FOR
        SELECT ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
               OriginalRecommendationIDs, RecommendationCount, TotalIndexAdvantage,
               IsSuperConsolidated, OriginalGroupCount
        FROM indexing.CleanedConsolidatedGroups
        ORDER BY TotalIndexAdvantage DESC;

    OPEN cons_cursor;
    FETCH NEXT FROM cons_cursor INTO @ServerNameVar, @DBName, @SchemaTable, @KeyCols, @IncludeCols, @RecIDs, @RecCount, @Advantage,
                                      @IsSuperConsolidated, @OriginalGroupCount;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- CRITICAL FIX (2026-03-02): Normalize column spacing to ensure consistent comparisons
        -- Remove all spaces after commas, then add them back consistently: ", " (comma+space)
        SET @KeyCols = REPLACE(REPLACE(@KeyCols, ', ', ','), ',', ', ');
        IF @IncludeCols IS NOT NULL
            SET @IncludeCols = REPLACE(REPLACE(@IncludeCols, ', ', ','), ',', ', ');

        DECLARE @ExistingName NVARCHAR(128) = NULL;
        DECLARE @ExistingKeys NVARCHAR(MAX) = NULL;
        DECLARE @ExistingIncludes NVARCHAR(MAX) = NULL;
        DECLARE @IsDisabled BIT = 0;
        DECLARE @Strategy NVARCHAR(50) = 'CREATE';
        DECLARE @MatchScore INT = 0;

        -- Look for exact match on disabled index
        -- CRITICAL: Never rebuild primary keys, unique indexes, or filtered indexes
        SELECT TOP 1
            @ExistingName = IndexName,
            @ExistingKeys = KeyColumns,
            @ExistingIncludes = IncludedColumns,
            @IsDisabled = IsDisabled
        FROM indexing.CurrentIndexes
        WHERE DatabaseName = @DBName
            AND SchemaTable = @SchemaTable
            AND KeyColumns = @KeyCols
            AND IsDisabled = 1
            AND IsPrimaryKey = 0  -- Never rebuild primary keys
            AND IsUnique = 0      -- Never rebuild unique constraints
            AND HasFilter = 0     -- Never rebuild filtered indexes
        ORDER BY IndexSizeMB DESC;

        IF @ExistingName IS NOT NULL
        BEGIN
            -- Check if existing includes contain all needed includes
            -- For REBUILD to be valid, the disabled index must already have all the columns we need
            IF indexing.fn_ContainsAllColumns(@ExistingIncludes, @IncludeCols) = 1
            BEGIN
                -- Exact match on disabled index with sufficient includes - use REBUILD
                SET @Strategy = 'REBUILD';
                SET @MatchScore = 1000;
            END
            ELSE
            BEGIN
                -- Disabled index exists but missing required include columns
                -- Use EXTEND_DISABLED strategy to match Python's labeling
                -- FIX (2026-02-27): Keep the disabled index reference for better documentation
                SET @Strategy = 'EXTEND_DISABLED';
                SET @MatchScore = 980;  -- High score, slightly less than REBUILD
            END
        END
        ELSE
        BEGIN
            -- Look for EXTEND match (recommendation keys are PREFIX of existing keys, needs additional includes)
            -- Example 1: Existing has [col1] with includes [col2], recommendation needs [col1] with includes [col2], [col3]
            -- Example 2: Existing has [col1], [col2] with includes [col3], recommendation needs [col1] with includes [col3], [col4]
            -- Python logic: If recommendation keys are start of existing keys, keep existing key structure and add includes
            -- CRITICAL: Never extend primary keys, unique indexes, or filtered indexes
            SELECT TOP 1
                @ExistingName = IndexName,
                @ExistingKeys = KeyColumns,
                @ExistingIncludes = IncludedColumns,
                @IsDisabled = IsDisabled
            FROM indexing.CurrentIndexes
            WHERE DatabaseName = @DBName
                AND SchemaTable = @SchemaTable
                AND IsDisabled = 0
                AND IsPrimaryKey = 0  -- Never extend primary keys
                AND IsUnique = 0      -- Never extend unique constraints
                AND HasFilter = 0     -- Never extend filtered indexes
                AND @IncludeCols IS NOT NULL  -- Recommendation needs includes
                AND (
                    -- Exact key match (original logic)
                    KeyColumns = @KeyCols
                    OR
                    -- Prefix match (Python logic): existing keys start with recommendation keys
                    -- Use SUBSTRING instead of LIKE because brackets are LIKE wildcards
                    (SUBSTRING(KeyColumns, 1, LEN(@KeyCols)) = @KeyCols
                     AND LEN(KeyColumns) > LEN(@KeyCols)
                     AND SUBSTRING(KeyColumns, LEN(@KeyCols) + 1, 2) = ', ')
                )
                AND (
                    -- Either existing has no includes (need to add all)
                    IncludedColumns IS NULL OR
                    -- Or existing has some includes but doesn't have all needed ones
                    (IncludedColumns IS NOT NULL AND
                     indexing.fn_ContainsAllColumns(IncludedColumns, @IncludeCols) = 0)
                )
            ORDER BY
                -- Prefer exact match first, then shortest keys (fewest extra keys), then most includes (tie-breaker)
                CASE WHEN KeyColumns = @KeyCols THEN 0 ELSE 1 END,
                LEN(KeyColumns),                    -- Fewest extra keys (most important)
                LEN(ISNULL(IncludedColumns, '')) DESC;  -- Most includes as tie-breaker

            IF @ExistingName IS NOT NULL
            BEGIN
                -- Check if exact key match or prefix match
                IF @ExistingKeys = @KeyCols
                BEGIN
                    -- Exact key match - UPDATE strategy (same keys, different includes)
                    SET @Strategy = 'UPDATE';
                    SET @MatchScore = 950;
                END
                ELSE
                BEGIN
                    -- Prefix match - EXTEND strategy (recommendation keys are prefix of existing keys)
                    SET @Strategy = 'EXTEND';
                    SET @MatchScore = 940;
                END
            END
            ELSE
            BEGIN
                -- Look for PREFIX match (existing index keys are a prefix of recommendation keys)
                -- Example: Existing has [col1], [col2] and recommendation needs [col1], [col2], [col3]
                -- CRITICAL: Exclude protected indexes from consideration
                SELECT TOP 1
                    @ExistingName = IndexName,
                    @ExistingKeys = KeyColumns,
                    @ExistingIncludes = IncludedColumns,
                    @IsDisabled = IsDisabled
                FROM indexing.CurrentIndexes
                WHERE DatabaseName = @DBName
                    AND SchemaTable = @SchemaTable
                    AND IsDisabled = 0
                    AND IsPrimaryKey = 0  -- Exclude primary keys
                    AND IsUnique = 0      -- Exclude unique constraints
                    AND HasFilter = 0     -- Exclude filtered indexes
                    AND @KeyCols LIKE KeyColumns + ',%'  -- Recommendation has additional keys
                ORDER BY LEN(KeyColumns) DESC;  -- Get longest matching prefix

                IF @ExistingName IS NOT NULL
                BEGIN
                    -- PREFIX match - could extend existing index with additional keys
                    SET @Strategy = 'PREFIX_MATCH';
                    SET @MatchScore = 800;
                END
                ELSE
                BEGIN
                    -- Look for SUPERSET match (existing index already covers recommendation)
                    -- Example: Existing has [col1], [col2], [col3] and recommendation needs [col1], [col2]
                    -- Note: This is informational only (no modifications), but we still exclude protected indexes for clarity
                    SELECT TOP 1
                        @ExistingName = IndexName,
                        @ExistingKeys = KeyColumns,
                        @ExistingIncludes = IncludedColumns,
                        @IsDisabled = IsDisabled
                    FROM indexing.CurrentIndexes
                    WHERE DatabaseName = @DBName
                        AND SchemaTable = @SchemaTable
                        AND IsDisabled = 0
                        AND IsPrimaryKey = 0  -- Exclude primary keys (informational)
                        AND IsUnique = 0      -- Exclude unique constraints (informational)
                        AND HasFilter = 0     -- Exclude filtered indexes (informational)
                        AND KeyColumns LIKE @KeyCols + ',%'  -- Existing has additional keys
                        -- Check includes as well
                        AND (
                            (@IncludeCols IS NULL) OR
                            (@IncludeCols IS NOT NULL AND IncludedColumns IS NOT NULL AND
                             indexing.fn_ContainsAllColumns(IncludedColumns, @IncludeCols) = 1)
                        )
                    ORDER BY LEN(KeyColumns);  -- Get shortest that still covers

                    IF @ExistingName IS NOT NULL
                    BEGIN
                        -- SUPERSET match - existing index already handles this
                        SET @Strategy = 'SUPERSET_COVERED';
                        SET @MatchScore = 900;
                    END
                    ELSE
                    BEGIN
                        -- Look for SUPERSET KEY match (existing index contains all needed keys as LEFTMOST prefix)
                        -- CRITICAL FIX (2026-02-27): Only match if needed keys are LEFTMOST in existing index
                        -- Example: Existing has [A], [B], [C] and recommendation needs [A] or [A], [B]
                        -- WRONG: Recommendation needs [C] - this is NOT leftmost, so DON'T match
                        -- Reason: SQL Server can't efficiently use an index if WHERE clause columns aren't leftmost
                        SELECT TOP 1
                            @ExistingName = IndexName,
                            @ExistingKeys = KeyColumns,
                            @ExistingIncludes = IncludedColumns,
                            @IsDisabled = IsDisabled
                        FROM indexing.CurrentIndexes
                        WHERE DatabaseName = @DBName
                            AND SchemaTable = @SchemaTable
                            AND IsDisabled = 0
                            AND IsPrimaryKey = 0  -- Exclude primary keys
                            AND IsUnique = 0      -- Exclude unique constraints
                            AND HasFilter = 0     -- Exclude filtered indexes
                            -- CRITICAL FIX: Check if needed keys are LEFTMOST prefix (not just contained anywhere)
                            AND (SUBSTRING(KeyColumns, 1, LEN(@KeyCols)) = @KeyCols)  -- Must be leftmost prefix
                            AND LEN(KeyColumns) > LEN(@KeyCols)  -- Existing has more keys (superset)
                            AND SUBSTRING(KeyColumns, LEN(@KeyCols) + 1, 2) = ', '  -- Proper comma separator
                            AND @IncludeCols IS NOT NULL  -- Recommendation needs includes
                            AND (
                                -- Either existing has no includes (need to add all)
                                IncludedColumns IS NULL OR
                                -- Or existing has some includes but doesn't have all needed ones
                                (IncludedColumns IS NOT NULL AND
                                 indexing.fn_ContainsAllColumns(IncludedColumns, @IncludeCols) = 0)
                            )
                        ORDER BY
                            -- Prefer shortest key list that contains needed keys
                            LEN(KeyColumns),
                            LEN(ISNULL(IncludedColumns, '')) DESC;

                        IF @ExistingName IS NOT NULL
                        BEGIN
                            -- SUPERSET KEY match - extend existing index with needed includes
                            -- This is treated like UPDATE strategy (exact key match)
                            -- because we're keeping the existing key structure
                            SET @Strategy = 'UPDATE';
                            SET @MatchScore = 930;  -- Slightly lower than exact match but higher than prefix
                        END
                        ELSE
                        BEGIN
                            -- No match - need to CREATE
                            IF @IsSuperConsolidated = 1
                                SET @Strategy = 'CREATE_SUPER_CONSOLIDATED';
                            ELSE IF @RecCount > 1
                                SET @Strategy = 'CREATE_CONSOLIDATED';
                            ELSE
                                SET @Strategy = 'CREATE';
                            SET @MatchScore = 0;
                        END
                    END
                END
            END
        END

        -- Insert analysis result
        INSERT INTO indexing.AnalysisResults (
            ServerName, DatabaseName, SchemaTable, Strategy, ExistingIndexName,
            ExistingKeyColumns, ExistingIncludeColumns,
            KeyColumns, IncludedColumns, RecommendationIDs,
            RecommendationCount, IsDisabled, IndexAdvantage, MatchScore,
            IsSuperConsolidated, OriginalGroupCount
        )
        VALUES (
            @ServerNameVar, @DBName, @SchemaTable, @Strategy, @ExistingName,
            @ExistingKeys, @ExistingIncludes,
            @KeyCols, @IncludeCols, @RecIDs,
            @RecCount, @IsDisabled, @Advantage, @MatchScore,
            @IsSuperConsolidated, @OriginalGroupCount
        );

        FETCH NEXT FROM cons_cursor INTO @ServerNameVar, @DBName, @SchemaTable, @KeyCols, @IncludeCols, @RecIDs, @RecCount, @Advantage,
                                          @IsSuperConsolidated, @OriginalGroupCount;
    END

    CLOSE cons_cursor;
    DEALLOCATE cons_cursor;

    IF @Debug = 1
    BEGIN
        DECLARE @CreateCnt INT, @RebuildCnt INT, @ExtendCnt INT, @UpdateCnt INT, @PrefixCnt INT, @SupersetCnt INT, @SuperConsCnt INT;
        SELECT @CreateCnt = COUNT(*) FROM indexing.AnalysisResults WHERE Strategy IN ('CREATE', 'CREATE_CONSOLIDATED');
        SELECT @RebuildCnt = COUNT(*) FROM indexing.AnalysisResults WHERE Strategy = 'REBUILD';
        SELECT @ExtendCnt = COUNT(*) FROM indexing.AnalysisResults WHERE Strategy = 'EXTEND';
        SELECT @UpdateCnt = COUNT(*) FROM indexing.AnalysisResults WHERE Strategy = 'UPDATE';
        SELECT @PrefixCnt = COUNT(*) FROM indexing.AnalysisResults WHERE Strategy = 'PREFIX_MATCH';
        SELECT @SupersetCnt = COUNT(*) FROM indexing.AnalysisResults WHERE Strategy = 'SUPERSET_COVERED';
        SELECT @SuperConsCnt = COUNT(*) FROM indexing.AnalysisResults WHERE Strategy = 'CREATE_SUPER_CONSOLIDATED';

        PRINT '  > Strategy breakdown:';
        PRINT '    CREATE/CONSOLIDATED: ' + CAST(@CreateCnt AS VARCHAR(10));
        PRINT '    CREATE_SUPER_CONSOLIDATED: ' + CAST(@SuperConsCnt AS VARCHAR(10));
        PRINT '    REBUILD: ' + CAST(@RebuildCnt AS VARCHAR(10));
        PRINT '    EXTEND: ' + CAST(@ExtendCnt AS VARCHAR(10));
        PRINT '    UPDATE: ' + CAST(@UpdateCnt AS VARCHAR(10));
        PRINT '    PREFIX_MATCH: ' + CAST(@PrefixCnt AS VARCHAR(10));
        PRINT '    SUPERSET_COVERED: ' + CAST(@SupersetCnt AS VARCHAR(10));
    END
END
GO

PRINT 'Stored procedure sp_AnalyzeIndexStrategies (V3 with SUPER-CONSOLIDATION) created successfully.';

GO

-- =============================================

IF OBJECT_ID('indexing.sp_GenerateOptimizationScript', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_GenerateOptimizationScript;
GO

SET QUOTED_IDENTIFIER ON;
GO

CREATE PROCEDURE indexing.sp_GenerateOptimizationScript
    @ServerName NVARCHAR(128) = NULL,
    @DatabaseName NVARCHAR(MAX) = NULL,  -- NULL = all user databases, or comma-delimited list
    @UseCSVForTesting BIT = 0,
    @OutputToTable BIT = 1,
    @Debug BIT = 0,
    @RunnableUnder VARCHAR(20) = NULL  -- NULL=all uncommented, '2'=2GB both, '1,5e'=1GB Std/5GB Ent
AS
BEGIN
    SET NOCOUNT ON;
    SET QUOTED_IDENTIFIER ON;

    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @StartTime DATETIME = GETDATE();
    DECLARE @IsEnterprise BIT = 0;

    -- Parse @RunnableUnder
    DECLARE @ThresholdStd DECIMAL(10,2) = NULL;
    DECLARE @ThresholdEnt DECIMAL(10,2) = NULL;
    DECLARE @ActiveThreshold DECIMAL(10,2) = NULL;

    IF @RunnableUnder IS NOT NULL AND LTRIM(RTRIM(@RunnableUnder)) <> ''
    BEGIN
        IF @RunnableUnder LIKE '%,%e'
        BEGIN
            SET @ThresholdStd = TRY_CAST(LEFT(@RunnableUnder, CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
            SET @ThresholdEnt = TRY_CAST(SUBSTRING(@RunnableUnder, CHARINDEX(',', @RunnableUnder) + 1,
                LEN(@RunnableUnder) - CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
        END
        ELSE
        BEGIN
            SET @ThresholdStd = TRY_CAST(@RunnableUnder AS DECIMAL(10,2));
            SET @ThresholdEnt = @ThresholdStd;
        END
    END
    DECLARE @ServerEdition NVARCHAR(500);
    DECLARE @RecCount INT;
    DECLARE @IdxCount INT;
    DECLARE @DBCount INT;
    DECLARE @DatabaseLabel NVARCHAR(128);

    BEGIN TRY
        -- Set defaults
        IF @ServerName IS NULL SET @ServerName = @@SERVERNAME;

        SET @DatabaseLabel = ISNULL(@DatabaseName, 'ALL');

        -- Step 1 & 2: Collect Recommendations and Current Indexes
        IF @UseCSVForTesting = 1
        BEGIN
            -- Load from CSV files (for testing)
            IF @Debug = 1 PRINT 'Step 1 & 2: Loading test data from CSV files...';

            EXEC indexing.sp_LoadTestDataFromCSV
                @CSVPath = 'D:\sites\claude\optimize-index\Python\Dev\input\',
                @Debug = @Debug;

            -- Look up server edition from CSV data
            SELECT @ServerEdition = Edition
            FROM indexing.ServerInfo
            WHERE ServerName = @ServerName;

            IF @ServerEdition IS NULL
            BEGIN
                SET @ServerEdition = 'Unknown';
                IF @Debug = 1 PRINT '  > WARNING: Server edition not found in serverinfo.csv, using Unknown';
            END

            IF @ServerEdition LIKE '%Enterprise%' OR @ServerEdition LIKE '%Developer%'
                SET @IsEnterprise = 1;
        END
        ELSE
        BEGIN
            -- Production mode - detect from local server
            SELECT @ServerEdition = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500));
            IF @ServerEdition LIKE '%Enterprise%' OR @ServerEdition LIKE '%Developer%'
                SET @IsEnterprise = 1;

            -- In production mode, use provided @DatabaseName or default to current DB
            IF @DatabaseName IS NULL SET @DatabaseName = DB_NAME();
        END

        IF @Debug = 1
        BEGIN
            PRINT '========================================';
            PRINT 'INDEX OPTIMIZATION SCRIPT GENERATOR V4.1';
            PRINT '========================================';
            PRINT 'Server: ' + @ServerName;
            IF @DatabaseName IS NOT NULL
                PRINT 'Database Filter: ' + @DatabaseName;
            PRINT 'Edition: ' + @ServerEdition + ' (Enterprise: ' + CAST(@IsEnterprise AS VARCHAR(1)) + ')';
            PRINT 'Testing Mode: ' + CAST(@UseCSVForTesting AS VARCHAR(1));
            PRINT 'Started: ' + CONVERT(VARCHAR(30), @StartTime, 120);
            PRINT '';
        END

        IF @UseCSVForTesting = 1
        BEGIN
            DECLARE @TotalRecCount INT;  -- Total across all servers
            SELECT @TotalRecCount = COUNT(*) FROM indexing.IndexRecommendations;
            SELECT @IdxCount = COUNT(*) FROM indexing.CurrentIndexes;

            IF @Debug = 1
            BEGIN
                PRINT '  > Loaded ' + CAST(@TotalRecCount AS VARCHAR(10)) + ' recommendations from CSV';
                PRINT '  > Loaded ' + CAST(@IdxCount AS VARCHAR(10)) + ' current indexes from CSV';

                -- Show database breakdown
                SELECT @DBCount = COUNT(DISTINCT DatabaseName) FROM indexing.IndexRecommendations;
                PRINT '  > Found ' + CAST(@DBCount AS VARCHAR(10)) + ' databases in recommendations';

                PRINT '  > Database breakdown:';
                DECLARE @DBName NVARCHAR(128), @DBRecCount INT;
                DECLARE db_cursor CURSOR FOR
                    SELECT DatabaseName, COUNT(*) AS RecCount
                    FROM indexing.IndexRecommendations
                    GROUP BY DatabaseName
                    ORDER BY COUNT(*) DESC;

                OPEN db_cursor;
                FETCH NEXT FROM db_cursor INTO @DBName, @DBRecCount;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    PRINT '    - ' + @DBName + ': ' + CAST(@DBRecCount AS VARCHAR(10)) + ' recommendations';
                    FETCH NEXT FROM db_cursor INTO @DBName, @DBRecCount;
                END
                CLOSE db_cursor;
                DEALLOCATE db_cursor;
            END

            -- Step 3: Run analysis (consolidation pipeline)
            IF @Debug = 1 PRINT '';
            IF @Debug = 1 PRINT 'Step 3: Analyzing recommendations and matching strategies...';

            EXEC indexing.sp_AnalyzeIndexStrategies @Debug = @Debug;

            -- Get count for THIS server only (for statistics)
            SELECT @RecCount = COUNT(*)
            FROM indexing.IndexRecommendations
            WHERE ServerName = @ServerName;
        END
        ELSE
        BEGIN
            -- Manual mode - assumes data already loaded via sp_LoadTestDataFromCSV
            -- and analyzed via sp_AnalyzeIndexStrategies
            IF @Debug = 1 PRINT '  > Using existing data from AnalysisResults table';

            -- Verify data exists and count total recommendations
            DECLARE @RowCount INT;
            SELECT @RowCount = COUNT(*), @RecCount = SUM(RecommendationCount)
            FROM indexing.AnalysisResults
            WHERE ServerName = @ServerName;
            IF @RowCount = 0
            BEGIN
                IF @Debug = 1
                BEGIN
                    PRINT 'No analysis results found for server: ' + @ServerName;
                    PRINT 'Recording "No Recommendations" status...';
                END

                -- Insert record showing no recommendations
                IF @OutputToTable = 1
                BEGIN
                    INSERT INTO indexing.GeneratedScripts (ServerName, DatabaseName, ScriptText, [Statistics], [Status])
                    VALUES (@ServerName, @DatabaseLabel, NULL, 'No Recommendations', 'No Recommendations');

                    IF @Debug = 1 PRINT '  > Status saved to GeneratedScripts table (ScriptID: ' + CAST(SCOPE_IDENTITY() AS VARCHAR(10)) + ')';
                END

                RETURN;
            END

            -- Look up server edition from ServerInfo table
            SELECT @ServerEdition = Edition
            FROM indexing.ServerInfo
            WHERE ServerName = @ServerName;

            IF @ServerEdition IS NULL
            BEGIN
                SET @ServerEdition = 'Unknown';
                IF @Debug = 1 PRINT '  > WARNING: Server edition not found in serverinfo.csv, using Unknown';
            END

            -- CRITICAL FIX: Reset @IsEnterprise first, then set based on TARGET server edition
            SET @IsEnterprise = 0;
            IF @ServerEdition LIKE '%Enterprise%' OR @ServerEdition LIKE '%Developer%'
                SET @IsEnterprise = 1;

            SET @ActiveThreshold = CASE WHEN @IsEnterprise = 1 THEN @ThresholdEnt ELSE @ThresholdStd END;

            IF @Debug = 1
            BEGIN
                PRINT '  > Found ' + CAST(@RowCount AS VARCHAR(10)) + ' analysis results covering ' + CAST(@RecCount AS VARCHAR(10)) + ' recommendations for ' + @ServerName;
                PRINT '  > Edition: ' + @ServerEdition + ' (Enterprise: ' + CAST(@IsEnterprise AS VARCHAR(1)) + ')';
            END
        END

        -- Step 4: Generate formatted script
        IF @Debug = 1 PRINT 'Step 4: Generating optimized script with Phase B enhancements...';

        DECLARE @ScriptText NVARCHAR(MAX) = '';
        DECLARE @CreateCount INT = 0;
        DECLARE @RebuildCount INT = 0;
        DECLARE @ExtendCount INT = 0;
        DECLARE @DropCount INT = 0;
        DECLARE @SupersetCount INT = 0;
        DECLARE @RunnableOperationCount INT = 0;  -- Track operations NOT commented out
        DECLARE @LargeOperationCount INT = 0;  -- Track operations that exceed @RunnableUnder threshold
        DECLARE @RunnableTotalGB DECIMAL(18,2) = 0;  -- Total GB for runnable operations
        DECLARE @LargeTotalGB DECIMAL(18,2) = 0;  -- Total GB for operations exceeding threshold

        -- Count operations by strategy (for this server only)
        SELECT @CreateCount = COUNT(*) FROM indexing.AnalysisResults WHERE ServerName = @ServerName AND Strategy IN ('CREATE', 'CREATE_CONSOLIDATED', 'CREATE_SUPER_CONSOLIDATED', 'PREFIX_MATCH', 'EXTEND_DISABLED');
        SELECT @RebuildCount = COUNT(*) FROM indexing.AnalysisResults WHERE ServerName = @ServerName AND Strategy = 'REBUILD';
        SELECT @ExtendCount = COUNT(*) FROM indexing.AnalysisResults WHERE ServerName = @ServerName AND Strategy IN ('EXTEND', 'UPDATE');  -- Both labeled as EXTEND in output
        SELECT @SupersetCount = COUNT(*) FROM indexing.AnalysisResults WHERE ServerName = @ServerName AND Strategy = 'SUPERSET_COVERED';
        SELECT @DBCount = COUNT(DISTINCT DatabaseName) FROM indexing.AnalysisResults WHERE ServerName = @ServerName;

        -- Initialize script text (statistics header will be added after loop)
        SET @ScriptText = '';

        -- Count tables per database for separator logic (single-table databases don't need separators)
        DECLARE @TableCounts TABLE (DatabaseName NVARCHAR(128), TableCount INT);
        INSERT INTO @TableCounts (DatabaseName, TableCount)
        SELECT DatabaseName, COUNT(DISTINCT SchemaTable)
        FROM indexing.AnalysisResults
        WHERE ServerName = @ServerName
        GROUP BY DatabaseName;

        -- Generate statements with advanced formatting based on strategy
        -- Group by database properly
        DECLARE @CurrentDB NVARCHAR(128) = '';
        DECLARE @CurrentTable NVARCHAR(256) = '';
        DECLARE @TablesInCurrentDB INT = 0;
        DECLARE @Schema NVARCHAR(128), @Table NVARCHAR(128);
        DECLARE @KeyCols NVARCHAR(MAX), @IncludeCols NVARCHAR(MAX);
        DECLARE @IndexName NVARCHAR(128);
        DECLARE @ExistingIndexName NVARCHAR(128);
        DECLARE @ExistingKeys NVARCHAR(MAX), @ExistingIncludes NVARCHAR(MAX);
        DECLARE @IsDisabled BIT;
        DECLARE @Strategy NVARCHAR(50);
        DECLARE @RecommendationIDs NVARCHAR(MAX);
        DECLARE @RecCount2 INT;
        DECLARE @WithClause NVARCHAR(50) = CASE WHEN @IsEnterprise = 1 THEN 'WITH(ONLINE=ON)' ELSE '' END;

        DECLARE @IsSuperConsolidated BIT;
        DECLARE @OriginalGroupCount INT;

        -- MissingIndexResults persistence variables
        DECLARE @CursorIndexAdvantage DECIMAL(18,2);
        DECLARE @FindingScript NVARCHAR(MAX);
        DECLARE @ScriptTextBeforeFinding INT;
        DECLARE @EstimatedGBCurrent DECIMAL(18,2);
        DECLARE @MIRSchemaName NVARCHAR(128);
        DECLARE @MIRTableName NVARCHAR(128);

        -- Clear unresolved MissingIndexResults for this server (re-analysis replaces pending findings; resolved history is preserved)
        IF OBJECT_ID('indexing.MissingIndexResults', 'U') IS NOT NULL
            DELETE FROM indexing.MissingIndexResults WHERE ServerName = @ServerName AND ResolvedDate IS NULL;

        -- Clean up any existing cursor from failed previous execution
        IF CURSOR_STATUS('global','results_cursor') >= -1
        BEGIN
            IF CURSOR_STATUS('global','results_cursor') > -1
                CLOSE results_cursor;
            DEALLOCATE results_cursor;
        END

        DECLARE results_cursor CURSOR FOR
            SELECT DatabaseName, SchemaTable, Strategy, ExistingIndexName, ExistingKeyColumns, ExistingIncludeColumns,
                   IsDisabled, KeyColumns, IncludedColumns, RecommendationIDs, RecommendationCount,
                   IsSuperConsolidated, OriginalGroupCount, IndexAdvantage
            FROM indexing.AnalysisResults
            WHERE ServerName = @ServerName
            ORDER BY DatabaseName, SchemaTable, IndexAdvantage DESC;

        OPEN results_cursor;
        FETCH NEXT FROM results_cursor INTO @DBName, @Schema, @Strategy, @ExistingIndexName, @ExistingKeys, @ExistingIncludes,
            @IsDisabled, @KeyCols, @IncludeCols, @RecommendationIDs, @RecCount2,
            @IsSuperConsolidated, @OriginalGroupCount, @CursorIndexAdvantage;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @EstimatedGBCurrent = NULL;

            -- Decompose SchemaTable (e.g., [dbo].[MyTable]) into separate schema and table names
            SET @MIRSchemaName = REPLACE(SUBSTRING(@Schema, 2, CHARINDEX('].[', @Schema) - 2), ']', '');
            SET @MIRTableName = REPLACE(REPLACE(SUBSTRING(@Schema, CHARINDEX('].[', @Schema) + 3, LEN(@Schema)), '[', ''), ']', '');

            -- Normalize column spacing: ensure consistent ", " (comma+space) separator
            -- Remove all existing spaces after commas, then add them back consistently
            SET @KeyCols = REPLACE(REPLACE(@KeyCols, ', ', ','), ',', ', ');
            SET @IncludeCols = REPLACE(REPLACE(@IncludeCols, ', ', ','), ',', ', ');
            SET @ExistingKeys = REPLACE(REPLACE(@ExistingKeys, ', ', ','), ',', ', ');
            SET @ExistingIncludes = REPLACE(REPLACE(@ExistingIncludes, ', ', ','), ',', ', ');
            -- Add database header if new database
            IF @DBName <> @CurrentDB
            BEGIN
                IF @CurrentDB <> ''
                BEGIN
                    -- Add 2 more blank lines before database change (1 already exists after last operation = 3 total, matching Python)
                    SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10);
                END

                -- Database section header with equals signs
                SET @ScriptText = @ScriptText +
                    '-- ====================================================================================================' + CHAR(13) + CHAR(10) +
                    '-- Database: ' + @DBName + CHAR(13) + CHAR(10) +
                    '-- ====================================================================================================' + CHAR(13) + CHAR(10) +
                    CHAR(13) + CHAR(10) +
                    'USE [' + @DBName + '];' + CHAR(13) + CHAR(10) +
                    CHAR(13) + CHAR(10);

                SET @CurrentDB = @DBName;
                SET @CurrentTable = '';  -- Reset table tracking for new database

                -- Get table count for this database
                SELECT @TablesInCurrentDB = TableCount
                FROM @TableCounts
                WHERE DatabaseName = @DBName;

                IF @TablesInCurrentDB IS NULL SET @TablesInCurrentDB = 0;
            END

            -- Add table delimiter if new table
            IF @Schema <> @CurrentTable
            BEGIN
                -- Add table separator after previous table (but not before first table or after database change)
                -- Only add separator if current database has more than 1 table (matching Python format)
                IF @CurrentTable <> '' AND @TablesInCurrentDB > 1
                BEGIN
                    -- Previous operation already added 1 blank line, so just add separator + 1 blank line after
                    SET @ScriptText = @ScriptText + '/****************************************************/' + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);
                END

                -- Table section header with comment block
                -- Extract schema and table name for sp_helpindexusage
                DECLARE @SchemaName NVARCHAR(128) = SUBSTRING(@Schema, 2, CHARINDEX('].[', @Schema) - 2);
                DECLARE @TableName NVARCHAR(128) = SUBSTRING(@Schema, CHARINDEX('].[', @Schema) + 3, LEN(@Schema));
                SET @TableName = REPLACE(@TableName, ']', '');

                -- Add sp_helpindexusage (commented if @ActiveThreshold IS NOT NULL)
                IF @ActiveThreshold IS NOT NULL
                BEGIN
                    SET @ScriptText = @ScriptText +
                        '-- Table: ' + @Schema + CHAR(13) + CHAR(10) +
                        '-- EXEC sp_helpindexusage ''' + @SchemaName + '.' + @TableName + '''' + CHAR(13) + CHAR(10) +
                        CHAR(13) + CHAR(10);
                END
                ELSE
                BEGIN
                    SET @ScriptText = @ScriptText +
                        '-- Table: ' + @Schema + CHAR(13) + CHAR(10) +
                        'EXEC sp_helpindexusage ''' + @SchemaName + '.' + @TableName + '''' + CHAR(13) + CHAR(10) +
                        CHAR(13) + CHAR(10);
                END

                SET @CurrentTable = @Schema;
            END

            -- Capture script position AFTER headers for MissingIndexResults delta extraction
            SET @ScriptTextBeforeFinding = LEN(ISNULL(@ScriptText, ''));

            -- Generate SQL based on strategy
            IF @Strategy = 'REBUILD'
            BEGIN
                -- ALTER INDEX REBUILD for disabled index with multi-line documentation
                SET @ScriptText = @ScriptText + '-- REBUILD DISABLED INDEX (covers ' + CAST(@RecCount2 AS VARCHAR(10)) + ' recommendation';
                IF @RecCount2 > 1
                    SET @ScriptText = @ScriptText + 's';
                SET @ScriptText = @ScriptText + ')' + CHAR(13) + CHAR(10);

                -- Add individual recommendation details with Idx Adv FIRST
                DECLARE @RebuildRecID INT;
                DECLARE @RebuildRecAdvantage DECIMAL(18,2);
                DECLARE @RebuildRecImpact DECIMAL(18,2);
                DECLARE @RebuildRecKeyCols NVARCHAR(MAX);
                DECLARE @RebuildRecIncludeCols NVARCHAR(MAX);
                DECLARE @RebuildRecCounter INT = 1;

                -- Parse recommendation IDs
                -- Order by IndexAdvantage DESC for consistent display
                DECLARE @RebuildXML XML = CAST('<i>' + REPLACE(@RecommendationIDs, ',', '</i><i>') + '</i>' AS XML);

                DECLARE rebuild_rec_cursor CURSOR FOR
                    SELECT ir.RecommendationID
                    FROM indexing.IndexRecommendations ir
                    INNER JOIN (
                        SELECT CAST(T.c.value('.', 'NVARCHAR(10)') AS INT) AS RecID
                        FROM @RebuildXML.nodes('/i') T(c)
                    ) ids ON ir.RecommendationID = ids.RecID
                    WHERE ir.DatabaseName = @DBName
                    ORDER BY ir.Impact DESC, ir.IndexAdvantage DESC;  -- Order by Impact, then IndexAdvantage (tiebreaker)

                OPEN rebuild_rec_cursor;
                FETCH NEXT FROM rebuild_rec_cursor INTO @RebuildRecID;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    -- Get recommendation details
                    SELECT @RebuildRecAdvantage = IndexAdvantage, @RebuildRecImpact = Impact,
                           @RebuildRecKeyCols = KeyColumns, @RebuildRecIncludeCols = IncludedColumns
                    FROM indexing.IndexRecommendations
                    WHERE RecommendationID = @RebuildRecID
                      AND DatabaseName = @DBName;

                    -- Normalize column spacing for display
                    SET @RebuildRecKeyCols = REPLACE(REPLACE(@RebuildRecKeyCols, ', ', ','), ',', ', ');
                    SET @RebuildRecIncludeCols = REPLACE(REPLACE(@RebuildRecIncludeCols, ', ', ','), ',', ', ');

                    -- Add multi-line recommendation documentation
                    -- Only show "Rec N:" if there are multiple recommendations
                    IF @RecCount2 > 1
                        SET @ScriptText = @ScriptText + '    -- Rec ' + CAST(@RebuildRecCounter AS VARCHAR(10)) + ':' + CHAR(13) + CHAR(10);

                    SET @ScriptText = @ScriptText + '    -- Idx Adv: ' + CAST(@RebuildRecAdvantage AS VARCHAR(20)) +
                                      ' (Impact: ' + CAST(@RebuildRecImpact AS VARCHAR(20)) + ')' + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + '    -- Key Columns: (' + @RebuildRecKeyCols + ')' + CHAR(13) + CHAR(10);

                    IF @RebuildRecIncludeCols IS NOT NULL
                        SET @ScriptText = @ScriptText + '    -- Include Columns: (' + @RebuildRecIncludeCols + ')' + CHAR(13) + CHAR(10);

                    -- No blank line between recommendations - only after last one
                    SET @RebuildRecCounter = @RebuildRecCounter + 1;
                    FETCH NEXT FROM rebuild_rec_cursor INTO @RebuildRecID;
                END

                CLOSE rebuild_rec_cursor;
                DEALLOCATE rebuild_rec_cursor;

                -- Add single blank line after all recommendations
                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- Check for smart size warning
                DECLARE @RebuildSizeWarning NVARCHAR(MAX);
                EXEC indexing.sp_GetHybridIndexSizeEstimate @DBName, @Schema, @ExistingKeys, @ExistingIncludes, @RebuildSizeWarning OUTPUT, 0;

                -- Check if this operation should be commented out
                DECLARE @ShouldCommentRebuild BIT = 0;
                DECLARE @EstimatedGBRebuild DECIMAL(18,2);
                IF @ActiveThreshold IS NOT NULL AND @RebuildSizeWarning IS NOT NULL
                BEGIN
                    -- Extract GB estimate from warning
                    DECLARE @GBPosRebuild INT = CHARINDEX('~', @RebuildSizeWarning);
                    DECLARE @GBEndPosRebuild INT = CHARINDEX(' GB', @RebuildSizeWarning, @GBPosRebuild);
                    IF @GBPosRebuild > 0 AND @GBEndPosRebuild > @GBPosRebuild
                    BEGIN
                        SET @EstimatedGBRebuild = TRY_CAST(SUBSTRING(@RebuildSizeWarning, @GBPosRebuild + 1, @GBEndPosRebuild - @GBPosRebuild - 1) AS DECIMAL(18,2));
                        IF @EstimatedGBRebuild >= @ActiveThreshold
                        BEGIN
                            SET @LargeOperationCount = @LargeOperationCount + 1;  -- Track large operation
                            SET @LargeTotalGB = @LargeTotalGB + @EstimatedGBRebuild;  -- Accumulate GB

                            -- Enterprise Bypass: Don't comment if Enterprise + RunnableUnder mode
                            IF @IsEnterprise = 0
                                SET @ShouldCommentRebuild = 1;
                        END
                    END
                END

                -- Add warning (always visible)
                IF @RebuildSizeWarning IS NOT NULL
                    SET @ScriptText = @ScriptText + @RebuildSizeWarning + CHAR(13) + CHAR(10);

                -- Start comment block if needed
                IF @ShouldCommentRebuild = 1
                    SET @ScriptText = @ScriptText + '/*' + CHAR(13) + CHAR(10);

                SET @ScriptText = @ScriptText +
                    'ALTER INDEX [' + @ExistingIndexName + '] ON ' + @Schema + ' REBUILD';

                IF @WithClause <> ''
                    SET @ScriptText = @ScriptText + ' ' + @WithClause;

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- Add Key/Include columns after ALTER INDEX (show EXISTING index structure, not recommendation)
                SET @ScriptText = @ScriptText + '-- Key Columns: (' + @ExistingKeys + ')' + CHAR(13) + CHAR(10);
                IF @ExistingIncludes IS NOT NULL
                    SET @ScriptText = @ScriptText + '-- Include Columns: (' + @ExistingIncludes + ')' + CHAR(13) + CHAR(10);
                ELSE
                    SET @ScriptText = @ScriptText + '-- Include Columns: (none)' + CHAR(13) + CHAR(10);

                -- Close comment block if needed (before the blank line)
                IF @ShouldCommentRebuild = 1
                    SET @ScriptText = @ScriptText + '*/' + CHAR(13) + CHAR(10);

                -- Track runnable operations (only if NOT commented out)
                IF @ShouldCommentRebuild = 0
                BEGIN
                    SET @RunnableOperationCount = @RunnableOperationCount + 1;
                    IF @EstimatedGBRebuild IS NOT NULL
                        SET @RunnableTotalGB = @RunnableTotalGB + @EstimatedGBRebuild;  -- Accumulate GB
                END

                -- Add blank line after REBUILD documentation
                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);
            END
            ELSE IF @Strategy = 'EXTEND_DISABLED'
            BEGIN
                -- EXTEND_DISABLED - Disabled index with exact key match but missing includes
                -- FIX (2026-02-27): Match Python's labeling for better clarity
                SET @ScriptText = @ScriptText + '-- EXTEND disabled index (covers ' + CAST(@RecCount2 AS VARCHAR(10)) + ' recommendation';
                IF @RecCount2 > 1
                    SET @ScriptText = @ScriptText + 's';
                SET @ScriptText = @ScriptText + ')' + CHAR(13) + CHAR(10);

                -- Add individual recommendation details
                DECLARE @ExtDisRecID INT;
                DECLARE @ExtDisRecAdvantage DECIMAL(18,2);
                DECLARE @ExtDisRecImpact DECIMAL(18,2);
                DECLARE @ExtDisRecKeyCols NVARCHAR(MAX);
                DECLARE @ExtDisRecIncludeCols NVARCHAR(MAX);
                DECLARE @ExtDisRecCounter INT = 1;

                DECLARE @ExtDisXML XML = CAST('<i>' + REPLACE(@RecommendationIDs, ',', '</i><i>') + '</i>' AS XML);

                DECLARE extdis_rec_cursor CURSOR FOR
                    SELECT ir.RecommendationID
                    FROM indexing.IndexRecommendations ir
                    INNER JOIN (
                        SELECT CAST(T.c.value('.', 'NVARCHAR(10)') AS INT) AS RecID
                        FROM @ExtDisXML.nodes('/i') T(c)
                    ) ids ON ir.RecommendationID = ids.RecID
                    WHERE ir.DatabaseName = @DBName
                    ORDER BY ir.Impact DESC, ir.IndexAdvantage DESC;  -- Order by Impact, then IndexAdvantage (tiebreaker)

                OPEN extdis_rec_cursor;
                FETCH NEXT FROM extdis_rec_cursor INTO @ExtDisRecID;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    SELECT @ExtDisRecAdvantage = IndexAdvantage, @ExtDisRecImpact = Impact,
                           @ExtDisRecKeyCols = KeyColumns, @ExtDisRecIncludeCols = IncludedColumns
                    FROM indexing.IndexRecommendations
                    WHERE RecommendationID = @ExtDisRecID AND DatabaseName = @DBName;

                    SET @ExtDisRecKeyCols = REPLACE(REPLACE(@ExtDisRecKeyCols, ', ', ','), ',', ', ');
                    SET @ExtDisRecIncludeCols = REPLACE(REPLACE(@ExtDisRecIncludeCols, ', ', ','), ',', ', ');

                    IF @RecCount2 > 1
                        SET @ScriptText = @ScriptText + '    -- Rec ' + CAST(@ExtDisRecCounter AS VARCHAR(10)) + ':' + CHAR(13) + CHAR(10);

                    SET @ScriptText = @ScriptText + '    -- Idx Adv: ' + CAST(@ExtDisRecAdvantage AS VARCHAR(20)) +
                                      ' (Impact: ' + CAST(@ExtDisRecImpact AS VARCHAR(20)) + ')' + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + '    -- Key Columns: (' + @ExtDisRecKeyCols + ')' + CHAR(13) + CHAR(10);

                    IF @ExtDisRecIncludeCols IS NOT NULL
                        SET @ScriptText = @ScriptText + '    -- Include Columns: (' + @ExtDisRecIncludeCols + ')' + CHAR(13) + CHAR(10);

                    SET @ExtDisRecCounter = @ExtDisRecCounter + 1;
                    FETCH NEXT FROM extdis_rec_cursor INTO @ExtDisRecID;
                END

                CLOSE extdis_rec_cursor;
                DEALLOCATE extdis_rec_cursor;

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- Show disabled index being extended (match Python's format)
                SET @ScriptText = @ScriptText + '-- EXTEND disabled index: ' + @ExistingIndexName + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '    -- Current Key Columns: (' + @ExistingKeys + ')' + CHAR(13) + CHAR(10);
                IF @ExistingIncludes IS NOT NULL AND @ExistingIncludes <> ''
                    SET @ScriptText = @ScriptText + '    -- Current Include Columns: (' + @ExistingIncludes + ')' + CHAR(13) + CHAR(10);
                ELSE
                    SET @ScriptText = @ScriptText + '    -- Current Include Columns: (none)' + CHAR(13) + CHAR(10);

                -- Calculate additional includes needed
                DECLARE @ExtDisAdditionalIncludes NVARCHAR(MAX) = @IncludeCols;
                IF @ExistingIncludes IS NOT NULL AND @ExistingIncludes <> ''
                BEGIN
                    -- Remove existing includes from needed includes (simplified version)
                    -- In production, would need full column comparison logic
                    SET @ExtDisAdditionalIncludes = @IncludeCols; -- Placeholder for now
                END

                SET @ScriptText = @ScriptText + '    -- Additional Includes Needed: (' + ISNULL(@ExtDisAdditionalIncludes, 'none') + ')' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- CRITICAL FIX: Extract table name from schema for index naming
                SET @Table = REPLACE(REPLACE(@Schema, '[', ''), ']', '');
                SET @Table = SUBSTRING(@Table, CHARINDEX('.', @Table) + 1, LEN(@Table));

                -- Generate index name for new index (CRITICAL: Must match current table!)
                SET @IndexName = 'IX_' + @Table + '_' + REPLACE(REPLACE(REPLACE(REPLACE(@KeyCols, '[', ''), ']', ''), ', ', '_'), ',', '_');
                IF @IncludeCols IS NOT NULL
                    SET @IndexName = @IndexName + '_INCLUDES';

                -- Check for smart size warning
                DECLARE @ExtDisSizeWarning NVARCHAR(MAX);
                EXEC indexing.sp_GetHybridIndexSizeEstimate @DBName, @Schema, @KeyCols, @IncludeCols, @ExtDisSizeWarning OUTPUT, 0;

                -- Check if this operation should be commented out
                DECLARE @ShouldCommentExtDis BIT = 0;
                DECLARE @EstimatedGBExtDis DECIMAL(18,2);
                IF @ActiveThreshold IS NOT NULL AND @ExtDisSizeWarning IS NOT NULL
                BEGIN
                    -- Extract GB estimate from warning
                    DECLARE @GBPosExtDis INT = CHARINDEX('~', @ExtDisSizeWarning);
                    DECLARE @GBEndPosExtDis INT = CHARINDEX(' GB', @ExtDisSizeWarning, @GBPosExtDis);
                    IF @GBPosExtDis > 0 AND @GBEndPosExtDis > @GBPosExtDis
                    BEGIN
                        SET @EstimatedGBExtDis = TRY_CAST(SUBSTRING(@ExtDisSizeWarning, @GBPosExtDis + 1, @GBEndPosExtDis - @GBPosExtDis - 1) AS DECIMAL(18,2));
                        IF @EstimatedGBExtDis >= @ActiveThreshold
                        BEGIN
                            SET @LargeOperationCount = @LargeOperationCount + 1;  -- Track large operation
                            SET @LargeTotalGB = @LargeTotalGB + @EstimatedGBExtDis;  -- Accumulate GB

                            -- Enterprise Bypass: Don't comment if Enterprise + RunnableUnder mode
                            IF @IsEnterprise = 0
                                SET @ShouldCommentExtDis = 1;
                        END
                    END
                END

                -- Add warning (always visible)
                IF @ExtDisSizeWarning IS NOT NULL
                    SET @ScriptText = @ScriptText + @ExtDisSizeWarning + CHAR(13) + CHAR(10);

                -- Start comment block if needed
                IF @ShouldCommentExtDis = 1
                    SET @ScriptText = @ScriptText + '/*' + CHAR(13) + CHAR(10);

                -- DROP the old disabled index first (DROP_EXISTING doesn't work on disabled indexes)
                SET @ScriptText = @ScriptText + 'DROP INDEX [' + @ExistingIndexName + '] ON ' + @Schema + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- Then CREATE the replacement with the same name
                SET @ScriptText = @ScriptText + 'CREATE NONCLUSTERED INDEX [' + @ExistingIndexName + ']' + CHAR(13) + CHAR(10) +
                    'ON ' + @Schema + ' (' + @KeyCols + ')';

                IF @IncludeCols IS NOT NULL
                    SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10) + 'INCLUDE (' + @IncludeCols + ')';

                IF @WithClause <> ''
                    SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10) + @WithClause;

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- Close comment block if needed (before the blank line)
                IF @ShouldCommentExtDis = 1
                    SET @ScriptText = @ScriptText + '*/' + CHAR(13) + CHAR(10);

                -- Track runnable operations (only if NOT commented out)
                IF @ShouldCommentExtDis = 0
                BEGIN
                    SET @RunnableOperationCount = @RunnableOperationCount + 1;
                    IF @EstimatedGBExtDis IS NOT NULL
                        SET @RunnableTotalGB = @RunnableTotalGB + @EstimatedGBExtDis;  -- Accumulate GB
                END

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);  -- Add blank line before separator
            END
            ELSE IF @Strategy IN ('EXTEND', 'UPDATE')
            BEGIN
                -- EXTEND/UPDATE - Existing index needs additional or different INCLUDE columns
                -- UPDATE = exact key match, EXTEND = prefix key match (both generate same script)
                SET @ScriptText = @ScriptText + '-- EXTEND existing index (covers ' + CAST(@RecCount2 AS VARCHAR(10)) + ' recommendation';
                IF @RecCount2 > 1
                    SET @ScriptText = @ScriptText + 's';
                SET @ScriptText = @ScriptText + ')' + CHAR(13) + CHAR(10);

                -- Add individual recommendation details with Idx Adv
                DECLARE @ExtendRecID INT;
                DECLARE @ExtendRecAdvantage DECIMAL(18,2);
                DECLARE @ExtendRecImpact DECIMAL(18,2);
                DECLARE @ExtendRecKeyCols NVARCHAR(MAX);
                DECLARE @ExtendRecIncludeCols NVARCHAR(MAX);
                DECLARE @ExtendRecCounter INT = 1;

                -- Parse recommendation IDs
                -- Order by: Impact DESC (business priority)
                DECLARE @ExtendXML XML = CAST('<i>' + REPLACE(@RecommendationIDs, ',', '</i><i>') + '</i>' AS XML);

                DECLARE extend_rec_cursor CURSOR FOR
                    SELECT ir.RecommendationID
                    FROM indexing.IndexRecommendations ir
                    INNER JOIN (
                        SELECT CAST(T.c.value('.', 'NVARCHAR(10)') AS INT) AS RecID
                        FROM @ExtendXML.nodes('/i') T(c)
                    ) ids ON ir.RecommendationID = ids.RecID
                    WHERE ir.DatabaseName = @DBName
                    ORDER BY ir.Impact DESC, ir.IndexAdvantage DESC;  -- Order by Impact, then IndexAdvantage (tiebreaker)

                OPEN extend_rec_cursor;
                FETCH NEXT FROM extend_rec_cursor INTO @ExtendRecID;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    -- Get recommendation details
                    SELECT @ExtendRecAdvantage = IndexAdvantage, @ExtendRecImpact = Impact,
                           @ExtendRecKeyCols = KeyColumns, @ExtendRecIncludeCols = IncludedColumns
                    FROM indexing.IndexRecommendations
                    WHERE RecommendationID = @ExtendRecID
                      AND DatabaseName = @DBName;

                    -- Normalize column spacing for display
                    SET @ExtendRecKeyCols = REPLACE(REPLACE(@ExtendRecKeyCols, ', ', ','), ',', ', ');
                    SET @ExtendRecIncludeCols = REPLACE(REPLACE(@ExtendRecIncludeCols, ', ', ','), ',', ', ');

                    -- Add multi-line recommendation documentation
                    -- Only show "Rec N:" if there are multiple recommendations
                    IF @RecCount2 > 1
                        SET @ScriptText = @ScriptText + '    -- Rec ' + CAST(@ExtendRecCounter AS VARCHAR(10)) + ':' + CHAR(13) + CHAR(10);

                    SET @ScriptText = @ScriptText + '    -- Idx Adv: ' + CAST(@ExtendRecAdvantage AS VARCHAR(20)) +
                                      ' (Impact: ' + CAST(@ExtendRecImpact AS VARCHAR(20)) + ')' + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + '    -- Key Columns: (' + @ExtendRecKeyCols + ')' + CHAR(13) + CHAR(10);

                    IF @ExtendRecIncludeCols IS NOT NULL
                        SET @ScriptText = @ScriptText + '    -- Include Columns: (' + @ExtendRecIncludeCols + ')' + CHAR(13) + CHAR(10);

                    SET @ExtendRecCounter = @ExtendRecCounter + 1;
                    FETCH NEXT FROM extend_rec_cursor INTO @ExtendRecID;
                END

                CLOSE extend_rec_cursor;
                DEALLOCATE extend_rec_cursor;

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '-- EXTEND current index: ' + @ExistingIndexName + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '    -- Current Key Columns: (' + @ExistingKeys + ')' + CHAR(13) + CHAR(10);

                IF @ExistingIncludes IS NOT NULL
                    SET @ScriptText = @ScriptText + '    -- Current Include Columns: (' + @ExistingIncludes + ')' + CHAR(13) + CHAR(10);
                ELSE
                    SET @ScriptText = @ScriptText + '    -- Current Include Columns: (none)' + CHAR(13) + CHAR(10);

                -- Calculate additional includes needed (only NEW columns, not existing ones)
                DECLARE @AdditionalIncludes NVARCHAR(MAX) = '';
                IF @ExistingIncludes IS NULL
                BEGIN
                    -- No existing includes, but still need to filter out key columns from @IncludeCols
                    IF OBJECT_ID('tempdb..#AdditionalIncludesFiltered') IS NOT NULL DROP TABLE #AdditionalIncludesFiltered;
                    IF OBJECT_ID('tempdb..#KeyColumnsFilter') IS NOT NULL DROP TABLE #KeyColumnsFilter;

                    CREATE TABLE #AdditionalIncludesFiltered (Position INT IDENTITY(1,1), ColumnName NVARCHAR(128));
                    CREATE TABLE #KeyColumnsFilter (ColumnName NVARCHAR(128));

                    -- Parse existing keys into temp table
                    INSERT INTO #KeyColumnsFilter (ColumnName)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@ExistingKeys, ',')
                    WHERE TRIM(value) != '';

                    -- Add all columns from @IncludeCols that are NOT in @ExistingKeys
                    INSERT INTO #AdditionalIncludesFiltered (ColumnName)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@IncludeCols, ',')
                    WHERE TRIM(value) != ''
                      AND TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')) NOT IN (SELECT ColumnName FROM #KeyColumnsFilter);

                    SELECT @AdditionalIncludes = ISNULL(STRING_AGG('[' + ColumnName + ']', ', ') WITHIN GROUP (ORDER BY Position), '')
                    FROM #AdditionalIncludesFiltered;
                END
                ELSE
                BEGIN
                    -- Clear temp tables from previous iterations (table variables persist!)
                    IF OBJECT_ID('tempdb..#ExistingIncludesSet') IS NOT NULL DROP TABLE #ExistingIncludesSet;
                    IF OBJECT_ID('tempdb..#ExistingKeysSet') IS NOT NULL DROP TABLE #ExistingKeysSet;
                    IF OBJECT_ID('tempdb..#NewIncludesNeeded') IS NOT NULL DROP TABLE #NewIncludesNeeded;

                    -- Parse existing includes into a set for comparison
                    CREATE TABLE #ExistingIncludesSet (ColName NVARCHAR(128));
                    INSERT INTO #ExistingIncludesSet (ColName)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@ExistingIncludes, ',')
                    WHERE TRIM(value) != '';

                    -- Parse existing KEY columns to exclude from includes
                    CREATE TABLE #ExistingKeysSet (ColName NVARCHAR(128));
                    INSERT INTO #ExistingKeysSet (ColName)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@ExistingKeys, ',')
                    WHERE TRIM(value) != '';

                    -- Find columns in @IncludeCols that are NOT in @ExistingIncludes AND NOT in @ExistingKeys
                    -- CRITICAL: Preserve exact order from @IncludeCols recommendation
                    -- STRING_SPLIT doesn't guarantee order, so we must manually parse and track positions
                    CREATE TABLE #NewIncludesNeeded (Position INT, ColName NVARCHAR(128));

                    -- Manually parse @IncludeCols to preserve exact order
                    DECLARE @IncludePos INT = 1;
                    DECLARE @IncludeItem NVARCHAR(128);
                    DECLARE @CommaPos INT;
                    DECLARE @IncludeRemaining NVARCHAR(MAX) = @IncludeCols + ','; -- Add trailing comma for easier parsing

                    WHILE LEN(@IncludeRemaining) > 0
                    BEGIN
                        SET @CommaPos = CHARINDEX(',', @IncludeRemaining);
                        IF @CommaPos = 0 BREAK;

                        SET @IncludeItem = TRIM(REPLACE(REPLACE(LEFT(@IncludeRemaining, @CommaPos - 1), '[', ''), ']', ''));
                        SET @IncludeRemaining = SUBSTRING(@IncludeRemaining, @CommaPos + 1, LEN(@IncludeRemaining));

                        IF @IncludeItem != ''
                          AND NOT EXISTS (SELECT 1 FROM #ExistingIncludesSet WHERE ColName = @IncludeItem)
                          AND NOT EXISTS (SELECT 1 FROM #ExistingKeysSet WHERE ColName = @IncludeItem)
                        BEGIN
                            INSERT INTO #NewIncludesNeeded (Position, ColName)
                            VALUES (@IncludePos, @IncludeItem);
                        END

                        SET @IncludePos = @IncludePos + 1;
                    END

                    -- Build comma-separated list of NEW columns only, preserving exact recommendation order
                    SELECT @AdditionalIncludes = STRING_AGG('[' + ColName + ']', ', ') WITHIN GROUP (ORDER BY Position)
                    FROM #NewIncludesNeeded;

                    -- If no new columns, show message
                    IF @AdditionalIncludes IS NULL OR @AdditionalIncludes = ''
                        SET @AdditionalIncludes = '(all columns already included)';
                END

                SET @ScriptText = @ScriptText + '    -- Additional Includes Needed: (' + @AdditionalIncludes + ')' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- Generate new index name (without _EXTENDED suffix to match Python)
                SET @Table = REPLACE(REPLACE(@Schema, '[', ''), ']', '');
                SET @Table = SUBSTRING(@Table, CHARINDEX('.', @Table) + 1, LEN(@Table));

                SET @IndexName = 'IX_' + @Table + '_' + REPLACE(REPLACE(REPLACE(@ExistingKeys, '[', ''), ']', ''), ', ', '_') + '_INCLUDES';

                -- Detect name collision (generated name matches existing index)
                DECLARE @HasNameCollision BIT = CASE WHEN @IndexName = @ExistingIndexName THEN 1 ELSE 0 END;

                -- Merge existing and new includes with deduplication (preserving order)
                -- MUST be calculated BEFORE size warning check
                DECLARE @MergedIncludes NVARCHAR(MAX);
                IF @ExistingIncludes IS NULL
                BEGIN
                    -- No existing includes, but still need to filter out key columns from @IncludeCols
                    IF OBJECT_ID('tempdb..#FilteredIncludes') IS NOT NULL DROP TABLE #FilteredIncludes;
                    IF OBJECT_ID('tempdb..#KeyColumnsFilter2') IS NOT NULL DROP TABLE #KeyColumnsFilter2;

                    CREATE TABLE #FilteredIncludes (Position INT IDENTITY(1,1), ColumnName NVARCHAR(128));
                    CREATE TABLE #KeyColumnsFilter2 (ColumnName NVARCHAR(128));

                    -- Parse existing keys into temp table
                    INSERT INTO #KeyColumnsFilter2 (ColumnName)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@ExistingKeys, ',')
                    WHERE TRIM(value) != '';

                    -- Add all columns from @IncludeCols that are NOT in @ExistingKeys
                    INSERT INTO #FilteredIncludes (ColumnName)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@IncludeCols, ',')
                    WHERE TRIM(value) != ''
                      AND TRIM(REPLACE(REPLACE(value, '[', ''), ']', '')) NOT IN (SELECT ColumnName FROM #KeyColumnsFilter2);

                    SELECT @MergedIncludes = ISNULL(STRING_AGG('[' + ColumnName + ']', ', ') WITHIN GROUP (ORDER BY Position), '')
                    FROM #FilteredIncludes;
                END
                ELSE
                BEGIN
                    -- Deduplicate includes while preserving first appearance order
                    SET @MergedIncludes = '';

                    -- Clear table from previous iteration (table variables persist at procedure scope!)
                    IF OBJECT_ID('tempdb..#ExtendIncludes') IS NOT NULL DROP TABLE #ExtendIncludes;
                    CREATE TABLE #ExtendIncludes (Position INT IDENTITY(1,1), ColumnName NVARCHAR(128));

                    -- Parse existing includes first (they maintain priority in order)
                    INSERT INTO #ExtendIncludes (ColumnName)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@ExistingIncludes, ',')
                    WHERE TRIM(value) != '';

                    -- Parse new includes, only add if not already present
                    INSERT INTO #ExtendIncludes (ColumnName)
                    SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                    FROM STRING_SPLIT(@IncludeCols, ',')
                    WHERE TRIM(value) != ''
                      AND NOT EXISTS (
                          SELECT 1 FROM #ExtendIncludes
                          WHERE ColumnName = TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                      );

                    -- Remove any columns that are already in the KEY columns (can't be in both)
                    DELETE FROM #ExtendIncludes
                    WHERE ColumnName IN (
                        SELECT TRIM(REPLACE(REPLACE(value, '[', ''), ']', ''))
                        FROM STRING_SPLIT(@ExistingKeys, ',')
                        WHERE TRIM(value) != ''
                    );

                    -- Rebuild merged includes in order of first appearance
                    SELECT @MergedIncludes = ISNULL(STRING_AGG('[' + ColumnName + ']', ', ') WITHIN GROUP (ORDER BY Position), '')
                    FROM #ExtendIncludes;
                END

                -- Check for smart size warning (after @MergedIncludes is calculated)
                DECLARE @SizeWarning NVARCHAR(MAX);
                EXEC indexing.sp_GetHybridIndexSizeEstimate @DBName, @Schema, @ExistingKeys, @MergedIncludes, @SizeWarning OUTPUT, 0;

                -- Check if this operation should be commented out
                DECLARE @ShouldCommentSQL BIT = 0;
                DECLARE @EstimatedGB DECIMAL(18,2);
                IF @ActiveThreshold IS NOT NULL AND @SizeWarning IS NOT NULL
                BEGIN
                    -- Extract GB estimate from warning
                    DECLARE @GBPos1 INT = CHARINDEX('~', @SizeWarning);
                    DECLARE @GBEndPos1 INT = CHARINDEX(' GB', @SizeWarning, @GBPos1);
                    IF @GBPos1 > 0 AND @GBEndPos1 > @GBPos1
                    BEGIN
                        SET @EstimatedGB = TRY_CAST(SUBSTRING(@SizeWarning, @GBPos1 + 1, @GBEndPos1 - @GBPos1 - 1) AS DECIMAL(18,2));
                        IF @EstimatedGB >= @ActiveThreshold
                        BEGIN
                            SET @LargeOperationCount = @LargeOperationCount + 1;  -- Track large operation
                            SET @LargeTotalGB = @LargeTotalGB + @EstimatedGB;  -- Accumulate GB
                            -- Enterprise Bypass: Don't comment if Enterprise + RunnableUnder mode
                            IF @IsEnterprise = 0
                                SET @ShouldCommentSQL = 1;
                        END
                    END
                END

                -- Add warning (always visible)
                IF @SizeWarning IS NOT NULL
                    SET @ScriptText = @ScriptText + @SizeWarning + CHAR(13) + CHAR(10);

                -- Start comment block if needed
                IF @ShouldCommentSQL = 1
                    SET @ScriptText = @ScriptText + '/*' + CHAR(13) + CHAR(10);

                -- CRITICAL SAFETY: Check if existing index should be dropped/replaced
                DECLARE @CanDrop BIT = 1;
                DECLARE @DropReason NVARCHAR(100) = '';

                SELECT TOP 1
                    @CanDrop = CASE WHEN IsPrimaryKey = 1 OR IsUnique = 1 OR HasFilter = 1 THEN 0 ELSE 1 END,
                    @DropReason = CASE
                        WHEN IsPrimaryKey = 1 THEN 'primary key'
                        WHEN IsUnique = 1 THEN 'unique index'
                        WHEN HasFilter = 1 THEN 'filtered index'
                        ELSE ''
                    END
                FROM indexing.CurrentIndexes
                WHERE DatabaseName = @DBName
                    AND SchemaTable = @Schema
                    AND IndexName = @ExistingIndexName;

                -- Build WITH clause for this operation
                DECLARE @ExtendWithClause NVARCHAR(100) = '';
                IF @HasNameCollision = 1 AND @CanDrop = 1
                BEGIN
                    -- Name collision: use DROP_EXISTING=ON (atomic replace)
                    IF @IsEnterprise = 1
                        SET @ExtendWithClause = 'WITH(DROP_EXISTING=ON, ONLINE=ON)';
                    ELSE
                        SET @ExtendWithClause = 'WITH(DROP_EXISTING=ON)';
                END
                ELSE
                BEGIN
                    -- No collision: standard WITH clause
                    SET @ExtendWithClause = @WithClause;
                END

                -- Generate CREATE statement with existing keys + merged includes
                SET @ScriptText = @ScriptText + 'CREATE NONCLUSTERED INDEX [' + @IndexName + ']' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + 'ON ' + @Schema + ' (' + @ExistingKeys + ')' + CHAR(13) + CHAR(10);

                -- Only add INCLUDE clause if there are columns to include
                IF @MergedIncludes IS NOT NULL AND @MergedIncludes != ''
                    SET @ScriptText = @ScriptText + 'INCLUDE (' + @MergedIncludes + ')' + CHAR(13) + CHAR(10);

                IF @ExtendWithClause <> ''
                    SET @ScriptText = @ScriptText + @ExtendWithClause + CHAR(13) + CHAR(10);

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- DROP old index (only needed when names differ - collision handled by DROP_EXISTING)
                IF @HasNameCollision = 0 AND @CanDrop = 1
                BEGIN
                    SET @ScriptText = @ScriptText + 'DROP INDEX [' + @ExistingIndexName + '] ON ' + @Schema + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);
                    SET @DropCount = @DropCount + 1;
                END
                ELSE IF @HasNameCollision = 0 AND @CanDrop = 0
                BEGIN
                    -- Add comment explaining why index was not dropped
                    SET @ScriptText = @ScriptText + '-- NOTE: Original index ' + @ExistingIndexName + ' preserved (' + @DropReason + ')' + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);
                END

                -- No separator here - it's added at START of next table (matching Python format)

                -- Check for redundant disabled indexes after EXTEND
                DECLARE @ExtRedundantName NVARCHAR(128);
                DECLARE @ExtRedundantKeys NVARCHAR(MAX);
                DECLARE @ExtRedundantIncludes NVARCHAR(MAX);
                DECLARE @ExtIsPrimaryKey BIT;
                DECLARE @ExtIsUnique BIT;
                DECLARE @ExtHasFilter BIT;

                DECLARE extend_redundant_cursor CURSOR FOR
                    SELECT IndexName, KeyColumns, IncludedColumns, IsPrimaryKey, IsUnique, HasFilter
                    FROM indexing.fn_FindRedundantDisabledIndexes(@DBName, @Schema, @ExistingKeys, @MergedIncludes);

                OPEN extend_redundant_cursor;
                FETCH NEXT FROM extend_redundant_cursor INTO @ExtRedundantName, @ExtRedundantKeys, @ExtRedundantIncludes, @ExtIsPrimaryKey, @ExtIsUnique, @ExtHasFilter;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    -- CRITICAL SAFETY: Never drop primary keys, unique indexes, or filtered indexes
                    IF @ExtIsPrimaryKey = 0 AND @ExtIsUnique = 0 AND @ExtHasFilter = 0
                    BEGIN
                        SET @DropCount = @DropCount + 1;

                        SET @ScriptText = @ScriptText + '-- DROP redundant disabled index' + CHAR(13) + CHAR(10);
                        SET @ScriptText = @ScriptText + '-- ' + @ExtRedundantName + CHAR(13) + CHAR(10);
                        SET @ScriptText = @ScriptText + '-- Key Columns: ' + @ExtRedundantKeys + CHAR(13) + CHAR(10);

                        IF @ExtRedundantIncludes IS NOT NULL AND @ExtRedundantIncludes <> ''
                            SET @ScriptText = @ScriptText + '-- Include Columns: ' + @ExtRedundantIncludes + CHAR(13) + CHAR(10);
                        ELSE
                            SET @ScriptText = @ScriptText + '-- Include Columns: (none)' + CHAR(13) + CHAR(10);

                        SET @ScriptText = @ScriptText + 'DROP INDEX [' + @ExtRedundantName + '] ON ' + @Schema + CHAR(13) + CHAR(10);
                        SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);  -- Blank line after DROP
                    END

                    FETCH NEXT FROM extend_redundant_cursor INTO @ExtRedundantName, @ExtRedundantKeys, @ExtRedundantIncludes, @ExtIsPrimaryKey, @ExtIsUnique, @ExtHasFilter;
                END

                CLOSE extend_redundant_cursor;
                DEALLOCATE extend_redundant_cursor;

                -- Track runnable operations (only if NOT commented out)
                IF @ShouldCommentSQL = 0
                BEGIN
                    SET @RunnableOperationCount = @RunnableOperationCount + 1;
                    IF @EstimatedGB IS NOT NULL
                        SET @RunnableTotalGB = @RunnableTotalGB + @EstimatedGB;  -- Accumulate GB
                END

                -- Close comment block if needed
                IF @ShouldCommentSQL = 1
                    SET @ScriptText = @ScriptText + '*/' + CHAR(13) + CHAR(10);
            END
            ELSE IF @Strategy = 'SUPERSET_COVERED'
            BEGIN
                -- SUPERSET_COVERED - Add comment showing recommendation already covered
                SET @ScriptText = @ScriptText + '-- ALREADY COVERED by existing index' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '-- Existing Index: [' + @ExistingIndexName + ']' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '-- Existing Key Columns: ' + @ExistingKeys + CHAR(13) + CHAR(10);

                IF @ExistingIncludes IS NOT NULL
                    SET @ScriptText = @ScriptText + '-- Existing Include Columns: ' + @ExistingIncludes + CHAR(13) + CHAR(10);

                SET @ScriptText = @ScriptText + '-- ' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '-- Recommendation wanted:' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '-- Key Columns: ' + @KeyCols + CHAR(13) + CHAR(10);

                IF @IncludeCols IS NOT NULL
                    SET @ScriptText = @ScriptText + '-- Include Columns: ' + @IncludeCols + CHAR(13) + CHAR(10);

                -- Add individual recommendation details with Idx Adv
                DECLARE @RecID INT;
                DECLARE @RecAdvantage DECIMAL(18,2);
                DECLARE @RecImpact DECIMAL(18,2);
                DECLARE @RecKeyCols NVARCHAR(MAX);
                DECLARE @RecIncludeCols NVARCHAR(MAX);
                DECLARE @RecCounter INT = 1;

                -- Parse recommendation IDs and show details
                -- Order by: Impact DESC (business priority)
                DECLARE @XML XML = CAST('<i>' + REPLACE(@RecommendationIDs, ',', '</i><i>') + '</i>' AS XML);

                DECLARE rec_cursor CURSOR FOR
                    SELECT ir.RecommendationID
                    FROM indexing.IndexRecommendations ir
                    INNER JOIN (
                        SELECT CAST(T.c.value('.', 'NVARCHAR(10)') AS INT) AS RecID
                        FROM @XML.nodes('/i') T(c)
                    ) ids ON ir.RecommendationID = ids.RecID
                    WHERE ir.DatabaseName = @DBName
                    ORDER BY ir.Impact DESC, ir.IndexAdvantage DESC;  -- Order by Impact, then IndexAdvantage (tiebreaker)

                OPEN rec_cursor;
                FETCH NEXT FROM rec_cursor INTO @RecID;

                SET @ScriptText = @ScriptText + '-- ' + CHAR(13) + CHAR(10);

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    -- Get recommendation details
                    SELECT @RecAdvantage = IndexAdvantage, @RecImpact = Impact,
                           @RecKeyCols = KeyColumns, @RecIncludeCols = IncludedColumns
                    FROM indexing.IndexRecommendations
                    WHERE RecommendationID = @RecID
                      AND DatabaseName = @DBName;

                    -- Normalize column spacing for display
                    SET @RecKeyCols = REPLACE(REPLACE(@RecKeyCols, ', ', ','), ',', ', ');
                    SET @RecIncludeCols = REPLACE(REPLACE(@RecIncludeCols, ', ', ','), ',', ', ');

                    -- Add multi-line recommendation documentation
                    SET @ScriptText = @ScriptText + '-- Rec ' + CAST(@RecCounter AS VARCHAR(10)) + ':' + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + '-- Key Columns: ' + @RecKeyCols + CHAR(13) + CHAR(10);

                    IF @RecIncludeCols IS NOT NULL
                        SET @ScriptText = @ScriptText + '-- Include Columns: ' + @RecIncludeCols + CHAR(13) + CHAR(10);

                    SET @ScriptText = @ScriptText + '-- Idx Adv: ' + CAST(@RecAdvantage AS VARCHAR(20)) +
                                      ' (Impact: ' + CAST(@RecImpact AS VARCHAR(20)) + ')' + CHAR(13) + CHAR(10);
                    -- No blank line between recommendations - only after last one

                    SET @RecCounter = @RecCounter + 1;
                    FETCH NEXT FROM rec_cursor INTO @RecID;
                END

                CLOSE rec_cursor;
                DEALLOCATE rec_cursor;

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);
            END
            ELSE IF @Strategy = 'PREFIX_MATCH'
            BEGIN
                -- PREFIX_MATCH - Show existing index being extended with new comprehensive index
                SET @ScriptText = @ScriptText + '-- EXTEND existing index with additional key columns' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '-- Existing Index: [' + @ExistingIndexName + ']' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '-- Existing Key Columns: ' + @ExistingKeys + CHAR(13) + CHAR(10);

                IF @ExistingIncludes IS NOT NULL
                    SET @ScriptText = @ScriptText + '-- Existing Include Columns: ' + @ExistingIncludes + CHAR(13) + CHAR(10);

                SET @ScriptText = @ScriptText + '-- ' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '-- New comprehensive index will have:' + CHAR(13) + CHAR(10);
                SET @ScriptText = @ScriptText + '-- Key Columns: ' + @KeyCols + CHAR(13) + CHAR(10);

                IF @IncludeCols IS NOT NULL
                    SET @ScriptText = @ScriptText + '-- Include Columns: ' + @IncludeCols + CHAR(13) + CHAR(10);

                -- Add individual recommendation details with Idx Adv
                DECLARE @PrefixRecID INT;
                DECLARE @PrefixRecAdvantage DECIMAL(18,2);
                DECLARE @PrefixRecImpact DECIMAL(18,2);
                DECLARE @PrefixRecKeyCols NVARCHAR(MAX);
                DECLARE @PrefixRecIncludeCols NVARCHAR(MAX);
                DECLARE @PrefixRecCounter INT = 1;

                -- Parse recommendation IDs
                -- Order by: Impact DESC (business priority)
                DECLARE @PrefixXML XML = CAST('<i>' + REPLACE(@RecommendationIDs, ',', '</i><i>') + '</i>' AS XML);

                DECLARE prefix_rec_cursor CURSOR FOR
                    SELECT ir.RecommendationID
                    FROM indexing.IndexRecommendations ir
                    INNER JOIN (
                        SELECT CAST(T.c.value('.', 'NVARCHAR(10)') AS INT) AS RecID
                        FROM @PrefixXML.nodes('/i') T(c)
                    ) ids ON ir.RecommendationID = ids.RecID
                    WHERE ir.DatabaseName = @DBName
                    ORDER BY ir.Impact DESC, ir.IndexAdvantage DESC;  -- Order by Impact, then IndexAdvantage (tiebreaker)

                OPEN prefix_rec_cursor;
                FETCH NEXT FROM prefix_rec_cursor INTO @PrefixRecID;

                SET @ScriptText = @ScriptText + '-- ' + CHAR(13) + CHAR(10);

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    -- Get recommendation details
                    SELECT @PrefixRecAdvantage = IndexAdvantage, @PrefixRecImpact = Impact,
                           @PrefixRecKeyCols = KeyColumns, @PrefixRecIncludeCols = IncludedColumns
                    FROM indexing.IndexRecommendations
                    WHERE RecommendationID = @PrefixRecID
                      AND DatabaseName = @DBName;

                    -- Normalize column spacing for display
                    SET @PrefixRecKeyCols = REPLACE(REPLACE(@PrefixRecKeyCols, ', ', ','), ',', ', ');
                    SET @PrefixRecIncludeCols = REPLACE(REPLACE(@PrefixRecIncludeCols, ', ', ','), ',', ', ');

                    -- Add multi-line recommendation documentation
                    SET @ScriptText = @ScriptText + '-- Rec ' + CAST(@PrefixRecCounter AS VARCHAR(10)) + ':' + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + '-- Key Columns: ' + @PrefixRecKeyCols + CHAR(13) + CHAR(10);

                    IF @PrefixRecIncludeCols IS NOT NULL
                        SET @ScriptText = @ScriptText + '-- Include Columns: ' + @PrefixRecIncludeCols + CHAR(13) + CHAR(10);

                    SET @ScriptText = @ScriptText + '-- Idx Adv: ' + CAST(@PrefixRecAdvantage AS VARCHAR(20)) +
                                      ' (Impact: ' + CAST(@PrefixRecImpact AS VARCHAR(20)) + ')' + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + '-- ' + CHAR(13) + CHAR(10);

                    SET @PrefixRecCounter = @PrefixRecCounter + 1;
                    FETCH NEXT FROM prefix_rec_cursor INTO @PrefixRecID;
                END

                CLOSE prefix_rec_cursor;
                DEALLOCATE prefix_rec_cursor;

                -- Generate index name
                SET @Table = REPLACE(REPLACE(@Schema, '[', ''), ']', '');
                SET @Table = SUBSTRING(@Table, CHARINDEX('.', @Table) + 1, LEN(@Table));

                SET @IndexName = 'IX_' + @Table + '_' + REPLACE(REPLACE(REPLACE(REPLACE(@KeyCols, '[', ''), ']', ''), ', ', '_'), ',', '_');
                IF @IncludeCols IS NOT NULL
                    SET @IndexName = @IndexName + '_INCLUDES';

                -- Check for smart size warning
                DECLARE @SizeWarning2 NVARCHAR(MAX);
                EXEC indexing.sp_GetHybridIndexSizeEstimate @DBName, @Schema, @KeyCols, @IncludeCols, @SizeWarning2 OUTPUT, 0;

                -- Check if this operation should be commented out
                DECLARE @ShouldCommentSQL2 BIT = 0;
                DECLARE @EstimatedGB2 DECIMAL(18,2);
                IF @ActiveThreshold IS NOT NULL AND @SizeWarning2 IS NOT NULL
                BEGIN
                    -- Extract GB estimate from warning
                    DECLARE @GBPos2 INT = CHARINDEX('~', @SizeWarning2);
                    DECLARE @GBEndPos2 INT = CHARINDEX(' GB', @SizeWarning2, @GBPos2);
                    IF @GBPos2 > 0 AND @GBEndPos2 > @GBPos2
                    BEGIN
                        SET @EstimatedGB2 = TRY_CAST(SUBSTRING(@SizeWarning2, @GBPos2 + 1, @GBEndPos2 - @GBPos2 - 1) AS DECIMAL(18,2));
                        IF @EstimatedGB2 >= @ActiveThreshold
                        BEGIN
                            SET @LargeOperationCount = @LargeOperationCount + 1;  -- Track large operation
                            SET @LargeTotalGB = @LargeTotalGB + @EstimatedGB2;  -- Accumulate GB
                            -- Enterprise Bypass: Don't comment if Enterprise + RunnableUnder mode
                            IF @IsEnterprise = 0
                                SET @ShouldCommentSQL2 = 1;
                        END
                    END
                END

                -- Add warning (always visible)
                IF @SizeWarning2 IS NOT NULL
                    SET @ScriptText = @ScriptText + @SizeWarning2 + CHAR(13) + CHAR(10);

                -- Start comment block if needed
                IF @ShouldCommentSQL2 = 1
                    SET @ScriptText = @ScriptText + '/*' + CHAR(13) + CHAR(10);

                -- Generate CREATE statement
                SET @ScriptText = @ScriptText +
                    'CREATE NONCLUSTERED INDEX [' + @IndexName + ']' + CHAR(13) + CHAR(10) +
                    'ON ' + @Schema + ' (' + @KeyCols + ')' + CHAR(13) + CHAR(10);

                IF @IncludeCols IS NOT NULL
                    SET @ScriptText = @ScriptText + 'INCLUDE (' + @IncludeCols + ')' + CHAR(13) + CHAR(10);

                IF @WithClause <> ''
                    SET @ScriptText = @ScriptText + @WithClause + CHAR(13) + CHAR(10);

                -- Track runnable operations (only if NOT commented out)
                IF @ShouldCommentSQL2 = 0
                BEGIN
                    SET @RunnableOperationCount = @RunnableOperationCount + 1;
                    IF @EstimatedGB2 IS NOT NULL
                        SET @RunnableTotalGB = @RunnableTotalGB + @EstimatedGB2;  -- Accumulate GB
                END

                -- Close comment block if needed (before the blank line)
                IF @ShouldCommentSQL2 = 1
                    SET @ScriptText = @ScriptText + '*/' + CHAR(13) + CHAR(10);

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);
            END
            ELSE IF @Strategy IN ('CREATE', 'CREATE_CONSOLIDATED', 'CREATE_SUPER_CONSOLIDATED')
            BEGIN
                -- Add header comment
                IF @RecCount2 > 1
                BEGIN
                    IF @IsSuperConsolidated = 1
                        SET @ScriptText = @ScriptText + '-- CREATE SUPER-CONSOLIDATED INDEX (covers ' + CAST(@RecCount2 AS VARCHAR(10)) + ' recommendation' +
                            CASE WHEN @RecCount2 > 1 THEN 's' ELSE '' END + ' from ' + CAST(@OriginalGroupCount AS VARCHAR(10)) + ' group' +
                            CASE WHEN @OriginalGroupCount > 1 THEN 's' ELSE '' END + ')' + CHAR(13) + CHAR(10);
                    ELSE
                        SET @ScriptText = @ScriptText + '-- CREATE new index (covers ' + CAST(@RecCount2 AS VARCHAR(10)) + ' recommendation' +
                            CASE WHEN @RecCount2 > 1 THEN 's' ELSE '' END + ')' + CHAR(13) + CHAR(10);
                END
                ELSE
                    SET @ScriptText = @ScriptText + '-- CREATE new index' + CHAR(13) + CHAR(10);

                -- Add individual recommendation details with multi-line format and Idx Adv
                DECLARE @CreateRecID INT;
                DECLARE @CreateRecAdvantage DECIMAL(18,2);
                DECLARE @CreateRecImpact DECIMAL(18,2);
                DECLARE @CreateRecKeyCols NVARCHAR(MAX);
                DECLARE @CreateRecIncludeCols NVARCHAR(MAX);
                DECLARE @CreateRecCounter INT = 1;

                -- Parse recommendation IDs
                -- Order by: Impact DESC (business priority)
                DECLARE @CreateXML XML = CAST('<i>' + REPLACE(@RecommendationIDs, ',', '</i><i>') + '</i>' AS XML);

                DECLARE create_rec_cursor CURSOR FOR
                    SELECT ir.RecommendationID
                    FROM indexing.IndexRecommendations ir
                    INNER JOIN (
                        SELECT CAST(T.c.value('.', 'NVARCHAR(10)') AS INT) AS RecID
                        FROM @CreateXML.nodes('/i') T(c)
                    ) ids ON ir.RecommendationID = ids.RecID
                    WHERE ir.DatabaseName = @DBName
                    ORDER BY ir.Impact DESC, ir.IndexAdvantage DESC;  -- Order by Impact, then IndexAdvantage (tiebreaker)

                OPEN create_rec_cursor;
                FETCH NEXT FROM create_rec_cursor INTO @CreateRecID;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    -- Get recommendation details
                    SELECT @CreateRecAdvantage = IndexAdvantage, @CreateRecImpact = Impact,
                           @CreateRecKeyCols = KeyColumns, @CreateRecIncludeCols = IncludedColumns
                    FROM indexing.IndexRecommendations
                    WHERE RecommendationID = @CreateRecID
                      AND DatabaseName = @DBName;

                    -- Normalize column spacing for display
                    SET @CreateRecKeyCols = REPLACE(REPLACE(@CreateRecKeyCols, ', ', ','), ',', ', ');
                    SET @CreateRecIncludeCols = REPLACE(REPLACE(@CreateRecIncludeCols, ', ', ','), ',', ', ');

                    -- Add multi-line recommendation documentation (Idx Adv first to match Python)
                    -- Only show "Rec N:" if there are multiple recommendations
                    IF @RecCount2 > 1
                        SET @ScriptText = @ScriptText + '    -- Rec ' + CAST(@CreateRecCounter AS VARCHAR(10)) + ':' + CHAR(13) + CHAR(10);

                    SET @ScriptText = @ScriptText + '    -- Idx Adv: ' + CAST(@CreateRecAdvantage AS VARCHAR(20)) +
                                      ' (Impact: ' + CAST(@CreateRecImpact AS VARCHAR(20)) + ')' + CHAR(13) + CHAR(10);
                    SET @ScriptText = @ScriptText + '    -- Key Columns: (' + @CreateRecKeyCols + ')' + CHAR(13) + CHAR(10);

                    IF @CreateRecIncludeCols IS NOT NULL
                        SET @ScriptText = @ScriptText + '    -- Include Columns: (' + @CreateRecIncludeCols + ')' + CHAR(13) + CHAR(10);
                    ELSE
                        SET @ScriptText = @ScriptText + '    -- Include Columns: (none)' + CHAR(13) + CHAR(10);

                    SET @CreateRecCounter = @CreateRecCounter + 1;
                    FETCH NEXT FROM create_rec_cursor INTO @CreateRecID;
                END

                CLOSE create_rec_cursor;
                DEALLOCATE create_rec_cursor;

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- Generate index name
                SET @Table = REPLACE(REPLACE(@Schema, '[', ''), ']', '');
                SET @Table = SUBSTRING(@Table, CHARINDEX('.', @Table) + 1, LEN(@Table));

                SET @IndexName = 'IX_' + @Table + '_' + REPLACE(REPLACE(REPLACE(REPLACE(@KeyCols, '[', ''), ']', ''), ', ', '_'), ',', '_');
                IF @IncludeCols IS NOT NULL
                    SET @IndexName = @IndexName + '_INCLUDES';

                -- Check for smart size warning
                DECLARE @SizeWarning3 NVARCHAR(MAX);
                EXEC indexing.sp_GetHybridIndexSizeEstimate @DBName, @Schema, @KeyCols, @IncludeCols, @SizeWarning3 OUTPUT, 0;

                -- Check if this operation should be commented out
                DECLARE @ShouldCommentSQL3 BIT = 0;
                DECLARE @EstimatedGB3 DECIMAL(18,2);
                IF @ActiveThreshold IS NOT NULL AND @SizeWarning3 IS NOT NULL
                BEGIN
                    -- Extract GB estimate from warning
                    DECLARE @GBPos3 INT = CHARINDEX('~', @SizeWarning3);
                    DECLARE @GBEndPos3 INT = CHARINDEX(' GB', @SizeWarning3, @GBPos3);
                    IF @GBPos3 > 0 AND @GBEndPos3 > @GBPos3
                    BEGIN
                        SET @EstimatedGB3 = TRY_CAST(SUBSTRING(@SizeWarning3, @GBPos3 + 1, @GBEndPos3 - @GBPos3 - 1) AS DECIMAL(18,2));
                        IF @EstimatedGB3 >= @ActiveThreshold
                        BEGIN
                            SET @LargeOperationCount = @LargeOperationCount + 1;  -- Track large operation
                            SET @LargeTotalGB = @LargeTotalGB + @EstimatedGB3;  -- Accumulate GB
                            -- Enterprise Bypass: Don't comment if Enterprise + RunnableUnder mode
                            IF @IsEnterprise = 0
                                SET @ShouldCommentSQL3 = 1;
                        END
                    END
                END

                -- Add warning (always visible)
                IF @SizeWarning3 IS NOT NULL
                    SET @ScriptText = @ScriptText + @SizeWarning3 + CHAR(13) + CHAR(10);

                -- Start comment block if needed
                IF @ShouldCommentSQL3 = 1
                    SET @ScriptText = @ScriptText + '/*' + CHAR(13) + CHAR(10);

                -- Generate CREATE statement
                SET @ScriptText = @ScriptText +
                    'CREATE NONCLUSTERED INDEX [' + @IndexName + ']' + CHAR(13) + CHAR(10) +
                    'ON ' + @Schema + ' (' + @KeyCols + ')' + CHAR(13) + CHAR(10);

                IF @IncludeCols IS NOT NULL
                    SET @ScriptText = @ScriptText + 'INCLUDE (' + @IncludeCols + ')' + CHAR(13) + CHAR(10);

                IF @WithClause <> ''
                    SET @ScriptText = @ScriptText + @WithClause + CHAR(13) + CHAR(10);

                SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);

                -- Check for redundant disabled indexes that can be dropped
                DECLARE @RedundantIndexName NVARCHAR(128);
                DECLARE @RedundantKeyColumns NVARCHAR(MAX);
                DECLARE @RedundantIncludeColumns NVARCHAR(MAX);
                DECLARE @IsPrimaryKeyIndex BIT;
                DECLARE @IsUniqueIndex BIT;
                DECLARE @HasFilterIndex BIT;

                DECLARE redundant_cursor CURSOR FOR
                    SELECT IndexName, KeyColumns, IncludedColumns, IsPrimaryKey, IsUnique, HasFilter
                    FROM indexing.fn_FindRedundantDisabledIndexes(@DBName, @Schema, @KeyCols, @IncludeCols);

                OPEN redundant_cursor;
                FETCH NEXT FROM redundant_cursor INTO @RedundantIndexName, @RedundantKeyColumns, @RedundantIncludeColumns, @IsPrimaryKeyIndex, @IsUniqueIndex, @HasFilterIndex;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    -- CRITICAL SAFETY: Never drop primary keys, unique indexes, or filtered indexes
                    IF @IsPrimaryKeyIndex = 0 AND @IsUniqueIndex = 0 AND @HasFilterIndex = 0
                    BEGIN
                        SET @DropCount = @DropCount + 1;

                        -- Add DROP documentation
                        SET @ScriptText = @ScriptText + '-- DROP redundant disabled index' + CHAR(13) + CHAR(10);
                        SET @ScriptText = @ScriptText + '-- ' + @RedundantIndexName + CHAR(13) + CHAR(10);
                        SET @ScriptText = @ScriptText + '-- Key Columns: ' + @RedundantKeyColumns + CHAR(13) + CHAR(10);

                        IF @RedundantIncludeColumns IS NOT NULL AND @RedundantIncludeColumns <> ''
                            SET @ScriptText = @ScriptText + '-- Include Columns: ' + @RedundantIncludeColumns + CHAR(13) + CHAR(10);
                        ELSE
                            SET @ScriptText = @ScriptText + '-- Include Columns: (none)' + CHAR(13) + CHAR(10);

                        -- Generate DROP statement
                        SET @ScriptText = @ScriptText + 'DROP INDEX [' + @RedundantIndexName + '] ON ' + @Schema + CHAR(13) + CHAR(10);
                        SET @ScriptText = @ScriptText + CHAR(13) + CHAR(10);  -- Blank line after DROP
                    END

                    FETCH NEXT FROM redundant_cursor INTO @RedundantIndexName, @RedundantKeyColumns, @RedundantIncludeColumns, @IsPrimaryKeyIndex, @IsUniqueIndex, @HasFilterIndex;
                END

                CLOSE redundant_cursor;
                DEALLOCATE redundant_cursor;

                -- Track runnable operations (only if NOT commented out)
                IF @ShouldCommentSQL3 = 0
                BEGIN
                    SET @RunnableOperationCount = @RunnableOperationCount + 1;
                    IF @EstimatedGB3 IS NOT NULL
                        SET @RunnableTotalGB = @RunnableTotalGB + @EstimatedGB3;  -- Accumulate GB
                END

                -- Close comment block if needed
                IF @ShouldCommentSQL3 = 1
                    SET @ScriptText = @ScriptText + '*/' + CHAR(13) + CHAR(10);
            END

            -- Extract per-finding DDL block and persist to MissingIndexResults
            SET @FindingScript = SUBSTRING(@ScriptText, @ScriptTextBeforeFinding + 1, LEN(@ScriptText) - @ScriptTextBeforeFinding);

            -- Strip trailing CRLF from stored CreateStatement
            WHILE RIGHT(@FindingScript, 2) = CHAR(13) + CHAR(10)
                SET @FindingScript = LEFT(@FindingScript, LEN(@FindingScript + 'x') - 3);

            -- Capture estimated size from whichever strategy branch computed it
            IF @Strategy = 'REBUILD' AND @EstimatedGBRebuild IS NOT NULL
                SET @EstimatedGBCurrent = @EstimatedGBRebuild;
            ELSE IF @Strategy = 'EXTEND_DISABLED' AND @EstimatedGBExtDis IS NOT NULL
                SET @EstimatedGBCurrent = @EstimatedGBExtDis;
            ELSE IF @Strategy IN ('EXTEND', 'UPDATE') AND @EstimatedGB IS NOT NULL
                SET @EstimatedGBCurrent = @EstimatedGB;
            ELSE IF @Strategy = 'PREFIX_MATCH' AND @EstimatedGB2 IS NOT NULL
                SET @EstimatedGBCurrent = @EstimatedGB2;
            ELSE IF @Strategy IN ('CREATE', 'CREATE_CONSOLIDATED', 'CREATE_SUPER_CONSOLIDATED') AND @EstimatedGB3 IS NOT NULL
                SET @EstimatedGBCurrent = @EstimatedGB3;

            IF OBJECT_ID('indexing.MissingIndexResults', 'U') IS NOT NULL
            BEGIN
                INSERT INTO indexing.MissingIndexResults (
                    ServerName, DatabaseName, SchemaName, TableName,
                    Strategy, ExistingIndexName, ExistingKeyColumns, ExistingIncludeColumns,
                    KeyColumns, IncludedColumns, IndexAdvantage, RecommendationCount,
                    RecommendationIDs, IsDisabled, IsSuperConsolidated, OriginalGroupCount,
                    EstimatedSizeGB, CreateStatement)
                VALUES (
                    @ServerName, @DBName, @MIRSchemaName, @MIRTableName,
                    @Strategy, @ExistingIndexName, @ExistingKeys, @ExistingIncludes,
                    @KeyCols, @IncludeCols, @CursorIndexAdvantage, @RecCount2,
                    @RecommendationIDs, @IsDisabled, @IsSuperConsolidated, @OriginalGroupCount,
                    @EstimatedGBCurrent, @FindingScript);
            END

            FETCH NEXT FROM results_cursor INTO @DBName, @Schema, @Strategy, @ExistingIndexName, @ExistingKeys, @ExistingIncludes,
                @IsDisabled, @KeyCols, @IncludeCols, @RecommendationIDs, @RecCount2,
                @IsSuperConsolidated, @OriginalGroupCount, @CursorIndexAdvantage;
        END

        CLOSE results_cursor;
        DEALLOCATE results_cursor;

        -- Build statistics header now that @DropCount is finalized
        -- Format matches Python output exactly
        -- Build stats header with explicit CAST to avoid truncation
        DECLARE @ConsolidationCount INT = @RecCount - @CreateCount - @ExtendCount - @RebuildCount - @SupersetCount;
        DECLARE @StatsHeader NVARCHAR(MAX) =
            '-- MSSQL Index Optimization Recommendations for ' + @ServerName + CHAR(13) + CHAR(10) +
            '-- Generated: ' + CONVERT(VARCHAR(30), GETDATE(), 120) + CHAR(13) + CHAR(10);

        -- Add @RunnableUnder note if enabled
        IF @ActiveThreshold IS NOT NULL
            SET @StatsHeader = @StatsHeader +
                '-- @RunnableUnder = ' + @RunnableUnder + ' (active threshold: ' + CAST(@ActiveThreshold AS VARCHAR(10)) + ' GB), sp_helpindexusage commented, indexes >= threshold commented out' + CHAR(13) + CHAR(10);

        SET @StatsHeader = @StatsHeader +
            '-- Applied all 8 DBA rules with intelligent optimization' + CHAR(13) + CHAR(10) +
            CHAR(13) + CHAR(10) +
            '/*' + CHAR(13) + CHAR(10) +
            'Statistics:' + CHAR(13) + CHAR(10) +
            'Initial recommendations: ' + CAST(@RecCount AS VARCHAR(10)) + CHAR(13) + CHAR(10) +
            'Final' + CHAR(13) + CHAR(10) +
            '    Databases: ' + CAST(@DBCount AS VARCHAR(10)) + CHAR(13) + CHAR(10) +
            '    Create New: ' + CAST(@CreateCount AS VARCHAR(10)) + ' (' + CAST(@ConsolidationCount AS VARCHAR(10)) + ' consolidations)' + CHAR(13) + CHAR(10) +
            '    Created Extended: ' + CAST(@ExtendCount AS VARCHAR(10)) + CHAR(13) + CHAR(10) +
            '    Drop: ' + CAST(@DropCount AS VARCHAR(10)) + CHAR(13) + CHAR(10) +
            '    Rebuild: ' + CAST(@RebuildCount AS VARCHAR(10)) + CHAR(13) + CHAR(10) +
            CASE WHEN @ActiveThreshold IS NOT NULL THEN
                '    Runnable: ' + CAST(@RunnableOperationCount AS VARCHAR(10)) +
                CASE WHEN @RunnableTotalGB > 0 THEN ' (' + CAST(CAST(@RunnableTotalGB AS DECIMAL(18,2)) AS VARCHAR(20)) + ' GB)' ELSE '' END + CHAR(13) + CHAR(10) +
                '    Exceeds Size Limit: ' + CAST(@LargeOperationCount AS VARCHAR(10)) +
                CASE WHEN @LargeTotalGB > 0 THEN ' (' + CAST(CAST(@LargeTotalGB AS DECIMAL(18,2)) AS VARCHAR(20)) + ' GB)' ELSE '' END + CHAR(13) + CHAR(10)
            ELSE '' END +
            '*/' + CHAR(13) + CHAR(10) +
            CHAR(13) + CHAR(10);

        -- Prepend statistics header to script
        -- Use CONCAT to avoid implicit truncation issues with + operator on NVARCHAR(MAX)
        SET @ScriptText = CONCAT(@StatsHeader, @ScriptText);

        -- Trim trailing blank lines (remove trailing CRLF sequences to match Python output)
        WHILE RIGHT(@ScriptText, 2) = CHAR(13) + CHAR(10)
            SET @ScriptText = LEFT(@ScriptText, LEN(@ScriptText) - 2);

        -- Check if there are actually any recommendations to generate
        IF @RecCount = 0 OR @DBCount = 0
        BEGIN
            IF @Debug = 1 PRINT '  > No recommendations found for this server';

            -- Override with NULL script and "No Recommendations" status
            SET @ScriptText = NULL;

            IF @OutputToTable = 1
            BEGIN
                INSERT INTO indexing.GeneratedScripts (ServerName, DatabaseName, ScriptText, [Statistics], [Status])
                VALUES (@ServerName, @DatabaseLabel, NULL, 'No Recommendations', 'No Recommendations');

                IF @Debug = 1 PRINT '  > Status saved to GeneratedScripts table (ScriptID: ' + CAST(SCOPE_IDENTITY() AS VARCHAR(10)) + ')';
            END
        END
        ELSE
        BEGIN
            -- Determine Status based on runnability and Enterprise bypass
            DECLARE @Status NVARCHAR(100);
            IF @ActiveThreshold IS NOT NULL AND @RunnableOperationCount = 0
                SET @Status = 'Nothing To Run Under Parameter';
            ELSE IF @ActiveThreshold IS NOT NULL AND @IsEnterprise = 1 AND @LargeOperationCount > 0
                SET @Status = 'Has Recommendations (Enterprise Bypass)';
            ELSE
                SET @Status = 'Has Recommendations';

            -- Save to table if requested
            IF @OutputToTable = 1
            BEGIN
                INSERT INTO indexing.GeneratedScripts (ServerName, DatabaseName, ScriptText, [Statistics], [Status])
                VALUES (@ServerName, @DatabaseLabel, @ScriptText,
                    CONCAT('Databases: ', @DBCount, ', CREATE: ', @CreateCount, ', EXTEND: ', @ExtendCount, ', REBUILD: ', @RebuildCount, ', DROP: ', @DropCount, ', SUPERSET: ', @SupersetCount,
                        CASE WHEN @ActiveThreshold IS NOT NULL THEN
                            CONCAT(', RUNNABLE: ', @RunnableOperationCount,
                                   CASE WHEN @RunnableTotalGB > 0 THEN CONCAT(' (', CAST(@RunnableTotalGB AS VARCHAR(20)), ' GB)') ELSE '' END,
                                   ', EXCEEDS SIZE LIMIT: ', @LargeOperationCount,
                                   CASE WHEN @LargeTotalGB > 0 THEN CONCAT(' (', CAST(@LargeTotalGB AS VARCHAR(20)), ' GB)') ELSE '' END)
                        ELSE '' END),
                    @Status);

                IF @Debug = 1 PRINT '  > Script saved to GeneratedScripts table (ScriptID: ' + CAST(SCOPE_IDENTITY() AS VARCHAR(10)) + ')';
            END
        END

        IF @Debug = 1
        BEGIN
            DECLARE @Duration INT = DATEDIFF(SECOND, @StartTime, GETDATE());
            PRINT '';
            PRINT 'Generated script for ' + CAST(@DBCount AS VARCHAR(10)) + ' databases';
            PRINT 'Completed in ' + CAST(@Duration AS VARCHAR(10)) + ' seconds';
            PRINT '========================================';
        END

    END TRY
    BEGIN CATCH
        SET @ErrorMessage = ERROR_MESSAGE();
        PRINT 'ERROR: ' + @ErrorMessage;
        ;THROW;
    END CATCH
END
GO

PRINT 'Stored procedure sp_GenerateOptimizationScript (V4.1) created successfully.';
PRINT '  > Fixed: Now properly handles multiple databases from CSV data';
PRINT '  > Fixed: Database count in statistics now accurate';
PRINT '  > Fixed: Generates separate database sections with headers';

GO

-- =============================================

IF OBJECT_ID('indexing.sp_LoadDataFromServer', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_LoadDataFromServer;
GO

CREATE PROCEDURE indexing.sp_LoadDataFromServer
    @ServerName NVARCHAR(128) = NULL,
    @MinIndexAdvantage DECIMAL(18,2) = 2500.0,
    @MinAvgUserImpact DECIMAL(18,2) = 99.0,
    @DatabaseMode NVARCHAR(MAX) = NULL,  -- NULL = all user databases, or comma-delimited list
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ServerName IS NULL
        SET @ServerName = @@SERVERNAME;

    IF @Debug = 1
    BEGIN
        PRINT 'Loading data from SQL Server DMVs...';
        PRINT '  Server: ' + @ServerName;
        PRINT '  Min Index Advantage: ' + CAST(@MinIndexAdvantage AS VARCHAR(20));
        PRINT '  Min Average User Impact: ' + CAST(@MinAvgUserImpact AS VARCHAR(20));
        IF @DatabaseMode IS NULL
            PRINT '  Database Filter: All user databases (database_id > 4, ONLINE)';
        ELSE
            PRINT '  Database Filter: ' + @DatabaseMode;
    END

    -- Clear existing data for this server
    DELETE FROM indexing.IndexRecommendations WHERE ServerName = @ServerName;
    DELETE FROM indexing.CurrentIndexes WHERE ServerName = @ServerName;
    DELETE FROM indexing.ServerInfo WHERE ServerName = @ServerName;

    IF @Debug = 1 PRINT 'Cleared existing data for ' + @ServerName;

    -- =============================================
    -- STEP 1: Load Server Edition Information
    -- =============================================
    IF @Debug = 1 PRINT 'Loading server edition information...';

    INSERT INTO indexing.ServerInfo (ServerName, Edition, IsEnterprise)
    SELECT
        @ServerName,
        CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)),
        CASE
            WHEN CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Enterprise%' THEN 1
            WHEN CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Developer%' THEN 1
            ELSE 0
        END;

    IF @Debug = 1 PRINT '  > Loaded server edition: ' + CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128));

    -- =============================================
    -- STEP 2: Load Missing Index Recommendations
    -- =============================================
    IF @Debug = 1 PRINT 'Loading missing index recommendations from DMVs...';

    -- Dynamic SQL for recommendations (this part works fine)
    DECLARE @SQL NVARCHAR(MAX) = N'
    WITH MissingIndexStats AS (
        SELECT
            mid.database_id,
            mid.object_id,
            mid.equality_columns,
            mid.inequality_columns,
            mid.included_columns,
            migs.user_seeks,
            migs.user_scans,
            migs.avg_total_user_cost,
            migs.avg_user_impact,
            CAST((migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans)) * 0.01 AS DECIMAL(18,2)) AS IndexAdvantage,
            CAST((migs.user_seeks + migs.user_scans) * migs.avg_total_user_cost * (migs.avg_user_impact / 100.0) AS DECIMAL(18,2)) AS Impact
        FROM sys.dm_db_missing_index_details mid
        INNER JOIN sys.dm_db_missing_index_groups mig ON mid.index_handle = mig.index_handle
        INNER JOIN sys.dm_db_missing_index_group_stats migs ON mig.index_group_handle = migs.group_handle
        WHERE mid.database_id = DB_ID()
          AND (migs.user_seeks + migs.user_scans) > 0
          AND OBJECT_SCHEMA_NAME(mid.object_id) <> ''cdc''
    )
    SELECT
        ''' + @ServerName + ''' AS ServerName,
        DB_NAME() AS DatabaseName,
        IndexAdvantage,
        NULL AS EstimatedQueryTime,
        QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(OBJECT_NAME(object_id)) AS SchemaTable,
        CASE
            WHEN equality_columns IS NOT NULL AND inequality_columns IS NOT NULL
                THEN equality_columns + '', '' + inequality_columns
            WHEN equality_columns IS NOT NULL
                THEN equality_columns
            WHEN inequality_columns IS NOT NULL
                THEN inequality_columns
            ELSE ''''
        END AS KeyColumns,
        included_columns AS IncludedColumns,
        user_seeks,
        user_scans,
        CAST((avg_user_impact * 100) AS DECIMAL(10,2)) AS PercentImprovement,
        avg_total_user_cost,
        Impact
    FROM MissingIndexStats
    WHERE (IndexAdvantage >= ' + CAST(@MinIndexAdvantage AS NVARCHAR(20)) + '
        OR (IndexAdvantage >= 1000 AND avg_user_impact > ' + CAST(@MinAvgUserImpact AS NVARCHAR(20)) + ')
        )
    ORDER BY IndexAdvantage DESC;
    ';

    -- Create temp table to collect recommendations
    CREATE TABLE #Recommendations (
        ServerName NVARCHAR(128),
        DatabaseName NVARCHAR(256),
        IndexAdvantage DECIMAL(18,2),
        EstimatedQueryTime NVARCHAR(20),
        SchemaTable NVARCHAR(512),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX),
        UserSeeks BIGINT,
        UserScans BIGINT,
        PercentImprovement DECIMAL(10,2),
        AvgTotalUserCost FLOAT,
        Impact DECIMAL(18,2)
    );

    -- Get list of databases based on @DatabaseMode parameter
    DECLARE @DBName NVARCHAR(128);
    DECLARE @DBExecSQL NVARCHAR(MAX);

    IF @DatabaseMode IS NULL
    BEGIN
        DECLARE db_cursor CURSOR FOR
            SELECT d.name
            FROM sys.databases d
            WHERE d.state_desc = 'ONLINE'
              AND d.database_id > 4
            ORDER BY d.name;
    END
    ELSE IF @DatabaseMode LIKE '%[%]%'
    BEGIN
        DECLARE db_cursor CURSOR FOR
            SELECT d.name
            FROM sys.databases d
            WHERE d.state_desc = 'ONLINE'
              AND d.name LIKE @DatabaseMode
            ORDER BY d.name;
    END
    ELSE
    BEGIN
        DECLARE db_cursor CURSOR FOR
            SELECT d.name
            FROM sys.databases d
            INNER JOIN STRING_SPLIT(@DatabaseMode, ',') s ON d.name = LTRIM(RTRIM(s.value))
            WHERE d.state_desc = 'ONLINE'
            ORDER BY d.name;
    END

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DBName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Debug = 1 PRINT '  > Processing database: ' + @DBName;

        SET @DBExecSQL = N'USE [' + @DBName + N']; ' + @SQL;

        BEGIN TRY
            INSERT INTO #Recommendations
            EXEC sp_executesql @DBExecSQL;
        END TRY
        BEGIN CATCH
            IF @Debug = 1
                PRINT '    WARNING: Could not process ' + @DBName + ' - ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DBName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    -- Insert recommendations into permanent table
    INSERT INTO indexing.IndexRecommendations (
        ServerName, DatabaseName, IndexAdvantage, EstimatedQueryTime,
        SchemaTable, KeyColumns, IncludedColumns,
        UserSeeks, UserScans, PercentImprovement, AvgTotalUserCost, Impact
    )
    SELECT * FROM #Recommendations;

    DECLARE @RecCount INT = @@ROWCOUNT;
    IF @Debug = 1 PRINT '  > Loaded ' + CAST(@RecCount AS VARCHAR(10)) + ' recommendations';

    DROP TABLE #Recommendations;

    -- =============================================
    -- STEP 3: Load Current Index Information
    -- OPTIMIZED: Only load indexes for tables with recommendations
    -- =============================================
    IF @Debug = 1 PRINT 'Loading current index information (filtered to tables with recommendations)...';

    -- Get list of tables that have recommendations per database
    -- Use global temp table so dynamic SQL can access it
    IF OBJECT_ID('tempdb..##TablesToProcess') IS NOT NULL
        DROP TABLE ##TablesToProcess;

    CREATE TABLE ##TablesToProcess (
        DatabaseName NVARCHAR(128),
        SchemaTable NVARCHAR(512)
    );

    INSERT INTO ##TablesToProcess (DatabaseName, SchemaTable)
    SELECT DISTINCT DatabaseName, SchemaTable
    FROM indexing.IndexRecommendations
    WHERE ServerName = @ServerName;

    DECLARE @TableCount INT;
    DECLARE @DBCountWithRecs INT;
    SELECT @TableCount = COUNT(*) FROM ##TablesToProcess;
    SELECT @DBCountWithRecs = COUNT(DISTINCT DatabaseName) FROM ##TablesToProcess;
    IF @Debug = 1 PRINT '  > Will process indexes for ' + CAST(@TableCount AS VARCHAR(10)) + ' tables across ' + CAST(@DBCountWithRecs AS VARCHAR(10)) + ' databases';

    -- Build filtered query with table list
    SET @SQL = N'
    -- Create temp table with tables to process for this database
    CREATE TABLE #FilterTables (SchemaTable NVARCHAR(512));
    INSERT INTO #FilterTables (SchemaTable)
    SELECT SchemaTable FROM ##TablesToProcess WHERE DatabaseName = DB_NAME();

    -- First, get the index basics with size (FILTERED to tables with recommendations)
    SELECT
        ''' + @ServerName + ''' AS ServerName,
        DB_NAME() AS DatabaseName,
        QUOTENAME(OBJECT_SCHEMA_NAME(i.object_id)) + ''.'' + QUOTENAME(OBJECT_NAME(i.object_id)) AS SchemaTable,
        i.name AS IndexName,
        i.object_id,
        i.index_id,
        i.is_disabled AS IsDisabled,
        i.is_primary_key AS IsPrimaryKey,
        i.is_unique AS IsUnique,
        i.has_filter AS HasFilter,
        CAST(ISNULL(SUM(ps.used_page_count) * 8.0 / 1024.0, 0) AS DECIMAL(18,2)) AS IndexSizeMB
    INTO #IndexBasics
    FROM sys.indexes i
    LEFT JOIN sys.dm_db_partition_stats ps ON i.object_id = ps.object_id AND i.index_id = ps.index_id
    WHERE i.type IN (1, 2)
      AND OBJECTPROPERTY(i.object_id, ''IsUserTable'') = 1
      AND QUOTENAME(OBJECT_SCHEMA_NAME(i.object_id)) + ''.'' + QUOTENAME(OBJECT_NAME(i.object_id)) IN (SELECT SchemaTable FROM #FilterTables)
    GROUP BY
        i.object_id, i.index_id, i.name,
        i.is_disabled, i.is_primary_key, i.is_unique, i.has_filter;

    -- Then, build key columns
    SELECT
        ib.object_id,
        ib.index_id,
        STUFF((
            SELECT '', '' + QUOTENAME(c.name)
            FROM sys.index_columns ic
            INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = ib.object_id
              AND ic.index_id = ib.index_id
              AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''NVARCHAR(MAX)''), 1, 2, '''') AS KeyColumns
    INTO #KeyCols
    FROM #IndexBasics ib;

    -- Then, build included columns
    SELECT
        ib.object_id,
        ib.index_id,
        STUFF((
            SELECT '', '' + QUOTENAME(c.name)
            FROM sys.index_columns ic
            INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = ib.object_id
              AND ic.index_id = ib.index_id
              AND ic.is_included_column = 1
            ORDER BY ic.index_column_id
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''NVARCHAR(MAX)''), 1, 2, '''') AS IncludedColumns
    INTO #IncludeCols
    FROM #IndexBasics ib;

    -- Finally, join everything together
    SELECT
        ib.ServerName,
        ib.DatabaseName,
        ib.SchemaTable,
        ib.IndexName,
        kc.KeyColumns,
        ic.IncludedColumns,
        ib.IsDisabled,
        ib.IsPrimaryKey,
        ib.IsUnique,
        ib.HasFilter,
        ib.IndexSizeMB
    FROM #IndexBasics ib
    LEFT JOIN #KeyCols kc ON ib.object_id = kc.object_id AND ib.index_id = kc.index_id
    LEFT JOIN #IncludeCols ic ON ib.object_id = ic.object_id AND ib.index_id = ic.index_id
    ORDER BY ib.SchemaTable, ib.IndexName;

    DROP TABLE #IndexBasics;
    DROP TABLE #KeyCols;
    DROP TABLE #IncludeCols;
    DROP TABLE #FilterTables;
    ';

    -- Create temp table for current indexes
    CREATE TABLE #CurrentIndexes (
        ServerName NVARCHAR(128),
        DatabaseName NVARCHAR(256),
        SchemaTable NVARCHAR(512),
        IndexName NVARCHAR(256),
        KeyColumns NVARCHAR(MAX),
        IncludedColumns NVARCHAR(MAX),
        IsDisabled BIT,
        IsPrimaryKey BIT,
        IsUnique BIT,
        HasFilter BIT,
        IndexSizeMB DECIMAL(18,2)
    );

    -- Redeclare cursor for databases (ONLY databases with recommendations)
    DECLARE db_cursor2 CURSOR FOR
        SELECT DISTINCT DatabaseName
        FROM ##TablesToProcess
        ORDER BY DatabaseName;

    OPEN db_cursor2;
    FETCH NEXT FROM db_cursor2 INTO @DBName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Debug = 1 PRINT '  > Processing indexes in: ' + @DBName;

        SET @DBExecSQL = N'USE [' + @DBName + N']; ' + @SQL;

        BEGIN TRY
            INSERT INTO #CurrentIndexes
            EXEC sp_executesql @DBExecSQL;
        END TRY
        BEGIN CATCH
            IF @Debug = 1
                PRINT '    WARNING: Could not process indexes in ' + @DBName + ' - ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM db_cursor2 INTO @DBName;
    END

    CLOSE db_cursor2;
    DEALLOCATE db_cursor2;

    -- Insert into permanent table
    INSERT INTO indexing.CurrentIndexes (
        ServerName, DatabaseName, SchemaTable, IndexName,
        KeyColumns, IncludedColumns, IsDisabled, IsPrimaryKey, IsUnique, HasFilter, IndexSizeMB
    )
    SELECT * FROM #CurrentIndexes;

    DECLARE @IndexCount INT = @@ROWCOUNT;
    IF @Debug = 1 PRINT '  > Loaded ' + CAST(@IndexCount AS VARCHAR(10)) + ' current indexes';

    DROP TABLE #CurrentIndexes;
    DROP TABLE ##TablesToProcess;

    -- =============================================
    -- Summary
    -- =============================================
    IF @Debug = 1
    BEGIN
        DECLARE @DBCount INT;
        SELECT @DBCount = COUNT(DISTINCT DatabaseName)
        FROM indexing.IndexRecommendations
        WHERE ServerName = @ServerName;

        PRINT '';
        PRINT 'Data loading complete:';
        PRINT '  Server: ' + @ServerName;
        PRINT '  Recommendations: ' + CAST(@RecCount AS VARCHAR(10));
        PRINT '  Current Indexes: ' + CAST(@IndexCount AS VARCHAR(10));
        PRINT '  Databases Processed: ' + CAST(@DBCount AS VARCHAR(10));
    END

END
GO

PRINT 'Stored procedure indexing.sp_LoadDataFromServer created successfully (FIXED VERSION).';
GO

GO

-- =============================================

IF OBJECT_ID('indexing.sp_LoadTestDataFromCSV', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_LoadTestDataFromCSV;
GO

CREATE PROCEDURE indexing.sp_LoadTestDataFromCSV
    @CSVPath NVARCHAR(500) = 'D:\sites\claude\optimize-index\Python\Dev\input\',
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @RecommendationsFile NVARCHAR(500);
    DECLARE @CurrentIndexesFile NVARCHAR(500);
    DECLARE @SQL NVARCHAR(MAX);
    DECLARE @RowCount INT;

    BEGIN TRY
        -- Build file paths
        SET @RecommendationsFile = @CSVPath + 'recommendations.csv';
        SET @CurrentIndexesFile = @CSVPath + 'currentindexes.csv';
        DECLARE @ServerInfoFile NVARCHAR(500) = @CSVPath + 'serverinfo.csv';

        IF @Debug = 1
        BEGIN
            PRINT 'Loading test data from CSV files...';
            PRINT 'Recommendations file: ' + @RecommendationsFile;
            PRINT 'Current indexes file: ' + @CurrentIndexesFile;
            PRINT 'Server info file: ' + @ServerInfoFile;
        END

        -- Clear existing data
        TRUNCATE TABLE indexing.IndexRecommendations;
        TRUNCATE TABLE indexing.CurrentIndexes;
        TRUNCATE TABLE indexing.ServerInfo;

        -- ============================================
        -- Load Recommendations using FORMAT CSV
        -- ============================================
        IF @Debug = 1 PRINT 'Loading recommendations...';

        -- Create temp table (all NVARCHAR to avoid type conversion issues)
        IF OBJECT_ID('tempdb..#TempRec') IS NOT NULL DROP TABLE #TempRec;
        CREATE TABLE #TempRec (
            Col1 NVARCHAR(128),   -- Server Name
            Col2 NVARCHAR(128),   -- database_name
            Col3 NVARCHAR(50),    -- index_advantage
            Col4 NVARCHAR(50),    -- last_user_seek
            Col5 NVARCHAR(256),   -- schema_table
            Col6 NVARCHAR(MAX),   -- key_columns
            Col7 NVARCHAR(MAX),   -- included_columns
            Col8 NVARCHAR(50),    -- unique_compiles
            Col9 NVARCHAR(50),    -- user_seeks
            Col10 NVARCHAR(50),   -- avg_total_user_cost
            Col11 NVARCHAR(50),   -- avg_user_impact
            Col12 NVARCHAR(50)    -- impact
        );

        -- Load using BULK INSERT with FORMAT='CSV'
        BEGIN TRY
            SET @SQL = '
            BULK INSERT #TempRec
            FROM ''' + @RecommendationsFile + '''
            WITH (
                FORMAT = ''CSV'',
                FIRSTROW = 2,
                FIELDQUOTE = ''"'',
                TABLOCK
            );';
            EXEC sp_executesql @SQL;
            SET @RowCount = @@ROWCOUNT;
        END TRY
        BEGIN CATCH
            -- If FORMAT='CSV' fails, try without it (fallback for older SQL versions)
            IF @Debug = 1 PRINT '  > FORMAT=CSV failed, trying standard BULK INSERT...';

            TRUNCATE TABLE #TempRec;

            SET @SQL = '
            BULK INSERT #TempRec
            FROM ''' + @RecommendationsFile + '''
            WITH (
                FIRSTROW = 2,
                FIELDTERMINATOR = '','',
                ROWTERMINATOR = ''0x0A'',
                TABLOCK,
                MAXERRORS = 1000
            );';
            EXEC sp_executesql @SQL;
            SET @RowCount = @@ROWCOUNT;
        END CATCH

        IF @Debug = 1
        BEGIN
            PRINT '  > Loaded ' + CAST(@RowCount AS VARCHAR(10)) + ' rows into temp table';

            -- Check for issues
            DECLARE @NullCount INT;
            SELECT @NullCount = COUNT(*) FROM #TempRec WHERE Col5 IS NULL OR Col5 = '';
            IF @NullCount > 0
                PRINT '  > WARNING: ' + CAST(@NullCount AS VARCHAR(10)) + ' rows have NULL/empty schema_table';
        END

        -- Insert with type conversion, skipping rows with NULL required fields
        INSERT INTO indexing.IndexRecommendations (
            ServerName, DatabaseName, SchemaTable, KeyColumns, IncludedColumns,
            IndexAdvantage, Impact
        )
        SELECT
            Col1,  -- ServerName
            Col2,  -- DatabaseName
            Col5,  -- SchemaTable
            Col6,  -- KeyColumns
            NULLIF(Col7, ''),  -- IncludedColumns (empty string -> NULL)
            TRY_CAST(NULLIF(Col3, '') AS DECIMAL(18,2)),  -- IndexAdvantage
            TRY_CAST(NULLIF(Col12, '') AS DECIMAL(18,2))  -- Impact
        FROM #TempRec
        WHERE Col5 IS NOT NULL AND Col5 <> ''  -- Skip rows with NULL/empty required fields
            AND Col6 IS NOT NULL AND Col6 <> '';  -- SchemaTable and KeyColumns required

        SET @RowCount = @@ROWCOUNT;
        IF @Debug = 1 PRINT '  > Inserted ' + CAST(@RowCount AS VARCHAR(10)) + ' recommendations';

        DROP TABLE #TempRec;

        -- ============================================
        -- Load Current Indexes
        -- ============================================
        IF @Debug = 1 PRINT 'Loading current indexes...';

        -- CSV Order: Server Name, database_name, index_name, last_lookup, schema_table,
        --            key_columns, included_columns, index_size_mb, num_of_reads,
        --            num_of_writes, difference, is_disabled, is_primary_key, is_unique, has_filter
        IF OBJECT_ID('tempdb..#TempIdx') IS NOT NULL DROP TABLE #TempIdx;
        CREATE TABLE #TempIdx (
            Col1 NVARCHAR(128),   -- Server Name
            Col2 NVARCHAR(128),   -- database_name
            Col3 NVARCHAR(128),   -- index_name
            Col4 NVARCHAR(50),    -- last_lookup
            Col5 NVARCHAR(256),   -- schema_table
            Col6 NVARCHAR(MAX),   -- key_columns
            Col7 NVARCHAR(MAX),   -- included_columns
            Col8 NVARCHAR(50),    -- index_size_mb
            Col9 NVARCHAR(50),    -- num_of_reads
            Col10 NVARCHAR(50),   -- num_of_writes
            Col11 NVARCHAR(50),   -- difference
            Col12 NVARCHAR(10),   -- is_disabled
            Col13 NVARCHAR(10),   -- is_primary_key
            Col14 NVARCHAR(10),   -- is_unique
            Col15 NVARCHAR(10)    -- has_filter
        );

        BEGIN TRY
            SET @SQL = '
            BULK INSERT #TempIdx
            FROM ''' + @CurrentIndexesFile + '''
            WITH (
                FORMAT = ''CSV'',
                FIRSTROW = 2,
                FIELDQUOTE = ''"'',
                TABLOCK
            );';
            EXEC sp_executesql @SQL;
            SET @RowCount = @@ROWCOUNT;
        END TRY
        BEGIN CATCH
            IF @Debug = 1 PRINT '  > FORMAT=CSV failed, trying standard BULK INSERT...';

            TRUNCATE TABLE #TempIdx;

            SET @SQL = '
            BULK INSERT #TempIdx
            FROM ''' + @CurrentIndexesFile + '''
            WITH (
                FIRSTROW = 2,
                FIELDTERMINATOR = '','',
                ROWTERMINATOR = ''0x0A'',
                TABLOCK,
                MAXERRORS = 1000
            );';
            EXEC sp_executesql @SQL;
            SET @RowCount = @@ROWCOUNT;
        END CATCH

        IF @Debug = 1 PRINT '  > Loaded ' + CAST(@RowCount AS VARCHAR(10)) + ' rows into temp table';

        -- Insert with type conversion (using corrected column positions)
        INSERT INTO indexing.CurrentIndexes (
            ServerName, DatabaseName, SchemaTable, IndexName, KeyColumns, IncludedColumns,
            IndexSizeMB, IsDisabled, IsPrimaryKey, IsUnique, HasFilter
        )
        SELECT
            Col1,  -- ServerName
            Col2,  -- DatabaseName
            Col5,  -- SchemaTable (position 5 in CSV)
            Col3,  -- IndexName (position 3 in CSV)
            Col6,  -- KeyColumns (position 6 in CSV)
            NULLIF(Col7, ''),  -- IncludedColumns (position 7 in CSV)
            TRY_CAST(NULLIF(Col8, '') AS DECIMAL(18,2)),  -- IndexSizeMB (position 8 in CSV)
            CASE WHEN Col12 = '1' THEN 1 ELSE 0 END,  -- IsDisabled (position 12)
            CASE WHEN Col13 = '1' THEN 1 ELSE 0 END,  -- IsPrimaryKey (position 13)
            CASE WHEN Col14 = '1' THEN 1 ELSE 0 END,  -- IsUnique (position 14)
            CASE WHEN Col15 = '1' THEN 1 ELSE 0 END   -- HasFilter (position 15)
        FROM #TempIdx
        WHERE Col5 IS NOT NULL AND Col5 <> ''  -- SchemaTable required (position 5)
            AND Col3 IS NOT NULL AND Col3 <> ''  -- IndexName required (position 3)
            AND Col6 IS NOT NULL AND Col6 <> '';  -- KeyColumns required (position 6)

        SET @RowCount = @@ROWCOUNT;
        IF @Debug = 1 PRINT '  > Inserted ' + CAST(@RowCount AS VARCHAR(10)) + ' current indexes';

        DROP TABLE #TempIdx;

        -- ============================================
        -- Load Server Info
        -- ============================================
        IF @Debug = 1 PRINT 'Loading server info...';

        IF OBJECT_ID('tempdb..#TempServer') IS NOT NULL DROP TABLE #TempServer;
        CREATE TABLE #TempServer (
            Col1 NVARCHAR(128),   -- ServerName
            Col2 NVARCHAR(50),    -- Edition
            Col3 NVARCHAR(100)    -- SQLVersion
        );

        BEGIN TRY
            SET @SQL = '
            BULK INSERT #TempServer
            FROM ''' + @ServerInfoFile + '''
            WITH (
                FORMAT = ''CSV'',
                FIRSTROW = 2,
                FIELDQUOTE = ''"'',
                TABLOCK
            );';
            EXEC sp_executesql @SQL;
            SET @RowCount = @@ROWCOUNT;
        END TRY
        BEGIN CATCH
            IF @Debug = 1 PRINT '  > FORMAT=CSV failed, trying standard BULK INSERT...';

            TRUNCATE TABLE #TempServer;

            SET @SQL = '
            BULK INSERT #TempServer
            FROM ''' + @ServerInfoFile + '''
            WITH (
                FIRSTROW = 2,
                FIELDTERMINATOR = '','',
                ROWTERMINATOR = ''0x0A'',
                TABLOCK,
                MAXERRORS = 10
            );';
            EXEC sp_executesql @SQL;
            SET @RowCount = @@ROWCOUNT;
        END CATCH

        IF @Debug = 1 PRINT '  > Loaded ' + CAST(@RowCount AS VARCHAR(10)) + ' rows into temp table';

        -- Insert server info
        INSERT INTO indexing.ServerInfo (ServerName, Edition)
        SELECT
            Col1,  -- ServerName
            Col2   -- Edition
        FROM #TempServer
        WHERE Col1 IS NOT NULL AND Col1 <> ''
            AND Col2 IS NOT NULL AND Col2 <> '';

        SET @RowCount = @@ROWCOUNT;
        IF @Debug = 1 PRINT '  > Inserted ' + CAST(@RowCount AS VARCHAR(10)) + ' server info records';

        DROP TABLE #TempServer;

        IF @Debug = 1 PRINT 'CSV data loaded successfully.';

    END TRY
    BEGIN CATCH
        SET @ErrorMessage = ERROR_MESSAGE();
        PRINT 'ERROR loading CSV files: ' + @ErrorMessage;
        PRINT 'Make sure:';
        PRINT '  1. CSV files exist at the specified path';
        PRINT '  2. SQL Server has read access to the files';
        PRINT '  3. Files are in UTF-8 format';

        -- Cleanup
        IF OBJECT_ID('tempdb..#TempRec') IS NOT NULL DROP TABLE #TempRec;
        IF OBJECT_ID('tempdb..#TempIdx') IS NOT NULL DROP TABLE #TempIdx;
        IF OBJECT_ID('tempdb..#TempServer') IS NOT NULL DROP TABLE #TempServer;

        ;THROW;
    END CATCH
END
GO

PRINT 'Stored procedure sp_LoadTestDataFromCSV created successfully.';

GO

-- =============================================
USE DBA_Utilities;
GO

IF OBJECT_ID('indexing.sp_ExportGeneratedScript', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_ExportGeneratedScript;
GO

CREATE PROCEDURE indexing.sp_ExportGeneratedScript
    @ServerName NVARCHAR(128) = NULL,  -- Get latest script for this server
    @ScriptID INT = NULL,              -- Get specific script by ID
    @OutputPath NVARCHAR(500) = NULL   -- Optional: specify output file path
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Script NVARCHAR(MAX);
    DECLARE @ActualScriptID INT;
    DECLARE @ActualServerName NVARCHAR(128);
    DECLARE @GeneratedDate DATETIME;
    DECLARE @Command NVARCHAR(4000);

    -- Validate parameters
    IF @ServerName IS NULL AND @ScriptID IS NULL
    BEGIN
        PRINT 'ERROR: Must specify either @ServerName or @ScriptID';
        PRINT 'Usage:';
        PRINT '  EXEC indexing.sp_ExportGeneratedScript @ServerName=''USW2-018-SQL''';
        PRINT '  EXEC indexing.sp_ExportGeneratedScript @ScriptID=1';
        RETURN;
    END

    IF @ServerName IS NOT NULL AND @ScriptID IS NOT NULL
    BEGIN
        PRINT 'ERROR: Specify either @ServerName OR @ScriptID, not both';
        RETURN;
    END

    -- Get script from GeneratedScripts table
    IF @ScriptID IS NOT NULL
    BEGIN
        -- Get specific script by ID
        SELECT
            @ActualScriptID = ScriptID,
            @ActualServerName = ServerName,
            @Script = ScriptText,
            @GeneratedDate = GeneratedDate
        FROM indexing.GeneratedScripts
        WHERE ScriptID = @ScriptID;

        IF @Script IS NULL
        BEGIN
            PRINT 'ERROR: No script found with ScriptID: ' + CAST(@ScriptID AS VARCHAR(10));
            RETURN;
        END
    END
    ELSE
    BEGIN
        -- Get latest script for server (highest ScriptID = most recent)
        SELECT TOP 1
            @ActualScriptID = ScriptID,
            @ActualServerName = ServerName,
            @Script = ScriptText,
            @GeneratedDate = GeneratedDate
        FROM indexing.GeneratedScripts
        WHERE ServerName = @ServerName
        ORDER BY ScriptID DESC;

        IF @Script IS NULL
        BEGIN
            PRINT 'ERROR: No script found for server: ' + @ServerName;
            RETURN;
        END
    END

    -- If no output path specified, check size and choose output method
    IF @OutputPath IS NULL
    BEGIN
        DECLARE @ScriptLength INT = LEN(@Script);

        -- For large scripts (>50KB), recommend file export
        IF @ScriptLength > 50000
        BEGIN
            PRINT '/*';
            PRINT '============================================';
            PRINT 'Script Length: ' + CAST(@ScriptLength AS VARCHAR(20)) + ' characters (TOO LARGE for console)';
            PRINT '============================================';
            PRINT '';
            PRINT 'This script is too large for reliable console viewing.';
            PRINT '';
            PRINT 'RECOMMENDED SOLUTION 1: Export to file';
            PRINT '  EXEC indexing.sp_ExportGeneratedScript';
            PRINT '      @ServerName=''' + @ActualServerName + ''',';
            PRINT '      @OutputPath=''C:\temp\' + @ActualServerName + '_script.sql'';';
            PRINT '';
            PRINT 'RECOMMENDED SOLUTION 2: Direct query in SSMS';
            PRINT '  1. Press Ctrl+Shift+F (Results to File)';
            PRINT '  2. Run this query:';
            PRINT '     SELECT ScriptText FROM indexing.GeneratedScripts WHERE ScriptID=' + CAST(@ActualScriptID AS VARCHAR(10)) + ';';
            PRINT '  3. Choose save location';
            PRINT '';
            PRINT 'SOLUTION 3: Copy from grid (may lose formatting)';
            PRINT '  SELECT ScriptText FROM indexing.GeneratedScripts WHERE ScriptID=' + CAST(@ActualScriptID AS VARCHAR(10)) + ';';
            PRINT '';
            PRINT '============================================';
            PRINT '*/';
            RETURN;
        END

        -- For smaller scripts, print in chunks
        PRINT '/*';
        PRINT 'ScriptID: ' + CAST(@ActualScriptID AS VARCHAR(10));
        PRINT 'Server: ' + @ActualServerName;
        PRINT 'Generated: ' + CONVERT(VARCHAR(20), @GeneratedDate, 120);
        PRINT 'Script Length: ' + CAST(@ScriptLength AS VARCHAR(20)) + ' characters';
        PRINT '*/';
        PRINT '';

        -- Print script in 8000-char chunks (PRINT limit)
        DECLARE @ChunkSize INT = 8000;
        DECLARE @Offset INT = 1;

        WHILE @Offset <= @ScriptLength
        BEGIN
            PRINT SUBSTRING(@Script, @Offset, @ChunkSize);
            SET @Offset = @Offset + @ChunkSize;
        END
    END
    ELSE
    BEGIN
        -- Export to file using BCP
        SET @Command = 'bcp "SELECT ScriptText FROM DBA_Utilities.indexing.GeneratedScripts WHERE ScriptID = ' + CAST(@ActualScriptID AS VARCHAR(10)) + '" queryout "' + @OutputPath + '" -c -T -S ' + @@SERVERNAME;

        PRINT 'Exporting script to: ' + @OutputPath;
        PRINT 'ScriptID: ' + CAST(@ActualScriptID AS VARCHAR(10)) + ' | Server: ' + @ActualServerName + ' | Generated: ' + CONVERT(VARCHAR(20), @GeneratedDate, 120);
        EXEC xp_cmdshell @Command;
        PRINT 'Export complete.';
    END
END
GO

PRINT 'Stored procedure sp_ExportGeneratedScript created successfully.';
PRINT '';
PRINT 'Usage Examples:';
PRINT '  -- Get latest script for a server:';
PRINT '  EXEC indexing.sp_ExportGeneratedScript @ServerName=''USW2-018-SQL''';
PRINT '';
PRINT '  -- Get specific script by ID:';
PRINT '  EXEC indexing.sp_ExportGeneratedScript @ScriptID=1';
PRINT '';
PRINT '  -- Export to file:';
PRINT '  EXEC indexing.sp_ExportGeneratedScript @ServerName=''USW2-018-SQL'', @OutputPath=''C:\temp\script.sql''';
PRINT '';
PRINT '  -- List all available scripts:';
PRINT '  SELECT ScriptID, ServerName, GeneratedDate, LEN(ScriptText) AS [Length] FROM indexing.GeneratedScripts ORDER BY ScriptID DESC;';
GO

GO

-- =============================================

IF OBJECT_ID('indexing.sp_CreateIndexOptimizationRecommendations', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_CreateIndexOptimizationRecommendations;
GO

CREATE PROCEDURE indexing.sp_CreateIndexOptimizationRecommendations
    @ServerName NVARCHAR(128) = NULL,
    @DatabaseName NVARCHAR(MAX) = NULL,  -- NULL = all user databases, or comma-delimited list
    @MinIndexAdvantage DECIMAL(18,2) = 2500.0,
    @MinAvgUserImpact DECIMAL(18,2) = 99.0,
    @RunnableUnder VARCHAR(20) = NULL,  -- NULL=all uncommented, '2'=2GB both, '1,5e'=1GB Std/5GB Ent
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Default server name to current server
    IF @ServerName IS NULL
        SET @ServerName = @@SERVERNAME;

    DECLARE @StartTime DATETIME = GETDATE();
    DECLARE @Duration INT;

    BEGIN TRY
        IF @Debug = 1
        BEGIN
            PRINT '=============================================='
            PRINT 'INDEX OPTIMIZATION RECOMMENDATIONS'
            PRINT 'One-Command Workflow'
            PRINT '=============================================='
            PRINT 'Server: ' + @ServerName
            PRINT 'Database: ' + ISNULL(@DatabaseName, 'All user databases')
            PRINT 'Min Index Advantage: ' + CAST(@MinIndexAdvantage AS VARCHAR(20))
            PRINT 'Min Avg User Impact: ' + CAST(@MinAvgUserImpact AS VARCHAR(20))
            IF @RunnableUnder IS NOT NULL
                PRINT '@RunnableUnder: ' + @RunnableUnder
            PRINT 'Started: ' + CONVERT(VARCHAR(30), @StartTime, 120)
            PRINT ''
        END

        -- Step 1: Load data from SQL Server DMVs
        IF @Debug = 1 PRINT 'Step 1/3: Loading data from SQL Server DMVs...'

        EXEC indexing.sp_LoadDataFromServer
            @ServerName = @ServerName,
            @MinIndexAdvantage = @MinIndexAdvantage,
            @MinAvgUserImpact = @MinAvgUserImpact,
            @DatabaseMode = @DatabaseName,  -- Pass database mode directly
            @Debug = @Debug;

        -- Step 2: Analyze and consolidate recommendations
        IF @Debug = 1 PRINT ''
        IF @Debug = 1 PRINT 'Step 2/3: Analyzing recommendations and determining strategies...'

        EXEC indexing.sp_AnalyzeIndexStrategies
            @Debug = @Debug;

        -- Step 3: Generate optimization script
        IF @Debug = 1 PRINT ''
        IF @Debug = 1 PRINT 'Step 3/3: Generating optimization script...'

        EXEC indexing.sp_GenerateOptimizationScript
            @ServerName = @ServerName,
            @DatabaseName = @DatabaseName,
            @RunnableUnder = @RunnableUnder,
            @Debug = @Debug;

        -- Return the latest script
        IF @Debug = 1
        BEGIN
            SET @Duration = DATEDIFF(SECOND, @StartTime, GETDATE());
            PRINT ''
            PRINT '=============================================='
            PRINT 'COMPLETE! Generated in ' + CAST(@Duration AS VARCHAR(10)) + ' seconds'
            PRINT '=============================================='
            PRINT ''
        END

        -- Return the most recent script for this server
        SELECT TOP 1
            ScriptID,
            ServerName,
            DatabaseName,
            GeneratedDate,
            [Statistics],
            [Status],
            ScriptText
        FROM indexing.GeneratedScripts
        WHERE ServerName = @ServerName
        ORDER BY ScriptID DESC;

    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();

        PRINT 'ERROR: ' + @ErrorMessage;

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
GO

PRINT 'Stored procedure indexing.sp_CreateIndexOptimizationRecommendations created successfully.'
GO

GO

-- =============================================
-- Size Estimation Procedures
-- =============================================

-- =============================================
-- sp_CalculateIndexSizeEstimate
-- =============================================
-- Calculates index size estimate by SAMPLING ACTUAL DATA
--
-- Strategy:
--   1. Sample up to 10,000 rows from the table
--   2. Calculate AVG(DATALENGTH(column)) for each column
--   3. Use actual average sizes instead of max_length guesses
--   4. Apply Microsoft's page/row formula with real data
--
-- This is FAR more accurate than using max_length/4 guesses
-- because it measures what's actually in the data.
--
-- Created: 2026-03-20
-- Updated: 2026-10-19 - Switched from max_length guesses to actual data sampling
-- Version: 2.0
-- =============================================

IF OBJECT_ID('indexing.sp_CalculateIndexSizeEstimate', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_CalculateIndexSizeEstimate;
GO

CREATE PROCEDURE indexing.sp_CalculateIndexSizeEstimate
    @DatabaseName NVARCHAR(128),
    @SchemaTable NVARCHAR(256),           -- Format: [schema].[table]
    @KeyColumns NVARCHAR(MAX),            -- Format: [col1], [col2], [col3]
    @IncludeColumns NVARCHAR(MAX) = NULL, -- Format: [col1], [col2], [col3]
    @EstimatedSizeGB DECIMAL(18,2) OUTPUT,
    @DetailedBreakdown NVARCHAR(MAX) OUTPUT,
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SQL NVARCHAR(MAX);
    DECLARE @ErrorMsg NVARCHAR(500);

    -- Initialize outputs
    SET @EstimatedSizeGB = NULL;
    SET @DetailedBreakdown = NULL;

    -- Parse schema and table
    DECLARE @Schema NVARCHAR(128);
    DECLARE @Table NVARCHAR(128);

    SET @Schema = REPLACE(REPLACE(SUBSTRING(@SchemaTable, 1, CHARINDEX('.', @SchemaTable) - 1), '[', ''), ']', '');
    SET @Table = REPLACE(REPLACE(SUBSTRING(@SchemaTable, CHARINDEX('.', @SchemaTable) + 1, LEN(@SchemaTable)), '[', ''), ']', '');

    IF @Debug = 1
    BEGIN
        PRINT '=== DEBUG: sp_CalculateIndexSizeEstimate v2.0 (data sampling) ===';
        PRINT 'Database: ' + @DatabaseName;
        PRINT 'Schema: ' + @Schema;
        PRINT 'Table: ' + @Table;
        PRINT 'Key Columns: ' + @KeyColumns;
        PRINT 'Include Columns: ' + ISNULL(@IncludeColumns, '(none)');
    END

    -- Clean up column lists for use in dynamic SQL
    DECLARE @CleanKeyColumns NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(@KeyColumns, '[', ''), ']', ''), ' ', '');
    DECLARE @CleanIncludeColumns NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(ISNULL(@IncludeColumns, ''), '[', ''), ']', ''), ' ', '');

    -- Build dynamic SQL to query the target database
    SET @SQL = N'
    USE [' + @DatabaseName + N'];

    DECLARE @TotalRows BIGINT;
    DECLARE @SampleRows INT = 10000;
    DECLARE @KeyColumnSize DECIMAL(18,2) = 0;
    DECLARE @IncludeColumnSize DECIMAL(18,2) = 0;
    DECLARE @LocatorSize INT = 0;
    DECLARE @NullableColumns INT = 0;
    DECLARE @LeafRowSize DECIMAL(18,2);
    DECLARE @RowsPerPage INT;
    DECLARE @TotalLeafPages BIGINT;
    DECLARE @TotalSizeMB DECIMAL(18,2);
    DECLARE @ClusteredKeySize INT = 0;
    DECLARE @ColumnBreakdown NVARCHAR(MAX) = '''';

    -- Get total row count
    SELECT @TotalRows = SUM(p.rows)
    FROM sys.tables t
    INNER JOIN sys.partitions p ON t.object_id = p.object_id
    WHERE t.schema_id = SCHEMA_ID(''' + @Schema + N''')
        AND t.name = ''' + @Table + N'''
        AND p.index_id IN (0, 1);

    IF @TotalRows IS NULL OR @TotalRows = 0
    BEGIN
        SET @TotalRows = 1000;
    END

    -- Get clustered index key size (for data row locator)
    SELECT @ClusteredKeySize = SUM(
        CASE
            WHEN c.system_type_id = 48 THEN 1   -- tinyint
            WHEN c.system_type_id = 52 THEN 2   -- smallint
            WHEN c.system_type_id = 56 THEN 4   -- int
            WHEN c.system_type_id = 127 THEN 8  -- bigint
            WHEN c.system_type_id = 36 THEN 16  -- uniqueidentifier
            ELSE c.max_length
        END
    )
    FROM sys.indexes i
    INNER JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
    WHERE i.object_id = OBJECT_ID(''' + @Schema + N'.' + @Table + N''')
        AND i.type = 1
        AND ic.is_included_column = 0;

    SET @LocatorSize = ISNULL(@ClusteredKeySize, 8);

    -- Create temp table to hold column size samples
    DROP TABLE IF EXISTS #ColumnSizes;
    CREATE TABLE #ColumnSizes (
        ColumnName NVARCHAR(128),
        ColumnType NVARCHAR(50),
        AvgSize DECIMAL(18,2),
        IsNullable BIT,
        IsKey BIT
    );

    -- Sample actual data for key columns
    DECLARE @ColName NVARCHAR(128);
    DECLARE @AvgSQL NVARCHAR(MAX);
    DECLARE @AvgSize DECIMAL(18,2);
    DECLARE @ColType NVARCHAR(50);
    DECLARE @IsNullable BIT;
    DECLARE @Pos INT;
    DECLARE @ColumnList NVARCHAR(MAX) = ''' + @CleanKeyColumns + N''';

    WHILE LEN(@ColumnList) > 0
    BEGIN
        SET @Pos = CHARINDEX('','', @ColumnList);
        IF @Pos = 0
        BEGIN
            SET @ColName = @ColumnList;
            SET @ColumnList = '''';
        END
        ELSE
        BEGIN
            SET @ColName = LEFT(@ColumnList, @Pos - 1);
            SET @ColumnList = SUBSTRING(@ColumnList, @Pos + 1, LEN(@ColumnList));
        END

        -- Get column metadata
        SELECT @ColType = t.name, @IsNullable = c.is_nullable
        FROM sys.columns c
        INNER JOIN sys.types t ON c.system_type_id = t.system_type_id AND c.user_type_id = t.user_type_id
        WHERE c.object_id = OBJECT_ID(''' + @Schema + N'.' + @Table + N''')
            AND c.name = @ColName;

        -- Sample actual data - AVG(DATALENGTH) gives real average bytes used
        SET @AvgSQL = N''SELECT @AvgOut = AVG(CAST(ISNULL(DATALENGTH(['' + @ColName + N'']), 0) AS DECIMAL(18,2)))
            FROM (SELECT TOP ('' + CAST(@SampleRows AS NVARCHAR(10)) + N'') ['' + @ColName + N'']
                  FROM [' + @Schema + N'].[' + @Table + N'] WITH (NOLOCK)
                  WHERE ['' + @ColName + N''] IS NOT NULL) x'';

        BEGIN TRY
            EXEC sp_executesql @AvgSQL, N''@AvgOut DECIMAL(18,2) OUTPUT'', @AvgOut = @AvgSize OUTPUT;
        END TRY
        BEGIN CATCH
            SET @AvgSize = 8; -- Default fallback
        END CATCH

        -- Handle NULL result (column is all NULLs)
        IF @AvgSize IS NULL SET @AvgSize = 0;

        -- For fixed-length types, use the fixed size (DATALENGTH already returns this, but ensure minimum)
        IF @ColType IN (''int'') SET @AvgSize = CASE WHEN @AvgSize < 4 THEN 4 ELSE @AvgSize END;
        IF @ColType IN (''bigint'') SET @AvgSize = CASE WHEN @AvgSize < 8 THEN 8 ELSE @AvgSize END;
        IF @ColType IN (''smallint'') SET @AvgSize = CASE WHEN @AvgSize < 2 THEN 2 ELSE @AvgSize END;
        IF @ColType IN (''tinyint'', ''bit'') SET @AvgSize = CASE WHEN @AvgSize < 1 THEN 1 ELSE @AvgSize END;
        IF @ColType IN (''datetime'', ''datetime2'') SET @AvgSize = CASE WHEN @AvgSize < 8 THEN 8 ELSE @AvgSize END;
        IF @ColType IN (''uniqueidentifier'') SET @AvgSize = 16;

        INSERT INTO #ColumnSizes (ColumnName, ColumnType, AvgSize, IsNullable, IsKey)
        VALUES (@ColName, @ColType, @AvgSize, @IsNullable, 1);

        SET @KeyColumnSize = @KeyColumnSize + @AvgSize;
        IF @IsNullable = 1 SET @NullableColumns = @NullableColumns + 1;
    END

    -- Sample actual data for include columns
    IF ''' + @CleanIncludeColumns + N''' != ''''
    BEGIN
        SET @ColumnList = ''' + @CleanIncludeColumns + N''';

        WHILE LEN(@ColumnList) > 0
        BEGIN
            SET @Pos = CHARINDEX('','', @ColumnList);
            IF @Pos = 0
            BEGIN
                SET @ColName = @ColumnList;
                SET @ColumnList = '''';
            END
            ELSE
            BEGIN
                SET @ColName = LEFT(@ColumnList, @Pos - 1);
                SET @ColumnList = SUBSTRING(@ColumnList, @Pos + 1, LEN(@ColumnList));
            END

            SELECT @ColType = t.name, @IsNullable = c.is_nullable
            FROM sys.columns c
            INNER JOIN sys.types t ON c.system_type_id = t.system_type_id AND c.user_type_id = t.user_type_id
            WHERE c.object_id = OBJECT_ID(''' + @Schema + N'.' + @Table + N''')
                AND c.name = @ColName;

            SET @AvgSQL = N''SELECT @AvgOut = AVG(CAST(ISNULL(DATALENGTH(['' + @ColName + N'']), 0) AS DECIMAL(18,2)))
                FROM (SELECT TOP ('' + CAST(@SampleRows AS NVARCHAR(10)) + N'') ['' + @ColName + N'']
                      FROM [' + @Schema + N'].[' + @Table + N'] WITH (NOLOCK)
                      WHERE ['' + @ColName + N''] IS NOT NULL) x'';

            BEGIN TRY
                EXEC sp_executesql @AvgSQL, N''@AvgOut DECIMAL(18,2) OUTPUT'', @AvgOut = @AvgSize OUTPUT;
            END TRY
            BEGIN CATCH
                SET @AvgSize = 8;
            END CATCH

            IF @AvgSize IS NULL SET @AvgSize = 0;

            IF @ColType IN (''int'') SET @AvgSize = CASE WHEN @AvgSize < 4 THEN 4 ELSE @AvgSize END;
            IF @ColType IN (''bigint'') SET @AvgSize = CASE WHEN @AvgSize < 8 THEN 8 ELSE @AvgSize END;
            IF @ColType IN (''smallint'') SET @AvgSize = CASE WHEN @AvgSize < 2 THEN 2 ELSE @AvgSize END;
            IF @ColType IN (''tinyint'', ''bit'') SET @AvgSize = CASE WHEN @AvgSize < 1 THEN 1 ELSE @AvgSize END;
            IF @ColType IN (''datetime'', ''datetime2'') SET @AvgSize = CASE WHEN @AvgSize < 8 THEN 8 ELSE @AvgSize END;
            IF @ColType IN (''uniqueidentifier'') SET @AvgSize = 16;

            INSERT INTO #ColumnSizes (ColumnName, ColumnType, AvgSize, IsNullable, IsKey)
            VALUES (@ColName, @ColType, @AvgSize, @IsNullable, 0);

            SET @IncludeColumnSize = @IncludeColumnSize + @AvgSize;
            IF @IsNullable = 1 SET @NullableColumns = @NullableColumns + 1;
        END
    END

    -- Build column breakdown for debugging
    SELECT @ColumnBreakdown = @ColumnBreakdown +
        CASE WHEN IsKey = 1 THEN ''  Key: '' ELSE ''  Inc: '' END +
        ColumnName + '' ('' + ColumnType + '') = '' + CAST(AvgSize AS VARCHAR(10)) + '' bytes avg'' + CHAR(13) + CHAR(10)
    FROM #ColumnSizes;

    -- Calculate overhead (header + null bitmap + slot array)
    DECLARE @NullBitmapSize INT = 2 + ((@NullableColumns + 7) / 8);
    DECLARE @OverheadSize INT = 1 + @NullBitmapSize + 2;

    -- Calculate leaf row size
    SET @LeafRowSize = @KeyColumnSize + @IncludeColumnSize + @LocatorSize + @OverheadSize;

    -- Calculate rows per page (8096 bytes usable)
    SET @RowsPerPage = CAST(8096 / (@LeafRowSize + 2) AS INT);
    IF @RowsPerPage < 1 SET @RowsPerPage = 1;

    -- Calculate total pages
    SET @TotalLeafPages = (@TotalRows + @RowsPerPage - 1) / @RowsPerPage;
    DECLARE @TotalPages BIGINT = CAST(@TotalLeafPages * 1.01 AS BIGINT);

    -- Convert to MB
    SET @TotalSizeMB = (@TotalPages * 8.0) / 1024.0;

    -- Build breakdown
    DECLARE @Breakdown NVARCHAR(MAX) =
        ''=== Column Sizes (sampled from '' + CAST(@SampleRows AS VARCHAR(10)) + '' rows) ==='' + CHAR(13) + CHAR(10) +
        @ColumnBreakdown +
        ''---'' + CHAR(13) + CHAR(10) +
        ''Key Columns Total: '' + CAST(@KeyColumnSize AS VARCHAR(10)) + '' bytes'' + CHAR(13) + CHAR(10) +
        ''Include Columns Total: '' + CAST(@IncludeColumnSize AS VARCHAR(10)) + '' bytes'' + CHAR(13) + CHAR(10) +
        ''Locator Size: '' + CAST(@LocatorSize AS VARCHAR(10)) + '' bytes'' + CHAR(13) + CHAR(10) +
        ''Overhead: '' + CAST(@OverheadSize AS VARCHAR(10)) + '' bytes'' + CHAR(13) + CHAR(10) +
        ''---'' + CHAR(13) + CHAR(10) +
        ''Leaf Row Size: '' + CAST(@LeafRowSize AS VARCHAR(10)) + '' bytes'' + CHAR(13) + CHAR(10) +
        ''Rows Per Page: '' + CAST(@RowsPerPage AS VARCHAR(10)) + CHAR(13) + CHAR(10) +
        ''Total Rows: '' + FORMAT(@TotalRows, ''N0'') + CHAR(13) + CHAR(10) +
        ''Total Pages: '' + FORMAT(@TotalPages, ''N0'') + CHAR(13) + CHAR(10) +
        ''---'' + CHAR(13) + CHAR(10) +
        ''Estimated Size: '' + CAST(@TotalSizeMB AS VARCHAR(20)) + '' MB ('' + CAST(@TotalSizeMB / 1024.0 AS VARCHAR(20)) + '' GB)'';

    SELECT @TotalSizeMB / 1024.0 AS EstimatedSizeGB, @Breakdown AS DetailedBreakdown;
    ';

    -- Create temp table for results
    DROP TABLE IF EXISTS #SizeResults;
    CREATE TABLE #SizeResults (
        EstimatedSizeGB DECIMAL(18,2),
        DetailedBreakdown NVARCHAR(MAX)
    );

    BEGIN TRY
        INSERT INTO #SizeResults
        EXEC sp_executesql @SQL;

        SELECT @EstimatedSizeGB = EstimatedSizeGB, @DetailedBreakdown = DetailedBreakdown
        FROM #SizeResults;

        IF @Debug = 1
        BEGIN
            PRINT '';
            PRINT @DetailedBreakdown;
            PRINT '';
            PRINT 'Final Estimate: ' + CAST(@EstimatedSizeGB AS VARCHAR(20)) + ' GB';
        END
    END TRY
    BEGIN CATCH
        SET @ErrorMsg = ERROR_MESSAGE();
        PRINT 'ERROR in sp_CalculateIndexSizeEstimate: ' + @ErrorMsg;
        RETURN;
    END CATCH
END;
GO

-- Test the procedure
/*
DECLARE @SizeGB DECIMAL(18,2);
DECLARE @Breakdown NVARCHAR(MAX);

EXEC indexing.sp_CalculateIndexSizeEstimate
    @DatabaseName = 'mc_npp_7779',
    @SchemaTable = '[dbo].[audit_trail_columns_changed]',
    @KeyColumns = '[table_name], [column_name_key]',
    @IncludeColumns = '[trans_id], [new_value], [old_value], [column_name]',
    @EstimatedSizeGB = @SizeGB OUTPUT,
    @DetailedBreakdown = @Breakdown OUTPUT,
    @Debug = 1;

SELECT @SizeGB AS EstimatedSizeGB;
PRINT @Breakdown;
*/

-- =============================================
-- sp_GetHybridIndexSizeEstimate
-- =============================================
-- Hybrid index size estimation strategy
--
-- Strategy:
--   1. Try Smart estimator first (similarity-based, uses actual data from similar indexes)
--   2. If Smart returns NULL (no similar indexes), fall back to Calculation estimator
--   3. Only return warnings for indexes >= 0.5 GB
--
-- Why Hybrid?
--   - Smart is more accurate when similar indexes exist (uses actual data)
--   - Calculation provides upper bound when no similar indexes exist
--   - Best of both worlds!
--
-- Created: 2026-03-20
-- Version: 1.0
-- =============================================

IF OBJECT_ID('indexing.sp_GetHybridIndexSizeEstimate', 'P') IS NOT NULL
    DROP PROCEDURE indexing.sp_GetHybridIndexSizeEstimate;
GO

CREATE PROCEDURE indexing.sp_GetHybridIndexSizeEstimate
    @DatabaseName NVARCHAR(128),
    @SchemaTable NVARCHAR(256),
    @RecKeyColumns NVARCHAR(MAX),
    @RecIncludeColumns NVARCHAR(MAX),
    @Warning NVARCHAR(MAX) OUTPUT,
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Warning = NULL;

    IF @Debug = 1
    BEGIN
        PRINT '=== HYBRID ESTIMATOR ===';
        PRINT 'Database: ' + @DatabaseName;
        PRINT 'Schema.Table: ' + @SchemaTable;
        PRINT 'Keys: ' + @RecKeyColumns;
        PRINT 'Includes: ' + ISNULL(@RecIncludeColumns, '(none)');
        PRINT '';
    END

    -- Strategy 1: Try Smart estimator (similarity-based)
    IF @Debug = 1
        PRINT '--- Trying Smart Estimator (similarity-based) ---';

    EXEC indexing.sp_GetSmartTableSizeEstimate
        @DatabaseName = @DatabaseName,
        @SchemaTable = @SchemaTable,
        @RecKeyColumns = @RecKeyColumns,
        @RecIncludeColumns = @RecIncludeColumns,
        @Warning = @Warning OUTPUT;

    -- If Smart found a similar index and generated warning, use it
    IF @Warning IS NOT NULL
    BEGIN
        IF @Debug = 1
        BEGIN
            PRINT 'Smart estimator found similar index:';
            PRINT @Warning;
            PRINT '';
            PRINT 'RESULT: Using Smart estimate';
        END
        RETURN;
    END

    IF @Debug = 1
    BEGIN
        PRINT 'Smart estimator returned NULL (no similar indexes or size < 0.5 GB)';
        PRINT '';
    END

    -- Strategy 2: Fall back to Calculation estimator
    IF @Debug = 1
        PRINT '--- Trying Calculation Estimator (column metadata) ---';

    DECLARE @CalcSizeGB DECIMAL(18,2);
    DECLARE @CalcBreakdown NVARCHAR(MAX);

    EXEC indexing.sp_CalculateIndexSizeEstimate
        @DatabaseName = @DatabaseName,
        @SchemaTable = @SchemaTable,
        @KeyColumns = @RecKeyColumns,
        @IncludeColumns = @RecIncludeColumns,
        @EstimatedSizeGB = @CalcSizeGB OUTPUT,
        @DetailedBreakdown = @CalcBreakdown OUTPUT,
        @Debug = 0;

    -- Only return warning if size >= 0.5 GB
    IF @CalcSizeGB IS NOT NULL AND @CalcSizeGB >= 0.5
    BEGIN
        SET @Warning = '-- WARNING: ~' + CAST(@CalcSizeGB AS VARCHAR(10)) +
            ' GB estimate (calculated from column metadata, no similar indexes found)';

        IF @Debug = 1
        BEGIN
            PRINT 'Calculation estimator result:';
            PRINT @Warning;
            PRINT '';
            PRINT 'Breakdown:';
            PRINT @CalcBreakdown;
            PRINT '';
            PRINT 'RESULT: Using Calculation estimate';
        END
    END
    ELSE
    BEGIN
        IF @Debug = 1
        BEGIN
            IF @CalcSizeGB IS NULL
                PRINT 'Calculation estimator returned NULL (error or no data)';
            ELSE
                PRINT 'Calculation estimator: ' + CAST(@CalcSizeGB AS VARCHAR(10)) + ' GB (< 0.5 GB threshold, no warning needed)';
            PRINT '';
            PRINT 'RESULT: No warning (size < 0.5 GB)';
        END
    END
END;
GO

-- =============================================
-- Test Cases
-- =============================================
/*

-- Test 1: Table WITH similar indexes (should use Smart)
DECLARE @Warning NVARCHAR(MAX);
EXEC indexing.sp_GetHybridIndexSizeEstimate
    @DatabaseName = 'mc_thermofisher_1819_dev',
    @SchemaTable = '[dbo].[audit_trail_columns_changed]',
    @RecKeyColumns = '[trans_id]',
    @RecIncludeColumns = '[new_value], [old_value], [column_name]',
    @Warning = @Warning OUTPUT,
    @Debug = 1;

SELECT @Warning AS Warning;
PRINT '';
PRINT '=====================================';
PRINT '';

-- Test 2: Table WITHOUT similar indexes (should use Calculation)
EXEC indexing.sp_GetHybridIndexSizeEstimate
    @DatabaseName = 'mc_thermofisher_1819_dev',
    @SchemaTable = '[dbo].[some_empty_table]',
    @RecKeyColumns = '[some_key]',
    @RecIncludeColumns = '[some_include]',
    @Warning = @Warning OUTPUT,
    @Debug = 1;

SELECT @Warning AS Warning;
PRINT '';
PRINT '=====================================';
PRINT '';

-- Test 3: Small index (should return NULL)
EXEC indexing.sp_GetHybridIndexSizeEstimate
    @DatabaseName = 'mc_small_db',
    @SchemaTable = '[dbo].[small_table]',
    @RecKeyColumns = '[id]',
    @RecIncludeColumns = NULL,
    @Warning = @Warning OUTPUT,
    @Debug = 1;

SELECT @Warning AS Warning;

*/

-- =============================================
-- Missing Index Recommendations (per-finding view)
-- =============================================

CREATE OR ALTER PROCEDURE indexing.sp_MissingIndexRecommendations
  @DatabaseName      NVARCHAR(MAX)  = NULL
 ,@TableName         NVARCHAR(128)  = NULL
 ,@RunnableUnder     VARCHAR(20)    = NULL  -- NULL=all uncommented, '2'=2GB both, '1,5e'=1GB Std/5GB Ent
 ,@RunAnalysis       BIT            = 0
 ,@MinIndexAdvantage DECIMAL(18,2)  = 2500.0
 ,@MinAvgUserImpact  DECIMAL(18,2)  = 99.0
AS
BEGIN
  SET NOCOUNT ON;

  IF @RunAnalysis = 1
  BEGIN
    EXEC indexing.sp_LoadDataFromServer
        @ServerName        = @@SERVERNAME,
        @DatabaseMode      = @DatabaseName,
        @MinIndexAdvantage = @MinIndexAdvantage,
        @MinAvgUserImpact  = @MinAvgUserImpact;

    EXEC indexing.sp_AnalyzeIndexStrategies;

    EXEC indexing.sp_GenerateOptimizationScript
        @ServerName    = @@SERVERNAME,
        @DatabaseName  = @DatabaseName,
        @RunnableUnder = @RunnableUnder;
  END

  DECLARE @ScriptText  NVARCHAR(MAX) = '';
  DECLARE @CRLF        CHAR(2)       = CHAR(13) + CHAR(10);
  DECLARE @Separator   VARCHAR(60)   = '/*****************************************************/';

  -- Parse @RunnableUnder: NULL=off, '2'=2GB both, '1,5e'=1GB Standard/5GB Enterprise
  DECLARE @ThresholdStd DECIMAL(10,2) = NULL;
  DECLARE @ThresholdEnt DECIMAL(10,2) = NULL;
  DECLARE @ActiveThreshold DECIMAL(10,2) = NULL;
  DECLARE @IsEnterprise BIT = 0;

  IF @RunnableUnder IS NOT NULL AND LTRIM(RTRIM(@RunnableUnder)) <> ''
  BEGIN
      IF @RunnableUnder LIKE '%,%e'
      BEGIN
          SET @ThresholdStd = TRY_CAST(LEFT(@RunnableUnder, CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
          SET @ThresholdEnt = TRY_CAST(SUBSTRING(@RunnableUnder, CHARINDEX(',', @RunnableUnder) + 1,
              LEN(@RunnableUnder) - CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
      END
      ELSE
      BEGIN
          SET @ThresholdStd = TRY_CAST(@RunnableUnder AS DECIMAL(10,2));
          SET @ThresholdEnt = @ThresholdStd;
      END
  END

  IF CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Enterprise%'
    OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Developer%'
    SET @IsEnterprise = 1;

  SET @ActiveThreshold = CASE WHEN @IsEnterprise = 1 THEN @ThresholdEnt ELSE @ThresholdStd END;

  DECLARE @TotalRecs      INT = 0;
  DECLARE @TotalDatabases  INT = 0;
  DECLARE @TotalTables     INT = 0;
  DECLARE @TotalCreate     INT = 0;
  DECLARE @TotalExtend     INT = 0;
  DECLARE @TotalRebuild    INT = 0;

  SELECT @TotalRecs      = COUNT(*)
        ,@TotalDatabases  = COUNT(DISTINCT DatabaseName)
        ,@TotalTables     = COUNT(DISTINCT DatabaseName + '.' + SchemaName + '.' + TableName)
        ,@TotalCreate     = SUM(CASE WHEN Strategy IN ('CREATE', 'CREATE_CONSOLIDATED', 'CREATE_SUPER_CONSOLIDATED', 'PREFIX_MATCH') THEN 1 ELSE 0 END)
        ,@TotalExtend     = SUM(CASE WHEN Strategy IN ('EXTEND', 'UPDATE', 'EXTEND_DISABLED') THEN 1 ELSE 0 END)
        ,@TotalRebuild    = SUM(CASE WHEN Strategy = 'REBUILD' THEN 1 ELSE 0 END)
  FROM indexing.MissingIndexResults
  WHERE ResolvedDate IS NULL
    AND Strategy NOT IN ('SUPERSET_COVERED')
    AND ServerName = @@SERVERNAME
    AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
    AND (@TableName IS NULL OR TableName = @TableName)
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SET @ScriptText =
    '/*' + @CRLF
    + '==============================================================================' + @CRLF
    + '  MISSING INDEX RECOMMENDATIONS' + @CRLF
    + '  Server: ' + @@SERVERNAME + @CRLF
    + '  Generated: ' + CONVERT(VARCHAR(30), GETDATE(), 120) + @CRLF
    + '==============================================================================' + @CRLF
    + 'Statistics:' + @CRLF
    + '    Databases:         ' + FORMAT(@TotalDatabases, 'N0') + @CRLF
    + '    Tables:            ' + FORMAT(@TotalTables, 'N0') + @CRLF
    + '    Recommendations:   ' + FORMAT(@TotalRecs, 'N0') + @CRLF
    + '      Create:          ' + FORMAT(@TotalCreate, 'N0') + @CRLF
    + '      Extend:          ' + FORMAT(@TotalExtend, 'N0') + @CRLF
    + '      Rebuild:         ' + FORMAT(@TotalRebuild, 'N0') + @CRLF
    + @CRLF
    + 'Filters:' + @CRLF
    + '    @DatabaseName   = ' + ISNULL('''' + @DatabaseName + '''', 'ALL') + @CRLF
    + '    @TableName      = ' + ISNULL('''' + @TableName + '''', 'ALL') + @CRLF
    + '    @RunnableUnder  = ' + ISNULL('''' + @RunnableUnder + '''', 'NULL (all uncommented)') + @CRLF
    + '*/' + @CRLF;

  IF @ActiveThreshold IS NOT NULL
    SET @ScriptText = @ScriptText
      + '-- @RunnableUnder = ' + @RunnableUnder
      + CASE WHEN @ThresholdStd <> @ThresholdEnt
          THEN ' (Standard: ' + CAST(@ThresholdStd AS VARCHAR(10)) + ' GB, Enterprise: ' + CAST(@ThresholdEnt AS VARCHAR(10)) + ' GB)'
          ELSE ' (' + CAST(@ActiveThreshold AS VARCHAR(10)) + ' GB)'
        END
      + ', indexes >= threshold commented out' + @CRLF;

  DECLARE @CurrentDB     NVARCHAR(128) = '';
  DECLARE @CurrentTable  NVARCHAR(400) = '';
  DECLARE @IsFirstDB     BIT = 1;

  DECLARE @Id              INT;
  DECLARE @DB              NVARCHAR(128);
  DECLARE @Schema          NVARCHAR(128);
  DECLARE @Table           NVARCHAR(128);
  DECLARE @Strategy        NVARCHAR(50);
  DECLARE @ExistingIdx     NVARCHAR(128);
  DECLARE @ExistingKeys    NVARCHAR(MAX);
  DECLARE @ExistingInc     NVARCHAR(MAX);
  DECLARE @KeyCols         NVARCHAR(MAX);
  DECLARE @IncCols         NVARCHAR(MAX);
  DECLARE @Advantage       DECIMAL(18,2);
  DECLARE @RecCount        INT;
  DECLARE @RecIDs          NVARCHAR(MAX);
  DECLARE @SizeGB          DECIMAL(18,2);
  DECLARE @CreateStmt      NVARCHAR(MAX);
  DECLARE @IsSuperCons     BIT;
  DECLARE @OrigGroupCnt    INT;
  DECLARE @ShouldComment   BIT;
  DECLARE @RunnableCount   INT = 0;

  DECLARE rec_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT MissingIndexId, DatabaseName, SchemaName, TableName,
           Strategy, ExistingIndexName, ExistingKeyColumns, ExistingIncludeColumns,
           KeyColumns, IncludedColumns, IndexAdvantage, RecommendationCount,
           RecommendationIDs, EstimatedSizeGB, CreateStatement,
           IsSuperConsolidated, OriginalGroupCount
    FROM indexing.MissingIndexResults
    WHERE ResolvedDate IS NULL
      AND Strategy NOT IN ('SUPERSET_COVERED')
      AND ServerName = @@SERVERNAME
      AND (@DatabaseName IS NULL
                OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
                OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
      AND (@TableName IS NULL OR TableName = @TableName)
      AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName)
    ORDER BY DatabaseName, SchemaName, TableName, IndexAdvantage DESC;

  OPEN rec_cursor;
  FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table,
    @Strategy, @ExistingIdx, @ExistingKeys, @ExistingInc,
    @KeyCols, @IncCols, @Advantage, @RecCount,
    @RecIDs, @SizeGB, @CreateStmt,
    @IsSuperCons, @OrigGroupCnt;

  WHILE @@FETCH_STATUS = 0
  BEGIN

    IF @DB <> @CurrentDB
    BEGIN
      IF @IsFirstDB = 0
        SET @ScriptText = @ScriptText + @CRLF;

      SET @CurrentDB    = @DB;
      SET @CurrentTable = '';
      SET @IsFirstDB    = 0;

      SET @ScriptText = @ScriptText
        + '-- ============================================================================' + @CRLF
        + '-- Database: ' + @DB + @CRLF
        + '-- ============================================================================' + @CRLF
        + 'USE ' + QUOTENAME(@DB) + @CRLF
        + 'GO' + @CRLF;
    END;

    DECLARE @TableKey NVARCHAR(400) = @DB + '.' + @Schema + '.' + @Table;
    IF @TableKey <> @CurrentTable
    BEGIN
      SET @CurrentTable = @TableKey;
      SET @ScriptText = @ScriptText
        + @CRLF
        + @Separator + @CRLF
        + '-- Table: ' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + @CRLF
        + @Separator + @CRLF
        + '--EXEC sp_helpindexUsage ''' + @Schema + '.' + @Table + '''' + @CRLF;
    END;

    -- Detail comment block
    SET @ScriptText = @ScriptText + @CRLF
      + '-- MISSING INDEX (' + @Strategy + ')' + @CRLF
      + '--   Strategy: ' + @Strategy
      + CASE WHEN @IsSuperCons = 1 THEN ' (super-consolidated from ' + FORMAT(ISNULL(@OrigGroupCnt, 0), 'N0') + ' groups)' ELSE '' END
      + @CRLF
      + '--   Recommendations: ' + FORMAT(ISNULL(@RecCount, 0), 'N0')
      + CASE WHEN @Advantage IS NOT NULL THEN '  |  Advantage: ' + CAST(@Advantage AS VARCHAR(20)) ELSE '' END
      + @CRLF
      + CASE WHEN @ExistingIdx IS NOT NULL THEN '--   Existing Index: ' + @ExistingIdx + @CRLF
             + '--     Keys:     ' + ISNULL(@ExistingKeys, '(none)') + @CRLF
             + '--     Includes: ' + ISNULL(@ExistingInc, '(none)') + @CRLF
             ELSE '' END
      + '--   New Keys:     ' + ISNULL(@KeyCols, '(none)') + @CRLF
      + CASE WHEN @IncCols IS NOT NULL THEN '--   New Includes: ' + @IncCols + @CRLF ELSE '' END
      + CASE WHEN @SizeGB IS NOT NULL THEN '--   Estimated Size: ~' + FORMAT(@SizeGB * 1024, 'N1') + ' MB' + @CRLF ELSE '' END
      + @CRLF;

    SET @ShouldComment = CASE WHEN @ActiveThreshold IS NOT NULL AND ISNULL(@SizeGB, 0) >= @ActiveThreshold THEN 1 ELSE 0 END;

    IF @CreateStmt IS NOT NULL
    BEGIN
      -- Strip trailing CRLF
      WHILE RIGHT(@CreateStmt, 2) = @CRLF
        SET @CreateStmt = LEFT(@CreateStmt, LEN(@CreateStmt + 'x') - 3);

      -- Strip any existing /* and */ that appear as standalone lines
      -- (from generation-time @RunnableUnder commenting)
      SET @CreateStmt = REPLACE(@CreateStmt, @CRLF + '/*' + @CRLF, @CRLF);
      SET @CreateStmt = REPLACE(@CreateStmt, @CRLF + '*/' , '');
      IF LEFT(@CreateStmt, 4) = '/*' + @CRLF
        SET @CreateStmt = SUBSTRING(@CreateStmt, 5, LEN(@CreateStmt));

      -- Strip trailing CRLF after cleanup
      WHILE RIGHT(@CreateStmt, 2) = @CRLF
        SET @CreateStmt = LEFT(@CreateStmt, LEN(@CreateStmt + 'x') - 3);

      -- Re-apply /* */ commenting based on CURRENT @RunnableUnder
      -- Find where the DDL starts (first CREATE/ALTER/DROP keyword)
      IF @ShouldComment = 1
      BEGIN
        DECLARE @DdlPos INT = PATINDEX('%' + @CRLF + 'CREATE %', @CreateStmt);
        IF @DdlPos = 0 SET @DdlPos = PATINDEX('%' + @CRLF + 'ALTER %', @CreateStmt);
        IF @DdlPos = 0 SET @DdlPos = PATINDEX('%' + @CRLF + 'DROP %', @CreateStmt);

        IF @DdlPos > 0
          SET @CreateStmt = LEFT(@CreateStmt, @DdlPos) + @CRLF + '/*' + SUBSTRING(@CreateStmt, @DdlPos + 1, LEN(@CreateStmt)) + @CRLF + '*/';
        ELSE
          SET @CreateStmt = '/*' + @CRLF + @CreateStmt + @CRLF + '*/';
      END

      SET @ScriptText = @ScriptText + @CreateStmt + @CRLF;
    END

    -- UPDATE ResolvedDate: commented out if finding exceeds threshold
    IF @ShouldComment = 1
      SET @ScriptText = @ScriptText
        + @CRLF + '/* UPDATE DBA_Utilities.indexing.MissingIndexResults SET ResolvedDate = GETDATE() WHERE MissingIndexId = ' + CAST(@Id AS VARCHAR(10)) + '; */' + @CRLF;
    ELSE
    BEGIN
      SET @ScriptText = @ScriptText
        + @CRLF + 'UPDATE DBA_Utilities.indexing.MissingIndexResults SET ResolvedDate = GETDATE() WHERE MissingIndexId = ' + CAST(@Id AS VARCHAR(10)) + ';' + @CRLF;
      SET @RunnableCount = @RunnableCount + 1;
    END

    FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table,
      @Strategy, @ExistingIdx, @ExistingKeys, @ExistingInc,
      @KeyCols, @IncCols, @Advantage, @RecCount,
      @RecIDs, @SizeGB, @CreateStmt,
      @IsSuperCons, @OrigGroupCnt;
  END;

  CLOSE rec_cursor;
  DEALLOCATE rec_cursor;

  SELECT @@SERVERNAME                                AS ServerName
        ,ISNULL(@DatabaseName, 'ALL')                AS DatabaseName
        ,GETDATE()                                   AS GeneratedDate
        ,FORMAT(@TotalRecs, 'N0') + ' recommendations ('
         + FORMAT(@TotalCreate, 'N0') + ' create, '
         + FORMAT(@TotalExtend, 'N0') + ' extend, '
         + FORMAT(@TotalRebuild, 'N0') + ' rebuild)'
                                                     AS [Statistics]
        ,CASE WHEN @RunnableCount > 0
              THEN 'Has Recommendations'
              WHEN @TotalRecs > 0 AND @RunnableCount = 0
              THEN 'Nothing To Run Under Parameter'
              ELSE 'No Recommendations'
         END                                         AS [Status]
        ,CASE WHEN @TotalRecs > 0
              THEN @ScriptText
              ELSE NULL
         END                                         AS ScriptText;
END;
GO
GO


-- ==========================================================================
-- EXPENSIVE QUERY PLAN ANALYSIS
-- ==========================================================================

-- =========================================================================
-- Table: indexing.ExpensiveQueryResults
-- =========================================================================
IF OBJECT_ID('indexing.ExpensiveQueryResults', 'U') IS NULL
BEGIN
  CREATE TABLE indexing.ExpensiveQueryResults
    (ExpensiveQueryId     INT            IDENTITY(1, 1)
    ,ServerName           NVARCHAR(128)  NOT NULL
    ,DatabaseName         NVARCHAR(128)  NOT NULL
    ,FindingType          VARCHAR(30)    NOT NULL
    ,SchemaName           NVARCHAR(128)  NULL
    ,TableName            NVARCHAR(128)  NULL
    ,IndexName            NVARCHAR(256)  NULL
    ,QueryHash            BINARY(8)      NULL
    ,TotalExecutions      BIGINT         NULL
    ,TotalLogicalReads    BIGINT         NULL
    ,TotalCPUTimeMs       BIGINT         NULL
    ,TotalDurationMs      BIGINT         NULL
    ,AvgLogicalReads      BIGINT         NULL
    ,AvgCPUTimeMs         BIGINT         NULL
    ,AvgDurationMs        BIGINT         NULL
    ,ScanType             VARCHAR(20)    NULL
    ,EstimatedRows        FLOAT          NULL
    ,MissingIndexKeys     NVARCHAR(MAX)  NULL
    ,MissingIndexIncludes NVARCHAR(MAX)  NULL
    ,MissingIndexImpact   FLOAT          NULL
    ,RegressionFactor     FLOAT          NULL
    ,SampleQueryText      NVARCHAR(MAX)  NULL
    ,FindingDetail        NVARCHAR(MAX)  NULL
    ,Recommendation       NVARCHAR(MAX)  NULL
    ,CreateStatement      NVARCHAR(MAX)  NULL
    ,EstimatedSizeGB      DECIMAL(18,2)  NULL
    ,DataSource           VARCHAR(20)    NOT NULL
    ,ProcessedDate        DATETIME2(3)   NOT NULL CONSTRAINT DF_ExpensiveQueryResults_ProcessedDate DEFAULT (SYSDATETIME())
    ,ResolvedDate         DATETIME2(3)   NULL
    ,CONSTRAINT PKC_ExpensiveQueryResults PRIMARY KEY CLUSTERED (ExpensiveQueryId DESC) WITH (FILLFACTOR = 100)
    ) ON [PRIMARY];
END
GO

-- =========================================================================
-- Proc: indexing.sp_ExpensiveQueryAnalysis
-- =========================================================================
CREATE OR ALTER PROCEDURE indexing.sp_ExpensiveQueryAnalysis
  @DatabaseName     NVARCHAR(MAX) = NULL
 ,@TopN             INT           = 50
 ,@SortBy           VARCHAR(20)   = 'READS'
 ,@MinExecutions    BIGINT        = 10
 ,@LookbackDays     INT           = 7
 ,@WithQueryStore   BIT           = 0
 ,@MinImpact        DECIMAL(5,2)  = 50.0
AS
BEGIN
  SET NOCOUNT ON;

  DELETE FROM indexing.ExpensiveQueryResults WHERE ResolvedDate IS NULL;

  DROP TABLE IF EXISTS #DBs;
  CREATE TABLE #DBs (DatabaseName NVARCHAR(128), rn INT);

  IF @DatabaseName IS NULL
  BEGIN
    INSERT INTO #DBs (DatabaseName, rn)
    SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.database_id > 4;
  END
  ELSE IF @DatabaseName LIKE '%[%]%'
  BEGIN
    INSERT INTO #DBs (DatabaseName, rn)
    SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.name LIKE @DatabaseName;
  END
  ELSE
  BEGIN
    INSERT INTO #DBs (DatabaseName, rn)
    SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
    FROM sys.databases d
    INNER JOIN STRING_SPLIT(@DatabaseName, ',') s ON d.name = LTRIM(RTRIM(s.value))
    WHERE d.state_desc = 'ONLINE';
  END;

  -- =========================================================================
  -- Phase 1: Plan Cache analysis (always runs)
  -- =========================================================================

  -- 1A: Find scans in top expensive queries from the plan cache
  DROP TABLE IF EXISTS #TopQueries;
  SELECT TOP (@TopN)
         qs.query_hash
        ,qs.plan_handle
        ,qs.sql_handle
        ,qs.execution_count
        ,qs.total_logical_reads
        ,qs.total_worker_time / 1000 AS total_cpu_time_ms
        ,qs.total_elapsed_time / 1000 AS total_duration_ms
        ,qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_logical_reads
        ,qs.total_worker_time / 1000 / NULLIF(qs.execution_count, 0) AS avg_cpu_time_ms
        ,qs.total_elapsed_time / 1000 / NULLIF(qs.execution_count, 0) AS avg_duration_ms
  INTO #TopQueries
  FROM sys.dm_exec_query_stats qs
  WHERE qs.execution_count >= @MinExecutions
  ORDER BY
    CASE @SortBy
      WHEN 'READS'      THEN qs.total_logical_reads
      WHEN 'CPU'         THEN qs.total_worker_time
      WHEN 'DURATION'    THEN qs.total_elapsed_time
      WHEN 'EXECUTIONS'  THEN qs.execution_count
      ELSE qs.total_logical_reads
    END DESC;

  DECLARE @i INT;
  DECLARE @db NVARCHAR(128);
  DECLARE @sql NVARCHAR(MAX);

  -- 1B: Extract scans from top query plans
  ;WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
  INSERT INTO indexing.ExpensiveQueryResults
    (ServerName, DatabaseName, FindingType, SchemaName, TableName, IndexName
    ,QueryHash, TotalExecutions, TotalLogicalReads, TotalCPUTimeMs, TotalDurationMs
    ,AvgLogicalReads, AvgCPUTimeMs, AvgDurationMs
    ,ScanType, EstimatedRows, SampleQueryText, FindingDetail, Recommendation, DataSource)
  SELECT
     @@SERVERNAME
    ,REPLACE(REPLACE(
       scan.node.value('(Object/@Database)[1]', 'NVARCHAR(128)')
     , '[', ''), ']', '')
    ,'TABLE_SCAN'
    ,REPLACE(REPLACE(
       scan.node.value('(Object/@Schema)[1]', 'NVARCHAR(128)')
     , '[', ''), ']', '')
    ,REPLACE(REPLACE(
       scan.node.value('(Object/@Table)[1]', 'NVARCHAR(128)')
     , '[', ''), ']', '')
    ,REPLACE(REPLACE(
       scan.node.value('(Object/@Index)[1]', 'NVARCHAR(256)')
     , '[', ''), ']', '')
    ,tq.query_hash
    ,tq.execution_count
    ,tq.total_logical_reads
    ,tq.total_cpu_time_ms
    ,tq.total_duration_ms
    ,tq.avg_logical_reads
    ,tq.avg_cpu_time_ms
    ,tq.avg_duration_ms
    ,CASE
       WHEN scan.node.value('@PhysicalOp', 'VARCHAR(50)') = 'Clustered Index Scan' THEN 'CLUSTERED_SCAN'
       WHEN scan.node.value('@PhysicalOp', 'VARCHAR(50)') = 'Table Scan' THEN 'HEAP_SCAN'
       WHEN scan.node.value('@PhysicalOp', 'VARCHAR(50)') = 'Index Scan' THEN 'INDEX_SCAN'
       ELSE scan.node.value('@PhysicalOp', 'VARCHAR(50)')
     END
    ,scan.node.value('@EstimateRows', 'FLOAT')
    ,LEFT(st.text, 4000)
    ,'Top query by ' + @SortBy + ' has ' + scan.node.value('@PhysicalOp', 'VARCHAR(50)')
      + ' on ' + ISNULL(scan.node.value('(Object/@Table)[1]', 'NVARCHAR(128)'), '?')
      + ' (est. ' + CAST(CAST(scan.node.value('@EstimateRows', 'FLOAT') AS BIGINT) AS VARCHAR(20)) + ' rows)'
    ,'Consider adding an index to convert this scan to a seek'
    ,'PLAN_CACHE'
  FROM #TopQueries tq
  CROSS APPLY sys.dm_exec_query_plan(tq.plan_handle) qp
  CROSS APPLY sys.dm_exec_sql_text(tq.sql_handle) st
  CROSS APPLY qp.query_plan.nodes('//RelOp[@PhysicalOp="Clustered Index Scan" or @PhysicalOp="Table Scan" or @PhysicalOp="Index Scan"]') AS scan(node)
  WHERE qp.query_plan IS NOT NULL
    AND scan.node.value('@EstimateRows', 'FLOAT') >= 1000
    AND scan.node.value('(Object/@Database)[1]', 'NVARCHAR(128)') IS NOT NULL;

  -- 1C: Extract missing index hints from top query plans
  ;WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
  INSERT INTO indexing.ExpensiveQueryResults
    (ServerName, DatabaseName, FindingType, SchemaName, TableName
    ,QueryHash, TotalExecutions, TotalLogicalReads, TotalCPUTimeMs, TotalDurationMs
    ,AvgLogicalReads, AvgCPUTimeMs, AvgDurationMs
    ,MissingIndexKeys, MissingIndexIncludes, MissingIndexImpact
    ,SampleQueryText, FindingDetail, DataSource)
  SELECT
     @@SERVERNAME
    ,REPLACE(REPLACE(
       mi.node.value('(MissingIndexGroup/MissingIndex/@Database)[1]', 'NVARCHAR(128)')
     , '[', ''), ']', '')
    ,'MISSING_INDEX'
    ,REPLACE(REPLACE(
       mi.node.value('(MissingIndexGroup/MissingIndex/@Schema)[1]', 'NVARCHAR(128)')
     , '[', ''), ']', '')
    ,REPLACE(REPLACE(
       mi.node.value('(MissingIndexGroup/MissingIndex/@Table)[1]', 'NVARCHAR(128)')
     , '[', ''), ']', '')
    ,tq.query_hash
    ,tq.execution_count
    ,tq.total_logical_reads
    ,tq.total_cpu_time_ms
    ,tq.total_duration_ms
    ,tq.avg_logical_reads
    ,tq.avg_cpu_time_ms
    ,tq.avg_duration_ms
    ,keycols.val
    ,inclcols.val
    ,mi.node.value('(MissingIndexGroup/@Impact)[1]', 'FLOAT')
    ,LEFT(st.text, 4000)
    ,'Missing index with ' + CAST(CAST(mi.node.value('(MissingIndexGroup/@Impact)[1]', 'FLOAT') AS DECIMAL(10,2)) AS VARCHAR(20))
      + '% impact on query with ' + FORMAT(tq.total_logical_reads, 'N0') + ' total reads'
    ,'PLAN_CACHE'
  FROM #TopQueries tq
  CROSS APPLY sys.dm_exec_query_plan(tq.plan_handle) qp
  CROSS APPLY sys.dm_exec_sql_text(tq.sql_handle) st
  CROSS APPLY qp.query_plan.nodes('//MissingIndexes') AS mi(node)
  CROSS APPLY (
    SELECT STUFF((
      SELECT DISTINCT ', ' + c.node.value('@Name', 'NVARCHAR(128)')
      FROM mi.node.nodes('MissingIndexGroup/MissingIndex/ColumnGroup[@Usage="EQUALITY" or @Usage="INEQUALITY"]/Column') AS c(node)
      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS val
  ) keycols
  CROSS APPLY (
    SELECT STUFF((
      SELECT DISTINCT ', ' + c.node.value('@Name', 'NVARCHAR(128)')
      FROM mi.node.nodes('MissingIndexGroup/MissingIndex/ColumnGroup[@Usage="INCLUDE"]/Column') AS c(node)
      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS val
  ) inclcols
  WHERE qp.query_plan IS NOT NULL
    AND mi.node.value('(MissingIndexGroup/@Impact)[1]', 'FLOAT') >= @MinImpact;

  -- Filter results to target databases only
  DELETE FROM indexing.ExpensiveQueryResults
  WHERE ResolvedDate IS NULL
    AND DatabaseName NOT IN (SELECT DatabaseName FROM #DBs);

  -- Remove findings that match already-resolved recommendations
  DELETE nr
  FROM indexing.ExpensiveQueryResults nr
  WHERE nr.ResolvedDate IS NULL
    AND nr.FindingType = 'MISSING_INDEX'
    AND EXISTS (
        SELECT 1 FROM indexing.ExpensiveQueryResults res
        WHERE res.ResolvedDate IS NOT NULL
          AND res.FindingType = 'MISSING_INDEX'
          AND res.DatabaseName = nr.DatabaseName
          AND res.SchemaName   = nr.SchemaName
          AND res.TableName    = nr.TableName
          AND res.MissingIndexKeys = nr.MissingIndexKeys
          AND ISNULL(res.MissingIndexIncludes, '') = ISNULL(nr.MissingIndexIncludes, '')
    );

  -- Deduplicate MISSING_INDEX: keep highest reads per exact match
  ;WITH Dupes AS (
      SELECT ExpensiveQueryId,
             ROW_NUMBER() OVER (
                 PARTITION BY DatabaseName, SchemaName, TableName, MissingIndexKeys, MissingIndexIncludes
                 ORDER BY TotalLogicalReads DESC
             ) AS rn
      FROM indexing.ExpensiveQueryResults
      WHERE ResolvedDate IS NULL AND FindingType = 'MISSING_INDEX'
  )
  DELETE FROM Dupes WHERE rn > 1;

  -- Consolidate same keys / different includes: merge into widest set
  ;WITH KeyGroups AS (
      SELECT ExpensiveQueryId, DatabaseName, SchemaName, TableName,
             MissingIndexKeys, MissingIndexIncludes, TotalLogicalReads,
             ROW_NUMBER() OVER (
                 PARTITION BY DatabaseName, SchemaName, TableName, MissingIndexKeys
                 ORDER BY TotalLogicalReads DESC
             ) AS rn,
             COUNT(*) OVER (
                 PARTITION BY DatabaseName, SchemaName, TableName, MissingIndexKeys
             ) AS grp_count
      FROM indexing.ExpensiveQueryResults
      WHERE ResolvedDate IS NULL AND FindingType = 'MISSING_INDEX'
  )
  UPDATE keeper
  SET MissingIndexIncludes = merged.val
  FROM indexing.ExpensiveQueryResults keeper
  INNER JOIN KeyGroups kg ON keeper.ExpensiveQueryId = kg.ExpensiveQueryId AND kg.rn = 1 AND kg.grp_count > 1
  CROSS APPLY (
      SELECT STUFF((
          SELECT DISTINCT ', ' + LTRIM(RTRIM(s.value))
          FROM indexing.ExpensiveQueryResults e2
          INNER JOIN KeyGroups kg2 ON e2.ExpensiveQueryId = kg2.ExpensiveQueryId
              AND kg2.DatabaseName = kg.DatabaseName AND kg2.SchemaName = kg.SchemaName
              AND kg2.TableName = kg.TableName AND kg2.MissingIndexKeys = kg.MissingIndexKeys
          CROSS APPLY STRING_SPLIT(e2.MissingIndexIncludes, ',') s
          WHERE LTRIM(RTRIM(s.value)) <> ''
          FOR XML PATH('')
      ), 1, 2, '') AS val
  ) merged
  WHERE merged.val IS NOT NULL;

  ;WITH KeyGroups AS (
      SELECT ExpensiveQueryId,
             ROW_NUMBER() OVER (
                 PARTITION BY DatabaseName, SchemaName, TableName, MissingIndexKeys
                 ORDER BY TotalLogicalReads DESC
             ) AS rn
      FROM indexing.ExpensiveQueryResults
      WHERE ResolvedDate IS NULL AND FindingType = 'MISSING_INDEX'
  )
  DELETE FROM KeyGroups WHERE rn > 1;

  -- Prefix consolidation: [col1] is prefix of [col1], [col2] -> keep wider
  DECLARE @prefixDone BIT = 0;
  WHILE @prefixDone = 0
  BEGIN
      DELETE narrow
      FROM indexing.ExpensiveQueryResults narrow
      WHERE narrow.ResolvedDate IS NULL
        AND narrow.FindingType = 'MISSING_INDEX'
        AND EXISTS (
            SELECT 1 FROM indexing.ExpensiveQueryResults wide
            WHERE wide.ResolvedDate IS NULL
              AND wide.FindingType = 'MISSING_INDEX'
              AND wide.DatabaseName = narrow.DatabaseName
              AND wide.SchemaName   = narrow.SchemaName
              AND wide.TableName    = narrow.TableName
              AND wide.ExpensiveQueryId <> narrow.ExpensiveQueryId
              AND REPLACE(REPLACE(wide.MissingIndexKeys, '[', ''), ']', '')
                  LIKE REPLACE(REPLACE(narrow.MissingIndexKeys, '[', ''), ']', '') + ', %'
        );

      IF @@ROWCOUNT = 0
          SET @prefixDone = 1;
  END

  DROP TABLE IF EXISTS #TopQueries;

  -- =========================================================================
  -- Phase 2: Query Store regression detection (opt-in)
  -- =========================================================================
  IF @WithQueryStore = 1
  BEGIN
    SELECT @i = MAX(rn) FROM #DBs;

    WHILE @i > 0
    BEGIN
      SELECT @db = DatabaseName FROM #DBs WHERE rn = @i;

      IF OBJECT_ID('tempdb..#QSRegressed') IS NOT NULL DROP TABLE #QSRegressed;

      SET @sql = N'USE ' + QUOTENAME(@db) + N';

      DECLARE @qsEnabled BIT = 0;
      SELECT @qsEnabled = CASE WHEN actual_state IN (1, 2) THEN 1 ELSE 0 END
      FROM sys.database_query_store_options;

      IF @qsEnabled = 1
      BEGIN
        SELECT
           q.query_hash
          ,qt.query_sql_text
          ,recent.avg_logical_reads AS recent_avg_reads
          ,historical.avg_logical_reads AS historical_avg_reads
          ,CASE WHEN historical.avg_logical_reads > 0
                THEN CAST(recent.avg_logical_reads AS FLOAT) / historical.avg_logical_reads
                ELSE 0
           END AS regression_factor
          ,recent.total_executions
          ,recent.total_logical_reads
          ,recent.avg_cpu_time_ms
          ,recent.avg_duration_ms
        INTO #QSRegressed
        FROM sys.query_store_query q
        JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
        CROSS APPLY (
          SELECT
             SUM(rs.count_executions) AS total_executions
            ,SUM(rs.count_executions * rs.avg_logical_io_reads) AS total_logical_reads
            ,CASE WHEN SUM(rs.count_executions) > 0
                  THEN SUM(rs.count_executions * rs.avg_logical_io_reads) / SUM(rs.count_executions)
                  ELSE 0
             END AS avg_logical_reads
            ,CASE WHEN SUM(rs.count_executions) > 0
                  THEN SUM(rs.count_executions * rs.avg_cpu_time) / SUM(rs.count_executions) / 1000
                  ELSE 0
             END AS avg_cpu_time_ms
            ,CASE WHEN SUM(rs.count_executions) > 0
                  THEN SUM(rs.count_executions * rs.avg_duration) / SUM(rs.count_executions) / 1000
                  ELSE 0
             END AS avg_duration_ms
          FROM sys.query_store_plan p
          JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
          JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
          WHERE p.query_id = q.query_id
            AND rsi.start_time >= DATEADD(DAY, -@pLookbackDays, GETUTCDATE())
          HAVING SUM(rs.count_executions) >= @pMinExecutions
        ) recent
        CROSS APPLY (
          SELECT
             CASE WHEN SUM(rs.count_executions) > 0
                  THEN SUM(rs.count_executions * rs.avg_logical_io_reads) / SUM(rs.count_executions)
                  ELSE 0
             END AS avg_logical_reads
          FROM sys.query_store_plan p
          JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
          JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
          WHERE p.query_id = q.query_id
            AND rsi.start_time < DATEADD(DAY, -@pLookbackDays, GETUTCDATE())
          HAVING SUM(rs.count_executions) >= @pMinExecutions
        ) historical
        WHERE CAST(recent.avg_logical_reads AS FLOAT) / NULLIF(historical.avg_logical_reads, 0) >= 3;

        INSERT INTO DBA_Utilities.indexing.ExpensiveQueryResults
          (ServerName, DatabaseName, FindingType
          ,QueryHash, TotalExecutions, TotalLogicalReads
          ,AvgLogicalReads, AvgCPUTimeMs, AvgDurationMs
          ,RegressionFactor, SampleQueryText
          ,FindingDetail, Recommendation, DataSource)
        SELECT
           @@SERVERNAME
          ,DB_NAME()
          ,''REGRESSED_QUERY''
          ,r.query_hash
          ,r.total_executions
          ,r.total_logical_reads
          ,r.recent_avg_reads
          ,r.avg_cpu_time_ms
          ,r.avg_duration_ms
          ,r.regression_factor
          ,LEFT(r.query_sql_text, 4000)
          ,''Query regressed '' + CAST(CAST(r.regression_factor AS DECIMAL(10,1)) AS VARCHAR(20))
            + ''x: recent avg '' + FORMAT(r.recent_avg_reads, ''N0'')
            + '' reads vs historical avg '' + FORMAT(r.historical_avg_reads, ''N0'') + '' reads''
          ,''Investigate plan change or data growth causing regression''
          ,''QUERY_STORE''
        FROM #QSRegressed r;
      END;';

      BEGIN TRY
        EXEC sp_executesql @sql
          ,N'@pLookbackDays INT, @pMinExecutions BIGINT'
          ,@pLookbackDays = @LookbackDays
          ,@pMinExecutions = @MinExecutions;
      END TRY
      BEGIN CATCH
        PRINT 'Error processing ' + @db + ': ' + ERROR_MESSAGE();
      END CATCH;

      SET @i = @i - 1;
    END;
  END;

  ---------------------------------------------------------------------------
  -- Enrich MISSING_INDEX findings via sp_BuildIndexScript
  ---------------------------------------------------------------------------
  DECLARE @eId INT, @eDB NVARCHAR(128), @eSchema NVARCHAR(128), @eTable NVARCHAR(128);
  DECLARE @eKeys NVARCHAR(MAX), @eIncludes NVARCHAR(MAX);
  DECLARE @oStrategy VARCHAR(20), @oScript NVARCHAR(MAX), @oRec NVARCHAR(MAX);
  DECLARE @eSizeWarning NVARCHAR(MAX), @eEstGB DECIMAL(18,2), @eGBPos INT, @eGBEnd INT;
  DECLARE @eSchemaTable NVARCHAR(256);

  DECLARE enrich_cursor CURSOR LOCAL FAST_FORWARD FOR
      SELECT ExpensiveQueryId, DatabaseName, SchemaName, TableName,
             MissingIndexKeys, MissingIndexIncludes
      FROM indexing.ExpensiveQueryResults
      WHERE ResolvedDate IS NULL AND FindingType = 'MISSING_INDEX';

  OPEN enrich_cursor;
  FETCH NEXT FROM enrich_cursor INTO @eId, @eDB, @eSchema, @eTable, @eKeys, @eIncludes;

  WHILE @@FETCH_STATUS = 0
  BEGIN
      EXEC indexing.sp_BuildIndexScript
          @DatabaseName   = @eDB,
          @SchemaName     = @eSchema,
          @TableName      = @eTable,
          @KeyColumns     = @eKeys,
          @IncludeColumns = @eIncludes,
          @Strategy       = @oStrategy OUTPUT,
          @Script         = @oScript OUTPUT,
          @Recommendation = @oRec OUTPUT;

      IF @oStrategy IN ('INVALID_COLUMNS', 'SUPERSET_COVERED')
      BEGIN
          UPDATE indexing.ExpensiveQueryResults
          SET CreateStatement = NULL,
              Recommendation  = @oRec,
              ResolvedDate    = GETDATE()
          WHERE ExpensiveQueryId = @eId;
      END
      ELSE
      BEGIN
          SET @eSizeWarning = NULL;
          SET @eEstGB = NULL;

          SET @eSchemaTable = QUOTENAME(@eSchema) + '.' + QUOTENAME(@eTable);

          BEGIN TRY
              EXEC indexing.sp_GetHybridIndexSizeEstimate
                  @DatabaseName      = @eDB,
                  @SchemaTable       = @eSchemaTable,
                  @RecKeyColumns     = @eKeys,
                  @RecIncludeColumns = @eIncludes,
                  @Warning           = @eSizeWarning OUTPUT;

              IF @eSizeWarning IS NOT NULL
              BEGIN
                  SET @eGBPos = CHARINDEX('~', @eSizeWarning);
                  SET @eGBEnd = CHARINDEX(' GB', @eSizeWarning, @eGBPos);
                  IF @eGBPos > 0 AND @eGBEnd > @eGBPos
                      SET @eEstGB = TRY_CAST(SUBSTRING(@eSizeWarning, @eGBPos + 1, @eGBEnd - @eGBPos - 1) AS DECIMAL(18,2));
              END
          END TRY
          BEGIN CATCH
              SET @eEstGB = NULL;
          END CATCH

          UPDATE indexing.ExpensiveQueryResults
          SET CreateStatement = @oScript,
              Recommendation  = @oRec,
              EstimatedSizeGB = @eEstGB
          WHERE ExpensiveQueryId = @eId;
      END

      FETCH NEXT FROM enrich_cursor INTO @eId, @eDB, @eSchema, @eTable, @eKeys, @eIncludes;
  END

  CLOSE enrich_cursor;
  DEALLOCATE enrich_cursor;

  DROP TABLE IF EXISTS #DBs;
END;
GO

-- =========================================================================
-- Proc: indexing.sp_ExpensiveQueryRecommendations
-- =========================================================================
CREATE OR ALTER PROCEDURE indexing.sp_ExpensiveQueryRecommendations
  @DatabaseName     NVARCHAR(MAX) = NULL
 ,@TableName        NVARCHAR(128) = NULL
 ,@RunAnalysis      BIT           = 0
 ,@TopN             INT           = 50
 ,@SortBy           VARCHAR(20)   = 'READS'
 ,@MinExecutions    BIGINT        = 10
 ,@LookbackDays     INT           = 7
 ,@WithQueryStore   BIT           = 0
 ,@MinImpact        DECIMAL(5,2)  = 50.0
 ,@FindingType      VARCHAR(30)   = NULL
 ,@RunnableUnder    VARCHAR(20)   = NULL  -- NULL=all uncommented, '2'=2GB both, '1,5e'=1GB Std/5GB Ent
AS
BEGIN
  SET NOCOUNT ON;

  -- Parse @RunnableUnder: NULL=off, '2'=2GB both, '1,5e'=1GB Standard/5GB Enterprise
  DECLARE @ThresholdStd DECIMAL(10,2) = NULL;
  DECLARE @ThresholdEnt DECIMAL(10,2) = NULL;
  DECLARE @ActiveThreshold DECIMAL(10,2) = NULL;
  DECLARE @IsEnterprise BIT = 0;

  IF @RunnableUnder IS NOT NULL AND LTRIM(RTRIM(@RunnableUnder)) <> ''
  BEGIN
      IF @RunnableUnder LIKE '%,%e'
      BEGIN
          SET @ThresholdStd = TRY_CAST(LEFT(@RunnableUnder, CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
          SET @ThresholdEnt = TRY_CAST(SUBSTRING(@RunnableUnder, CHARINDEX(',', @RunnableUnder) + 1,
              LEN(@RunnableUnder) - CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
      END
      ELSE
      BEGIN
          SET @ThresholdStd = TRY_CAST(@RunnableUnder AS DECIMAL(10,2));
          SET @ThresholdEnt = @ThresholdStd;
      END
  END

  IF CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Enterprise%'
      OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Developer%'
      SET @IsEnterprise = 1;

  SET @ActiveThreshold = CASE WHEN @IsEnterprise = 1 THEN @ThresholdEnt ELSE @ThresholdStd END;

  IF @RunAnalysis = 1
    EXEC indexing.sp_ExpensiveQueryAnalysis
        @DatabaseName   = @DatabaseName
       ,@TopN           = @TopN
       ,@SortBy         = @SortBy
       ,@MinExecutions  = @MinExecutions
       ,@LookbackDays   = @LookbackDays
       ,@WithQueryStore = @WithQueryStore
       ,@MinImpact     = @MinImpact;

  DECLARE @ScriptText  NVARCHAR(MAX) = '';
  DECLARE @CRLF        CHAR(2)       = CHAR(13) + CHAR(10);
  DECLARE @Separator   VARCHAR(60)   = '/*****************************************************/';

  DECLARE @TotalRecs       INT = 0;
  DECLARE @TotalDatabases  INT = 0;
  DECLARE @TotalScans      INT = 0;
  DECLARE @TotalMissing    INT = 0;
  DECLARE @TotalRegressed  INT = 0;

  SELECT @TotalRecs       = COUNT(*)
        ,@TotalDatabases   = COUNT(DISTINCT DatabaseName)
        ,@TotalScans       = SUM(CASE WHEN FindingType = 'TABLE_SCAN' THEN 1 ELSE 0 END)
        ,@TotalMissing     = SUM(CASE WHEN FindingType = 'MISSING_INDEX' THEN 1 ELSE 0 END)
        ,@TotalRegressed   = SUM(CASE WHEN FindingType = 'REGRESSED_QUERY' THEN 1 ELSE 0 END)
  FROM indexing.ExpensiveQueryResults
  WHERE ResolvedDate IS NULL
    AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
    AND (@TableName    IS NULL OR TableName    = @TableName)
    AND (@FindingType  IS NULL OR FindingType  = @FindingType)
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SET @ScriptText =
    '/*' + @CRLF
    + '==============================================================================' + @CRLF
    + '  EXPENSIVE QUERY PLAN ANALYSIS' + @CRLF
    + '  Server: ' + @@SERVERNAME + @CRLF
    + '  Generated: ' + CONVERT(VARCHAR(30), GETDATE(), 120) + @CRLF
    + '==============================================================================' + @CRLF
    + 'Statistics:' + @CRLF
    + '    Databases:          ' + CAST(@TotalDatabases AS VARCHAR(10)) + @CRLF
    + '    Total Findings:     ' + CAST(@TotalRecs AS VARCHAR(10)) + @CRLF
    + '      Table Scans:      ' + CAST(@TotalScans AS VARCHAR(10)) + @CRLF
    + '      Missing Indexes:  ' + CAST(@TotalMissing AS VARCHAR(10)) + @CRLF
    + '      Regressed Queries:' + CAST(@TotalRegressed AS VARCHAR(10)) + @CRLF
    + @CRLF
    + 'Filters:' + @CRLF
    + '    @DatabaseName   = ' + ISNULL('''' + @DatabaseName + '''', 'ALL') + @CRLF
    + '    @TableName      = ' + ISNULL('''' + @TableName + '''', 'ALL') + @CRLF
    + '    @FindingType    = ' + ISNULL('''' + @FindingType + '''', 'ALL') + @CRLF
    + '    @TopN           = ' + CAST(@TopN AS VARCHAR(10)) + @CRLF
    + '    @SortBy         = ' + @SortBy + @CRLF
    + '    @MinExecutions  = ' + CAST(@MinExecutions AS VARCHAR(20)) + @CRLF
    + '    @LookbackDays   = ' + CAST(@LookbackDays AS VARCHAR(10)) + @CRLF
    + '    @MinImpact      = ' + CAST(@MinImpact AS VARCHAR(10)) + '%%' + @CRLF
    + '    @WithQueryStore = ' + CAST(@WithQueryStore AS VARCHAR(1)) + @CRLF
    + '    @RunnableUnder = ' + ISNULL('''' + @RunnableUnder + '''', 'NULL (all uncommented)') + @CRLF
    + @CRLF
    + 'Data Sources: Plan Cache' + CASE WHEN @WithQueryStore = 1 THEN ', Query Store' ELSE '' END + @CRLF
    + '*/' + @CRLF;

  DECLARE @CurrentDB    NVARCHAR(128) = '';
  DECLARE @CurrentType  VARCHAR(30)   = '';
  DECLARE @CurrentTable NVARCHAR(400) = '';
  DECLARE @IsFirstDB    BIT = 1;
  DECLARE @TableKey      NVARCHAR(400);
  DECLARE @SizeWarning   NVARCHAR(MAX);
  DECLARE @EstimatedGB   DECIMAL(18,2);
  DECLARE @ShouldComment BIT;
  DECLARE @LargeCount    INT = 0;
  DECLARE @RunnableCount INT = 0;
  DECLARE @GBPos         INT;
  DECLARE @GBEnd         INT;
  DECLARE @SchemaTable   NVARCHAR(500);

  DECLARE @Id              INT;
  DECLARE @DB              NVARCHAR(128);
  DECLARE @FType           VARCHAR(30);
  DECLARE @Schema          NVARCHAR(128);
  DECLARE @Table           NVARCHAR(128);
  DECLARE @IdxName         NVARCHAR(256);
  DECLARE @QHash           BINARY(8);
  DECLARE @TotalExec       BIGINT;
  DECLARE @TotalReads      BIGINT;
  DECLARE @TotalCPU        BIGINT;
  DECLARE @TotalDur        BIGINT;
  DECLARE @AvgReads        BIGINT;
  DECLARE @AvgCPU          BIGINT;
  DECLARE @AvgDur          BIGINT;
  DECLARE @ScanTyp         VARCHAR(20);
  DECLARE @EstRows         FLOAT;
  DECLARE @MIKeys          NVARCHAR(MAX);
  DECLARE @MIIncludes      NVARCHAR(MAX);
  DECLARE @MIImpact        FLOAT;
  DECLARE @RegFactor       FLOAT;
  DECLARE @SampleQuery     NVARCHAR(MAX);
  DECLARE @Detail          NVARCHAR(MAX);
  DECLARE @Rec             NVARCHAR(MAX);
  DECLARE @CreateStmt      NVARCHAR(MAX);
  DECLARE @EstSizeGB       DECIMAL(18,2);
  DECLARE @Source           VARCHAR(20);

  -- Pre-build summary text per database + finding type
  DROP TABLE IF EXISTS #FindingSummaries;
  ;WITH RankedFindings AS (
    SELECT
       DatabaseName
      ,FindingType
      ,CASE FindingType
        WHEN 'TABLE_SCAN' THEN
          '--   ' + ISNULL(QUOTENAME(SchemaName) + '.' + QUOTENAME(TableName), '?')
          + ' - ' + ISNULL(ScanType, '?')
          + ', ' + FORMAT(ISNULL(EstimatedRows, 0), 'N0') + ' est rows'
          + ', ' + FORMAT(ISNULL(TotalLogicalReads, 0), 'N0') + ' total reads'
        WHEN 'MISSING_INDEX' THEN
          '--   ' + FORMAT(CAST(ISNULL(MissingIndexImpact, 0) AS DECIMAL(10,1)), 'N1')
          + '% impact on ' + ISNULL(QUOTENAME(SchemaName) + '.' + QUOTENAME(TableName), '?')
          + ' - keys: ' + ISNULL(MissingIndexKeys, '?')
        WHEN 'REGRESSED_QUERY' THEN
          '--   ' + FORMAT(CAST(ISNULL(RegressionFactor, 0) AS DECIMAL(10,1)), 'N1')
          + 'x  ' + LEFT(REPLACE(REPLACE(ISNULL(SampleQueryText, '?'), CHAR(13), ' '), CHAR(10), ' '), 120)
          + '  (' + FORMAT(ISNULL(AvgLogicalReads, 0), 'N0') + ' avg reads, '
          + FORMAT(ISNULL(TotalExecutions, 0), 'N0') + ' executions)'
        ELSE ''
       END AS SummaryLine
      ,ROW_NUMBER() OVER (
        PARTITION BY DatabaseName, FindingType
        ORDER BY
          CASE FindingType
            WHEN 'TABLE_SCAN' THEN TotalLogicalReads
            WHEN 'MISSING_INDEX' THEN CAST(MissingIndexImpact * TotalLogicalReads AS BIGINT)
            WHEN 'REGRESSED_QUERY' THEN CAST(RegressionFactor * 1000000 AS BIGINT)
            ELSE TotalLogicalReads
          END DESC
       ) AS rn
    FROM indexing.ExpensiveQueryResults
    WHERE ResolvedDate IS NULL
      AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
      AND (@TableName    IS NULL OR TableName    = @TableName)
      AND (@FindingType  IS NULL OR FindingType  = @FindingType)
      AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName)
  )
  SELECT
     DatabaseName
    ,FindingType
    ,CASE FindingType
       WHEN 'TABLE_SCAN' THEN '-- Top Scans:'
       WHEN 'MISSING_INDEX' THEN '-- Top Missing Indexes:'
       WHEN 'REGRESSED_QUERY' THEN '-- Top Regressions:'
       ELSE '-- Top Findings:'
     END AS SummaryHeader
    ,STRING_AGG(SummaryLine, CHAR(13) + CHAR(10)) WITHIN GROUP (ORDER BY rn) AS SummaryBody
  INTO #FindingSummaries
  FROM RankedFindings
  WHERE rn <= 10
  GROUP BY DatabaseName, FindingType;

  DECLARE @SummaryText NVARCHAR(MAX);

  DECLARE rec_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT ExpensiveQueryId, DatabaseName, FindingType, SchemaName, TableName, IndexName
          ,QueryHash, TotalExecutions, TotalLogicalReads, TotalCPUTimeMs, TotalDurationMs
          ,AvgLogicalReads, AvgCPUTimeMs, AvgDurationMs
          ,ScanType, EstimatedRows
          ,MissingIndexKeys, MissingIndexIncludes, MissingIndexImpact
          ,RegressionFactor, SampleQueryText, FindingDetail, Recommendation
          ,CreateStatement, EstimatedSizeGB, DataSource
    FROM indexing.ExpensiveQueryResults
    WHERE ResolvedDate IS NULL
      AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
      AND (@TableName    IS NULL OR TableName    = @TableName)
      AND (@FindingType  IS NULL OR FindingType  = @FindingType)
      AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName)
    ORDER BY DatabaseName, FindingType, SchemaName, TableName,
      CASE WHEN FindingType = 'TABLE_SCAN' THEN TotalLogicalReads
           WHEN FindingType = 'MISSING_INDEX' THEN CAST(MissingIndexImpact * TotalLogicalReads AS BIGINT)
           WHEN FindingType = 'REGRESSED_QUERY' THEN CAST(RegressionFactor * 1000000 AS BIGINT)
           ELSE TotalLogicalReads
      END DESC;

  OPEN rec_cursor;
  FETCH NEXT FROM rec_cursor INTO @Id, @DB, @FType, @Schema, @Table, @IdxName
    ,@QHash, @TotalExec, @TotalReads, @TotalCPU, @TotalDur
    ,@AvgReads, @AvgCPU, @AvgDur
    ,@ScanTyp, @EstRows
    ,@MIKeys, @MIIncludes, @MIImpact
    ,@RegFactor, @SampleQuery, @Detail, @Rec
    ,@CreateStmt, @EstSizeGB, @Source;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @SchemaTable = QUOTENAME(@Schema) + '.' + QUOTENAME(@Table);

    IF @DB <> @CurrentDB
    BEGIN
      IF @IsFirstDB = 0
        SET @ScriptText = @ScriptText + @CRLF;

      SET @CurrentDB    = @DB;
      SET @CurrentType  = '';
      SET @CurrentTable = '';
      SET @IsFirstDB    = 0;

      SET @ScriptText = @ScriptText
        + '-- ============================================================================' + @CRLF
        + '-- Database: ' + @DB + @CRLF
        + '-- ============================================================================' + @CRLF
        + 'USE ' + QUOTENAME(@DB) + @CRLF
        + 'GO' + @CRLF;
    END;

    IF @FType <> @CurrentType
    BEGIN
      SET @CurrentType = @FType;
      SET @SummaryText = NULL;

      SELECT @SummaryText = SummaryHeader + @CRLF + SummaryBody
      FROM #FindingSummaries
      WHERE DatabaseName = @DB AND FindingType = @FType;

      SET @ScriptText = @ScriptText
        + @CRLF
        + @Separator + @CRLF
        + '-- Finding Type: ' + @FType + @CRLF
        + @Separator + @CRLF;

      IF @SummaryText IS NOT NULL
        SET @ScriptText = @ScriptText
          + @CRLF + @SummaryText + @CRLF;
    END;

    ---------------------------------------------------------------------------
    -- Table header for MISSING_INDEX (grouped by table)
    ---------------------------------------------------------------------------
    IF @FType = 'MISSING_INDEX'
    BEGIN
      SET @TableKey = @DB + '.' + @Schema + '.' + @Table;
      IF @TableKey <> @CurrentTable
      BEGIN
        SET @CurrentTable = @TableKey;
        SET @ScriptText = @ScriptText
          + @CRLF + @Separator + @CRLF
          + '-- Table: ' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + @CRLF
          + @Separator + @CRLF;

        SET @ScriptText = @ScriptText
            + '--EXEC sp_helpindexUsage ''' + ISNULL(@Schema, 'dbo') + '.' + @Table + '''' + @CRLF;
      END
    END

    ---------------------------------------------------------------------------
    -- Per-finding detail
    ---------------------------------------------------------------------------
    SET @ScriptText = @ScriptText + @CRLF
      + '-- ' + @Detail + @CRLF
      + '--   Stats: ' + FORMAT(ISNULL(@TotalReads, 0), 'N0') + ' total reads'
      + '  |  ' + FORMAT(ISNULL(@TotalExec, 0), 'N0') + ' executions'
      + '  |  avg ' + FORMAT(ISNULL(@AvgReads, 0), 'N0') + ' reads/exec' + @CRLF;

    IF @FType = 'TABLE_SCAN'
      SET @ScriptText = @ScriptText
        + '--   Object: ' + ISNULL(QUOTENAME(@Schema) + '.' + QUOTENAME(@Table), '?')
        + CASE WHEN @IdxName IS NOT NULL THEN ' (' + @IdxName + ')' ELSE '' END + @CRLF
        + '--   Scan Type: ' + ISNULL(@ScanTyp, '?')
        + '  |  Est. Rows: ' + FORMAT(ISNULL(@EstRows, 0), 'N0') + @CRLF;

    IF @FType = 'MISSING_INDEX'
      SET @ScriptText = @ScriptText
        + '--   Keys: ' + ISNULL(@MIKeys, '?') + @CRLF
        + '--   Includes: ' + ISNULL(@MIIncludes, '(none)') + @CRLF
        + '--   Impact: ' + FORMAT(CAST(ISNULL(@MIImpact, 0) AS DECIMAL(10,2)), 'N2') + '%' + @CRLF;

    IF @FType = 'REGRESSED_QUERY'
      SET @ScriptText = @ScriptText
        + '--   Regression: ' + CAST(CAST(ISNULL(@RegFactor, 0) AS DECIMAL(10,1)) AS VARCHAR(20)) + 'x worse than historical' + @CRLF
        + '--   Avg CPU: ' + FORMAT(ISNULL(@AvgCPU, 0), 'N0') + ' ms  |  Avg Duration: ' + FORMAT(ISNULL(@AvgDur, 0), 'N0') + ' ms' + @CRLF;

    SET @ScriptText = @ScriptText
      + '--   Recommendation: ' + ISNULL(@Rec, '?') + @CRLF;

    IF @EstSizeGB IS NOT NULL
      SET @ScriptText = @ScriptText
        + '--   Estimated Size: ~' + FORMAT(@EstSizeGB * 1024, 'N1') + ' MB' + @CRLF;

    ---------------------------------------------------------------------------
    -- CREATE statement + @RunnableUnder
    ---------------------------------------------------------------------------
    IF @CreateStmt IS NOT NULL
    BEGIN
      SET @ShouldComment = 0;

      IF @ActiveThreshold IS NOT NULL AND ISNULL(@EstSizeGB, 0) >= @ActiveThreshold
        SET @ShouldComment = 1;

      IF @ShouldComment = 1
      BEGIN
        SET @LargeCount = @LargeCount + 1;
        SET @ScriptText = @ScriptText
          + @CRLF + '/*' + @CRLF + @CreateStmt + @CRLF + '*/' + @CRLF
          + @CRLF + '/* UPDATE DBA_Utilities.indexing.ExpensiveQueryResults SET ResolvedDate = GETDATE() WHERE ExpensiveQueryId = ' + CAST(@Id AS VARCHAR(10)) + '; */' + @CRLF;
      END
      ELSE
      BEGIN
        SET @RunnableCount = @RunnableCount + 1;
        SET @ScriptText = @ScriptText
          + @CRLF + @CreateStmt + @CRLF
          + @CRLF + 'UPDATE DBA_Utilities.indexing.ExpensiveQueryResults SET ResolvedDate = GETDATE() WHERE ExpensiveQueryId = ' + CAST(@Id AS VARCHAR(10)) + ';' + @CRLF;
      END
    END
    ELSE
    BEGIN
      SET @ScriptText = @ScriptText
        + @CRLF + 'UPDATE DBA_Utilities.indexing.ExpensiveQueryResults SET ResolvedDate = GETDATE() WHERE ExpensiveQueryId = ' + CAST(@Id AS VARCHAR(10)) + ';' + @CRLF;
    END

    FETCH NEXT FROM rec_cursor INTO @Id, @DB, @FType, @Schema, @Table, @IdxName
      ,@QHash, @TotalExec, @TotalReads, @TotalCPU, @TotalDur
      ,@AvgReads, @AvgCPU, @AvgDur
      ,@ScanTyp, @EstRows
      ,@MIKeys, @MIIncludes, @MIImpact
      ,@RegFactor, @SampleQuery, @Detail, @Rec
      ,@CreateStmt, @EstSizeGB, @Source;
  END;

  CLOSE rec_cursor;
  DEALLOCATE rec_cursor;

  DECLARE @TotalUnfiltered INT;
  SELECT @TotalUnfiltered = COUNT(*)
  FROM indexing.ExpensiveQueryResults
  WHERE ResolvedDate IS NULL
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SELECT @@SERVERNAME                                AS ServerName
        ,ISNULL(@DatabaseName, 'ALL')                AS DatabaseName
        ,GETDATE()                                   AS GeneratedDate
        ,CAST(@TotalRecs AS VARCHAR(10)) + ' findings ('
         + CAST(@TotalScans AS VARCHAR(10)) + ' scans, '
         + CAST(@TotalMissing AS VARCHAR(10)) + ' missing indexes, '
         + CAST(@TotalRegressed AS VARCHAR(10)) + ' regressions)'
                                                     AS [Statistics]
        ,CASE WHEN @TotalRecs > 0 AND @ActiveThreshold IS NOT NULL
              THEN 'Has Recommendations (' + CAST(@RunnableCount AS VARCHAR(10)) + ' runnable'
                   + CASE WHEN @LargeCount > 0 THEN ', ' + CAST(@LargeCount AS VARCHAR(10)) + ' over threshold commented' ELSE '' END + ')'
              WHEN @TotalRecs > 0
              THEN 'Has Recommendations'
              WHEN @TotalRecs = 0 AND @TotalUnfiltered > 0
              THEN 'Nothing To Run'
              ELSE 'No Recommendations'
         END                                         AS [Status]
        ,CASE WHEN @TotalRecs > 0
              THEN @ScriptText
              ELSE NULL
         END                                         AS ScriptText;
END;
GO


-- ==========================================================================
-- COLUMN ACCESS PATTERN ANALYSIS
-- ==========================================================================

-- =========================================================================
-- Table: indexing.ColumnAccessPatternResults
-- =========================================================================
IF OBJECT_ID('indexing.ColumnAccessPatternResults', 'U') IS NULL
BEGIN
  CREATE TABLE indexing.ColumnAccessPatternResults
    (ColumnAccessPatternId INT            IDENTITY(1, 1)
    ,ServerName            NVARCHAR(128)  NOT NULL
    ,DatabaseName          NVARCHAR(128)  NOT NULL
    ,SchemaName            NVARCHAR(128)  NOT NULL
    ,TableName             NVARCHAR(128)  NOT NULL
    ,ColumnName            NVARCHAR(128)  NOT NULL
    ,UsageType             VARCHAR(20)    NOT NULL
    ,QueryCount            INT            NOT NULL
    ,TotalExecutions       BIGINT         NULL
    ,TotalLogicalReads     BIGINT         NULL
    ,ExistingIndexCoverage VARCHAR(20)    NULL
    ,SuggestedAction       NVARCHAR(MAX)  NULL
    ,DataSource            VARCHAR(20)    NOT NULL
    ,ProcessedDate         DATETIME2(3)   NOT NULL CONSTRAINT DF_ColumnAccessPatternResults_ProcessedDate DEFAULT (SYSDATETIME())
    ,ResolvedDate          DATETIME2(3)   NULL
    ,CONSTRAINT PKC_ColumnAccessPatternResults PRIMARY KEY CLUSTERED (ColumnAccessPatternId DESC) WITH (FILLFACTOR = 100)
    ) ON [PRIMARY];
END
GO

-- =========================================================================
-- Proc: indexing.sp_ColumnAccessPatternAnalysis
-- =========================================================================
CREATE OR ALTER PROCEDURE indexing.sp_ColumnAccessPatternAnalysis
  @DatabaseName     NVARCHAR(MAX) = NULL
 ,@TopN             INT           = 200
 ,@MinQueryCount    INT           = 3
AS
BEGIN
  SET NOCOUNT ON;

  DELETE FROM indexing.ColumnAccessPatternResults WHERE ResolvedDate IS NULL;

  DROP TABLE IF EXISTS #DBs;
  CREATE TABLE #DBs (DatabaseName NVARCHAR(128), rn INT);

  IF @DatabaseName IS NULL
  BEGIN
    INSERT INTO #DBs (DatabaseName, rn)
    SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.database_id > 4;
  END
  ELSE IF @DatabaseName LIKE '%[%]%'
  BEGIN
    INSERT INTO #DBs (DatabaseName, rn)
    SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.name LIKE @DatabaseName;
  END
  ELSE
  BEGIN
    INSERT INTO #DBs (DatabaseName, rn)
    SELECT d.name, ROW_NUMBER() OVER (ORDER BY d.name)
    FROM sys.databases d
    INNER JOIN STRING_SPLIT(@DatabaseName, ',') s ON d.name = LTRIM(RTRIM(s.value))
    WHERE d.state_desc = 'ONLINE';
  END;

  DROP TABLE IF EXISTS #TopPlans;
  SELECT TOP (@TopN)
         qs.plan_handle
        ,qs.sql_handle
        ,qs.query_hash
        ,qs.execution_count
        ,qs.total_logical_reads
  INTO #TopPlans
  FROM sys.dm_exec_query_stats qs
  WHERE qs.execution_count >= 2
  ORDER BY qs.total_logical_reads DESC;

  DROP TABLE IF EXISTS #RawColumnAccess;
  ;WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
  SELECT
     tp.query_hash
    ,tp.execution_count
    ,tp.total_logical_reads
    ,REPLACE(REPLACE(scan.node.value('(Object/@Database)[1]', 'NVARCHAR(128)'), '[', ''), ']', '') AS DatabaseName
    ,REPLACE(REPLACE(scan.node.value('(Object/@Schema)[1]', 'NVARCHAR(128)'), '[', ''), ']', '') AS SchemaName
    ,REPLACE(REPLACE(scan.node.value('(Object/@Table)[1]', 'NVARCHAR(128)'), '[', ''), ']', '') AS TableName
    ,REPLACE(REPLACE(col.node.value('@Column', 'NVARCHAR(128)'), '[', ''), ']', '') AS ColumnName
    ,CASE
       WHEN scan.node.exist('SeekPredicates') = 1 THEN 'SEEK_PREDICATE'
       ELSE 'SCAN_PREDICATE'
     END AS UsageType
  INTO #RawColumnAccess
  FROM #TopPlans tp
  CROSS APPLY sys.dm_exec_query_plan(tp.plan_handle) qp
  CROSS APPLY qp.query_plan.nodes('//RelOp[IndexScan or TableScan]') AS scan(node)
  CROSS APPLY scan.node.nodes('.//ColumnReference') AS col(node)
  WHERE qp.query_plan IS NOT NULL
    AND scan.node.value('(Object/@Database)[1]', 'NVARCHAR(128)') IS NOT NULL
    AND col.node.value('@Column', 'NVARCHAR(128)') IS NOT NULL;

  ;WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
  INSERT INTO #RawColumnAccess
  SELECT
     tp.query_hash
    ,tp.execution_count
    ,tp.total_logical_reads
    ,REPLACE(REPLACE(mi.node.value('(MissingIndexGroup/MissingIndex/@Database)[1]', 'NVARCHAR(128)'), '[', ''), ']', '')
    ,REPLACE(REPLACE(mi.node.value('(MissingIndexGroup/MissingIndex/@Schema)[1]', 'NVARCHAR(128)'), '[', ''), ']', '')
    ,REPLACE(REPLACE(mi.node.value('(MissingIndexGroup/MissingIndex/@Table)[1]', 'NVARCHAR(128)'), '[', ''), ']', '')
    ,REPLACE(REPLACE(col.node.value('@Name', 'NVARCHAR(128)'), '[', ''), ']', '')
    ,CASE col_group.node.value('@Usage', 'VARCHAR(20)')
       WHEN 'EQUALITY' THEN 'EQUALITY'
       WHEN 'INEQUALITY' THEN 'INEQUALITY'
       WHEN 'INCLUDE' THEN 'INCLUDE'
       ELSE 'OTHER'
     END
  FROM #TopPlans tp
  CROSS APPLY sys.dm_exec_query_plan(tp.plan_handle) qp
  CROSS APPLY qp.query_plan.nodes('//MissingIndexes') AS mi(node)
  CROSS APPLY mi.node.nodes('MissingIndexGroup/MissingIndex/ColumnGroup') AS col_group(node)
  CROSS APPLY col_group.node.nodes('Column') AS col(node)
  WHERE qp.query_plan IS NOT NULL;

  DELETE FROM #RawColumnAccess
  WHERE DatabaseName NOT IN (SELECT DatabaseName FROM #DBs);

  INSERT INTO indexing.ColumnAccessPatternResults
    (ServerName, DatabaseName, SchemaName, TableName, ColumnName, UsageType
    ,QueryCount, TotalExecutions, TotalLogicalReads, DataSource)
  SELECT
     @@SERVERNAME
    ,r.DatabaseName
    ,r.SchemaName
    ,r.TableName
    ,r.ColumnName
    ,r.UsageType
    ,COUNT(DISTINCT r.query_hash) AS QueryCount
    ,SUM(r.execution_count) AS TotalExecutions
    ,SUM(r.total_logical_reads) AS TotalLogicalReads
    ,'PLAN_CACHE'
  FROM #RawColumnAccess r
  WHERE r.SchemaName <> 'cdc'
    AND r.TableName NOT LIKE 'zds%'
    AND r.TableName NOT LIKE 'ds%'
  GROUP BY r.DatabaseName, r.SchemaName, r.TableName, r.ColumnName, r.UsageType
  HAVING COUNT(DISTINCT r.query_hash) >= @MinQueryCount;

  DECLARE @i INT;
  DECLARE @db NVARCHAR(128);
  DECLARE @sql NVARCHAR(MAX);

  SELECT @i = MAX(rn) FROM #DBs;

  WHILE @i > 0
  BEGIN
    SELECT @db = DatabaseName FROM #DBs WHERE rn = @i;

    SET @sql = N'USE ' + QUOTENAME(@db) + N';

    UPDATE r
    SET r.ExistingIndexCoverage = idx.coverage
    FROM DBA_Utilities.indexing.ColumnAccessPatternResults r
    OUTER APPLY (
      SELECT TOP 1
        CASE
          WHEN ic.is_included_column = 0 AND ic.key_ordinal = 1 THEN ''LEADING_KEY''
          WHEN ic.is_included_column = 0 THEN ''KEY''
          WHEN ic.is_included_column = 1 THEN ''INCLUDED''
        END AS coverage
      FROM sys.indexes i
      JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
      JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
      JOIN sys.objects o ON i.object_id = o.object_id
      JOIN sys.schemas s ON o.schema_id = s.schema_id
      WHERE s.name = r.SchemaName
        AND o.name = r.TableName
        AND c.name = r.ColumnName
        AND i.type IN (1, 2)
      ORDER BY
        CASE WHEN ic.is_included_column = 0 AND ic.key_ordinal = 1 THEN 1
             WHEN ic.is_included_column = 0 THEN 2
             WHEN ic.is_included_column = 1 THEN 3
        END
    ) idx
    WHERE r.DatabaseName = DB_NAME()
      AND r.ResolvedDate IS NULL;';

    BEGIN TRY
      EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
      PRINT 'Error processing ' + @db + ': ' + ERROR_MESSAGE();
    END CATCH;

    SET @i = @i - 1;
  END;

  UPDATE indexing.ColumnAccessPatternResults
  SET SuggestedAction = CASE
    WHEN ExistingIndexCoverage IS NULL AND UsageType IN ('EQUALITY', 'SEEK_PREDICATE') THEN 'Consider as leading key column in a new index'
    WHEN ExistingIndexCoverage IS NULL AND UsageType = 'INEQUALITY' THEN 'Consider as secondary key column in a new index'
    WHEN ExistingIndexCoverage IS NULL AND UsageType = 'INCLUDE' THEN 'Consider as INCLUDE column on an existing index'
    WHEN ExistingIndexCoverage IS NULL AND UsageType = 'SCAN_PREDICATE' THEN 'Column used in scan predicate — index on this column may convert scans to seeks'
    WHEN ExistingIndexCoverage = 'INCLUDED' AND UsageType IN ('EQUALITY', 'SEEK_PREDICATE') THEN 'Column is INCLUDEd but used in predicates — promote to key column'
    WHEN ExistingIndexCoverage = 'KEY' AND UsageType IN ('EQUALITY', 'SEEK_PREDICATE') THEN 'Column is a key but not leading — consider reordering or new index'
    WHEN ExistingIndexCoverage = 'LEADING_KEY' THEN 'Already a leading key — well indexed'
    ELSE 'Review index coverage'
  END
  WHERE ResolvedDate IS NULL;

  DROP TABLE IF EXISTS #TopPlans;
  DROP TABLE IF EXISTS #RawColumnAccess;
  DROP TABLE IF EXISTS #DBs;
END;
GO

-- =========================================================================
-- Proc: indexing.sp_ColumnAccessPatternRecommendations
-- =========================================================================
CREATE OR ALTER PROCEDURE indexing.sp_ColumnAccessPatternRecommendations
  @DatabaseName     NVARCHAR(MAX) = NULL
 ,@TableName        NVARCHAR(128) = NULL
 ,@RunnableUnder    VARCHAR(20)   = NULL
 ,@RunAnalysis      BIT           = 0
 ,@TopN             INT           = 200
 ,@MinQueryCount    INT           = 3
 ,@ShowCovered      BIT           = 0
AS
BEGIN
  SET NOCOUNT ON;

  IF @RunAnalysis = 1
    EXEC indexing.sp_ColumnAccessPatternAnalysis
        @DatabaseName  = @DatabaseName
       ,@TopN          = @TopN
       ,@MinQueryCount = @MinQueryCount;

  DECLARE @ScriptText  NVARCHAR(MAX) = '';
  DECLARE @CRLF        CHAR(2)       = CHAR(13) + CHAR(10);
  DECLARE @Separator   VARCHAR(60)   = '/*****************************************************/';

  DECLARE @ThresholdStd DECIMAL(10,2) = NULL;
  DECLARE @ThresholdEnt DECIMAL(10,2) = NULL;
  DECLARE @ActiveThreshold DECIMAL(10,2) = NULL;

  IF @RunnableUnder IS NOT NULL AND LTRIM(RTRIM(@RunnableUnder)) <> ''
  BEGIN
      IF @RunnableUnder LIKE '%,%e'
      BEGIN
          SET @ThresholdStd = TRY_CAST(LEFT(@RunnableUnder, CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
          SET @ThresholdEnt = TRY_CAST(SUBSTRING(@RunnableUnder, CHARINDEX(',', @RunnableUnder) + 1,
              LEN(@RunnableUnder) - CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
      END
      ELSE
      BEGIN
          SET @ThresholdStd = TRY_CAST(@RunnableUnder AS DECIMAL(10,2));
          SET @ThresholdEnt = @ThresholdStd;
      END
  END

  DECLARE @TotalPatterns  INT = 0;
  DECLARE @TotalDatabases INT = 0;
  DECLARE @TotalTables    INT = 0;
  DECLARE @TotalUncovered INT = 0;

  SELECT @TotalPatterns   = COUNT(*)
        ,@TotalUncovered  = SUM(CASE WHEN ExistingIndexCoverage IS NULL THEN 1 ELSE 0 END)
  FROM indexing.ColumnAccessPatternResults
  WHERE ResolvedDate IS NULL
    AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
    AND (@TableName    IS NULL OR TableName    = @TableName)
    AND (@ShowCovered = 1 OR ExistingIndexCoverage IS NULL OR ExistingIndexCoverage <> 'LEADING_KEY')
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  DROP TABLE IF EXISTS #TableRecs;
  CREATE TABLE #TableRecs
    (DatabaseName     NVARCHAR(128)
    ,SchemaName       NVARCHAR(128)
    ,TableName        NVARCHAR(128)
    ,KeyColumns       NVARCHAR(MAX)
    ,IncludeColumns   NVARCHAR(MAX)
    ,CreateStatement  NVARCHAR(MAX)
    ,EstimatedSizeGB  DECIMAL(18,2)
    ,NearMatchIndex   NVARCHAR(256)
    ,NearMatchAction  VARCHAR(20));

  ;WITH ColumnsByTable AS (
    SELECT
       DatabaseName, SchemaName, TableName, ColumnName, UsageType, QueryCount, TotalLogicalReads
      ,ROW_NUMBER() OVER (
         PARTITION BY DatabaseName, SchemaName, TableName
         ORDER BY
           CASE UsageType
             WHEN 'EQUALITY' THEN 1
             WHEN 'SEEK_PREDICATE' THEN 2
             WHEN 'INEQUALITY' THEN 3
             WHEN 'SCAN_PREDICATE' THEN 4
             ELSE 99
           END,
           QueryCount DESC, TotalLogicalReads DESC
       ) AS key_order
    FROM indexing.ColumnAccessPatternResults
    WHERE ResolvedDate IS NULL
      AND UsageType IN ('EQUALITY', 'INEQUALITY', 'SEEK_PREDICATE', 'SCAN_PREDICATE')
      AND (ExistingIndexCoverage IS NULL OR ExistingIndexCoverage <> 'LEADING_KEY')
      AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
      AND (@TableName IS NULL OR TableName = @TableName)
      AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName)
  )
  INSERT INTO #TableRecs (DatabaseName, SchemaName, TableName, KeyColumns, IncludeColumns)
  SELECT
     c.DatabaseName, c.SchemaName, c.TableName
    ,STUFF((SELECT ', [' + c2.ColumnName + ']'
            FROM ColumnsByTable c2
            WHERE c2.DatabaseName = c.DatabaseName AND c2.SchemaName = c.SchemaName AND c2.TableName = c.TableName
            ORDER BY c2.key_order
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
    ,STUFF((SELECT ', [' + i2.ColumnName + ']'
            FROM indexing.ColumnAccessPatternResults i2
            WHERE i2.DatabaseName = c.DatabaseName AND i2.SchemaName = c.SchemaName AND i2.TableName = c.TableName
              AND i2.ResolvedDate IS NULL
              AND i2.UsageType = 'INCLUDE'
              AND (i2.ExistingIndexCoverage IS NULL OR i2.ExistingIndexCoverage <> 'LEADING_KEY')
            ORDER BY i2.TotalLogicalReads DESC
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  FROM ColumnsByTable c
  GROUP BY c.DatabaseName, c.SchemaName, c.TableName;

  DROP TABLE IF EXISTS #DBs2;
  CREATE TABLE #DBs2 (DatabaseName NVARCHAR(128), rn INT);
  INSERT INTO #DBs2
  SELECT DISTINCT DatabaseName, ROW_NUMBER() OVER (ORDER BY DatabaseName)
  FROM #TableRecs;

  DECLARE @i INT;
  DECLARE @db2 NVARCHAR(128);
  DECLARE @sql2 NVARCHAR(MAX);

  SELECT @i = MAX(rn) FROM #DBs2;

  WHILE @i > 0
  BEGIN
    SELECT @db2 = DatabaseName FROM #DBs2 WHERE rn = @i;

    SET @sql2 = N'USE ' + QUOTENAME(@db2) + N';

    UPDATE tr
    SET tr.NearMatchIndex = nm.index_name
       ,tr.NearMatchAction = nm.match_type
    FROM DBA_Utilities..#TableRecs tr
    OUTER APPLY (
      SELECT TOP 1
         i.name AS index_name
        ,CASE
           WHEN key_match.match_count = key_match.total_rec_keys THEN ''EXTEND''
           WHEN key_match.match_count >= 1 THEN ''PARTIAL''
         END AS match_type
      FROM sys.indexes i
      JOIN sys.objects o ON i.object_id = o.object_id
      JOIN sys.schemas s ON o.schema_id = s.schema_id
      CROSS APPLY (
        SELECT
           SUM(CASE WHEN EXISTS (
             SELECT 1 FROM sys.index_columns ic2
             JOIN sys.columns c2 ON ic2.object_id = c2.object_id AND ic2.column_id = c2.column_id
             WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id
               AND ic2.is_included_column = 0
               AND ''['' + c2.name + '']'' = LTRIM(rec_col.value)
           ) THEN 1 ELSE 0 END) AS match_count
          ,COUNT(*) AS total_rec_keys
        FROM STRING_SPLIT(tr.KeyColumns, '','') rec_col
        WHERE LTRIM(rec_col.value) <> ''''
      ) key_match
      WHERE s.name = tr.SchemaName
        AND o.name = tr.TableName
        AND i.type = 2
        AND i.is_primary_key = 0
        AND key_match.match_count >= 1
      ORDER BY key_match.match_count DESC
    ) nm
    WHERE tr.DatabaseName = DB_NAME()
      AND tr.NearMatchIndex IS NULL;';

    BEGIN TRY
      EXEC sp_executesql @sql2;
    END TRY
    BEGIN CATCH
      PRINT 'Error checking indexes for ' + @db2 + ': ' + ERROR_MESSAGE();
    END CATCH;

    SET @i = @i - 1;
  END;

  DECLARE @IsEnterprise BIT = 0;
  IF CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Enterprise%'
    OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Developer%'
    SET @IsEnterprise = 1;

  SET @ActiveThreshold = CASE WHEN @IsEnterprise = 1 THEN @ThresholdEnt ELSE @ThresholdStd END;

  UPDATE #TableRecs
  SET CreateStatement = CASE
    WHEN NearMatchAction = 'EXTEND' AND NearMatchIndex IS NOT NULL THEN
      'CREATE NONCLUSTERED INDEX [' + NearMatchIndex + ']'
      + CHAR(13) + CHAR(10) + 'ON [' + SchemaName + '].[' + TableName + '] (' + KeyColumns + ')'
      + CASE WHEN IncludeColumns IS NOT NULL
             THEN CHAR(13) + CHAR(10) + 'INCLUDE (' + IncludeColumns + ')'
             ELSE ''
        END
      + CHAR(13) + CHAR(10) + 'WITH (DROP_EXISTING = ON'
      + CASE WHEN @IsEnterprise = 1 THEN ', ONLINE = ON' ELSE '' END + ');'
    ELSE
      'CREATE NONCLUSTERED INDEX [IX_' + TableName + '_'
      + REPLACE(REPLACE(REPLACE(KeyColumns, '[', ''), ']', ''), ', ', '_')
      + CASE WHEN IncludeColumns IS NOT NULL THEN '_INCLUDES' ELSE '' END + ']'
      + CHAR(13) + CHAR(10) + 'ON [' + SchemaName + '].[' + TableName + '] (' + KeyColumns + ')'
      + CASE WHEN IncludeColumns IS NOT NULL
             THEN CHAR(13) + CHAR(10) + 'INCLUDE (' + IncludeColumns + ')'
             ELSE ''
        END
      + CASE WHEN @IsEnterprise = 1
             THEN CHAR(13) + CHAR(10) + 'WITH (ONLINE = ON);'
             ELSE ';'
        END
    END
  WHERE KeyColumns IS NOT NULL;

  DECLARE @seDB NVARCHAR(128), @seSchema NVARCHAR(128), @seTable NVARCHAR(128);
  DECLARE @seKeys NVARCHAR(MAX), @seInc NVARCHAR(MAX);
  DECLARE @seWarning NVARCHAR(MAX), @seEstGB DECIMAL(18,2), @seGBPos INT, @seGBEnd INT;
  DECLARE @seSchemaTable NVARCHAR(256);

  DECLARE size_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName, SchemaName, TableName, KeyColumns, IncludeColumns
    FROM #TableRecs WHERE CreateStatement IS NOT NULL;

  OPEN size_cursor;
  FETCH NEXT FROM size_cursor INTO @seDB, @seSchema, @seTable, @seKeys, @seInc;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @seWarning = NULL;
    SET @seEstGB = NULL;
    SET @seSchemaTable = QUOTENAME(@seSchema) + '.' + QUOTENAME(@seTable);

    BEGIN TRY
      EXEC indexing.sp_GetHybridIndexSizeEstimate
          @DatabaseName      = @seDB,
          @SchemaTable       = @seSchemaTable,
          @RecKeyColumns     = @seKeys,
          @RecIncludeColumns = @seInc,
          @Warning           = @seWarning OUTPUT;

      IF @seWarning IS NOT NULL
      BEGIN
        SET @seGBPos = CHARINDEX('~', @seWarning);
        SET @seGBEnd = CHARINDEX(' GB', @seWarning, @seGBPos);
        IF @seGBPos > 0 AND @seGBEnd > @seGBPos
          SET @seEstGB = TRY_CAST(SUBSTRING(@seWarning, @seGBPos + 1, @seGBEnd - @seGBPos - 1) AS DECIMAL(18,2));
      END
    END TRY
    BEGIN CATCH
      SET @seEstGB = NULL;
    END CATCH

    IF @seEstGB IS NOT NULL
      UPDATE #TableRecs SET EstimatedSizeGB = @seEstGB
      WHERE DatabaseName = @seDB AND SchemaName = @seSchema AND TableName = @seTable;

    FETCH NEXT FROM size_cursor INTO @seDB, @seSchema, @seTable, @seKeys, @seInc;
  END

  CLOSE size_cursor;
  DEALLOCATE size_cursor;

  SELECT @TotalTables    = COUNT(*)
        ,@TotalDatabases = COUNT(DISTINCT DatabaseName)
  FROM #TableRecs
  WHERE CreateStatement IS NOT NULL;

  SET @ScriptText =
    '/*' + @CRLF
    + '==============================================================================' + @CRLF
    + '  COLUMN ACCESS PATTERN ANALYSIS' + @CRLF
    + '  Server: ' + @@SERVERNAME + @CRLF
    + '  Generated: ' + CONVERT(VARCHAR(30), GETDATE(), 120) + @CRLF
    + '==============================================================================' + @CRLF
    + 'Statistics:' + @CRLF
    + '    Databases:          ' + CAST(@TotalDatabases AS VARCHAR(10)) + @CRLF
    + '    Tables:             ' + CAST(@TotalTables AS VARCHAR(10)) + @CRLF
    + '    Column Patterns:    ' + CAST(@TotalPatterns AS VARCHAR(10)) + @CRLF
    + '    Not Indexed:        ' + CAST(@TotalUncovered AS VARCHAR(10)) + @CRLF
    + @CRLF
    + 'Filters:' + @CRLF
    + '    @DatabaseName   = ' + ISNULL('''' + @DatabaseName + '''', 'ALL') + @CRLF
    + '    @TableName      = ' + ISNULL('''' + @TableName + '''', 'ALL') + @CRLF
    + '    @MinQueryCount  = ' + CAST(@MinQueryCount AS VARCHAR(10)) + @CRLF
    + '    @RunnableUnder  = ' + ISNULL('''' + @RunnableUnder + '''', 'NULL (all uncommented)') + @CRLF
    + '    @ShowCovered    = ' + CAST(@ShowCovered AS VARCHAR(1)) + @CRLF
    + @CRLF
    + 'Coverage Legend:' + @CRLF
    + '    (none)       = Column not in any index' + @CRLF
    + '    INCLUDED     = Column is in an INCLUDE but used in predicates — promote to key' + @CRLF
    + '    KEY          = Column is a key but not leading — may need reordering or new index' + @CRLF
    + '    LEADING_KEY  = Already well indexed (hidden by default, use @ShowCovered = 1)' + @CRLF
    + '*/' + @CRLF;

  DECLARE @CurrentDB    NVARCHAR(128) = '';
  DECLARE @CurrentTable NVARCHAR(400) = '';
  DECLARE @IsFirstDB    BIT = 1;

  DECLARE @Id            INT;
  DECLARE @DB            NVARCHAR(128);
  DECLARE @Schema        NVARCHAR(128);
  DECLARE @Table         NVARCHAR(128);
  DECLARE @ColName       NVARCHAR(128);
  DECLARE @Usage         VARCHAR(20);
  DECLARE @QCount        INT;
  DECLARE @TotalExec     BIGINT;
  DECLARE @TotalReads    BIGINT;
  DECLARE @Coverage      VARCHAR(20);
  DECLARE @Action        NVARCHAR(MAX);
  DECLARE @TableKey      NVARCHAR(400);
  DECLARE @TableSummary  NVARCHAR(MAX);
  DECLARE @RecKeys       NVARCHAR(MAX);
  DECLARE @RecIncludes   NVARCHAR(MAX);
  DECLARE @RecCreate     NVARCHAR(MAX);
  DECLARE @RecNearMatch  NVARCHAR(256);
  DECLARE @RecMatchType  VARCHAR(20);
  DECLARE @RecEstGB      DECIMAL(18,2);
  DECLARE @ShouldComment BIT;
  DECLARE @RunnableCount INT = 0;
  DECLARE @ResolveIds    NVARCHAR(MAX);

  DECLARE rec_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT ColumnAccessPatternId, DatabaseName, SchemaName, TableName
          ,ColumnName, UsageType, QueryCount, TotalExecutions, TotalLogicalReads
          ,ExistingIndexCoverage, SuggestedAction
    FROM indexing.ColumnAccessPatternResults
    WHERE ResolvedDate IS NULL
      AND (@DatabaseName IS NULL
              OR (@DatabaseName LIKE '%[%]%' AND DatabaseName LIKE @DatabaseName)
              OR (@DatabaseName NOT LIKE '%[%]%' AND DatabaseName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','))))
      AND (@TableName    IS NULL OR TableName    = @TableName)
      AND (@ShowCovered = 1 OR ExistingIndexCoverage IS NULL OR ExistingIndexCoverage <> 'LEADING_KEY')
      AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName)
    ORDER BY DatabaseName, SchemaName, TableName, TotalLogicalReads DESC;

  OPEN rec_cursor;
  FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table
    ,@ColName, @Usage, @QCount, @TotalExec, @TotalReads
    ,@Coverage, @Action;

  WHILE @@FETCH_STATUS = 0
  BEGIN

    SET @TableKey = @DB + '.' + @Schema + '.' + @Table;
    IF @TableKey <> @CurrentTable
    BEGIN
      SET @CurrentTable = @TableKey;

      SET @RecKeys = NULL;
      SET @RecIncludes = NULL;
      SET @RecCreate = NULL;
      SET @RecEstGB = NULL;
      SET @RecNearMatch = NULL;
      SET @RecMatchType = NULL;

      SELECT @RecKeys      = KeyColumns
            ,@RecIncludes  = IncludeColumns
            ,@RecCreate    = CreateStatement
            ,@RecEstGB     = EstimatedSizeGB
            ,@RecNearMatch = NearMatchIndex
            ,@RecMatchType = NearMatchAction
      FROM #TableRecs
      WHERE DatabaseName = @DB AND SchemaName = @Schema AND TableName = @Table;

      IF @ShowCovered = 0 AND @RecCreate IS NULL
      BEGIN
        FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table
          ,@ColName, @Usage, @QCount, @TotalExec, @TotalReads
          ,@Coverage, @Action;
        CONTINUE;
      END

      IF @DB <> @CurrentDB
      BEGIN
        IF @IsFirstDB = 0
          SET @ScriptText = @ScriptText + @CRLF;

        SET @CurrentDB = @DB;
        SET @IsFirstDB = 0;

        SET @ScriptText = @ScriptText
          + '-- ============================================================================' + @CRLF
          + '-- Database: ' + @DB + @CRLF
          + '-- ============================================================================' + @CRLF
          + 'USE ' + QUOTENAME(@DB) + @CRLF
          + 'GO' + @CRLF;
      END

      SET @TableSummary = NULL;
      SELECT @TableSummary = STRING_AGG(
        '--   ' + ColumnName
        + ' (' + UsageType + ')'
        + ' - ' + CAST(QueryCount AS VARCHAR(10)) + ' queries'
        + ', ' + FORMAT(ISNULL(TotalLogicalReads, 0), 'N0') + ' total reads'
        + CASE WHEN ExistingIndexCoverage IS NOT NULL THEN ' [' + ExistingIndexCoverage + ']' ELSE '' END
      , CHAR(13) + CHAR(10)) WITHIN GROUP (ORDER BY TotalLogicalReads DESC)
      FROM (
        SELECT TOP 10 ColumnName, UsageType, QueryCount, TotalLogicalReads, ExistingIndexCoverage
        FROM indexing.ColumnAccessPatternResults
        WHERE ResolvedDate IS NULL
          AND DatabaseName = @DB AND SchemaName = @Schema AND TableName = @Table
          AND (@ShowCovered = 1 OR ExistingIndexCoverage IS NULL OR ExistingIndexCoverage <> 'LEADING_KEY')
        ORDER BY TotalLogicalReads DESC
      ) top10;

      SET @ScriptText = @ScriptText
        + @CRLF
        + @Separator + @CRLF
        + '-- Table: ' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + @CRLF
        + @Separator + @CRLF;

      IF @TableSummary IS NOT NULL
        SET @ScriptText = @ScriptText
          + @CRLF + '-- Column Access Patterns:' + @CRLF
          + @TableSummary + @CRLF;

      IF @RecCreate IS NOT NULL
      BEGIN
        SET @ScriptText = @ScriptText
          + @CRLF + '-- RECOMMENDED INDEX:' + @CRLF
          + '--   Key Columns: ' + ISNULL(@RecKeys, '?') + @CRLF
          + CASE WHEN @RecIncludes IS NOT NULL
                 THEN '--   Includes:    ' + @RecIncludes + @CRLF
                 ELSE ''
            END;

        IF @RecNearMatch IS NOT NULL
          SET @ScriptText = @ScriptText
            + '--   Near Match:  ' + @RecNearMatch + ' (' + ISNULL(@RecMatchType, '?') + ' - modify existing index)' + @CRLF;

        IF @RecEstGB IS NOT NULL
          SET @ScriptText = @ScriptText
            + '--   Estimated Size: ~' + FORMAT(@RecEstGB * 1024, 'N1') + ' MB' + @CRLF;

        SET @ResolveIds = NULL;
        SELECT @ResolveIds = STRING_AGG(CAST(ColumnAccessPatternId AS VARCHAR(10)), ',')
        FROM indexing.ColumnAccessPatternResults
        WHERE ResolvedDate IS NULL
          AND DatabaseName = @DB AND SchemaName = @Schema AND TableName = @Table;

        SET @ShouldComment = CASE WHEN @ActiveThreshold IS NOT NULL AND ISNULL(@RecEstGB, 0) >= @ActiveThreshold THEN 1 ELSE 0 END;

        SET @ScriptText = @ScriptText
          + '-- EXEC sp_helpIndexUsage ''' + @Schema + '.' + @Table + ''';' + @CRLF;

        IF @ShouldComment = 1
        BEGIN
          SET @ScriptText = @ScriptText
            + @CRLF + '/*' + @CRLF + @RecCreate + @CRLF + '*/' + @CRLF;

          IF @ResolveIds IS NOT NULL
            SET @ScriptText = @ScriptText
              + @CRLF + '/* UPDATE DBA_Utilities.indexing.ColumnAccessPatternResults SET ResolvedDate = GETDATE() WHERE ColumnAccessPatternId IN (' + @ResolveIds + '); */' + @CRLF;
        END
        ELSE
        BEGIN
          SET @RunnableCount = @RunnableCount + 1;
          SET @ScriptText = @ScriptText
            + @CRLF + @RecCreate + @CRLF;

          IF @ResolveIds IS NOT NULL
            SET @ScriptText = @ScriptText
              + @CRLF + 'UPDATE DBA_Utilities.indexing.ColumnAccessPatternResults SET ResolvedDate = GETDATE() WHERE ColumnAccessPatternId IN (' + @ResolveIds + ');' + @CRLF;
        END
      END
      ELSE
      BEGIN
        SET @ScriptText = @ScriptText
          + @CRLF + '-- EXEC sp_helpIndexUsage ''' + @Schema + '.' + @Table + ''';' + @CRLF;
      END;
    END;

    FETCH NEXT FROM rec_cursor INTO @Id, @DB, @Schema, @Table
      ,@ColName, @Usage, @QCount, @TotalExec, @TotalReads
      ,@Coverage, @Action;
  END;

  CLOSE rec_cursor;
  DEALLOCATE rec_cursor;

  DECLARE @TotalUnfiltered INT;
  SELECT @TotalUnfiltered = COUNT(*)
  FROM indexing.ColumnAccessPatternResults
  WHERE ResolvedDate IS NULL
    AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName);

  SELECT @@SERVERNAME                                AS ServerName
        ,ISNULL(@DatabaseName, 'ALL')                AS DatabaseName
        ,GETDATE()                                   AS GeneratedDate
        ,CAST(@TotalTables AS VARCHAR(10)) + ' recommendations, '
         + CAST(@TotalPatterns AS VARCHAR(10)) + ' column patterns'
                                                     AS [Statistics]
        ,CASE WHEN @TotalTables > 0
              THEN 'Has Recommendations'
              ELSE 'No Recommendations'
         END                                         AS [Status]
        ,CASE WHEN @TotalTables > 0
              THEN @ScriptText
              ELSE NULL
         END                                         AS ScriptText;

  DROP TABLE IF EXISTS #TableRecs;
  DROP TABLE IF EXISTS #DBs2;
END;
GO


-- ==========================================================================
-- SCHEMA MIGRATIONS
-- ==========================================================================

IF COL_LENGTH('indexing.IndexOptimizationResults', 'EstimatedSizeGB') IS NULL
    ALTER TABLE indexing.IndexOptimizationResults ADD EstimatedSizeGB DECIMAL(18,2) NULL;
GO
IF COL_LENGTH('indexing.KeyLookupResults', 'EstimatedSizeGB') IS NULL
    ALTER TABLE indexing.KeyLookupResults ADD EstimatedSizeGB DECIMAL(18,2) NULL;
GO
IF COL_LENGTH('indexing.ExpensiveQueryResults', 'EstimatedSizeGB') IS NULL
    ALTER TABLE indexing.ExpensiveQueryResults ADD EstimatedSizeGB DECIMAL(18,2) NULL;
GO


-- ==========================================================================
-- SUITE: ORCHESTRATOR + SUMMARY + SHARED UTILITY
-- ==========================================================================

-- ==========================================================================
-- Shared Utility: indexing.sp_BuildIndexScript
-- ==========================================================================

CREATE OR ALTER PROCEDURE indexing.sp_BuildIndexScript
    @DatabaseName      NVARCHAR(128),
    @SchemaName        NVARCHAR(128),
    @TableName         NVARCHAR(128),
    @KeyColumns        NVARCHAR(MAX),
    @IncludeColumns    NVARCHAR(MAX) = NULL,
    @Strategy          VARCHAR(20)    OUTPUT,
    @Script            NVARCHAR(MAX)  OUTPUT,
    @Recommendation    NVARCHAR(MAX)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CRLF CHAR(2) = CHAR(13) + CHAR(10);
    DECLARE @SchemaTable NVARCHAR(500) = QUOTENAME(@SchemaName) + '.' + QUOTENAME(@TableName);

    DECLARE @NormKeys NVARCHAR(MAX) = LTRIM(RTRIM(
        REPLACE(REPLACE(REPLACE(REPLACE(@KeyColumns, '[', ''), ']', ''), ' DESC', ''), ' ASC', '')));
    DECLARE @NormIncludes NVARCHAR(MAX) = CASE WHEN @IncludeColumns IS NOT NULL
        THEN LTRIM(RTRIM(REPLACE(REPLACE(@IncludeColumns, '[', ''), ']', '')))
        ELSE NULL END;

    SET @Strategy = 'CREATE';
    SET @Script = NULL;
    SET @Recommendation = NULL;

    ---------------------------------------------------------------------------
    -- Load existing indexes on target table
    ---------------------------------------------------------------------------
    CREATE TABLE #ExIdx (
        IndexName       NVARCHAR(256),
        IsDisabled      BIT,
        IsPrimaryKey    BIT,
        IsUnique        BIT,
        HasFilter       BIT,
        FilterDef       NVARCHAR(MAX),
        KeyColumns      NVARCHAR(MAX),
        IncludeColumns  NVARCHAR(MAX),
        [FillFactor]    INT
    );

    DECLARE @SQL NVARCHAR(MAX) = N'USE ' + QUOTENAME(@DatabaseName) + N';

    ;WITH KeyCols AS (
        SELECT ic.object_id, ic.index_id,
               STUFF((SELECT '', ['' + c2.name + '']''
                      FROM sys.index_columns ic2
                      JOIN sys.columns c2 ON ic2.object_id = c2.object_id AND ic2.column_id = c2.column_id
                      WHERE ic2.object_id = ic.object_id AND ic2.index_id = ic.index_id
                        AND ic2.is_included_column = 0
                      ORDER BY ic2.key_ordinal
                      FOR XML PATH('''')), 1, 2, '''') AS KeyColumns
        FROM sys.index_columns ic
        GROUP BY ic.object_id, ic.index_id
    ),
    IncCols AS (
        SELECT ic.object_id, ic.index_id,
               STUFF((SELECT '', ['' + c2.name + '']''
                      FROM sys.index_columns ic2
                      JOIN sys.columns c2 ON ic2.object_id = c2.object_id AND ic2.column_id = c2.column_id
                      WHERE ic2.object_id = ic.object_id AND ic2.index_id = ic.index_id
                        AND ic2.is_included_column = 1
                      ORDER BY c2.name
                      FOR XML PATH('''')), 1, 2, '''') AS IncludeColumns
        FROM sys.index_columns ic
        GROUP BY ic.object_id, ic.index_id
    )
    INSERT INTO #ExIdx (IndexName, IsDisabled, IsPrimaryKey, IsUnique, HasFilter, FilterDef, KeyColumns, IncludeColumns, [FillFactor])
    SELECT i.name, i.is_disabled, i.is_primary_key, i.is_unique,
           CASE WHEN i.filter_definition IS NOT NULL THEN 1 ELSE 0 END,
           i.filter_definition,
           kc.KeyColumns, ic.IncludeColumns, i.fill_factor
    FROM sys.indexes i
    JOIN sys.objects o ON i.object_id = o.object_id
    JOIN sys.schemas s ON o.schema_id = s.schema_id
    LEFT JOIN KeyCols kc ON i.object_id = kc.object_id AND i.index_id = kc.index_id
    LEFT JOIN IncCols ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    WHERE i.type IN (1, 2)
      AND o.is_ms_shipped = 0
      AND i.name IS NOT NULL
      AND s.name = @pSchema
      AND o.name = @pTable;
    ';

    BEGIN TRY
        EXEC sp_executesql @SQL,
            N'@pSchema NVARCHAR(128), @pTable NVARCHAR(128)',
            @pSchema = @SchemaName, @pTable = @TableName;
    END TRY
    BEGIN CATCH
        SET @Recommendation = 'Could not load existing indexes: ' + ERROR_MESSAGE();
    END CATCH

    ---------------------------------------------------------------------------
    -- Validate recommended columns exist on the target table
    ---------------------------------------------------------------------------
    CREATE TABLE #TableCols (ColName NVARCHAR(128));

    DECLARE @ColSQL NVARCHAR(MAX) = N'USE ' + QUOTENAME(@DatabaseName) + N';
    INSERT INTO #TableCols (ColName)
    SELECT c.name
    FROM sys.columns c
    JOIN sys.objects o ON c.object_id = o.object_id
    JOIN sys.schemas s ON o.schema_id = s.schema_id
    WHERE s.name = @pSchema AND o.name = @pTable;
    ';

    BEGIN TRY
        EXEC sp_executesql @ColSQL,
            N'@pSchema NVARCHAR(128), @pTable NVARCHAR(128)',
            @pSchema = @SchemaName, @pTable = @TableName;
    END TRY
    BEGIN CATCH
    END CATCH

    DECLARE @InvalidCols NVARCHAR(MAX);

    SELECT @InvalidCols = STUFF((
        SELECT ', ' + LTRIM(RTRIM(k.value))
        FROM STRING_SPLIT(REPLACE(REPLACE(@KeyColumns, '[', ''), ']', ''), ',') k
        WHERE LTRIM(RTRIM(k.value)) <> ''
          AND LTRIM(RTRIM(k.value)) NOT IN (SELECT ColName FROM #TableCols)
        FOR XML PATH('')
    ), 1, 2, '');

    IF @InvalidCols IS NULL AND @IncludeColumns IS NOT NULL
    BEGIN
        SELECT @InvalidCols = STUFF((
            SELECT ', ' + LTRIM(RTRIM(k.value))
            FROM STRING_SPLIT(REPLACE(REPLACE(@IncludeColumns, '[', ''), ']', ''), ',') k
            WHERE LTRIM(RTRIM(k.value)) <> ''
              AND LTRIM(RTRIM(k.value)) NOT IN (SELECT ColName FROM #TableCols)
            FOR XML PATH('')
        ), 1, 2, '');
    END

    IF @InvalidCols IS NOT NULL
    BEGIN
        SET @Strategy = 'INVALID_COLUMNS';
        SET @Script = NULL;
        SET @Recommendation = 'SKIPPED - columns not found on ' + @SchemaTable + ': ' + @InvalidCols;
        RETURN;
    END

    ---------------------------------------------------------------------------
    -- Normalize existing index keys for comparison
    ---------------------------------------------------------------------------
    ALTER TABLE #ExIdx ADD NormKeys NVARCHAR(MAX);

    UPDATE #ExIdx
    SET NormKeys = LTRIM(RTRIM(
        REPLACE(REPLACE(REPLACE(REPLACE(KeyColumns, '[', ''), ']', ''), ' DESC', ''), ' ASC', '')));

    ---------------------------------------------------------------------------
    -- Helper table for include column merging
    ---------------------------------------------------------------------------
    DECLARE @MergeCols TABLE (ColName NVARCHAR(128));

    ---------------------------------------------------------------------------
    -- Variables for matching
    ---------------------------------------------------------------------------
    DECLARE @ExName NVARCHAR(256);
    DECLARE @ExKeys NVARCHAR(MAX);
    DECLARE @ExIncludes NVARCHAR(MAX);
    DECLARE @ExFillFactor INT;
    DECLARE @AllCovered BIT;
    DECLARE @MergedIncludes NVARCHAR(MAX);
    DECLARE @IndexName NVARCHAR(500);

    ---------------------------------------------------------------------------
    -- Check 1: REBUILD - disabled index with exact key match
    ---------------------------------------------------------------------------
    SELECT TOP 1 @ExName = IndexName, @ExKeys = KeyColumns, @ExIncludes = IncludeColumns
    FROM #ExIdx
    WHERE IsDisabled = 1 AND NormKeys = @NormKeys;

    IF @ExName IS NOT NULL
    BEGIN
        SET @Strategy = 'REBUILD';
        SET @Script = 'ALTER INDEX ' + QUOTENAME(@ExName) + ' ON ' + @SchemaTable + ' REBUILD;';
        SET @Recommendation = 'Rebuild disabled index ' + QUOTENAME(@ExName);
        RETURN;
    END

    ---------------------------------------------------------------------------
    -- Check 2: Exact key match (enabled)
    ---------------------------------------------------------------------------
    SET @ExName = NULL;
    SELECT TOP 1
        @ExName = IndexName, @ExKeys = KeyColumns,
        @ExIncludes = IncludeColumns, @ExFillFactor = [FillFactor]
    FROM #ExIdx
    WHERE IsDisabled = 0 AND IsPrimaryKey = 0 AND NormKeys = @NormKeys;

    IF @ExName IS NOT NULL
    BEGIN
        SET @AllCovered = 1;
        IF @NormIncludes IS NOT NULL
        BEGIN
            DECLARE @Super1 NVARCHAR(MAX) = REPLACE(REPLACE(
                ISNULL(@ExKeys, '') + CASE WHEN @ExIncludes IS NOT NULL THEN ', ' + @ExIncludes ELSE '' END,
                '[', ''), ']', '');
            SET @Super1 = REPLACE(REPLACE(@Super1, ' DESC', ''), ' ASC', '');

            IF EXISTS (
                SELECT 1 FROM STRING_SPLIT(@NormIncludes, ',') sub
                WHERE LTRIM(RTRIM(sub.value)) <> ''
                  AND LTRIM(RTRIM(sub.value)) NOT IN (
                      SELECT LTRIM(RTRIM(sup.value)) FROM STRING_SPLIT(@Super1, ',') sup
                      WHERE LTRIM(RTRIM(sup.value)) <> ''
                  )
            )
                SET @AllCovered = 0;
        END

        IF @AllCovered = 1
        BEGIN
            SET @Strategy = 'SUPERSET_COVERED';
            SET @Recommendation = 'Already covered by existing index ' + QUOTENAME(@ExName);
            RETURN;
        END

        SET @Strategy = 'EXTEND';
        GOTO BuildExtend;
    END

    ---------------------------------------------------------------------------
    -- Check 3: Recommendation keys are prefix of existing index keys
    ---------------------------------------------------------------------------
    SET @ExName = NULL;
    SELECT TOP 1
        @ExName = IndexName, @ExKeys = KeyColumns,
        @ExIncludes = IncludeColumns, @ExFillFactor = [FillFactor]
    FROM #ExIdx
    WHERE IsDisabled = 0
      AND NormKeys LIKE @NormKeys + ', %';

    IF @ExName IS NOT NULL
    BEGIN
        SET @AllCovered = 1;
        IF @NormIncludes IS NOT NULL
        BEGIN
            DECLARE @Super2 NVARCHAR(MAX) = REPLACE(REPLACE(
                ISNULL(@ExKeys, '') + CASE WHEN @ExIncludes IS NOT NULL THEN ', ' + @ExIncludes ELSE '' END,
                '[', ''), ']', '');
            SET @Super2 = REPLACE(REPLACE(@Super2, ' DESC', ''), ' ASC', '');

            IF EXISTS (
                SELECT 1 FROM STRING_SPLIT(@NormIncludes, ',') sub
                WHERE LTRIM(RTRIM(sub.value)) <> ''
                  AND LTRIM(RTRIM(sub.value)) NOT IN (
                      SELECT LTRIM(RTRIM(sup.value)) FROM STRING_SPLIT(@Super2, ',') sup
                      WHERE LTRIM(RTRIM(sup.value)) <> ''
                  )
            )
                SET @AllCovered = 0;
        END

        IF @AllCovered = 1
        BEGIN
            SET @Strategy = 'SUPERSET_COVERED';
            SET @Recommendation = 'Already covered by existing index ' + QUOTENAME(@ExName)
                + ' (keys: ' + @ExKeys + ')';
            RETURN;
        END

        SET @Strategy = 'EXTEND';
        GOTO BuildExtend;
    END

    ---------------------------------------------------------------------------
    -- Check 4: Existing keys are prefix of recommendation keys
    ---------------------------------------------------------------------------
    SET @ExName = NULL;
    SELECT TOP 1
        @ExName = IndexName, @ExKeys = KeyColumns,
        @ExIncludes = IncludeColumns, @ExFillFactor = [FillFactor]
    FROM #ExIdx
    WHERE IsDisabled = 0 AND IsPrimaryKey = 0 AND IsUnique = 0
      AND @NormKeys LIKE NormKeys + ', %';

    IF @ExName IS NOT NULL
    BEGIN
        SET @Strategy = 'EXTEND';
        GOTO BuildExtend;
    END

    ---------------------------------------------------------------------------
    -- Default: CREATE
    ---------------------------------------------------------------------------
    GOTO BuildCreate;

    ---------------------------------------------------------------------------
    -- BUILD EXTEND: DROP old + CREATE new with merged includes
    ---------------------------------------------------------------------------
    BuildExtend:

    -- Determine the broader key set for the new index BEFORE merging includes
    -- Check 2 (exact match) and Check 3 (rec is prefix of existing): use @ExKeys to preserve existing keys
    -- Check 4 (existing is prefix of rec): use @KeyColumns since it's broader
    DECLARE @NormExKeys NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(REPLACE(@ExKeys, '[', ''), ']', ''), ' DESC', ''), ' ASC', '');
    DECLARE @ExtendKeys NVARCHAR(MAX) = CASE
        WHEN @NormKeys LIKE @NormExKeys + ', %' THEN @KeyColumns
        ELSE @ExKeys
    END;
    DECLARE @NormExtendKeys NVARCHAR(MAX) = REPLACE(REPLACE(REPLACE(REPLACE(@ExtendKeys, '[', ''), ']', ''), ' DESC', ''), ' ASC', '');

    DELETE FROM @MergeCols;

    IF @ExIncludes IS NOT NULL
        INSERT INTO @MergeCols (ColName)
        SELECT DISTINCT LTRIM(RTRIM(REPLACE(REPLACE(value, '[', ''), ']', '')))
        FROM STRING_SPLIT(@ExIncludes, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    -- Exclude columns already in the extended key set from includes
    DELETE FROM @MergeCols
    WHERE ColName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@NormExtendKeys, ',') WHERE LTRIM(RTRIM(value)) <> '');

    IF @NormIncludes IS NOT NULL
        INSERT INTO @MergeCols (ColName)
        SELECT DISTINCT LTRIM(RTRIM(sub.value))
        FROM STRING_SPLIT(@NormIncludes, ',') sub
        WHERE LTRIM(RTRIM(sub.value)) <> ''
          AND LTRIM(RTRIM(sub.value)) NOT IN (SELECT ColName FROM @MergeCols)
          AND LTRIM(RTRIM(sub.value)) NOT IN (
              SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@NormExtendKeys, ',')
              WHERE LTRIM(RTRIM(value)) <> ''
          );

    SET @MergedIncludes = STUFF((
        SELECT ', ' + QUOTENAME(ColName)
        FROM @MergeCols
        ORDER BY ColName
        FOR XML PATH('')
    ), 1, 2, '');
    SET @IndexName = 'IX_' + @TableName + '_' + REPLACE(@NormExtendKeys, ', ', '_');
    IF @MergedIncludes IS NOT NULL
        SET @IndexName = @IndexName + '_INCLUDES';

    SET @Script = '-- EXTENDING existing index ' + QUOTENAME(@ExName) + @CRLF
        + '-- Existing keys: ' + ISNULL(@ExKeys, '(none)') + @CRLF
        + '-- Existing includes: ' + ISNULL(@ExIncludes, '(none)') + @CRLF
        + @CRLF
        + 'DROP INDEX IF EXISTS ' + QUOTENAME(@ExName) + ' ON ' + @SchemaTable + ';' + @CRLF
        + @CRLF
        + 'CREATE NONCLUSTERED INDEX ' + QUOTENAME(@IndexName) + @CRLF
        + 'ON ' + @SchemaTable + ' (' + @ExtendKeys + ')';

    IF @MergedIncludes IS NOT NULL
        SET @Script = @Script + @CRLF + 'INCLUDE (' + @MergedIncludes + ')';

    SET @Script = @Script + ';';

    SET @Recommendation = 'Extend ' + QUOTENAME(@ExName) + ' with additional includes';
    RETURN;

    ---------------------------------------------------------------------------
    -- BUILD CREATE: new index
    ---------------------------------------------------------------------------
    BuildCreate:

    SET @IndexName = 'IX_' + @TableName + '_' + REPLACE(@NormKeys, ', ', '_');
    IF @IncludeColumns IS NOT NULL
        SET @IndexName = @IndexName + '_INCLUDES';

    SET @Script = 'CREATE NONCLUSTERED INDEX ' + QUOTENAME(@IndexName) + @CRLF
        + 'ON ' + @SchemaTable + ' (' + @KeyColumns + ')';

    IF @IncludeColumns IS NOT NULL
        SET @Script = @Script + @CRLF + 'INCLUDE (' + @IncludeColumns + ')';

    SET @Script = @Script + ';';

    SET @Strategy = 'CREATE';
    SET @Recommendation = 'Create new index on ' + @SchemaTable;
    RETURN;

END
GO

-- ==========================================================================
-- Fleet Summary: indexing.sp_IndexingSuiteSummary
-- ==========================================================================

CREATE OR ALTER PROCEDURE indexing.sp_IndexingSuiteSummary
    @Days INT = 30,
    @DatabaseName NVARCHAR(128) = NULL,
    @Detail BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Since DATETIME2(3) = DATEADD(DAY, -@Days, SYSDATETIME());

    RAISERROR('============================================================', 10, 1) WITH NOWAIT;
    DECLARE @Msg NVARCHAR(200) = 'INDEXING SUITE SUMMARY - Last ' + CAST(@Days AS VARCHAR(10)) + ' Days';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = 'Server: ' + @@SERVERNAME + '  |  Since: ' + CONVERT(VARCHAR(10), @Since, 120);
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    IF @DatabaseName IS NOT NULL
    BEGIN
        SET @Msg = 'Database: ' + @DatabaseName;
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END
    IF @Detail = 1
    BEGIN
        SET @Msg = 'Mode: DETAIL';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END
    RAISERROR('============================================================', 10, 1) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- Collect metrics into a unified temp table
    ---------------------------------------------------------------------------
    CREATE TABLE #Summary (
        SortOrder       INT,
        Tool            VARCHAR(40),
        Resolved        INT,
        Pending         INT,
        Databases       INT,
        Tables          INT,
        Indexes         INT,
        SizeSavedMB     DECIMAL(12,1),
        ReadsImpacted   BIGINT,
        WritesEliminated BIGINT,
        ExecutionsAffected BIGINT,
        CPUTimeSavedMs  BIGINT,
        DurationSec     INT,
        Runs            INT,
        Detail          NVARCHAR(500)
    );

    ---------------------------------------------------------------------------
    -- 1. Duplicate Index Detection
    ---------------------------------------------------------------------------
    IF OBJECT_ID('indexing.IndexOptimizationResults', 'U') IS NOT NULL
    BEGIN
        INSERT INTO #Summary (SortOrder, Tool, Resolved, Pending, Databases, Tables, Indexes, SizeSavedMB, WritesEliminated, Detail)
        SELECT
            1,
            'Duplicate Index',
            SUM(CASE WHEN ResolvedDate >= @Since THEN 1 ELSE 0 END),
            SUM(CASE WHEN ResolvedDate IS NULL THEN 1 ELSE 0 END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName + '.' + SchemaName + '.' + TableName END),
            SUM(CASE WHEN ResolvedDate >= @Since THEN 1 ELSE 0 END),
            CAST(SUM(CASE WHEN ResolvedDate >= @Since AND ActionType IN ('DUPLICATE', 'REDUNDANT', 'DUPLICATE of PK')
                          THEN ISNULL(Index1SizeKB, 0) / 1024.0
                          WHEN ResolvedDate >= @Since AND ActionType = 'COMBINE'
                          THEN (ISNULL(Index1SizeKB, 0) + ISNULL(Index2SizeKB, 0)) / 1024.0
                          ELSE 0 END) AS DECIMAL(12,1)),
            SUM(CASE WHEN ResolvedDate >= @Since
                     THEN ISNULL(Index1UserScans, 0) + ISNULL(Index1UserSeeks, 0)
                          + CASE WHEN ActionType = 'COMBINE' THEN ISNULL(Index2UserScans, 0) + ISNULL(Index2UserSeeks, 0) ELSE 0 END
                     ELSE 0 END),
            CAST(SUM(CASE WHEN ResolvedDate >= @Since AND ActionType = 'DUPLICATE' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' duplicate, '
            + CAST(SUM(CASE WHEN ResolvedDate >= @Since AND ActionType = 'REDUNDANT' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' redundant, '
            + CAST(SUM(CASE WHEN ResolvedDate >= @Since AND ActionType = 'DUPLICATE of PK' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' PK dup, '
            + CAST(SUM(CASE WHEN ResolvedDate >= @Since AND ActionType = 'COMBINE' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' combine'
        FROM indexing.IndexOptimizationResults
        WHERE (@DatabaseName IS NULL OR DatabaseName = @DatabaseName);
    END

    ---------------------------------------------------------------------------
    -- 2. Key Lookup Elimination
    ---------------------------------------------------------------------------
    IF OBJECT_ID('indexing.KeyLookupResults', 'U') IS NOT NULL
    BEGIN
        INSERT INTO #Summary (SortOrder, Tool, Resolved, Pending, Databases, Tables, Indexes, ReadsImpacted, ExecutionsAffected, Detail)
        SELECT
            2,
            'Key Lookup Elimination',
            SUM(CASE WHEN ResolvedDate >= @Since THEN 1 ELSE 0 END),
            SUM(CASE WHEN ResolvedDate IS NULL THEN 1 ELSE 0 END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName + '.' + SchemaName + '.' + TableName END),
            SUM(CASE WHEN ResolvedDate >= @Since THEN 1 ELSE 0 END),
            SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(TotalLogicalReads, 0) ELSE 0 END),
            SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(TotalExecutions, 0) ELSE 0 END),
            CAST(SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(PlanCount, 0) ELSE 0 END) AS VARCHAR(10)) + ' plans across '
            + CAST(COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN NCIndexName END) AS VARCHAR(10)) + ' indexes'
        FROM indexing.KeyLookupResults
        WHERE (@DatabaseName IS NULL OR DatabaseName = @DatabaseName);
    END

    ---------------------------------------------------------------------------
    -- 3. Unused Index Detection
    ---------------------------------------------------------------------------
    IF OBJECT_ID('indexing.UnusedIndexResults', 'U') IS NOT NULL
    BEGIN
        INSERT INTO #Summary (SortOrder, Tool, Resolved, Pending, Databases, Tables, Indexes, SizeSavedMB, WritesEliminated, Detail)
        SELECT
            3,
            'Unused Index Detection',
            SUM(CASE WHEN ResolvedDate >= @Since THEN 1 ELSE 0 END),
            SUM(CASE WHEN ResolvedDate IS NULL THEN 1 ELSE 0 END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName + '.' + SchemaName + '.' + TableName END),
            SUM(CASE WHEN ResolvedDate >= @Since THEN 1 ELSE 0 END),
            CAST(SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(IndexSizeKB, 0) / 1024.0 ELSE 0 END) AS DECIMAL(12,1)),
            SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(UserUpdates, 0) ELSE 0 END),
            'Confidence: '
            + CAST(SUM(CASE WHEN ResolvedDate >= @Since AND Confidence = 'HIGH' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' high, '
            + CAST(SUM(CASE WHEN ResolvedDate >= @Since AND Confidence = 'MEDIUM' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' medium, '
            + CAST(SUM(CASE WHEN ResolvedDate >= @Since AND Confidence = 'LOW' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' low'
        FROM indexing.UnusedIndexResults
        WHERE (@DatabaseName IS NULL OR DatabaseName = @DatabaseName);
    END

    ---------------------------------------------------------------------------
    -- 4. Expensive Query Plan Analysis
    ---------------------------------------------------------------------------
    IF OBJECT_ID('indexing.ExpensiveQueryResults', 'U') IS NOT NULL
    BEGIN
        INSERT INTO #Summary (SortOrder, Tool, Resolved, Pending, Databases, Tables, Indexes, ReadsImpacted, ExecutionsAffected, CPUTimeSavedMs, Detail)
        SELECT
            4,
            'Expensive Query Analysis',
            SUM(CASE WHEN ResolvedDate >= @Since THEN 1 ELSE 0 END),
            SUM(CASE WHEN ResolvedDate IS NULL THEN 1 ELSE 0 END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName + '.' + SchemaName + '.' + TableName END),
            NULL,
            SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(TotalLogicalReads, 0) ELSE 0 END),
            SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(TotalExecutions, 0) ELSE 0 END),
            SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(TotalCPUTimeMs, 0) ELSE 0 END),
            CAST(SUM(CASE WHEN ResolvedDate >= @Since AND FindingType = 'TABLE_SCAN' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' scans, '
            + CAST(SUM(CASE WHEN ResolvedDate >= @Since AND FindingType = 'MISSING_INDEX' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' missing idx, '
            + CAST(SUM(CASE WHEN ResolvedDate >= @Since AND FindingType = 'REGRESSED_QUERY' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' regressed'
        FROM indexing.ExpensiveQueryResults
        WHERE (@DatabaseName IS NULL OR DatabaseName = @DatabaseName);
    END

    ---------------------------------------------------------------------------
    -- 5. Column Access Pattern Analysis
    ---------------------------------------------------------------------------
    IF OBJECT_ID('indexing.ColumnAccessPatternResults', 'U') IS NOT NULL
    BEGIN
        INSERT INTO #Summary (SortOrder, Tool, Resolved, Pending, Databases, Tables, ReadsImpacted, ExecutionsAffected, Detail)
        SELECT
            5,
            'Column Access Patterns',
            SUM(CASE WHEN ResolvedDate >= @Since THEN 1 ELSE 0 END),
            SUM(CASE WHEN ResolvedDate IS NULL THEN 1 ELSE 0 END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName END),
            COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN DatabaseName + '.' + SchemaName + '.' + TableName END),
            SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(TotalLogicalReads, 0) ELSE 0 END),
            SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(TotalExecutions, 0) ELSE 0 END),
            CAST(COUNT(DISTINCT CASE WHEN ResolvedDate >= @Since THEN ColumnName END) AS VARCHAR(10)) + ' columns across '
            + CAST(SUM(CASE WHEN ResolvedDate >= @Since THEN ISNULL(QueryCount, 0) ELSE 0 END) AS VARCHAR(10)) + ' query refs'
        FROM indexing.ColumnAccessPatternResults
        WHERE (@DatabaseName IS NULL OR DatabaseName = @DatabaseName);
    END

    ---------------------------------------------------------------------------
    -- 6. Missing Index Recommendations (optimize-index)
    ---------------------------------------------------------------------------
    IF OBJECT_ID('indexing.GeneratedScripts', 'U') IS NOT NULL
    BEGIN
        INSERT INTO #Summary (SortOrder, Tool, Resolved, Pending, Databases, Detail)
        SELECT
            6,
            'Missing Index (optimize-index)',
            SUM(CASE WHEN Status LIKE 'Has Recommendations%' THEN 1 ELSE 0 END),
            SUM(CASE WHEN Status = 'Nothing To Run Under Parameter' THEN 1 ELSE 0 END),
            COUNT(DISTINCT DatabaseName),
            CAST(SUM(CASE WHEN Status LIKE 'Has Recommendations%' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' DBs with recommendations, '
            + CAST(SUM(CASE WHEN Status = 'Nothing To Run Under Parameter' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' exceed size threshold, '
            + CAST(SUM(CASE WHEN Status = 'No Recommendations' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' clean'
            + CASE WHEN SUM(CASE WHEN Status LIKE '%Enterprise Bypass%' THEN 1 ELSE 0 END) > 0
                   THEN ', ' + CAST(SUM(CASE WHEN Status LIKE '%Enterprise Bypass%' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' enterprise bypass'
                   ELSE '' END
        FROM indexing.GeneratedScripts
        WHERE (@DatabaseName IS NULL OR DatabaseName = @DatabaseName);
    END

    ---------------------------------------------------------------------------
    -- 7. Index Maintenance
    ---------------------------------------------------------------------------
    IF OBJECT_ID('indexing.IndexMaintenanceHistory', 'U') IS NOT NULL
    BEGIN
        INSERT INTO #Summary (SortOrder, Tool, Resolved, Databases, Tables, Indexes, SizeSavedMB, DurationSec, Runs, Detail)
        SELECT
            7,
            'Index Maintenance',
            SUM(CASE WHEN Status = 'Success' THEN 1 ELSE 0 END),
            COUNT(DISTINCT CASE WHEN Status = 'Success' THEN DatabaseName END),
            COUNT(DISTINCT CASE WHEN Status = 'Success' THEN DatabaseName + '.' + SchemaName + '.' + TableName END),
            SUM(CASE WHEN Status = 'Success' THEN 1 ELSE 0 END),
            CAST(SUM(CASE WHEN Status = 'Success' THEN ISNULL(SizeMB, 0) ELSE 0 END) AS DECIMAL(12,1)),
            SUM(CASE WHEN Status = 'Success' THEN ISNULL(DurationSeconds, 0) ELSE 0 END),
            COUNT(DISTINCT RunId),
            CAST(SUM(CASE WHEN Action = 'REORGANIZE' AND Status = 'Success' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' reorg ('
            + FORMAT(SUM(CASE WHEN Action = 'REORGANIZE' AND Status = 'Success' THEN ISNULL(SizeMB, 0) ELSE 0 END), 'N0') + ' MB), '
            + CAST(SUM(CASE WHEN Action = 'REBUILD_ONLINE' AND Status = 'Success' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' rebuild online, '
            + CAST(SUM(CASE WHEN Action = 'REBUILD_OFFLINE' AND Status = 'Success' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' rebuild offline ('
            + FORMAT(SUM(CASE WHEN Action LIKE 'REBUILD%' AND Status = 'Success' THEN ISNULL(SizeMB, 0) ELSE 0 END), 'N0') + ' MB)'
            + CASE WHEN SUM(CASE WHEN Status = 'Failed' THEN 1 ELSE 0 END) > 0
                   THEN ', ' + CAST(SUM(CASE WHEN Status = 'Failed' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' failed'
                   ELSE '' END
            + CASE WHEN SUM(CASE WHEN Status = 'TimeLimitReached' THEN 1 ELSE 0 END) > 0
                   THEN ', ' + CAST(SUM(CASE WHEN Status = 'TimeLimitReached' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' time-limited'
                   ELSE '' END
        FROM indexing.IndexMaintenanceHistory
        WHERE CreatedDate >= @Since
          AND Status <> 'DryRun'
          AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName);
    END

    ---------------------------------------------------------------------------
    -- 8. Statistics Update
    ---------------------------------------------------------------------------
    IF OBJECT_ID('dbo.StatisticsUpdate', 'U') IS NOT NULL
    BEGIN
        INSERT INTO #Summary (SortOrder, Tool, Resolved, Databases, Tables, Runs, Detail)
        SELECT
            8,
            'Statistics Update',
            SUM(CASE WHEN Outcome = 'Success' THEN 1 ELSE 0 END),
            COUNT(DISTINCT DatabaseName),
            COUNT(DISTINCT DatabaseName + '.' + SchemaName + '.' + TableName),
            COUNT(DISTINCT Run),
            CAST(SUM(CASE WHEN Outcome = 'Success' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' success, '
            + CAST(SUM(CASE WHEN Outcome = 'Failure' THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' failed across '
            + CAST(COUNT(DISTINCT Run) AS VARCHAR(10)) + ' runs'
            + ', avg staleness ' + CAST(CAST(AVG(CAST(ISNULL(DaysSinceUpdate, 0) AS FLOAT)) AS INT) AS VARCHAR(10)) + ' days'
            + ', ' + FORMAT(SUM(ISNULL(Modifications, 0)), 'N0') + ' total modifications'
        FROM dbo.StatisticsUpdate
        WHERE UpdateDate >= @Since
          AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName);
    END

    ---------------------------------------------------------------------------
    -- Output
    ---------------------------------------------------------------------------
    SELECT
        s.Tool,
        s.Resolved,
        s.Pending,
        s.Databases                                     AS DBs,
        s.Tables                                        AS Tbls,
        s.Indexes                                       AS Idxs,
        s.SizeSavedMB                                   AS SizeMB,
        CASE WHEN s.ReadsImpacted > 0
             THEN FORMAT(s.ReadsImpacted, 'N0')
        END                                             AS ReadsImpacted,
        CASE WHEN s.WritesEliminated > 0
             THEN FORMAT(s.WritesEliminated, 'N0')
        END                                             AS WritesEliminated,
        CASE WHEN s.ExecutionsAffected > 0
             THEN FORMAT(s.ExecutionsAffected, 'N0')
        END                                             AS Executions,
        CASE WHEN s.CPUTimeSavedMs > 0
             THEN FORMAT(s.CPUTimeSavedMs, 'N0')
        END                                             AS CPUTimeMs,
        CASE WHEN s.DurationSec > 0
             THEN CAST(s.DurationSec / 3600 AS VARCHAR(5)) + 'h '
                + CAST((s.DurationSec % 3600) / 60 AS VARCHAR(5)) + 'm '
                + CAST(s.DurationSec % 60 AS VARCHAR(5)) + 's'
        END                                             AS Duration,
        s.Runs,
        s.Detail
    FROM #Summary s
    WHERE ISNULL(s.Resolved, 0) > 0
       OR ISNULL(s.Pending, 0) > 0
       OR ISNULL(s.SizeSavedMB, 0) > 0
       OR ISNULL(s.ReadsImpacted, 0) > 0
       OR ISNULL(s.WritesEliminated, 0) > 0
       OR ISNULL(s.ExecutionsAffected, 0) > 0
       OR ISNULL(s.CPUTimeSavedMs, 0) > 0
       OR ISNULL(s.DurationSec, 0) > 0
       OR ISNULL(s.Runs, 0) > 0
    ORDER BY s.SortOrder;

    ---------------------------------------------------------------------------
    -- Detail result sets (when @Detail = 1)
    ---------------------------------------------------------------------------
    IF @Detail = 1
    BEGIN

        -- 1. Duplicate Index Detail
        IF OBJECT_ID('indexing.IndexOptimizationResults', 'U') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM indexing.IndexOptimizationResults
                        WHERE ResolvedDate >= @Since AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName))
            BEGIN
                RAISERROR('', 10, 1) WITH NOWAIT;
                RAISERROR('--- Duplicate Index Detail ---', 10, 1) WITH NOWAIT;

                SELECT
                    ResolvedDate,
                    DatabaseName,
                    SchemaName + '.' + TableName AS [Object],
                    ActionType,
                    Index1Name,
                    CAST(ISNULL(Index1SizeKB, 0) / 1024.0 AS DECIMAL(10,1)) AS Index1SizeMB,
                    Index2Name,
                    CAST(ISNULL(Index2SizeKB, 0) / 1024.0 AS DECIMAL(10,1)) AS Index2SizeMB
                FROM indexing.IndexOptimizationResults
                WHERE ResolvedDate >= @Since
                  AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName)
                ORDER BY ResolvedDate DESC;
            END
        END

        -- 2. Key Lookup Elimination Detail
        IF OBJECT_ID('indexing.KeyLookupResults', 'U') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM indexing.KeyLookupResults
                        WHERE ResolvedDate >= @Since AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName))
            BEGIN
                RAISERROR('--- Key Lookup Elimination Detail ---', 10, 1) WITH NOWAIT;

                SELECT
                    ResolvedDate,
                    DatabaseName,
                    SchemaName + '.' + TableName AS [Object],
                    NCIndexName,
                    RecommendedIncludes,
                    PlanCount,
                    FORMAT(TotalLogicalReads, 'N0') AS TotalLogicalReads,
                    FORMAT(TotalExecutions, 'N0')   AS TotalExecutions
                FROM indexing.KeyLookupResults
                WHERE ResolvedDate >= @Since
                  AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName)
                ORDER BY ResolvedDate DESC;
            END
        END

        -- 3. Unused Index Detection Detail
        IF OBJECT_ID('indexing.UnusedIndexResults', 'U') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM indexing.UnusedIndexResults
                        WHERE ResolvedDate >= @Since AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName))
            BEGIN
                RAISERROR('--- Unused Index Detail ---', 10, 1) WITH NOWAIT;

                SELECT
                    ResolvedDate,
                    DatabaseName,
                    SchemaName + '.' + TableName AS [Object],
                    IndexName,
                    IndexKeys,
                    CAST(ISNULL(IndexSizeKB, 0) / 1024.0 AS DECIMAL(10,1)) AS SizeMB,
                    Confidence,
                    FORMAT(UserUpdates, 'N0') AS WriteOverhead,
                    DropStatement AS ActionStatement
                FROM indexing.UnusedIndexResults
                WHERE ResolvedDate >= @Since
                  AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName)
                ORDER BY ResolvedDate DESC;
            END
        END

        -- 4. Expensive Query Detail
        IF OBJECT_ID('indexing.ExpensiveQueryResults', 'U') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM indexing.ExpensiveQueryResults
                        WHERE ResolvedDate >= @Since AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName))
            BEGIN
                RAISERROR('--- Expensive Query Detail ---', 10, 1) WITH NOWAIT;

                SELECT
                    ResolvedDate,
                    DatabaseName,
                    SchemaName + '.' + TableName AS [Object],
                    FindingType,
                    IndexName,
                    FORMAT(TotalLogicalReads, 'N0') AS TotalLogicalReads,
                    FORMAT(TotalCPUTimeMs, 'N0')    AS TotalCPUTimeMs,
                    FORMAT(TotalExecutions, 'N0')    AS TotalExecutions
                FROM indexing.ExpensiveQueryResults
                WHERE ResolvedDate >= @Since
                  AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName)
                ORDER BY ResolvedDate DESC;
            END
        END

        -- 5. Column Access Pattern Detail
        IF OBJECT_ID('indexing.ColumnAccessPatternResults', 'U') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM indexing.ColumnAccessPatternResults
                        WHERE ResolvedDate >= @Since AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName))
            BEGIN
                RAISERROR('--- Column Access Pattern Detail ---', 10, 1) WITH NOWAIT;

                SELECT
                    ResolvedDate,
                    DatabaseName,
                    SchemaName + '.' + TableName AS [Object],
                    ColumnName,
                    UsageType,
                    QueryCount,
                    FORMAT(TotalLogicalReads, 'N0') AS TotalLogicalReads,
                    ExistingIndexCoverage,
                    SuggestedAction
                FROM indexing.ColumnAccessPatternResults
                WHERE ResolvedDate >= @Since
                  AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName)
                ORDER BY ResolvedDate DESC;
            END
        END

        -- 6. Index Maintenance Detail
        IF OBJECT_ID('indexing.IndexMaintenanceHistory', 'U') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM indexing.IndexMaintenanceHistory
                        WHERE CreatedDate >= @Since AND Status <> 'DryRun'
                          AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName))
            BEGIN
                RAISERROR('--- Index Maintenance Detail ---', 10, 1) WITH NOWAIT;

                SELECT
                    CreatedDate,
                    DatabaseName,
                    SchemaName + '.' + TableName AS [Object],
                    IndexName,
                    IndexType,
                    Action,
                    FragmentationPct AS [Frag%%],
                    SizeMB,
                    DurationSeconds  AS Seconds,
                    Status,
                    ErrorMessage
                FROM indexing.IndexMaintenanceHistory
                WHERE CreatedDate >= @Since
                  AND Status <> 'DryRun'
                  AND SchemaName <> '-'
                  AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName)
                ORDER BY CreatedDate DESC;
            END
        END

        -- 7. Statistics Update Detail
        IF OBJECT_ID('dbo.StatisticsUpdate', 'U') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.StatisticsUpdate
                        WHERE UpdateDate >= @Since
                          AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName))
            BEGIN
                RAISERROR('--- Statistics Update Detail ---', 10, 1) WITH NOWAIT;

                SELECT
                    UpdateDate,
                    DatabaseName,
                    SchemaName + '.' + TableName AS [Object],
                    StatisticName,
                    DaysSinceUpdate AS StaleDays,
                    FORMAT(Modifications, 'N0') AS Modifications,
                    Outcome
                FROM dbo.StatisticsUpdate
                WHERE UpdateDate >= @Since
                  AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName)
                ORDER BY UpdateDate DESC;
            END
        END

    END -- @Detail = 1

END
GO

-- ==========================================================================
-- Orchestrator: indexing.sp_IndexOptimizationSuite
-- ==========================================================================

CREATE OR ALTER PROCEDURE indexing.sp_IndexOptimizationSuite
    @DatabaseName        NVARCHAR(MAX)  = NULL,
    @RunnableUnder       VARCHAR(20)    = NULL,  -- NULL=all uncommented, '2'=2GB both, '1,5e'=1GB Std/5GB Ent
    @LinkedServer        BIT            = 0,     -- When 1, wraps output in EXEC(...) AT [server] for running from ops

    @RunDuplicateIndex   BIT            = 1,
    @RunKeyLookup        BIT            = 1,
    @RunUnusedIndex      BIT            = 1,
    @RunOptimizeIndex    BIT            = 1,
    @RunExpensiveQuery   BIT            = 1,
    @RunColumnAccess     BIT            = 1,

    @MinExecutions       BIGINT         = 500,
    @MinImpact           DECIMAL(5,2)   = 50.0,
    @TopN                INT            = 500,
    @Confidence          VARCHAR(10)    = 'HIGH',
    @Action              VARCHAR(10)    = 'DISABLE',
    @MinUpdateCount      BIGINT         = 1000,
    @MinObservDays       INT            = 7,
    @CombinedOutput      BIT            = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Msg NVARCHAR(500);
    DECLARE @StartTime DATETIME2(3) = SYSDATETIME();
    DECLARE @StepStart DATETIME2(3);
    DECLARE @StepSec INT;
    DECLARE @TotalTools INT = 0;
    DECLARE @CompletedTools INT = 0;
    DECLARE @IsEnterprise BIT = 0;

    -- Parse @RunnableUnder: NULL=off, '2'=2GB both, '1,5e'=1GB Standard/5GB Enterprise
    DECLARE @ThresholdStd DECIMAL(10,2) = NULL;
    DECLARE @ThresholdEnt DECIMAL(10,2) = NULL;
    DECLARE @ActiveThreshold DECIMAL(10,2) = NULL;

    IF @RunnableUnder IS NOT NULL AND LTRIM(RTRIM(@RunnableUnder)) <> ''
    BEGIN
        IF @RunnableUnder LIKE '%,%e'
        BEGIN
            SET @ThresholdStd = TRY_CAST(LEFT(@RunnableUnder, CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
            SET @ThresholdEnt = TRY_CAST(SUBSTRING(@RunnableUnder, CHARINDEX(',', @RunnableUnder) + 1,
                LEN(@RunnableUnder) - CHARINDEX(',', @RunnableUnder) - 1) AS DECIMAL(10,2));
        END
        ELSE
        BEGIN
            SET @ThresholdStd = TRY_CAST(@RunnableUnder AS DECIMAL(10,2));
            SET @ThresholdEnt = @ThresholdStd;
        END
    END

    IF CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Enterprise%'
        OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(500)) LIKE '%Developer%'
        SET @IsEnterprise = 1;

    SET @ActiveThreshold = CASE WHEN @IsEnterprise = 1 THEN @ThresholdEnt ELSE @ThresholdStd END;

    SELECT @TotalTools = CAST(@RunDuplicateIndex AS INT) + CAST(@RunKeyLookup AS INT) + CAST(@RunUnusedIndex AS INT)
                       + CAST(@RunOptimizeIndex AS INT) + CAST(@RunExpensiveQuery AS INT) + CAST(@RunColumnAccess AS INT);

    ---------------------------------------------------------------------------
    -- Header
    ---------------------------------------------------------------------------
    RAISERROR('============================================================', 10, 1) WITH NOWAIT;
    RAISERROR('INDEX OPTIMIZATION SUITE', 10, 1) WITH NOWAIT;
    SET @Msg = 'Server: ' + @@SERVERNAME;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = 'Database: ' + REPLACE(ISNULL(@DatabaseName, 'ALL'), '%', '%%');
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = 'Tools: ' + CAST(@TotalTools AS VARCHAR(10)) + ' selected';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = 'Started: ' + CONVERT(VARCHAR(30), @StartTime, 120);
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    RAISERROR('============================================================', 10, 1) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- Results collection
    ---------------------------------------------------------------------------
    CREATE TABLE #SuiteResults (
        ToolOrder    INT,
        ToolName     VARCHAR(40),
        ServerName   NVARCHAR(128),
        DatabaseName NVARCHAR(MAX),
        GeneratedDate DATETIME,
        [Statistics]   NVARCHAR(500),
        Status       NVARCHAR(200),
        ScriptText   NVARCHAR(MAX),
        DurationSec  INT
    );

    ---------------------------------------------------------------------------
    -- 1. Duplicate Index Detection
    --    Output: ServerName, DatabaseName, GeneratedDate, LastAnalysisDate,
    --            [Statistics], Status, ScriptText
    ---------------------------------------------------------------------------
    IF @RunDuplicateIndex = 1
    BEGIN
        SET @StepStart = SYSDATETIME();
        SET @CompletedTools = @CompletedTools + 1;
        SET @Msg = '[' + CAST(@CompletedTools AS VARCHAR(2)) + '/' + CAST(@TotalTools AS VARCHAR(2)) + '] Duplicate Index Detection...';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        DROP TABLE IF EXISTS #Step1;
        CREATE TABLE #Step1 (ServerName NVARCHAR(128), DatabaseName NVARCHAR(MAX),
            GeneratedDate DATETIME, LastAnalysisDate DATETIME,
            [Statistics] NVARCHAR(500), Status NVARCHAR(200), ScriptText NVARCHAR(MAX));

        BEGIN TRY
            INSERT INTO #Step1
            EXEC indexing.sp_DuplicateIndexOptimizationRecommendations
                @RunAnalysis   = 1,
                @DatabaseName  = @DatabaseName,
                @RunnableUnder = @RunnableUnder;

            INSERT INTO #SuiteResults (ToolOrder, ToolName, ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText, DurationSec)
            SELECT 1, 'Duplicate Index', ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText,
                   DATEDIFF(SECOND, @StepStart, SYSDATETIME())
            FROM #Step1;
        END TRY
        BEGIN CATCH
            INSERT INTO #SuiteResults (ToolOrder, ToolName, Status, DurationSec)
            VALUES (1, 'Duplicate Index', 'ERROR: ' + ERROR_MESSAGE(), DATEDIFF(SECOND, @StepStart, SYSDATETIME()));
        END CATCH

        DROP TABLE IF EXISTS #Step1;
        SET @StepSec = DATEDIFF(SECOND, @StepStart, SYSDATETIME());
        SET @Msg = '    Done (' + CAST(@StepSec AS VARCHAR(10)) + 's)';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    ---------------------------------------------------------------------------
    -- 2. Key Lookup Elimination
    --    Output: ServerName, DatabaseName, GeneratedDate,
    --            [Statistics], Status, ScriptText
    ---------------------------------------------------------------------------
    ---------------------------------------------------------------------------
    -- 2. Key Lookup Elimination
    --    Analysis proc uses INSERT...EXEC internally, so run analysis
    --    separately then call recommendations with @RunAnalysis = 0.
    ---------------------------------------------------------------------------
    IF @RunKeyLookup = 1
    BEGIN
        SET @StepStart = SYSDATETIME();
        SET @CompletedTools = @CompletedTools + 1;
        SET @Msg = '[' + CAST(@CompletedTools AS VARCHAR(2)) + '/' + CAST(@TotalTools AS VARCHAR(2)) + '] Key Lookup Elimination...';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        DROP TABLE IF EXISTS #Step2;
        CREATE TABLE #Step2 (ServerName NVARCHAR(128), DatabaseName NVARCHAR(MAX),
            GeneratedDate DATETIME,
            [Statistics] NVARCHAR(500), Status NVARCHAR(200), ScriptText NVARCHAR(MAX));

        BEGIN TRY
            EXEC indexing.sp_KeyLookupAnalysis
                @DatabaseName  = @DatabaseName,
                @MinExecutions = @MinExecutions;

            INSERT INTO #Step2
            EXEC indexing.sp_KeyLookupRecommendations
                @RunAnalysis   = 0,
                @DatabaseName  = @DatabaseName,
                @RunnableUnder = @RunnableUnder,
                @MinExecutions = @MinExecutions;

            INSERT INTO #SuiteResults (ToolOrder, ToolName, ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText, DurationSec)
            SELECT 2, 'Key Lookup', ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText,
                   DATEDIFF(SECOND, @StepStart, SYSDATETIME())
            FROM #Step2;
        END TRY
        BEGIN CATCH
            INSERT INTO #SuiteResults (ToolOrder, ToolName, Status, DurationSec)
            VALUES (2, 'Key Lookup', 'ERROR: ' + ERROR_MESSAGE(), DATEDIFF(SECOND, @StepStart, SYSDATETIME()));
        END CATCH

        DROP TABLE IF EXISTS #Step2;
        SET @StepSec = DATEDIFF(SECOND, @StepStart, SYSDATETIME());
        SET @Msg = '    Done (' + CAST(@StepSec AS VARCHAR(10)) + 's)';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    ---------------------------------------------------------------------------
    -- 3. Unused Index Detection
    --    Output: ServerName, DatabaseName, GeneratedDate,
    --            [Statistics], Status, ScriptText
    ---------------------------------------------------------------------------
    IF @RunUnusedIndex = 1
    BEGIN
        SET @StepStart = SYSDATETIME();
        SET @CompletedTools = @CompletedTools + 1;
        SET @Msg = '[' + CAST(@CompletedTools AS VARCHAR(2)) + '/' + CAST(@TotalTools AS VARCHAR(2)) + '] Unused Index Detection...';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        DROP TABLE IF EXISTS #Step3;
        CREATE TABLE #Step3 (ServerName NVARCHAR(128), DatabaseName NVARCHAR(MAX),
            GeneratedDate DATETIME,
            [Statistics] NVARCHAR(500), Status NVARCHAR(200), ScriptText NVARCHAR(MAX));

        BEGIN TRY
            INSERT INTO #Step3
            EXEC indexing.sp_UnusedIndexRecommendations
                @RunAnalysis    = 1,
                @DatabaseName   = @DatabaseName,
                @Action         = @Action,
                @Confidence     = @Confidence,
                @MinUpdateCount = @MinUpdateCount,
                @MinObservDays  = @MinObservDays;

            INSERT INTO #SuiteResults (ToolOrder, ToolName, ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText, DurationSec)
            SELECT 3, 'Unused Index', ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText,
                   DATEDIFF(SECOND, @StepStart, SYSDATETIME())
            FROM #Step3;
        END TRY
        BEGIN CATCH
            INSERT INTO #SuiteResults (ToolOrder, ToolName, Status, DurationSec)
            VALUES (3, 'Unused Index', 'ERROR: ' + ERROR_MESSAGE(), DATEDIFF(SECOND, @StepStart, SYSDATETIME()));
        END CATCH

        DROP TABLE IF EXISTS #Step3;
        SET @StepSec = DATEDIFF(SECOND, @StepStart, SYSDATETIME());
        SET @Msg = '    Done (' + CAST(@StepSec AS VARCHAR(10)) + 's)';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    ---------------------------------------------------------------------------
    -- 4. Missing Index / Optimize-Index
    --    Run analysis sub-procs directly (they use INSERT...EXEC internally).
    --    sp_GenerateOptimizationScript populates MissingIndexResults.
    --    Then call sp_MissingIndexRecommendations with @RunAnalysis = 0
    --    (simple cursor, no INSERT...EXEC nesting).
    ---------------------------------------------------------------------------
    IF @RunOptimizeIndex = 1
    BEGIN
        SET @StepStart = SYSDATETIME();
        SET @CompletedTools = @CompletedTools + 1;
        SET @Msg = '[' + CAST(@CompletedTools AS VARCHAR(2)) + '/' + CAST(@TotalTools AS VARCHAR(2)) + '] Missing Index (optimize-index)...';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        BEGIN TRY
            EXEC indexing.sp_LoadDataFromServer
                @ServerName        = @@SERVERNAME,
                @DatabaseMode      = @DatabaseName,
                @MinIndexAdvantage = 2500.0,
                @MinAvgUserImpact  = 99.0;

            EXEC indexing.sp_AnalyzeIndexStrategies;

            EXEC indexing.sp_GenerateOptimizationScript
                @ServerName    = @@SERVERNAME,
                @DatabaseName  = @DatabaseName,
                @RunnableUnder = @RunnableUnder;

            IF @CombinedOutput = 0
            BEGIN
                DROP TABLE IF EXISTS #Step4;
                CREATE TABLE #Step4 (ServerName NVARCHAR(128), DatabaseName NVARCHAR(MAX),
                    GeneratedDate DATETIME, [Statistics] NVARCHAR(500), Status NVARCHAR(200), ScriptText NVARCHAR(MAX));

                INSERT INTO #Step4
                EXEC indexing.sp_MissingIndexRecommendations
                    @RunAnalysis   = 0,
                    @DatabaseName  = @DatabaseName,
                    @RunnableUnder = @RunnableUnder;

                INSERT INTO #SuiteResults (ToolOrder, ToolName, ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText, DurationSec)
                SELECT 4, 'Missing Index', ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText,
                       DATEDIFF(SECOND, @StepStart, SYSDATETIME())
                FROM #Step4;

                DROP TABLE IF EXISTS #Step4;
            END
            ELSE
            BEGIN
                DECLARE @miResolved INT = 0, @miPending INT = 0;
                SELECT @miResolved = COUNT(CASE WHEN ResolvedDate IS NOT NULL THEN 1 END),
                       @miPending = COUNT(CASE WHEN ResolvedDate IS NULL AND Strategy NOT IN ('SUPERSET_COVERED') THEN 1 END)
                FROM indexing.MissingIndexResults
                WHERE ServerName = @@SERVERNAME;

                INSERT INTO #SuiteResults (ToolOrder, ToolName, ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText, DurationSec)
                VALUES (4, 'Missing Index', @@SERVERNAME, ISNULL(@DatabaseName, 'ALL'), GETDATE(),
                        CAST(@miPending AS VARCHAR(10)) + ' recommendations',
                        CASE WHEN @miPending > 0 THEN 'Has Recommendations' ELSE 'No Recommendations' END,
                        NULL,
                        DATEDIFF(SECOND, @StepStart, SYSDATETIME()));
            END
        END TRY
        BEGIN CATCH
            INSERT INTO #SuiteResults (ToolOrder, ToolName, Status, DurationSec)
            VALUES (4, 'Missing Index', 'ERROR: ' + ERROR_MESSAGE(), DATEDIFF(SECOND, @StepStart, SYSDATETIME()));
        END CATCH

        SET @StepSec = DATEDIFF(SECOND, @StepStart, SYSDATETIME());
        SET @Msg = '    Done (' + CAST(@StepSec AS VARCHAR(10)) + 's)';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    ---------------------------------------------------------------------------
    -- 5. Expensive Query Analysis
    --    Cannot use INSERT...EXEC — sp_CalculateIndexSizeEstimate uses
    --    INSERT...EXEC internally. Call procs directly, read results table.
    ---------------------------------------------------------------------------
    IF @RunExpensiveQuery = 1
    BEGIN
        SET @StepStart = SYSDATETIME();
        SET @CompletedTools = @CompletedTools + 1;
        SET @Msg = '[' + CAST(@CompletedTools AS VARCHAR(2)) + '/' + CAST(@TotalTools AS VARCHAR(2)) + '] Expensive Query Analysis...';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        BEGIN TRY
            EXEC indexing.sp_ExpensiveQueryAnalysis
                @DatabaseName  = @DatabaseName,
                @TopN          = @TopN,
                @MinExecutions = @MinExecutions,
                @MinImpact     = @MinImpact;

            IF @CombinedOutput = 0
            BEGIN
                DROP TABLE IF EXISTS #Step5;
                CREATE TABLE #Step5 (ServerName NVARCHAR(128), DatabaseName NVARCHAR(MAX),
                    GeneratedDate DATETIME, [Statistics] NVARCHAR(500), Status NVARCHAR(200), ScriptText NVARCHAR(MAX));

                INSERT INTO #Step5
                EXEC indexing.sp_ExpensiveQueryRecommendations
                    @RunAnalysis   = 0,
                    @DatabaseName  = @DatabaseName,
                    @TopN          = @TopN,
                    @MinExecutions = @MinExecutions,
                    @MinImpact     = @MinImpact,
                    @RunnableUnder = @RunnableUnder;

                INSERT INTO #SuiteResults (ToolOrder, ToolName, ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText, DurationSec)
                SELECT 5, 'Expensive Query', ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText,
                       DATEDIFF(SECOND, @StepStart, SYSDATETIME())
                FROM #Step5;

                DROP TABLE IF EXISTS #Step5;
            END
            ELSE
            BEGIN
                DECLARE @eqResolved INT = 0, @eqPending INT = 0;
                SELECT @eqResolved = COUNT(CASE WHEN ResolvedDate IS NOT NULL THEN 1 END),
                       @eqPending = COUNT(CASE WHEN ResolvedDate IS NULL THEN 1 END)
                FROM indexing.ExpensiveQueryResults
                WHERE ServerName = @@SERVERNAME;

                INSERT INTO #SuiteResults (ToolOrder, ToolName, ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText, DurationSec)
                VALUES (5, 'Expensive Query', @@SERVERNAME, ISNULL(@DatabaseName, 'ALL'), GETDATE(),
                        CAST(@eqResolved AS VARCHAR(10)) + ' resolved, ' + CAST(@eqPending AS VARCHAR(10)) + ' pending',
                        CASE WHEN @eqPending > 0 THEN 'Has Recommendations' ELSE 'No Recommendations' END,
                        NULL,
                        DATEDIFF(SECOND, @StepStart, SYSDATETIME()));
            END
        END TRY
        BEGIN CATCH
            INSERT INTO #SuiteResults (ToolOrder, ToolName, Status, DurationSec)
            VALUES (5, 'Expensive Query', 'ERROR: ' + ERROR_MESSAGE(), DATEDIFF(SECOND, @StepStart, SYSDATETIME()));
        END CATCH

        SET @StepSec = DATEDIFF(SECOND, @StepStart, SYSDATETIME());
        SET @Msg = '    Done (' + CAST(@StepSec AS VARCHAR(10)) + 's)';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    ---------------------------------------------------------------------------
    -- 6. Column Access Patterns
    --    Output: ServerName, DatabaseName, GeneratedDate,
    --            [Statistics], Status, ScriptText
    ---------------------------------------------------------------------------
    IF @RunColumnAccess = 1
    BEGIN
        SET @StepStart = SYSDATETIME();
        SET @CompletedTools = @CompletedTools + 1;
        SET @Msg = '[' + CAST(@CompletedTools AS VARCHAR(2)) + '/' + CAST(@TotalTools AS VARCHAR(2)) + '] Column Access Patterns...';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        DROP TABLE IF EXISTS #Step6;
        CREATE TABLE #Step6 (ServerName NVARCHAR(128), DatabaseName NVARCHAR(MAX),
            GeneratedDate DATETIME,
            [Statistics] NVARCHAR(500), Status NVARCHAR(200), ScriptText NVARCHAR(MAX));

        BEGIN TRY
            INSERT INTO #Step6
            EXEC indexing.sp_ColumnAccessPatternRecommendations
                @RunAnalysis   = 1,
                @DatabaseName  = @DatabaseName,
                @RunnableUnder = @RunnableUnder,
                @TopN          = @TopN;

            INSERT INTO #SuiteResults (ToolOrder, ToolName, ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText, DurationSec)
            SELECT 6, 'Column Access', ServerName, DatabaseName, GeneratedDate, [Statistics], Status, ScriptText,
                   DATEDIFF(SECOND, @StepStart, SYSDATETIME())
            FROM #Step6;
        END TRY
        BEGIN CATCH
            INSERT INTO #SuiteResults (ToolOrder, ToolName, Status, DurationSec)
            VALUES (6, 'Column Access', 'ERROR: ' + ERROR_MESSAGE(), DATEDIFF(SECOND, @StepStart, SYSDATETIME()));
        END CATCH

        DROP TABLE IF EXISTS #Step6;
        SET @StepSec = DATEDIFF(SECOND, @StepStart, SYSDATETIME());
        SET @Msg = '    Done (' + CAST(@StepSec AS VARCHAR(10)) + 's)';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    ---------------------------------------------------------------------------
    -- Summary
    ---------------------------------------------------------------------------
    DECLARE @TotalSec INT = DATEDIFF(SECOND, @StartTime, SYSDATETIME());

    RAISERROR('', 10, 1) WITH NOWAIT;
    RAISERROR('============================================================', 10, 1) WITH NOWAIT;
    SET @Msg = 'COMPLETE - ' + CAST(@TotalTools AS VARCHAR(2)) + ' tools in '
        + CAST(@TotalSec / 60 AS VARCHAR(5)) + 'm ' + CAST(@TotalSec % 60 AS VARCHAR(5)) + 's';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    RAISERROR('============================================================', 10, 1) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- Output
    ---------------------------------------------------------------------------
    IF @CombinedOutput = 0
    BEGIN
        SELECT
            r.ToolName,
            r.Status,
            r.[Statistics],
            CAST(r.DurationSec AS VARCHAR(10)) + 's' AS Duration,
            r.ScriptText
        FROM #SuiteResults r
        ORDER BY r.ToolOrder;
    END
    ELSE
    BEGIN
        -----------------------------------------------------------------------
        -- Combined output: one script organized by database -> table -> tool
        -----------------------------------------------------------------------
        DECLARE @Out NVARCHAR(MAX) = '';
        DECLARE @CRLF2 CHAR(2) = CHAR(13) + CHAR(10);
        DECLARE @Sep VARCHAR(60) = '/*****************************************************/';

        -- Collect all database+table combinations with unresolved findings
        CREATE TABLE #AllTables (
            DatabaseName NVARCHAR(128),
            SchemaName   NVARCHAR(128),
            TableName    NVARCHAR(128)
        );

        IF @RunDuplicateIndex = 1 AND OBJECT_ID('indexing.IndexOptimizationResults', 'U') IS NOT NULL
            INSERT INTO #AllTables SELECT DISTINCT DatabaseName, SchemaName, TableName
            FROM indexing.IndexOptimizationResults WHERE ResolvedDate IS NULL;

        IF @RunKeyLookup = 1 AND OBJECT_ID('indexing.KeyLookupResults', 'U') IS NOT NULL
            INSERT INTO #AllTables SELECT DISTINCT DatabaseName, SchemaName, TableName
            FROM indexing.KeyLookupResults WHERE ResolvedDate IS NULL;

        IF @RunUnusedIndex = 1 AND OBJECT_ID('indexing.UnusedIndexResults', 'U') IS NOT NULL
            INSERT INTO #AllTables SELECT DISTINCT DatabaseName, SchemaName, TableName
            FROM indexing.UnusedIndexResults WHERE ResolvedDate IS NULL
              AND UserUpdates >= @MinUpdateCount AND ObservationDays >= @MinObservDays
              AND CASE Confidence WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END
                  >= CASE @Confidence WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END;

        IF @RunOptimizeIndex = 1 AND OBJECT_ID('indexing.MissingIndexResults', 'U') IS NOT NULL
            INSERT INTO #AllTables SELECT DISTINCT DatabaseName, SchemaName, TableName
            FROM indexing.MissingIndexResults
            WHERE ResolvedDate IS NULL AND ServerName = @@SERVERNAME
              AND Strategy NOT IN ('SUPERSET_COVERED');

        IF @RunExpensiveQuery = 1 AND OBJECT_ID('indexing.ExpensiveQueryResults', 'U') IS NOT NULL
            INSERT INTO #AllTables SELECT DISTINCT DatabaseName, SchemaName, TableName
            FROM indexing.ExpensiveQueryResults WHERE ResolvedDate IS NULL AND FindingType = 'MISSING_INDEX';

        -- Column Access: build consolidated recommendations first
        DROP TABLE IF EXISTS #CATableRecs;
        CREATE TABLE #CATableRecs (
            DatabaseName NVARCHAR(128), SchemaName NVARCHAR(128), TableName NVARCHAR(128),
            KeyColumns NVARCHAR(MAX), IncludeColumns NVARCHAR(MAX),
            CreateStatement NVARCHAR(MAX), EstimatedSizeGB DECIMAL(18,2),
            NearMatchIndex NVARCHAR(256), NearMatchAction VARCHAR(20));

        IF @RunColumnAccess = 1 AND OBJECT_ID('indexing.ColumnAccessPatternResults', 'U') IS NOT NULL
        BEGIN
            ;WITH ColumnsByTable AS (
                SELECT DatabaseName, SchemaName, TableName, ColumnName, UsageType, QueryCount, TotalLogicalReads
                  ,ROW_NUMBER() OVER (PARTITION BY DatabaseName, SchemaName, TableName
                    ORDER BY CASE UsageType WHEN 'EQUALITY' THEN 1 WHEN 'SEEK_PREDICATE' THEN 2
                      WHEN 'INEQUALITY' THEN 3 WHEN 'SCAN_PREDICATE' THEN 4 ELSE 99 END,
                      QueryCount DESC, TotalLogicalReads DESC) AS key_order
                FROM indexing.ColumnAccessPatternResults
                WHERE ResolvedDate IS NULL
                  AND UsageType IN ('EQUALITY','INEQUALITY','SEEK_PREDICATE','SCAN_PREDICATE')
                  AND (ExistingIndexCoverage IS NULL OR ExistingIndexCoverage <> 'LEADING_KEY')
                  AND DatabaseName IN (SELECT DatabaseName FROM #AllTables UNION SELECT DatabaseName FROM indexing.ColumnAccessPatternResults WHERE ResolvedDate IS NULL)
                  AND EXISTS (SELECT 1 FROM sys.databases WHERE name = DatabaseName)
            )
            INSERT INTO #CATableRecs (DatabaseName, SchemaName, TableName, KeyColumns, IncludeColumns)
            SELECT c.DatabaseName, c.SchemaName, c.TableName
              ,STUFF((SELECT ', [' + c2.ColumnName + ']' FROM ColumnsByTable c2
                WHERE c2.DatabaseName = c.DatabaseName AND c2.SchemaName = c.SchemaName AND c2.TableName = c.TableName
                ORDER BY c2.key_order FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
              ,STUFF((SELECT ', [' + i2.ColumnName + ']' FROM indexing.ColumnAccessPatternResults i2
                WHERE i2.DatabaseName = c.DatabaseName AND i2.SchemaName = c.SchemaName AND i2.TableName = c.TableName
                  AND i2.ResolvedDate IS NULL AND i2.UsageType = 'INCLUDE'
                  AND (i2.ExistingIndexCoverage IS NULL OR i2.ExistingIndexCoverage <> 'LEADING_KEY')
                ORDER BY i2.TotalLogicalReads DESC FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
            FROM ColumnsByTable c
            GROUP BY c.DatabaseName, c.SchemaName, c.TableName;

            -- Check existing indexes for near-matches
            DECLARE @caDB2 NVARCHAR(128), @caSQL2 NVARCHAR(MAX);
            DECLARE ca_db_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT DatabaseName FROM #CATableRecs;
            OPEN ca_db_cursor;
            FETCH NEXT FROM ca_db_cursor INTO @caDB2;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @caSQL2 = N'USE ' + QUOTENAME(@caDB2) + N';
                UPDATE tr SET tr.NearMatchIndex = nm.index_name, tr.NearMatchAction = nm.match_type
                FROM DBA_Utilities..#CATableRecs tr
                OUTER APPLY (
                  SELECT TOP 1 i.name AS index_name
                    ,CASE WHEN km.match_count = km.total_rec_keys THEN ''EXTEND'' WHEN km.match_count >= 1 THEN ''PARTIAL'' END AS match_type
                  FROM sys.indexes i JOIN sys.objects o ON i.object_id = o.object_id JOIN sys.schemas s ON o.schema_id = s.schema_id
                  CROSS APPLY (
                    SELECT SUM(CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic2 JOIN sys.columns c2 ON ic2.object_id = c2.object_id AND ic2.column_id = c2.column_id
                      WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id AND ic2.is_included_column = 0 AND ''['' + c2.name + '']'' = LTRIM(rc.value)
                    ) THEN 1 ELSE 0 END) AS match_count, COUNT(*) AS total_rec_keys
                    FROM STRING_SPLIT(tr.KeyColumns, '','') rc WHERE LTRIM(rc.value) <> ''''
                  ) km
                  WHERE s.name = tr.SchemaName AND o.name = tr.TableName AND i.type = 2 AND i.is_primary_key = 0 AND km.match_count >= 1
                  ORDER BY km.match_count DESC
                ) nm WHERE tr.DatabaseName = DB_NAME() AND tr.NearMatchIndex IS NULL;';
                BEGIN TRY EXEC sp_executesql @caSQL2; END TRY BEGIN CATCH END CATCH;
                FETCH NEXT FROM ca_db_cursor INTO @caDB2;
            END
            CLOSE ca_db_cursor;
            DEALLOCATE ca_db_cursor;

            -- Build CREATE statements
            UPDATE #CATableRecs
            SET CreateStatement = CASE
                WHEN NearMatchAction = 'EXTEND' AND NearMatchIndex IS NOT NULL THEN
                  'CREATE NONCLUSTERED INDEX [' + NearMatchIndex + ']'
                  + CHAR(13)+CHAR(10) + 'ON [' + SchemaName + '].[' + TableName + '] (' + KeyColumns + ')'
                  + CASE WHEN IncludeColumns IS NOT NULL THEN CHAR(13)+CHAR(10) + 'INCLUDE (' + IncludeColumns + ')' ELSE '' END
                  + CHAR(13)+CHAR(10) + 'WITH (DROP_EXISTING = ON' + CASE WHEN @IsEnterprise = 1 THEN ', ONLINE = ON' ELSE '' END + ');'
                ELSE
                  'CREATE NONCLUSTERED INDEX [IX_' + TableName + '_'
                  + REPLACE(REPLACE(REPLACE(KeyColumns, '[', ''), ']', ''), ', ', '_')
                  + CASE WHEN IncludeColumns IS NOT NULL THEN '_INCLUDES' ELSE '' END + ']'
                  + CHAR(13)+CHAR(10) + 'ON [' + SchemaName + '].[' + TableName + '] (' + KeyColumns + ')'
                  + CASE WHEN IncludeColumns IS NOT NULL THEN CHAR(13)+CHAR(10) + 'INCLUDE (' + IncludeColumns + ')' ELSE '' END
                  + CASE WHEN @IsEnterprise = 1 THEN CHAR(13)+CHAR(10) + 'WITH (ONLINE = ON);' ELSE ';' END
                END
            WHERE KeyColumns IS NOT NULL;

            INSERT INTO #AllTables SELECT DISTINCT DatabaseName, SchemaName, TableName
            FROM #CATableRecs WHERE CreateStatement IS NOT NULL;
        END

        -- Deduplicate
        ;WITH D AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY DatabaseName, SchemaName, TableName ORDER BY (SELECT NULL)) AS rn FROM #AllTables)
        DELETE FROM D WHERE rn > 1;

        -- Filter to target databases
        IF @DatabaseName IS NOT NULL
        BEGIN
            IF @DatabaseName LIKE '%[%]%'
                DELETE FROM #AllTables WHERE DatabaseName NOT LIKE @DatabaseName;
            ELSE
                DELETE FROM #AllTables WHERE DatabaseName NOT IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseName, ','));
        END

        -- Per-tool finding counts
        DECLARE @hdrDup VARCHAR(50) = '', @hdrKey VARCHAR(50) = '', @hdrUnused VARCHAR(50) = '',
                @hdrMissing VARCHAR(50) = '', @hdrExpensive VARCHAR(50) = '', @hdrColumn VARCHAR(50) = '';
        DECLARE @hdrCount INT;

        IF @RunDuplicateIndex = 1 AND OBJECT_ID('indexing.IndexOptimizationResults', 'U') IS NOT NULL
        BEGIN
            SELECT @hdrCount = COUNT(*) FROM indexing.IndexOptimizationResults
            WHERE ResolvedDate IS NULL AND DatabaseName IN (SELECT DatabaseName FROM #AllTables);
            SET @hdrDup = '  Duplicate Index:       ' + CAST(@hdrCount AS VARCHAR(10)) + ' findings' + @CRLF2;
        END

        IF @RunKeyLookup = 1 AND OBJECT_ID('indexing.KeyLookupResults', 'U') IS NOT NULL
        BEGIN
            SELECT @hdrCount = COUNT(*) FROM indexing.KeyLookupResults
            WHERE ResolvedDate IS NULL AND DatabaseName IN (SELECT DatabaseName FROM #AllTables);
            SET @hdrKey = '  Key Lookup:            ' + CAST(@hdrCount AS VARCHAR(10)) + ' findings' + @CRLF2;
        END

        IF @RunUnusedIndex = 1 AND OBJECT_ID('indexing.UnusedIndexResults', 'U') IS NOT NULL
        BEGIN
            SELECT @hdrCount = COUNT(*) FROM indexing.UnusedIndexResults
            WHERE ResolvedDate IS NULL AND DatabaseName IN (SELECT DatabaseName FROM #AllTables)
                AND UserUpdates >= @MinUpdateCount AND ObservationDays >= @MinObservDays
                AND CASE Confidence WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END
                    >= CASE @Confidence WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END;
            SET @hdrUnused = '  Unused Index:          ' + CAST(@hdrCount AS VARCHAR(10)) + ' findings' + @CRLF2;
        END

        IF @RunOptimizeIndex = 1 AND OBJECT_ID('indexing.MissingIndexResults', 'U') IS NOT NULL
        BEGIN
            SELECT @hdrCount = COUNT(*) FROM indexing.MissingIndexResults
            WHERE ResolvedDate IS NULL AND ServerName = @@SERVERNAME AND Strategy NOT IN ('SUPERSET_COVERED')
                AND DatabaseName IN (SELECT DatabaseName FROM #AllTables);
            SET @hdrMissing = '  Missing Index:         ' + CAST(@hdrCount AS VARCHAR(10)) + ' findings' + @CRLF2;
        END

        IF @RunExpensiveQuery = 1 AND OBJECT_ID('indexing.ExpensiveQueryResults', 'U') IS NOT NULL
        BEGIN
            SELECT @hdrCount = COUNT(*) FROM indexing.ExpensiveQueryResults
            WHERE ResolvedDate IS NULL AND DatabaseName IN (SELECT DatabaseName FROM #AllTables);
            SET @hdrExpensive = '  Expensive Query:       ' + CAST(@hdrCount AS VARCHAR(10)) + ' findings' + @CRLF2;
        END

        IF @RunColumnAccess = 1
        BEGIN
            SELECT @hdrCount = COUNT(*) FROM #CATableRecs WHERE CreateStatement IS NOT NULL;
            SET @hdrColumn = '  Column Access:         ' + CAST(@hdrCount AS VARCHAR(10)) + ' findings' + @CRLF2;
        END

        -- Header
        SET @Out =
            '/*' + @CRLF2
            + '==============================================================================' + @CRLF2
            + '  INDEX OPTIMIZATION SUITE - COMBINED OUTPUT' + @CRLF2
            + '  Server: ' + @@SERVERNAME + @CRLF2
            + '  Edition: ' + CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) + @CRLF2
            + '  Version: ' + CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(30)) + @CRLF2
            + '  Generated: ' + CONVERT(VARCHAR(30), GETDATE(), 120) + @CRLF2
            + '  Databases: ' + CAST((SELECT COUNT(DISTINCT DatabaseName) FROM #AllTables) AS VARCHAR(10)) + @CRLF2
            + '  Tables: ' + CAST((SELECT COUNT(*) FROM #AllTables) AS VARCHAR(10)) + @CRLF2
            + '==============================================================================' + @CRLF2
            + @CRLF2
            + '  Tools:' + @CRLF2
            + @hdrDup + @hdrKey + @hdrUnused + @hdrMissing + @hdrExpensive + @hdrColumn
            + @CRLF2
            + '==============================================================================' + @CRLF2
            + '*/' + @CRLF2;

        -- Cursor over database -> table
        DECLARE @CombinedRunnableCount INT = 0;
        DECLARE @cDB NVARCHAR(128), @cSchema NVARCHAR(128), @cTable NVARCHAR(128);
        DECLARE @cCurrentDB NVARCHAR(128) = '';
        DECLARE @cSchemaTable NVARCHAR(500);
        DECLARE @cSection NVARCHAR(MAX);
        DECLARE @caIds NVARCHAR(MAX);
        DECLARE @caCreate NVARCHAR(MAX), @caEstGB DECIMAL(18,2);
        DECLARE @caKeys NVARCHAR(MAX), @caIncludes NVARCHAR(MAX), @caNearMatch NVARCHAR(256);

        -- Track modified indexes per table for cross-tool dedup
        CREATE TABLE #ModifiedIndexes (
            DatabaseName NVARCHAR(128), SchemaName NVARCHAR(128), TableName NVARCHAR(128),
            IndexName NVARCHAR(256), ToolName VARCHAR(40));
        DECLARE @coveredBy VARCHAR(40);

        DECLARE combined_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT DatabaseName, SchemaName, TableName
            FROM #AllTables
            ORDER BY DatabaseName, SchemaName, TableName;

        OPEN combined_cursor;
        FETCH NEXT FROM combined_cursor INTO @cDB, @cSchema, @cTable;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- Database header
            IF @cDB <> @cCurrentDB
            BEGIN
                SET @cCurrentDB = @cDB;
                SET @Out = @Out + @CRLF2
                    + '-- ============================================================================' + @CRLF2
                    + '-- Database: ' + @cDB + @CRLF2
                    + '-- ============================================================================' + @CRLF2
                    + 'USE ' + QUOTENAME(@cDB) + @CRLF2
                    + 'GO' + @CRLF2;
            END

            SET @cSchemaTable = QUOTENAME(@cSchema) + '.' + QUOTENAME(@cTable);

            -- Table header
            SET @Out = @Out + @CRLF2
                + @Sep + @CRLF2
                + '-- Table: ' + @cSchemaTable + @CRLF2
                + @Sep + @CRLF2
                + '--EXEC sp_helpindexUsage ''' + @cSchema + '.' + @cTable + '''' + @CRLF2;

            ---------------------------------------------------------------
            -- Duplicate Index findings for this table
            ---------------------------------------------------------------
            IF @RunDuplicateIndex = 1 AND OBJECT_ID('indexing.IndexOptimizationResults', 'U') IS NOT NULL
            BEGIN
                SET @cSection = NULL;

                DECLARE @dId INT, @dAction VARCHAR(20),
                        @dIdx1Name NVARCHAR(256), @dIdx1Id INT, @dIdx1Keys NVARCHAR(MAX), @dIdx1Inc NVARCHAR(MAX),
                        @dIdx1SizeKB BIGINT, @dIdx1Seeks BIGINT, @dIdx1Scans BIGINT,
                        @dIdx2Name NVARCHAR(256), @dIdx2Id INT, @dIdx2Keys NVARCHAR(MAX), @dIdx2Inc NVARCHAR(MAX),
                        @dIdx2SizeKB BIGINT, @dIdx2Seeks BIGINT, @dIdx2Scans BIGINT,
                        @dNewName NVARCHAR(500), @dNewKeys NVARCHAR(MAX), @dNewInc NVARCHAR(MAX), @dNewExists BIT,
                        @dCreate NVARCHAR(MAX), @dDrop1 NVARCHAR(1000), @dDrop2 NVARCHAR(1000),
                        @dEstGB DECIMAL(18,2), @dCheckSizeKB BIGINT, @dShouldComment BIT;

                DECLARE dup_cursor CURSOR LOCAL FAST_FORWARD FOR
                    SELECT IndexOptimizationId, ActionType,
                           Index1Name, Index1Id, Index1Keys, Index1Includes, Index1SizeKB, Index1UserSeeks, Index1UserScans,
                           Index2Name, Index2Id, Index2Keys, Index2Includes, Index2SizeKB, Index2UserSeeks, Index2UserScans,
                           NewIndexName, NewIndexKeys, NewIncludeColumns, NewIndexNameExists,
                           CreateStatement, DropStatement1, DropStatement2, EstimatedSizeGB
                    FROM indexing.IndexOptimizationResults
                    WHERE ResolvedDate IS NULL
                      AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                    ORDER BY CASE ActionType
                        WHEN 'DUPLICATE'       THEN 1
                        WHEN 'DUPLICATE of PK' THEN 2
                        WHEN 'REDUNDANT'       THEN 3
                        WHEN 'COMBINE'         THEN 4
                    END;

                OPEN dup_cursor;
                FETCH NEXT FROM dup_cursor INTO @dId, @dAction,
                    @dIdx1Name, @dIdx1Id, @dIdx1Keys, @dIdx1Inc, @dIdx1SizeKB, @dIdx1Seeks, @dIdx1Scans,
                    @dIdx2Name, @dIdx2Id, @dIdx2Keys, @dIdx2Inc, @dIdx2SizeKB, @dIdx2Seeks, @dIdx2Scans,
                    @dNewName, @dNewKeys, @dNewInc, @dNewExists, @dCreate, @dDrop1, @dDrop2, @dEstGB;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    IF @cSection IS NULL SET @cSection = '' ELSE SET @cSection = @cSection + @CRLF2;

                    IF @dAction IN ('DUPLICATE', 'DUPLICATE of PK', 'REDUNDANT')
                        SET @cSection = @cSection
                            + '-- ' + @dAction + @CRLF2
                            + '--   DROP:  ' + @dIdx1Name + ' (Id: ' + CAST(@dIdx1Id AS VARCHAR(10)) + ')' + @CRLF2
                            + '--     Key Columns:     ' + @dIdx1Keys + @CRLF2
                            + '--     Include Columns: ' + ISNULL(NULLIF(@dIdx1Inc, ''), '(none)') + @CRLF2
                            + '--     Size: ' + FORMAT(CAST(ISNULL(@dIdx1SizeKB, 0) / 1024.0 AS DECIMAL(10,1)), 'N1') + ' MB'
                            + '  |  Seeks: ' + FORMAT(ISNULL(@dIdx1Seeks, 0), 'N0')
                            + '  |  Scans: ' + FORMAT(ISNULL(@dIdx1Scans, 0), 'N0') + @CRLF2
                            + '--   KEEP:  ' + ISNULL(@dIdx2Name, 'CLUSTERED PK') + ISNULL(' (Id: ' + CAST(@dIdx2Id AS VARCHAR(10)) + ')', '') + @CRLF2
                            + '--     Key Columns:     ' + ISNULL(@dIdx2Keys, '(clustered key)') + @CRLF2
                            + '--     Include Columns: ' + ISNULL(NULLIF(@dIdx2Inc, ''), '(none)') + @CRLF2
                            + '--     Size: ' + FORMAT(CAST(ISNULL(@dIdx2SizeKB, 0) / 1024.0 AS DECIMAL(10,1)), 'N1') + ' MB'
                            + '  |  Seeks: ' + FORMAT(ISNULL(@dIdx2Seeks, 0), 'N0')
                            + '  |  Scans: ' + FORMAT(ISNULL(@dIdx2Scans, 0), 'N0') + @CRLF2
                            + @CRLF2
                            + @dDrop1 + @CRLF2
                            + @CRLF2
                            + 'UPDATE DBA_Utilities.indexing.IndexOptimizationResults SET ResolvedDate = GETDATE() WHERE IndexOptimizationId = ' + CAST(@dId AS VARCHAR(10)) + ';' + @CRLF2;
                    ELSE
                    BEGIN
                        SET @cSection = @cSection
                            + '-- COMBINE' + @CRLF2
                            + '--   Index 1: ' + @dIdx1Name + ' (Id: ' + CAST(@dIdx1Id AS VARCHAR(10)) + ')' + @CRLF2
                            + '--     Key Columns:     ' + @dIdx1Keys + @CRLF2
                            + '--     Include Columns: ' + ISNULL(NULLIF(@dIdx1Inc, ''), '(none)') + @CRLF2
                            + '--     Size: ' + FORMAT(CAST(ISNULL(@dIdx1SizeKB, 0) / 1024.0 AS DECIMAL(10,1)), 'N1') + ' MB'
                            + '  |  Seeks: ' + FORMAT(ISNULL(@dIdx1Seeks, 0), 'N0')
                            + '  |  Scans: ' + FORMAT(ISNULL(@dIdx1Scans, 0), 'N0') + @CRLF2
                            + '--   Index 2: ' + ISNULL(@dIdx2Name, '') + ' (Id: ' + CAST(ISNULL(@dIdx2Id, 0) AS VARCHAR(10)) + ')' + @CRLF2
                            + '--     Key Columns:     ' + ISNULL(@dIdx2Keys, '') + @CRLF2
                            + '--     Include Columns: ' + ISNULL(NULLIF(@dIdx2Inc, ''), '(none)') + @CRLF2
                            + '--     Size: ' + FORMAT(CAST(ISNULL(@dIdx2SizeKB, 0) / 1024.0 AS DECIMAL(10,1)), 'N1') + ' MB'
                            + '  |  Seeks: ' + FORMAT(ISNULL(@dIdx2Seeks, 0), 'N0')
                            + '  |  Scans: ' + FORMAT(ISNULL(@dIdx2Scans, 0), 'N0') + @CRLF2
                            + '--   New Index: ' + ISNULL(@dNewName, '') + @CRLF2
                            + '--     Key Columns:     ' + ISNULL(@dNewKeys, '') + @CRLF2
                            + '--     Include Columns: ' + ISNULL(NULLIF(@dNewInc, ''), '(none)') + @CRLF2
                            + CASE WHEN @dNewExists = 1 THEN '--   WARNING: New index name already exists' + @CRLF2 ELSE '' END
                            + CASE WHEN @dEstGB IS NOT NULL THEN '--   Estimated Size: ~' + FORMAT(@dEstGB * 1024, 'N1') + ' MB' + @CRLF2 ELSE '' END
                            + @CRLF2;

                        SET @dCheckSizeKB = ISNULL(CASE WHEN ISNULL(@dIdx1SizeKB, 0) > ISNULL(@dIdx2SizeKB, 0) THEN @dIdx1SizeKB ELSE @dIdx2SizeKB END, 0);
                        SET @dShouldComment = CASE WHEN @ActiveThreshold IS NOT NULL
                            AND (@dCheckSizeKB >= CAST(@ActiveThreshold * 1048576 AS BIGINT) OR ISNULL(@dEstGB, 0) >= @ActiveThreshold) THEN 1 ELSE 0 END;

                        IF @dShouldComment = 1
                            SET @cSection = @cSection + '/*' + @CRLF2;

                        IF @dCreate IS NOT NULL
                        BEGIN
                            IF @IsEnterprise = 1
                                SET @cSection = @cSection + REPLACE(@dCreate, ';', ' WITH (ONLINE = ON);') + @CRLF2;
                            ELSE
                                SET @cSection = @cSection + @dCreate + @CRLF2;
                        END

                        SET @cSection = @cSection
                            + @CRLF2
                            + @dDrop1 + @CRLF2
                            + ISNULL(@dDrop2 + @CRLF2, '');

                        IF @dNewExists = 1
                            SET @cSection = @cSection + @CRLF2
                                + 'EXEC sp_rename N''' + @cSchema + '.' + @cTable + '.' + @dNewName + ''', N''' + REPLACE(@dNewName, '_NEW', '') + ''', N''INDEX''' + @CRLF2;

                        IF @dShouldComment = 1
                            SET @cSection = @cSection + '*/' + @CRLF2;

                        SET @cSection = @cSection + @CRLF2;

                        IF @dShouldComment = 1
                            SET @cSection = @cSection
                                + '/* UPDATE DBA_Utilities.indexing.IndexOptimizationResults SET ResolvedDate = GETDATE() WHERE IndexOptimizationId = ' + CAST(@dId AS VARCHAR(10)) + '; */' + @CRLF2;
                        ELSE
                            SET @cSection = @cSection
                                + 'UPDATE DBA_Utilities.indexing.IndexOptimizationResults SET ResolvedDate = GETDATE() WHERE IndexOptimizationId = ' + CAST(@dId AS VARCHAR(10)) + ';' + @CRLF2;
                    END

                    FETCH NEXT FROM dup_cursor INTO @dId, @dAction,
                        @dIdx1Name, @dIdx1Id, @dIdx1Keys, @dIdx1Inc, @dIdx1SizeKB, @dIdx1Seeks, @dIdx1Scans,
                        @dIdx2Name, @dIdx2Id, @dIdx2Keys, @dIdx2Inc, @dIdx2SizeKB, @dIdx2Seeks, @dIdx2Scans,
                        @dNewName, @dNewKeys, @dNewInc, @dNewExists, @dCreate, @dDrop1, @dDrop2, @dEstGB;
                END

                CLOSE dup_cursor;
                DEALLOCATE dup_cursor;

                IF @cSection IS NOT NULL
                BEGIN
                    SET @Out = @Out + @CRLF2 + '-- === DUPLICATE INDEX ===' + @CRLF2 + @cSection;

                    INSERT INTO #ModifiedIndexes (DatabaseName, SchemaName, TableName, IndexName, ToolName)
                    SELECT DatabaseName, SchemaName, TableName, Index1Name, 'Duplicate Index'
                    FROM indexing.IndexOptimizationResults
                    WHERE ResolvedDate IS NULL AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable;
                END
            END

            ---------------------------------------------------------------
            -- Key Lookup findings for this table
            ---------------------------------------------------------------
            IF @RunKeyLookup = 1 AND OBJECT_ID('indexing.KeyLookupResults', 'U') IS NOT NULL
            BEGIN
                SET @cSection = NULL;
                SELECT @cSection = ISNULL(@cSection + @CRLF2, '')
                    + '--   Index: ' + NCIndexName + @CRLF2
                    + '--     Key Columns:         ' + ISNULL(NCIndexKeys, '(none)') + @CRLF2
                    + '--     Current Includes:    ' + ISNULL(NCIndexIncludes, '(none)') + @CRLF2
                    + '--     Size: ' + FORMAT(CAST(ISNULL(NCIndexSizeKB, 0) / 1024.0 AS DECIMAL(10,1)), 'N1') + ' MB' + @CRLF2
                    + '--   Add Includes:          ' + ISNULL(RecommendedIncludes, '(none)') + @CRLF2
                    + CASE WHEN EstimatedSizeGB IS NOT NULL THEN '--   Estimated New Size: ~' + FORMAT(EstimatedSizeGB * 1024, 'N1') + ' MB' + @CRLF2 ELSE '' END
                    + '--   Impact: ' + FORMAT(TotalLogicalReads, 'N0') + ' total reads  |  '
                    + FORMAT(TotalExecutions, 'N0') + ' executions  |  '
                    + FORMAT(AvgLogicalReads, 'N0') + ' avg reads/exec  |  '
                    + FORMAT(PlanCount, 'N0') + ' plan(s)' + @CRLF2
                    + @CRLF2
                    + CASE WHEN CreateStatement IS NULL THEN ''
                      ELSE
                        CASE WHEN @ActiveThreshold IS NOT NULL
                              AND (ISNULL(EstimatedSizeGB, 0) >= @ActiveThreshold OR (EstimatedSizeGB IS NULL AND ISNULL(NCIndexSizeKB, 0) >= CAST(@ActiveThreshold * 1048576 AS BIGINT)))
                            THEN '/*' + @CRLF2
                              + CASE WHEN @IsEnterprise = 1 THEN
                                  REPLACE(REPLACE(CreateStatement
                                    , 'WITH (DROP_EXISTING = ON);', 'WITH (DROP_EXISTING = ON, ONLINE = ON);')
                                    , ');' + @CRLF2 + @CRLF2 + 'DROP INDEX', ') WITH (ONLINE = ON);' + @CRLF2 + @CRLF2 + 'DROP INDEX')
                                ELSE CreateStatement END
                              + @CRLF2 + '*/' + @CRLF2 + @CRLF2
                          WHEN @IsEnterprise = 1 THEN
                            REPLACE(REPLACE(CreateStatement
                              , 'WITH (DROP_EXISTING = ON);', 'WITH (DROP_EXISTING = ON, ONLINE = ON);')
                              , ');' + @CRLF2 + @CRLF2 + 'DROP INDEX', ') WITH (ONLINE = ON);' + @CRLF2 + @CRLF2 + 'DROP INDEX')
                            + @CRLF2 + @CRLF2
                          ELSE CreateStatement + @CRLF2 + @CRLF2
                        END
                    END
                    + CASE WHEN @ActiveThreshold IS NOT NULL
                          AND (ISNULL(EstimatedSizeGB, 0) >= @ActiveThreshold OR (EstimatedSizeGB IS NULL AND ISNULL(NCIndexSizeKB, 0) >= CAST(@ActiveThreshold * 1048576 AS BIGINT)))
                        THEN '/* UPDATE DBA_Utilities.indexing.KeyLookupResults SET ResolvedDate = GETDATE() WHERE KeyLookupId = ' + CAST(KeyLookupId AS VARCHAR(10)) + '; */' + @CRLF2
                        ELSE 'UPDATE DBA_Utilities.indexing.KeyLookupResults SET ResolvedDate = GETDATE() WHERE KeyLookupId = ' + CAST(KeyLookupId AS VARCHAR(10)) + ';' + @CRLF2
                    END
                FROM indexing.KeyLookupResults
                WHERE ResolvedDate IS NULL
                  AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                ORDER BY TotalLogicalReads DESC;

                IF @cSection IS NOT NULL
                BEGIN
                    SET @Out = @Out + @CRLF2 + '-- === KEY LOOKUP ELIMINATION ===' + @CRLF2 + @cSection;

                    INSERT INTO #ModifiedIndexes (DatabaseName, SchemaName, TableName, IndexName, ToolName)
                    SELECT DatabaseName, SchemaName, TableName, NCIndexName, 'Key Lookup'
                    FROM indexing.KeyLookupResults
                    WHERE ResolvedDate IS NULL AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable;
                END
            END

            ---------------------------------------------------------------
            -- Unused Index findings for this table
            ---------------------------------------------------------------
            IF @RunUnusedIndex = 1 AND OBJECT_ID('indexing.UnusedIndexResults', 'U') IS NOT NULL
            BEGIN
                SET @cSection = NULL;
                SELECT @cSection = ISNULL(@cSection + @CRLF2, '')
                    + '--   Index: ' + IndexName + ' (' + ISNULL(IndexType, 'NONCLUSTERED') + ')' + @CRLF2
                    + '--     Size: ' + FORMAT(CAST(ISNULL(IndexSizeKB, 0) / 1024.0 AS DECIMAL(10,1)), 'N1') + ' MB' + @CRLF2
                    + '--   Usage (since ' + ISNULL(CONVERT(VARCHAR(10), DMVStatsResetDate, 23), '?') + '):' + @CRLF2
                    + '--     Seeks: ' + FORMAT(ISNULL(UserSeeks, 0), 'N0')
                    + '  |  Scans: ' + FORMAT(ISNULL(UserScans, 0), 'N0')
                    + '  |  Lookups: ' + FORMAT(ISNULL(UserLookups, 0), 'N0')
                    + '  |  Updates: ' + FORMAT(ISNULL(UserUpdates, 0), 'N0') + @CRLF2
                    + '--   Observation:' + @CRLF2
                    + '--     Source: ' + ISNULL(ObservationSource, '?')
                    + '  |  Days: ' + FORMAT(ISNULL(ObservationDays, 0), 'N0') + @CRLF2
                    + '--     Confidence: ' + ISNULL(Confidence, '?') + @CRLF2
                    + @CRLF2
                    + ISNULL(DropStatement, '') + @CRLF2
                    + @CRLF2
                    + 'UPDATE DBA_Utilities.indexing.UnusedIndexResults SET ResolvedDate = GETDATE() WHERE UnusedIndexId = ' + CAST(UnusedIndexId AS VARCHAR(10)) + ';' + @CRLF2
                FROM indexing.UnusedIndexResults
                WHERE ResolvedDate IS NULL
                  AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                  AND UserUpdates >= @MinUpdateCount AND ObservationDays >= @MinObservDays
                  AND CASE Confidence WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END
                      >= CASE @Confidence WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END
                ORDER BY ISNULL(IndexSizeKB, 0) DESC;

                IF @cSection IS NOT NULL
                    SET @Out = @Out + @CRLF2 + '-- === UNUSED INDEX ===' + @CRLF2 + @cSection;
            END

            ---------------------------------------------------------------
            -- Missing Index (optimize-index) findings for this table
            ---------------------------------------------------------------
            IF @RunOptimizeIndex = 1 AND OBJECT_ID('indexing.MissingIndexResults', 'U') IS NOT NULL
            BEGIN
                SET @cSection = NULL;

                DECLARE @mId INT, @mStrategy NVARCHAR(50), @mExIdx NVARCHAR(128), @mKeys NVARCHAR(MAX), @mInc NVARCHAR(MAX);
                DECLARE @mAdvantage DECIMAL(18,2), @mRecCount INT, @mEstGB DECIMAL(18,2), @mCreate NVARCHAR(MAX);
                DECLARE @mIsSuperCons BIT, @mOrigGrpCnt INT;

                DECLARE mi_cursor CURSOR LOCAL FAST_FORWARD FOR
                    SELECT MissingIndexId, Strategy, ExistingIndexName, KeyColumns, IncludedColumns,
                           IndexAdvantage, RecommendationCount, EstimatedSizeGB, CreateStatement,
                           IsSuperConsolidated, OriginalGroupCount
                    FROM indexing.MissingIndexResults
                    WHERE ResolvedDate IS NULL AND ServerName = @@SERVERNAME
                      AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                      AND Strategy NOT IN ('SUPERSET_COVERED')
                    ORDER BY IndexAdvantage DESC;

                OPEN mi_cursor;
                FETCH NEXT FROM mi_cursor INTO @mId, @mStrategy, @mExIdx, @mKeys, @mInc,
                    @mAdvantage, @mRecCount, @mEstGB, @mCreate, @mIsSuperCons, @mOrigGrpCnt;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    IF @cSection IS NULL SET @cSection = '' ELSE SET @cSection = @cSection + @CRLF2;

                    SET @cSection = @cSection
                        + '--   Strategy: ' + @mStrategy
                        + CASE WHEN @mIsSuperCons = 1 THEN ' (super-consolidated from ' + CAST(ISNULL(@mOrigGrpCnt, 0) AS VARCHAR(10)) + ' groups)' ELSE '' END + @CRLF2
                        + '--   Recommendations: ' + FORMAT(ISNULL(@mRecCount, 0), 'N0')
                        + CASE WHEN @mAdvantage IS NOT NULL THEN '  |  Advantage: ' + CAST(@mAdvantage AS VARCHAR(20)) ELSE '' END + @CRLF2
                        + CASE WHEN @mExIdx IS NOT NULL THEN '--   Existing Index: ' + @mExIdx + @CRLF2 ELSE '' END
                        + '--   New Keys: ' + ISNULL(@mKeys, '(none)') + @CRLF2
                        + CASE WHEN @mInc IS NOT NULL THEN '--   New Includes: ' + @mInc + @CRLF2 ELSE '' END
                        + CASE WHEN @mEstGB IS NOT NULL THEN '--   Estimated Size: ~' + FORMAT(@mEstGB, 'N2') + ' GB' + @CRLF2 ELSE '' END
                        + @CRLF2;

                    -- Check if this finding's existing index was already modified by another tool
                    SET @coveredBy = NULL;
                    IF @mExIdx IS NOT NULL
                        SELECT TOP 1 @coveredBy = ToolName FROM #ModifiedIndexes
                        WHERE DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable AND IndexName = @mExIdx;

                    IF @coveredBy IS NOT NULL
                    BEGIN
                        SET @cSection = @cSection
                            + '-- Covered above by ' + @coveredBy + @CRLF2 + @CRLF2;
                        IF @ActiveThreshold IS NOT NULL AND ISNULL(@mEstGB, 0) >= @ActiveThreshold
                            SET @cSection = @cSection
                                + '/* UPDATE DBA_Utilities.indexing.MissingIndexResults SET ResolvedDate = GETDATE() WHERE MissingIndexId = ' + CAST(@mId AS VARCHAR(10)) + '; */' + @CRLF2;
                        ELSE
                            SET @cSection = @cSection
                                + 'UPDATE DBA_Utilities.indexing.MissingIndexResults SET ResolvedDate = GETDATE() WHERE MissingIndexId = ' + CAST(@mId AS VARCHAR(10)) + ';' + @CRLF2;
                    END
                    ELSE IF @ActiveThreshold IS NOT NULL AND ISNULL(@mEstGB, 0) >= @ActiveThreshold
                    BEGIN
                        IF @mCreate IS NOT NULL AND LEFT(LTRIM(@mCreate), 2) <> '/*'
                            SET @cSection = @cSection + '/*' + @CRLF2 + @mCreate + @CRLF2 + '*/' + @CRLF2 + @CRLF2;
                        ELSE
                            SET @cSection = @cSection + ISNULL(@mCreate + @CRLF2 + @CRLF2, '');
                        SET @cSection = @cSection
                            + '/* UPDATE DBA_Utilities.indexing.MissingIndexResults SET ResolvedDate = GETDATE() WHERE MissingIndexId = ' + CAST(@mId AS VARCHAR(10)) + '; */' + @CRLF2;
                    END
                    ELSE
                        SET @cSection = @cSection
                            + ISNULL(@mCreate + @CRLF2 + @CRLF2, '')
                            + 'UPDATE DBA_Utilities.indexing.MissingIndexResults SET ResolvedDate = GETDATE() WHERE MissingIndexId = ' + CAST(@mId AS VARCHAR(10)) + ';' + @CRLF2;

                    FETCH NEXT FROM mi_cursor INTO @mId, @mStrategy, @mExIdx, @mKeys, @mInc,
                        @mAdvantage, @mRecCount, @mEstGB, @mCreate, @mIsSuperCons, @mOrigGrpCnt;
                END

                CLOSE mi_cursor;
                DEALLOCATE mi_cursor;

                IF @cSection IS NOT NULL
                BEGIN
                    SET @Out = @Out + @CRLF2 + '-- === MISSING INDEX ===' + @CRLF2 + @cSection;

                    INSERT INTO #ModifiedIndexes (DatabaseName, SchemaName, TableName, IndexName, ToolName)
                    SELECT @cDB, @cSchema, @cTable,
                        SUBSTRING(CreateStatement,
                            CHARINDEX('CREATE NONCLUSTERED INDEX [', CreateStatement) + 27,
                            CHARINDEX(']', CreateStatement, CHARINDEX('CREATE NONCLUSTERED INDEX [', CreateStatement) + 27)
                            - CHARINDEX('CREATE NONCLUSTERED INDEX [', CreateStatement) - 27),
                        'Missing Index'
                    FROM indexing.MissingIndexResults
                    WHERE ResolvedDate IS NULL AND ServerName = @@SERVERNAME
                      AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                      AND Strategy NOT IN ('SUPERSET_COVERED')
                      AND CreateStatement IS NOT NULL
                      AND CHARINDEX('CREATE NONCLUSTERED INDEX [', CreateStatement) > 0;
                END
            END

            ---------------------------------------------------------------
            -- Expensive Query findings for this table
            ---------------------------------------------------------------
            IF @RunExpensiveQuery = 1 AND OBJECT_ID('indexing.ExpensiveQueryResults', 'U') IS NOT NULL
            BEGIN
                SET @cSection = NULL;
                SELECT @cSection = ISNULL(@cSection + @CRLF2, '')
                    + '--   Finding: ' + ISNULL(FindingType, '?') + @CRLF2
                    + '--   Detail: ' + ISNULL(FindingDetail, '') + @CRLF2
                    + CASE WHEN IndexName IS NOT NULL THEN '--   Index: ' + IndexName + @CRLF2 ELSE '' END
                    + CASE WHEN ScanType IS NOT NULL THEN '--   Scan Type: ' + ScanType + @CRLF2 ELSE '' END
                    + '--   Impact: ' + FORMAT(ISNULL(TotalLogicalReads, 0), 'N0') + ' total reads  |  '
                    + FORMAT(ISNULL(TotalExecutions, 0), 'N0') + ' executions  |  '
                    + FORMAT(ISNULL(TotalCPUTimeMs, 0), 'N0') + ' ms CPU  |  '
                    + FORMAT(ISNULL(TotalDurationMs, 0), 'N0') + ' ms duration' + @CRLF2
                    + '--   Averages: ' + FORMAT(ISNULL(AvgLogicalReads, 0), 'N0') + ' reads/exec  |  '
                    + FORMAT(ISNULL(AvgCPUTimeMs, 0), 'N0') + ' ms CPU/exec  |  '
                    + FORMAT(ISNULL(AvgDurationMs, 0), 'N0') + ' ms duration/exec' + @CRLF2
                    + CASE WHEN MissingIndexKeys IS NOT NULL THEN '--   Missing Index Keys: ' + MissingIndexKeys + @CRLF2 ELSE '' END
                    + CASE WHEN MissingIndexIncludes IS NOT NULL THEN '--   Missing Index Includes: ' + MissingIndexIncludes + @CRLF2 ELSE '' END
                    + CASE WHEN MissingIndexImpact IS NOT NULL THEN '--   Estimated Impact: ' + FORMAT(CAST(MissingIndexImpact AS DECIMAL(5,2)), 'N2') + '%' + @CRLF2 ELSE '' END
                    + CASE WHEN Recommendation IS NOT NULL THEN '--   Recommendation: ' + Recommendation + @CRLF2 ELSE '' END
                    + CASE WHEN EstimatedSizeGB IS NOT NULL THEN '--   Estimated Size: ~' + FORMAT(EstimatedSizeGB * 1024, 'N1') + ' MB' + @CRLF2 ELSE '' END
                    + @CRLF2
                    + CASE WHEN EXISTS (
                        SELECT 1 FROM #ModifiedIndexes mi
                        WHERE mi.DatabaseName = @cDB AND mi.SchemaName = @cSchema AND mi.TableName = @cTable
                          AND CreateStatement LIKE '%' + mi.IndexName + '%'
                      ) THEN '-- Covered above by ' + ISNULL((
                        SELECT TOP 1 mi.ToolName FROM #ModifiedIndexes mi
                        WHERE mi.DatabaseName = @cDB AND mi.SchemaName = @cSchema AND mi.TableName = @cTable
                          AND CreateStatement LIKE '%' + mi.IndexName + '%'), '') + @CRLF2 + @CRLF2
                      ELSE CASE WHEN CreateStatement IS NULL THEN ''
                          WHEN @ActiveThreshold IS NOT NULL AND ISNULL(EstimatedSizeGB, 0) >= @ActiveThreshold
                            THEN '/*' + @CRLF2
                              + CASE WHEN @IsEnterprise = 1 THEN REPLACE(CreateStatement, ';', ' WITH (ONLINE = ON);') ELSE CreateStatement END
                              + @CRLF2 + '*/' + @CRLF2 + @CRLF2
                          WHEN @IsEnterprise = 1
                            THEN REPLACE(CreateStatement, ';', ' WITH (ONLINE = ON);') + @CRLF2 + @CRLF2
                          ELSE CreateStatement + @CRLF2 + @CRLF2
                          END
                    END
                    + CASE WHEN @ActiveThreshold IS NOT NULL AND ISNULL(EstimatedSizeGB, 0) >= @ActiveThreshold
                        THEN '/* UPDATE DBA_Utilities.indexing.ExpensiveQueryResults SET ResolvedDate = GETDATE() WHERE ExpensiveQueryId = ' + CAST(ExpensiveQueryId AS VARCHAR(10)) + '; */' + @CRLF2
                        ELSE 'UPDATE DBA_Utilities.indexing.ExpensiveQueryResults SET ResolvedDate = GETDATE() WHERE ExpensiveQueryId = ' + CAST(ExpensiveQueryId AS VARCHAR(10)) + ';' + @CRLF2
                    END
                FROM indexing.ExpensiveQueryResults
                WHERE ResolvedDate IS NULL
                  AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                ORDER BY TotalLogicalReads DESC;

                IF @cSection IS NOT NULL
                BEGIN
                    SET @Out = @Out + @CRLF2 + '-- === EXPENSIVE QUERY ===' + @CRLF2 + @cSection;

                    INSERT INTO #ModifiedIndexes (DatabaseName, SchemaName, TableName, IndexName, ToolName)
                    SELECT @cDB, @cSchema, @cTable,
                        SUBSTRING(CreateStatement,
                            CHARINDEX('CREATE NONCLUSTERED INDEX [', CreateStatement) + 27,
                            CHARINDEX(']', CreateStatement, CHARINDEX('CREATE NONCLUSTERED INDEX [', CreateStatement) + 27)
                            - CHARINDEX('CREATE NONCLUSTERED INDEX [', CreateStatement) - 27),
                        'Expensive Query'
                    FROM indexing.ExpensiveQueryResults
                    WHERE ResolvedDate IS NULL AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                      AND CreateStatement IS NOT NULL
                      AND CHARINDEX('CREATE NONCLUSTERED INDEX [', CreateStatement) > 0;
                END
            END

            ---------------------------------------------------------------
            -- Column Access findings for this table
            ---------------------------------------------------------------
            IF @RunColumnAccess = 1
            BEGIN
                SET @caCreate = NULL;
                SET @caEstGB = NULL;
                SET @caKeys = NULL;
                SET @caIncludes = NULL;
                SET @caNearMatch = NULL;

                SELECT @caCreate = CreateStatement, @caEstGB = EstimatedSizeGB,
                       @caKeys = KeyColumns, @caIncludes = IncludeColumns,
                       @caNearMatch = NearMatchIndex
                FROM #CATableRecs
                WHERE DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                  AND CreateStatement IS NOT NULL;

                IF @caCreate IS NOT NULL
                BEGIN
                    -- Check if covered by a prior tool
                    SET @coveredBy = NULL;
                    SELECT TOP 1 @coveredBy = ToolName FROM #ModifiedIndexes
                    WHERE DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                      AND @caCreate LIKE '%' + IndexName + '%';

                    IF @caNearMatch IS NOT NULL AND @coveredBy IS NULL
                        SELECT TOP 1 @coveredBy = ToolName FROM #ModifiedIndexes
                        WHERE DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable
                          AND IndexName = @caNearMatch;

                    SET @cSection = '-- RECOMMENDED INDEX:' + @CRLF2
                        + '--   Key Columns: ' + ISNULL(@caKeys, '?') + @CRLF2
                        + CASE WHEN @caIncludes IS NOT NULL THEN '--   Includes:    ' + @caIncludes + @CRLF2 ELSE '' END
                        + CASE WHEN @caNearMatch IS NOT NULL THEN '--   Near Match:  ' + @caNearMatch + ' (EXTEND - modify existing index)' + @CRLF2 ELSE '' END
                        + CASE WHEN @caEstGB IS NOT NULL THEN '--   Estimated Size: ~' + FORMAT(@caEstGB, 'N2') + ' GB' + @CRLF2 ELSE '' END
                        + @CRLF2;

                    IF @coveredBy IS NOT NULL
                        SET @cSection = @cSection + '-- Covered above by ' + @coveredBy + @CRLF2;
                    ELSE
                        SET @cSection = @cSection + @caCreate + @CRLF2;

                    SET @caIds = NULL;
                    SELECT @caIds = STRING_AGG(CAST(ColumnAccessPatternId AS VARCHAR(10)), ',')
                    FROM indexing.ColumnAccessPatternResults
                    WHERE ResolvedDate IS NULL
                      AND DatabaseName = @cDB AND SchemaName = @cSchema AND TableName = @cTable;

                    IF @caIds IS NOT NULL
                    BEGIN
                        IF @coveredBy IS NOT NULL AND @ActiveThreshold IS NOT NULL AND ISNULL(@caEstGB, 0) >= @ActiveThreshold
                            SET @cSection = @cSection + @CRLF2
                                + '/* UPDATE DBA_Utilities.indexing.ColumnAccessPatternResults SET ResolvedDate = GETDATE() WHERE ColumnAccessPatternId IN (' + @caIds + '); */' + @CRLF2;
                        ELSE
                            SET @cSection = @cSection + @CRLF2
                                + 'UPDATE DBA_Utilities.indexing.ColumnAccessPatternResults SET ResolvedDate = GETDATE() WHERE ColumnAccessPatternId IN (' + @caIds + ');' + @CRLF2;
                    END

                    SET @Out = @Out + @CRLF2 + '-- === COLUMN ACCESS ===' + @CRLF2 + @cSection;
                END
            END

            FETCH NEXT FROM combined_cursor INTO @cDB, @cSchema, @cTable;
        END

        CLOSE combined_cursor;
        DEALLOCATE combined_cursor;

        -- Count runnable findings (not commented out by @RunnableUnder)
        IF @ActiveThreshold IS NOT NULL
        BEGIN
            -- Duplicate Index: REDUNDANT/DUPLICATE always runnable (DROPs), COMBINE runnable if below threshold
            IF @RunDuplicateIndex = 1 AND OBJECT_ID('indexing.IndexOptimizationResults', 'U') IS NOT NULL
                SELECT @CombinedRunnableCount = @CombinedRunnableCount + COUNT(*)
                FROM indexing.IndexOptimizationResults
                WHERE ResolvedDate IS NULL AND DatabaseName IN (SELECT DatabaseName FROM #AllTables)
                  AND (ActionType <> 'COMBINE' OR ISNULL(EstimatedSizeGB, 0) < @ActiveThreshold);

            -- Key Lookup: runnable if estimated size below threshold
            IF @RunKeyLookup = 1 AND OBJECT_ID('indexing.KeyLookupResults', 'U') IS NOT NULL
                SELECT @CombinedRunnableCount = @CombinedRunnableCount + COUNT(*)
                FROM indexing.KeyLookupResults
                WHERE ResolvedDate IS NULL AND DatabaseName IN (SELECT DatabaseName FROM #AllTables)
                  AND (ISNULL(EstimatedSizeGB, 0) < @ActiveThreshold OR (EstimatedSizeGB IS NULL AND ISNULL(NCIndexSizeKB, 0) < CAST(@ActiveThreshold * 1048576 AS BIGINT)));

            -- Unused Index: always runnable (DISABLE/DROP)
            IF @RunUnusedIndex = 1 AND OBJECT_ID('indexing.UnusedIndexResults', 'U') IS NOT NULL
                SELECT @CombinedRunnableCount = @CombinedRunnableCount + COUNT(*)
                FROM indexing.UnusedIndexResults
                WHERE ResolvedDate IS NULL AND DatabaseName IN (SELECT DatabaseName FROM #AllTables)
                  AND UserUpdates >= @MinUpdateCount AND ObservationDays >= @MinObservDays
                  AND CASE Confidence WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END
                      >= CASE @Confidence WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END;

            -- Missing Index: runnable if below threshold
            IF @RunOptimizeIndex = 1 AND OBJECT_ID('indexing.MissingIndexResults', 'U') IS NOT NULL
                SELECT @CombinedRunnableCount = @CombinedRunnableCount + COUNT(*)
                FROM indexing.MissingIndexResults
                WHERE ResolvedDate IS NULL AND ServerName = @@SERVERNAME
                  AND Strategy NOT IN ('SUPERSET_COVERED')
                  AND DatabaseName IN (SELECT DatabaseName FROM #AllTables)
                  AND ISNULL(EstimatedSizeGB, 0) < @ActiveThreshold;

            -- Expensive Query: runnable if below threshold
            IF @RunExpensiveQuery = 1 AND OBJECT_ID('indexing.ExpensiveQueryResults', 'U') IS NOT NULL
                SELECT @CombinedRunnableCount = @CombinedRunnableCount + COUNT(*)
                FROM indexing.ExpensiveQueryResults
                WHERE ResolvedDate IS NULL AND DatabaseName IN (SELECT DatabaseName FROM #AllTables)
                  AND ISNULL(EstimatedSizeGB, 0) < @ActiveThreshold;

            -- Column Access: runnable if below threshold
            SELECT @CombinedRunnableCount = @CombinedRunnableCount + COUNT(*)
            FROM #CATableRecs
            WHERE CreateStatement IS NOT NULL AND ISNULL(EstimatedSizeGB, 0) < @ActiveThreshold;
        END
        ELSE
            SET @CombinedRunnableCount = (SELECT COUNT(*) FROM #AllTables);

        -- Wrap output for linked server execution if requested
        IF @LinkedServer = 1 AND @Out IS NOT NULL AND LEN(@Out) > 0
        BEGIN
            DECLARE @LSOut NVARCHAR(MAX) = '';
            DECLARE @LSServer NVARCHAR(128) = @@SERVERNAME;
            DECLARE @LSCurrentDB NVARCHAR(128) = '';
            DECLARE @LSLine NVARCHAR(MAX);
            DECLARE @LSIdx INT;
            DECLARE @LSRemain NVARCHAR(MAX) = @Out;
            DECLARE @LSTrim NVARCHAR(MAX);
            DECLARE @LSExecBlock NVARCHAR(MAX) = '';
            DECLARE @LSInExec BIT = 0;
            DECLARE @LSInComment BIT = 0;
            DECLARE @LSAtSuffix NVARCHAR(200) = ''') AT ' + QUOTENAME(@LSServer) + ';' + @CRLF2 + 'GO' + @CRLF2;

            WHILE LEN(@LSRemain) > 0
            BEGIN
                SET @LSIdx = CHARINDEX(@CRLF2, @LSRemain);
                IF @LSIdx = 0
                BEGIN
                    SET @LSLine = @LSRemain;
                    SET @LSRemain = '';
                END
                ELSE
                BEGIN
                    SET @LSLine = LEFT(@LSRemain, @LSIdx - 1);
                    SET @LSRemain = SUBSTRING(@LSRemain, @LSIdx + 2, LEN(@LSRemain));
                END

                SET @LSTrim = LTRIM(@LSLine);

                -- Capture USE [db], skip the line
                IF @LSTrim LIKE 'USE [[]%'
                BEGIN
                    SET @LSCurrentDB = SUBSTRING(@LSTrim, 6, CHARINDEX(']', @LSTrim, 6) - 6);
                    CONTINUE;
                END

                -- Skip standalone GO
                IF @LSTrim = 'GO' CONTINUE;

                -- Detect single-line commented UPDATE: /* UPDATE DBA_Utilities... */
                IF @LSTrim LIKE '/* UPDATE DBA[_]Utilities%*/'
                BEGIN
                    -- Flush any pending exec block first
                    IF @LSInExec = 1
                    BEGIN
                        SET @LSOut = @LSOut + 'EXEC(''USE ' + QUOTENAME(@LSCurrentDB) + '; ' + @LSExecBlock + @LSAtSuffix;
                        SET @LSExecBlock = '';
                        SET @LSInExec = 0;
                    END
                    -- Extract the UPDATE statement from inside /* ... */
                    DECLARE @LSUpdInner NVARCHAR(MAX) = LTRIM(RTRIM(SUBSTRING(@LSTrim, 3, LEN(@LSTrim) - 4)));
                    SET @LSUpdInner = REPLACE(@LSUpdInner, '''', '''''');
                    SET @LSOut = @LSOut + '/* EXEC(''USE ' + QUOTENAME(@LSCurrentDB) + '; ' + @LSUpdInner + @LSAtSuffix + ' */' + @CRLF2;
                    CONTINUE;
                END

                -- Detect uncommented UPDATE DBA_Utilities
                IF @LSTrim LIKE 'UPDATE DBA[_]Utilities%'
                BEGIN
                    IF @LSInExec = 1
                    BEGIN
                        SET @LSOut = @LSOut + 'EXEC(''USE ' + QUOTENAME(@LSCurrentDB) + '; ' + @LSExecBlock + @LSAtSuffix + @CRLF2;
                        SET @LSExecBlock = '';
                        SET @LSInExec = 0;
                    END
                    DECLARE @LSUpdStmt NVARCHAR(MAX) = REPLACE(@LSTrim, '''', '''''');
                    SET @LSOut = @LSOut + 'EXEC(''USE ' + QUOTENAME(@LSCurrentDB) + '; ' + @LSUpdStmt + @LSAtSuffix;
                    CONTINUE;
                END

                -- Track /* comment blocks (for RunnableUnder commented-out statements)
                -- These are blocks that start with /* on its own line (not /****/ separators)
                IF @LSTrim = '/*' AND @LSInComment = 0
                BEGIN
                    IF @LSInExec = 1
                    BEGIN
                        SET @LSOut = @LSOut + 'EXEC(''USE ' + QUOTENAME(@LSCurrentDB) + '; ' + @LSExecBlock + @LSAtSuffix + @CRLF2;
                        SET @LSExecBlock = '';
                        SET @LSInExec = 0;
                    END
                    SET @LSInComment = 1;
                    SET @LSOut = @LSOut + @LSLine + @CRLF2;
                    CONTINUE;
                END

                IF @LSTrim = '*/' AND @LSInComment = 1
                BEGIN
                    IF @LSInExec = 1
                    BEGIN
                        SET @LSOut = @LSOut + 'EXEC(''USE ' + QUOTENAME(@LSCurrentDB) + '; ' + @LSExecBlock + @LSAtSuffix;
                        SET @LSExecBlock = '';
                        SET @LSInExec = 0;
                    END
                    SET @LSInComment = 0;
                    SET @LSOut = @LSOut + @LSLine + @CRLF2;
                    CONTINUE;
                END

                -- Detect start of executable statement (CREATE, ALTER INDEX, DROP INDEX, EXEC sp_rename)
                IF @LSTrim LIKE 'CREATE NONCLUSTERED INDEX%'
                    OR @LSTrim LIKE 'ALTER INDEX%'
                BEGIN
                    IF @LSInExec = 1
                    BEGIN
                        SET @LSOut = @LSOut + 'EXEC(''USE ' + QUOTENAME(@LSCurrentDB) + '; ' + @LSExecBlock + @LSAtSuffix + @CRLF2;
                        SET @LSExecBlock = '';
                    END
                    SET @LSInExec = 1;
                    SET @LSExecBlock = REPLACE(@LSTrim, '''', '''''');
                    CONTINUE;
                END

                -- DROP INDEX outside exec block → start its own exec block
                IF @LSInExec = 0 AND @LSTrim LIKE 'DROP INDEX%'
                BEGIN
                    SET @LSInExec = 1;
                    SET @LSExecBlock = REPLACE(@LSTrim, '''', '''''');
                    CONTINUE;
                END

                -- Inside exec block: continuation lines (ON, INCLUDE, WITH, DROP INDEX, sp_rename)
                IF @LSInExec = 1 AND @LSTrim <> ''
                    AND (@LSTrim LIKE 'ON [[]%' OR @LSTrim LIKE 'INCLUDE (%' OR @LSTrim LIKE 'WITH%(%'
                        OR @LSTrim LIKE 'DROP INDEX%' OR @LSTrim LIKE 'EXEC sp_rename%')
                BEGIN
                    SET @LSExecBlock = @LSExecBlock + CHAR(10) + REPLACE(@LSTrim, '''', '''''');
                    CONTINUE;
                END

                -- Blank line inside exec block → keep accumulating (DROP INDEX may follow)
                IF @LSInExec = 1 AND @LSTrim = ''
                    CONTINUE;

                -- Comment while in exec block → flush the block, then output the comment
                IF @LSInExec = 1 AND @LSTrim LIKE '--%'
                BEGIN
                    SET @LSOut = @LSOut + 'EXEC(''USE ' + QUOTENAME(@LSCurrentDB) + '; ' + @LSExecBlock + @LSAtSuffix + @CRLF2;
                    SET @LSExecBlock = '';
                    SET @LSInExec = 0;
                END

                -- Pass through everything else (comments, separators, blank lines)
                SET @LSOut = @LSOut + @LSLine + @CRLF2;
            END

            -- Flush any trailing exec block
            IF @LSInExec = 1
                SET @LSOut = @LSOut + 'EXEC(''USE ' + QUOTENAME(@LSCurrentDB) + '; ' + @LSExecBlock + @LSAtSuffix;

            SET @Out = @LSOut;
        END

        -- Return combined output as single row
        SELECT
            @@SERVERNAME AS ServerName,
            ISNULL(@DatabaseName, 'ALL') AS DatabaseName,
            GETDATE() AS GeneratedDate,
            CAST((SELECT COUNT(DISTINCT DatabaseName) FROM #AllTables) AS VARCHAR(10)) + ' databases, '
                + CAST((SELECT COUNT(*) FROM #AllTables) AS VARCHAR(10)) + ' tables' AS [Statistics],
            CASE WHEN (SELECT COUNT(*) FROM #AllTables) = 0 THEN 'No Recommendations'
                 WHEN @CombinedRunnableCount = 0 THEN 'Nothing To Run Under Parameter'
                 ELSE 'Has Recommendations'
            END AS Status,
            CASE WHEN (SELECT COUNT(*) FROM #AllTables) > 0 THEN @Out ELSE NULL END AS ScriptText;
    END

END
GO


-- ==========================================================================
-- INSTALLATION COMPLETE
-- ==========================================================================
PRINT '';
PRINT '=============================================='
PRINT 'Index Optimization Suite installed successfully.'
PRINT '=============================================='
GO
