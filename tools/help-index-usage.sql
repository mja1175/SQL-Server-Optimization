-- ==========================================================================
-- help-index-usage: sp_helpindexUsage dependency chain
-- Installs to master (procs) and DBA_Utilities (table)
-- ==========================================================================

-- Table: dbo.IndexUsageTemp (DBA_Utilities)
USE DBA_Utilities;
GO

IF OBJECT_ID('dbo.IndexUsageTemp', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IndexUsageTemp
( DatabaseName VARCHAR(128) NOT NULL
  ,TableName VARCHAR(128) NULL
  ,index_id INT NOT NULL
  ,IndexName NVARCHAR(128) NOT NULL
  ,index_keys NVARCHAR(400) NOT NULL 
  ,included_columns NVARCHAR(MAX) NULL 
  ,SizeKB INT NOT NULL
  ,UserSeeks BIGINT NULL
  ,UserScans BIGINT NULL
  ,UserLookups BIGINT NULL
  ,UserReads BIGINT NULL
  ,UserWrites BIGINT NULL
  ,ReadWriteDiff BIGINT NULL
  ,Fill_Factor INT NULL
  ,filter_definition NVARCHAR(300) NULL 
  ,LastUserSeek DATETIME NULL 
  ,LastUserScan DATETIME NULL
  ,LastUserLookup DATETIME NULL
  ,LastUserUpdate DATETIME NULL
  ,is_disabled BIT NOT NULL
  ,index_description NVARCHAR(300) NOT NULL
  ,columns_in_tree NVARCHAR(MAX) NOT NULL 
  ,columns_in_leaf NVARCHAR(MAX) NOT NULL
  ,InsertDate DATETIME2(3) NOT NULL CONSTRAINT DF_IndexUsageTemp_InsertDate DEFAULT (GETDATE())
  ,IndexUsageTempId INT NOT NULL IDENTITY(1,1)
 ,CONSTRAINT PK_IndexUsageTemp PRIMARY KEY CLUSTERED (IndexUsageTempId ASC)  WITH(FILLFACTOR = 100)ON [PRIMARY]);
END
GO

-- Procs: installed in master, marked as system objects
USE master;
GO

-- ==========================================================================
-- Proc: sp_ExposeColsInIndexLevels (dependency for sp_helpindex2)
-- ==========================================================================

/*============================================================================
  File:     sp_SQLskills_ExposeColsInIndexLevels

  Summary:  This procedure lists columns in the key vs. those in the leaf level
			of a nonclustered index. This is dependent on whether or not the 
			nonclustered is UNIQUE as well as whether or not the table has a 
			clustered index. It also changes based on whether or not the 
			clustering key is UNIQUE.
			
  Date:     May 2010

  Version:	SQL Server 2005/2008
------------------------------------------------------------------------------
  Written by Paul S. Randal and Kimberly L. Tripp, SQLskills.com

  For more scripts and sample code, check out 
    http://www.SQLskills.com

============================================================================*/

--USE master;
GO

CREATE OR ALTER PROCEDURE sp_ExposeColsInIndexLevels
(
  @object_id INT
 ,@index_id INT
 ,@ColsInTree NVARCHAR(2126) OUTPUT
 ,@ColsInLeaf NVARCHAR(MAX) OUTPUT)
AS
  BEGIN
    DECLARE @nonclus_uniq   INT
           ,@column_id      INT
           ,@column_name    NVARCHAR(260)
           ,@col_descending BIT
           ,@colstr         NVARCHAR(MAX);

    -- Get clustered index keys (id and name)
    SELECT sic.column_id
          ,QUOTENAME(sc.name, N']') AS column_name
          ,sic.is_descending_key
    INTO #clus_keys
    FROM sys.index_columns AS sic
         JOIN sys.columns AS sc ON sic.column_id = sc.column_id
                                   AND sc.object_id = sic.object_id
    WHERE sic.object_id = @object_id
          AND sic.index_id = 1;

    -- Get nonclustered index keys
    SELECT sic.column_id
          ,sic.is_included_column
          ,QUOTENAME(sc.name, N']') AS column_name
          ,sic.is_descending_key
    INTO #nonclus_keys
    FROM sys.index_columns AS sic
         JOIN sys.columns AS sc ON sic.column_id = sc.column_id
                                   AND sc.object_id = sic.object_id
    WHERE sic.object_id = @object_id
          AND sic.index_id = @index_id;

    -- Is the nonclustered unique?
    SELECT @nonclus_uniq = indexes.is_unique
    FROM sys.indexes
    WHERE indexes.object_id = @object_id
          AND indexes.index_id = @index_id;

    IF (@nonclus_uniq = 0)
      BEGIN
        -- Case 1: nonunique nonclustered index

        -- cursor for nonclus columns not included and
        -- nonclus columns included but also clus keys
        DECLARE mycursor CURSOR FOR
          SELECT #nonclus_keys.column_id
                ,#nonclus_keys.column_name
                ,#nonclus_keys.is_descending_key
          FROM #nonclus_keys
          WHERE #nonclus_keys.is_included_column = 0;
        OPEN mycursor;
        FETCH NEXT FROM mycursor
        INTO @column_id
            ,@column_name
            ,@col_descending;
        WHILE @@FETCH_STATUS = 0
          BEGIN
            SELECT @colstr = ISNULL(@colstr, N'') + @column_name
                             + CASE WHEN @col_descending = 1 THEN '(-)' ELSE N'' END + N', ';
            FETCH NEXT FROM mycursor
            INTO @column_id
                ,@column_name
                ,@col_descending;
          END;
        CLOSE mycursor;
        DEALLOCATE mycursor;

        -- cursor over clus_keys if clustered
        DECLARE mycursor CURSOR FOR
          SELECT #clus_keys.column_id
                ,#clus_keys.column_name
                ,#clus_keys.is_descending_key
          FROM #clus_keys
          WHERE #clus_keys.column_id NOT IN (SELECT #nonclus_keys.column_id
                                             FROM #nonclus_keys
                                             WHERE #nonclus_keys.is_included_column = 0);
        OPEN mycursor;
        FETCH NEXT FROM mycursor
        INTO @column_id
            ,@column_name
            ,@col_descending;
        WHILE @@FETCH_STATUS = 0
          BEGIN
            SELECT @colstr = ISNULL(@colstr, N'') + @column_name
                             + CASE WHEN @col_descending = 1 THEN '(-)' ELSE N'' END + N', ';
            FETCH NEXT FROM mycursor
            INTO @column_id
                ,@column_name
                ,@col_descending;
          END;
        CLOSE mycursor;
        DEALLOCATE mycursor;

        SELECT @ColsInTree = SUBSTRING(@colstr, 1, LEN(@colstr) - 1);

        -- find columns not in the nc and not in cl - that are still left to be included.
        DECLARE mycursor CURSOR FOR
          SELECT #nonclus_keys.column_id
                ,#nonclus_keys.column_name
                ,#nonclus_keys.is_descending_key
          FROM #nonclus_keys
          WHERE #nonclus_keys.column_id NOT IN (SELECT #clus_keys.column_id
                                                FROM #clus_keys
                                                UNION
                                                SELECT column_id
                                                FROM #nonclus_keys
                                                WHERE is_included_column = 0);
        OPEN mycursor;
        FETCH NEXT FROM mycursor
        INTO @column_id
            ,@column_name
            ,@col_descending;
        WHILE @@FETCH_STATUS = 0
          BEGIN
            SELECT @colstr = ISNULL(@colstr, N'') + @column_name
                             + CASE WHEN @col_descending = 1 THEN '(-)' ELSE N'' END + N', ';
            FETCH NEXT FROM mycursor
            INTO @column_id
                ,@column_name
                ,@col_descending;
          END;
        CLOSE mycursor;
        DEALLOCATE mycursor;

        SELECT @ColsInLeaf = SUBSTRING(@colstr, 1, LEN(@colstr) - 1);

      END;

    -- Case 2: unique nonclustered
    ELSE
      BEGIN
        -- cursor over nonclus_keys that are not includes
        SELECT @colstr = N'';
        DECLARE mycursor CURSOR FOR
          SELECT #nonclus_keys.column_id
                ,#nonclus_keys.column_name
                ,#nonclus_keys.is_descending_key
          FROM #nonclus_keys
          WHERE #nonclus_keys.is_included_column = 0;
        OPEN mycursor;
        FETCH NEXT FROM mycursor
        INTO @column_id
            ,@column_name
            ,@col_descending;
        WHILE @@FETCH_STATUS = 0
          BEGIN
            SELECT @colstr = ISNULL(@colstr, N'') + @column_name
                             + CASE WHEN @col_descending = 1 THEN '(-)' ELSE N'' END + N', ';
            FETCH NEXT FROM mycursor
            INTO @column_id
                ,@column_name
                ,@col_descending;
          END;
        CLOSE mycursor;
        DEALLOCATE mycursor;

        SELECT @ColsInTree = SUBSTRING(@colstr, 1, LEN(@colstr) - 1);

        -- start with the @ColsInTree and add remaining columns not present...
        DECLARE mycursor CURSOR FOR
          SELECT #nonclus_keys.column_id
                ,#nonclus_keys.column_name
                ,#nonclus_keys.is_descending_key
          FROM #nonclus_keys
          WHERE #nonclus_keys.is_included_column = 1;
        OPEN mycursor;
        FETCH NEXT FROM mycursor
        INTO @column_id
            ,@column_name
            ,@col_descending;
        WHILE @@FETCH_STATUS = 0
          BEGIN
            SELECT @colstr = ISNULL(@colstr, N'') + @column_name
                             + CASE WHEN @col_descending = 1 THEN '(-)' ELSE N'' END + N', ';
            FETCH NEXT FROM mycursor
            INTO @column_id
                ,@column_name
                ,@col_descending;
          END;
        CLOSE mycursor;
        DEALLOCATE mycursor;

        -- get remaining clustered column as long as they're not already in the nonclustered
        DECLARE mycursor CURSOR FOR
          SELECT #clus_keys.column_id
                ,#clus_keys.column_name
                ,#clus_keys.is_descending_key
          FROM #clus_keys
          WHERE #clus_keys.column_id NOT IN (SELECT #nonclus_keys.column_id
                                             FROM #nonclus_keys);
        OPEN mycursor;
        FETCH NEXT FROM mycursor
        INTO @column_id
            ,@column_name
            ,@col_descending;
        WHILE @@FETCH_STATUS = 0
          BEGIN
            SELECT @colstr = ISNULL(@colstr, N'') + @column_name
                             + CASE WHEN @col_descending = 1 THEN '(-)' ELSE N'' END + N', ';
            FETCH NEXT FROM mycursor
            INTO @column_id
                ,@column_name
                ,@col_descending;
          END;
        CLOSE mycursor;
        DEALLOCATE mycursor;

        SELECT @ColsInLeaf = SUBSTRING(@colstr, 1, LEN(@colstr) - 1);
        SELECT @colstr = N'';

      END;
    -- Cleanup
    DROP TABLE #clus_keys;
    DROP TABLE #nonclus_keys;

  END;
GO

EXEC sys.sp_MS_marksystemobject 'sp_ExposeColsInIndexLevels';
GO

-- ==========================================================================
-- Proc: sp_helpindex2 (dependency for sp_helpindexUsage)
-- ==========================================================================

/*============================================================================
  File:     sp_SQLskills_helpindex.sql

  Summary:  So, what are the included columns?! Do you have a filter?
			This is a MODIFIED sp_helpindex script that includes:
               - Index IDs
               - INCLUDEd columns
               - Filtered index columns
               - Leaf/tree details for rowstore indexes
               - Columns defined for columnstore indexes
            Additional details:
               - whether or not the index is disabled
               - Index usage stats

  Date:     February 2016

  Version:  Works on 2008R2 - 2016 (requires: sp_SQLskills_ExposeColsInIndexLevels)
------------------------------------------------------------------------------
  Written by Kimberly L. Tripp, SYSolutions, Inc.

  For more scripts and sample code, check out 
    http://www.SQLskills.com

============================================================================*/

--USE master;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.sp_helpindex2 @objname NVARCHAR(776) -- the table to check for indexes
AS

  SET NOCOUNT ON;

  DECLARE @objid             INT -- the object id of the table
         ,@indid             SMALLINT -- the index id of an index
         ,@type              TINYINT -- the index type
         ,@groupid           INT -- the filegroup id of an index
         ,@indname           sysname
         ,@groupname         sysname
         ,@status            INT
         ,@keys              NVARCHAR(2126) --Length (16*max_identifierLength)+(15*2)+(16*3)
         ,@inc_columns       NVARCHAR(MAX)
         ,@inc_Count         SMALLINT
         ,@loop_inc_Count    SMALLINT
         ,@dbname            sysname
         ,@ignore_dup_key    BIT
         ,@is_unique         BIT
         ,@is_hypothetical   BIT
         ,@is_primary_key    BIT
         ,@is_unique_key     BIT
         ,@is_disabled       BIT
         ,@auto_created      BIT
         ,@no_recompute      BIT
         ,@filter_definition NVARCHAR(MAX)
         ,@ColsInTree        NVARCHAR(2126)
         ,@ColsInLeaf        NVARCHAR(MAX)
         ,@ExecStr           NVARCHAR(MAX);

  -- Check to see that the object names are local to the current database.
  SELECT @dbname = PARSENAME(@objname, 3);
  IF @dbname IS NULL
    SELECT @dbname = DB_NAME();
  ELSE IF @dbname <> DB_NAME()
         BEGIN
           RAISERROR(15250, -1, -1);
           RETURN (1);
         END;

  -- Check to see the the table exists and initialize @objid.
  SELECT @objid = OBJECT_ID(@objname);
  IF @objid IS NULL
    BEGIN
      RAISERROR(15009, -1, -1, @objname, @dbname);
      RETURN (1);
    END;

  -- OPEN CURSOR OVER INDEXES (skip stats: bug shiloh_51196)
  DECLARE ms_crs_ind CURSOR LOCAL STATIC FOR
    SELECT i.index_id
          ,i.type
          ,i.data_space_id
          ,QUOTENAME(i.name, N']') AS name
          ,i.ignore_dup_key
          ,i.is_unique
          ,i.is_hypothetical
          ,i.is_primary_key
          ,i.is_unique_constraint
          ,s.auto_created
          ,s.no_recompute
          ,i.filter_definition
          ,i.is_disabled
    FROM sys.indexes AS i
         JOIN sys.stats AS s ON i.object_id = s.object_id
                                AND i.index_id = s.stats_id
    WHERE i.object_id = @objid;
  OPEN ms_crs_ind;
  FETCH ms_crs_ind
  INTO @indid
      ,@type
      ,@groupid
      ,@indname
      ,@ignore_dup_key
      ,@is_unique
      ,@is_hypothetical
      ,@is_primary_key
      ,@is_unique_key
      ,@auto_created
      ,@no_recompute
      ,@filter_definition
      ,@is_disabled;

  -- IF NO INDEX, QUIT
  IF @@fetch_status < 0
    BEGIN
      DEALLOCATE ms_crs_ind;
      RAISERROR(15472, -1, -1, @objname); -- Object does not have any indexes.
      RETURN (0);
    END;

  -- create temp tables
  CREATE TABLE #spindtab
  ( index_name sysname COLLATE DATABASE_DEFAULT NOT NULL
   ,index_id INT
   ,type TINYINT
   ,ignore_dup_key BIT
   ,is_unique BIT
   ,is_hypothetical BIT
   ,is_primary_key BIT
   ,is_unique_key BIT
   ,is_disabled BIT
   ,auto_created BIT
   ,no_recompute BIT
   ,groupname sysname COLLATE DATABASE_DEFAULT NULL
   ,index_keys NVARCHAR(2126) COLLATE DATABASE_DEFAULT NULL -- see @keys above for length descr
   ,filter_definition NVARCHAR(MAX)
   ,inc_Count SMALLINT
   ,inc_columns NVARCHAR(MAX)
   ,cols_in_tree NVARCHAR(2126)
   ,cols_in_leaf NVARCHAR(MAX));

  CREATE TABLE #IncludedColumns
  ( RowNumber SMALLINT
   ,Name NVARCHAR(128));

  -- Now check out each index, figure out its type and keys and
  --	save the info in a temporary table that we'll print out at the end.
  WHILE @@fetch_status >= 0
    BEGIN
      -- First we'll figure out what the keys are.
      DECLARE @i       INT
             ,@thiskey NVARCHAR(131); -- 128+3

      SELECT @keys = QUOTENAME(INDEX_COL(@objname, @indid, 1), N']')
            ,@i = 2;
      IF (INDEXKEY_PROPERTY(@objid, @indid, 1, 'isdescending') = 1)
        SELECT @keys = @keys + N'(-)';

      SELECT @thiskey = QUOTENAME(INDEX_COL(@objname, @indid, @i), N']');
      IF ((@thiskey IS NOT NULL)
          AND (INDEXKEY_PROPERTY(@objid, @indid, @i, 'isdescending') = 1))
        SELECT @thiskey = @thiskey + N'(-)';

      WHILE (@thiskey IS NOT NULL)
        BEGIN
          SELECT @keys = @keys + N', ' + @thiskey
                ,@i = @i + 1;
          SELECT @thiskey = QUOTENAME(INDEX_COL(@objname, @indid, @i), N']');
          IF ((@thiskey IS NOT NULL)
              AND (INDEXKEY_PROPERTY(@objid, @indid, @i, 'isdescending') = 1))
            SELECT @thiskey = @thiskey + N'(-)';
        END;

      -- Second, we'll figure out what the included columns are.
      SELECT @inc_columns = NULL;

      SELECT @inc_Count = COUNT(*)
      FROM sys.tables AS tbl
           INNER JOIN sys.indexes AS si ON (si.index_id > 0
                                            AND si.is_hypothetical = 0)
                                           AND (si.object_id = tbl.object_id)
           INNER JOIN sys.index_columns AS ic ON (ic.column_id > 0
                                                  AND (ic.key_ordinal > 0
                                                       OR ic.partition_ordinal = 0
                                                       OR ic.is_included_column != 0))
                                                 AND (ic.index_id = CAST(si.index_id AS INT)
                                                      AND ic.object_id = si.object_id)
           INNER JOIN sys.columns AS clmns ON clmns.object_id = ic.object_id
                                              AND clmns.column_id = ic.column_id
      WHERE ic.is_included_column = 1
            AND (si.index_id = @indid)
            AND (tbl.object_id = @objid);

      IF @inc_Count > 0
        BEGIN
          DELETE FROM #IncludedColumns;
          INSERT #IncludedColumns
          SELECT ROW_NUMBER() OVER (ORDER BY clmns.column_id)
                ,clmns.name
          FROM sys.tables AS tbl
               INNER JOIN sys.indexes AS si ON (si.index_id > 0
                                                AND si.is_hypothetical = 0)
                                               AND (si.object_id = tbl.object_id)
               INNER JOIN sys.index_columns AS ic ON (ic.column_id > 0
                                                      AND (ic.key_ordinal > 0
                                                           OR ic.partition_ordinal = 0
                                                           OR ic.is_included_column != 0))
                                                     AND (ic.index_id = CAST(si.index_id AS INT)
                                                          AND ic.object_id = si.object_id)
               INNER JOIN sys.columns AS clmns ON clmns.object_id = ic.object_id
                                                  AND clmns.column_id = ic.column_id
          WHERE ic.is_included_column = 1
                AND (si.index_id = @indid)
                AND (tbl.object_id = @objid);

          SELECT @inc_columns = QUOTENAME(#IncludedColumns.Name, N']')
          FROM #IncludedColumns
          WHERE #IncludedColumns.RowNumber = 1;

          SET @loop_inc_Count = 1;

          WHILE @loop_inc_Count < @inc_Count
            BEGIN
              SELECT @inc_columns = @inc_columns + N', ' + QUOTENAME(#IncludedColumns.Name, N']')
              FROM #IncludedColumns
              WHERE #IncludedColumns.RowNumber = @loop_inc_Count + 1;
              SET @loop_inc_Count = @loop_inc_Count + 1;
            END;
        END;

      SELECT @groupname = NULL;

      SELECT @groupname = data_spaces.name
      FROM sys.data_spaces
      WHERE data_spaces.data_space_id = @groupid;

      -- Get the column list for the tree and leaf level, for all nonclustered indexes IF 
      -- the table has a clustered index

      -- Clustered index is non-unique
      IF @indid = 1
         AND (SELECT indexes.is_unique
              FROM sys.indexes
              WHERE indexes.index_id = 1
                    AND indexes.object_id = @objid) = 0
        SELECT @ColsInTree = @keys + N', UNIQUIFIER'
              ,@ColsInLeaf = N'All columns "included" - the leaf level IS the data row, plus the UNIQUIFIER';

      -- Clustered index AND is unique
      IF @indid = 1
         AND (SELECT indexes.is_unique
              FROM sys.indexes
              WHERE indexes.index_id = 1
                    AND indexes.object_id = @objid) = 1
        SELECT @ColsInTree = @keys
              ,@ColsInLeaf = N'All columns "included" - the leaf level IS the data row.';

      -- Only run this for nonclustered indexes
      IF @indid > 1
        EXEC sp_ExposeColsInIndexLevels @objid
                                        ,@indid
                                        ,@ColsInTree OUTPUT
                                        ,@ColsInLeaf OUTPUT;

      -- Nonclustered, non-unique index with non-unique clustered ROWSTORE (type = 1) index
      IF @indid > 1
         AND @is_unique = 0
         AND (SELECT indexes.is_unique
              FROM sys.indexes
              WHERE indexes.index_id = 1
                    AND indexes.type = 1
                    AND indexes.object_id = @objid) = 0
        SELECT @ColsInTree = @ColsInTree + N', UNIQUIFIER'
              ,@ColsInLeaf = @ColsInLeaf + N', UNIQUIFIER';

      -- Nonclustered, unique index with non-unique clustered ROWSTORE (type = 1) index
      IF @indid > 1
         AND @is_unique = 1
         AND (SELECT indexes.is_unique
              FROM sys.indexes
              WHERE indexes.index_id = 1
                    AND indexes.type = 1
                    AND indexes.object_id = @objid) = 0
        SELECT @ColsInLeaf = @ColsInLeaf + N', UNIQUIFIER';

      -- Nonclustered rowstore on a heap
      IF (@indid > 1
          AND @type = 2)
         AND (SELECT COUNT(*)
              FROM sys.indexes
              WHERE indexes.index_id = 1
                    AND indexes.object_id = @objid) = 0 -- table is a HEAP
        BEGIN
          IF (@is_unique_key = 0)
            SELECT @ColsInTree = @keys + N', RID'
                  ,@ColsInLeaf = @keys + N', RID'
                                 + CASE WHEN @inc_columns IS NOT NULL THEN N', ' + @inc_columns ELSE N'' END;

          IF (@is_unique_key = 1)
            SELECT @ColsInTree = @keys
                  ,@ColsInLeaf = @keys + N', RID'
                                 + CASE WHEN @inc_columns IS NOT NULL THEN N', ' + @inc_columns ELSE N'' END;
        END;

      INSERT INTO #spindtab
      VALUES
      (@indname, @indid, @type, @ignore_dup_key, @is_unique, @is_hypothetical, @is_primary_key, @is_unique_key
      ,@is_disabled, @auto_created, @no_recompute, @groupname, @keys, @filter_definition, @inc_Count, @inc_columns
      ,@ColsInTree, @ColsInLeaf);

      -- Next index
      FETCH ms_crs_ind
      INTO @indid
          ,@type
          ,@groupid
          ,@indname
          ,@ignore_dup_key
          ,@is_unique
          ,@is_hypothetical
          ,@is_primary_key
          ,@is_unique_key
          ,@auto_created
          ,@no_recompute
          ,@filter_definition
          ,@is_disabled;
    END;
  DEALLOCATE ms_crs_ind;

  -- DISPLAY THE RESULTS

  -- Query by version
  IF CONVERT(SMALLINT, SUBSTRING(CONVERT(VARCHAR(50), SERVERPROPERTY('ProductVersion')), 1, 2)) < 16
    SELECT @ExecStr = N'select ' + N'''index_id'' = index_id,              '
                      + N'''is_disabled'' = is_disabled,        ' + N'''index_name'' = index_name,          '
                      + N'''index_description'' =               '
                      + N' convert(varchar(210), ' --bits 16 off, 1, 2, 16777216 on, located on group   '
                      + N'   case when index_id = 1 and type = 1 then ''clustered''                   '
                      + N'       when index_id = 1 and type = 5 then ''clustered, columnstore''       '
                      + N'       when index_id > 1 and type = 2 then ''nonclustered''    '
                      + N'       when index_id > 1 and type = 6 then ''nonclustered, columnstore''    '
                      + N'       when index_id > 1 and type = 7 then ''nonclustered, HASH''    '
                      + N'   else ''new index type'' end                                              '
                      + N'   + case when ignore_dup_key <>0 then '', ignore duplicate keys'' else '''' end '
                      + N'   + case when is_unique=1 then '', unique'' else '''' end                       '
                      + N'   + case when is_hypothetical <>0 then '', hypothetical'' else '''' end         '
                      + N'   + case when is_primary_key <>0 then '', primary key'' else '''' end           '
                      + N'   + case when is_unique_key <>0 then '', unique key'' else '''' end             '
                      + N'   + case when auto_created <>0 then '', auto create'' else '''' end             '
                      + N'   + case when no_recompute <>0 then '', stats no recompute'' else '''' end      '
                      + N'   + case when groupname IS NOT NULL then '' located on '' + groupname else '''' end),  '
                      + N'''index_keys'' = 
			          case when type IN (5, 6) then ''n/a, see columns_in_leaf for details''
			          else index_keys end,
		           ''included_columns'' = 
			          case when type IN (5, 6) then ''n/a, columnstore index''
                           when type = 7 then ''n/a, HASH''
			          else inc_columns end,
		           ''filter_definition'' = 
			          case when type IN (5, 6) then ''n/a, columnstore index''
                           when type = 7 then ''n/a, HASH''
			          else filter_definition end,
		           ''columns_in_tree'' = 
			          case when type IN (5, 6) then ''n/a, columnstore index''
                           when type = 7 then ''n/a, HASH''
			          else cols_in_tree end,
		           ''columns_in_leaf'' = 
			          case when type IN (5, 6) then ''Columns with columnstore index: '' + cols_in_leaf
                            when type = 7 then ''n/a, HASH''
			          else cols_in_leaf end 

	        from #spindtab
	        order by index_id ';

  IF CONVERT(SMALLINT, SUBSTRING(CONVERT(VARCHAR(50), SERVERPROPERTY('ProductVersion')), 1, 2)) >= 16
    SELECT @ExecStr = N'select ' + N'''index_id'' = index_id,              '
                      + N'''is_disabled'' = is_disabled,        ' + N'''index_name'' = index_name,          '
                      + N'''index_description'' =               '
                      + N' convert(varchar(210), ' --bits 16 off, 1, 2, 16777216 on, located on group   '
                      + N'   case when index_id = 1 and type = 1 then ''clustered''                   '
                      + N'       when index_id = 1 and type = 5 then ''clustered, columnstore''       '
                      + N'       when index_id > 1 and type = 2 then ''nonclustered''    '
                      + N'       when index_id > 1 and type = 6 then ''nonclustered, columnstore''    '
                      + N'       when index_id > 1 and type = 7 then ''nonclustered, HASH''    '
                      + N'   else ''new index type'' end                                              '
                      + N'   + case when ignore_dup_key <>0 then '', ignore duplicate keys'' else '''' end '
                      + N'   + case when is_unique=1 then '', unique'' else '''' end                       '
                      + N'   + case when is_hypothetical <>0 then '', hypothetical'' else '''' end         '
                      + N'   + case when is_primary_key <>0 then '', primary key'' else '''' end           '
                      + N'   + case when is_unique_key <>0 then '', unique key'' else '''' end             '
                      + N'   + case when auto_created <>0 then '', auto create'' else '''' end             '
                      + N'   + case when no_recompute <>0 then '', stats no recompute'' else '''' end      '
                      + N'   + case when memory_optimized = 1 then '' located in MEMORY '' else '''' end   '
                      + N'   + case when groupname IS NOT NULL AND 
                                    (memory_optimized = 0 OR memory_optimized IS NULL) 
                                    then '' located on '' + groupname else '''' end),  '
                      + N'''index_keys'' = 
			          case when type IN (5, 6) then ''n/a, see columns_in_leaf for details''
			          else index_keys end,
		           ''included_columns'' = 
			          case when type IN (5, 6) then ''n/a, columnstore index''
                           when type = 7 then ''n/a, HASH''
			          else inc_columns end,
		           ''filter_definition'' = 
			          case when type IN (5, 6) then ''n/a, columnstore index''
                           when type = 7 then ''n/a, HASH''
			          else filter_definition end,
		           ''columns_in_tree'' = 
			          case when type IN (5, 6) then ''n/a, columnstore index''
                           when type = 7 then ''n/a, HASH''
			          else cols_in_tree end,
		           ''columns_in_leaf'' = 
			          case when type IN (5, 6) then ''Columns with columnstore index: '' + cols_in_leaf
                            when type = 7 then ''n/a, HASH''
			          else cols_in_leaf end 

	        from #spindtab
	        order by index_id ';

  EXEC (@ExecStr);

  RETURN (0); 
GO

EXEC sys.sp_MS_marksystemobject 'sp_helpindex2';
GO

-- ==========================================================================
-- Proc: sp_helpindexUsage (main entry point)
-- ==========================================================================

CREATE OR ALTER PROCEDURE dbo.sp_helpindexUsage
  @TableName NVARCHAR(128)
 ,@IndexName NVARCHAR(300) = ''
 ,@OutPut    INT           = 0
AS
  BEGIN
    SET NOCOUNT ON;
    DECLARE @i      INT
           ,@sql    VARCHAR(MAX)
           ,@DBName VARCHAR(128);

    DROP TABLE IF EXISTS #DBs;
    CREATE TABLE #DBs
      (DataBaseName VARCHAR(128) NOT NULL
      ,rn           INT          NOT NULL);

    IF @OutPut = 1
      BEGIN
        INSERT INTO #DBs (DataBaseName, rn)
        SELECT d.name
              ,ROW_NUMBER() OVER (ORDER BY d.name) AS rn
        FROM sys.databases AS d
        WHERE 1 = 1
              AND d.database_id > 4
              AND d.state = 0;
      END;

    IF @OutPut IN (0, 2)
      BEGIN
        INSERT INTO #DBs (DataBaseName, rn)
        SELECT d.name
              ,ROW_NUMBER() OVER (ORDER BY d.name) AS rn
        FROM sys.databases AS d
        WHERE 1 = 1
              AND d.database_id = DB_ID();

        DROP TABLE IF EXISTS #Index;
        CREATE TABLE #Index
          (index_id          INT           NOT NULL
          ,is_disabled       BIT           NOT NULL
          ,index_name        NVARCHAR(128) NOT NULL
          ,index_description NVARCHAR(300) NOT NULL
          ,index_keys        NVARCHAR(400) NOT NULL
          ,included_columns  NVARCHAR(MAX) NULL
          ,filter_definition NVARCHAR(300) NULL
          ,columns_in_tree   NVARCHAR(MAX) NOT NULL
          ,columns_in_leaf   NVARCHAR(MAX) NOT NULL);

        INSERT INTO #Index (index_id
                           ,is_disabled
                           ,index_name
                           ,index_description
                           ,index_keys
                           ,included_columns
                           ,filter_definition
                           ,columns_in_tree
                           ,columns_in_leaf)
        EXEC dbo.sp_helpindex2 @objname = @TableName;

        DROP TABLE IF EXISTS #size;
        CREATE TABLE #size
          (index_id   INT           NOT NULL
          ,index_name NVARCHAR(128) NOT NULL
          ,SizeKB     INT           NOT NULL
          ,Comments   NVARCHAR(MAX) NOT NULL);

        INSERT INTO #size (index_id, index_name, SizeKB, Comments)
        EXEC sys.sp_MSindexspace @TableName;
      END;

    DROP TABLE IF EXISTS #Results;
    CREATE TABLE #Results
      (DatabaseName   VARCHAR(128)  NOT NULL
      ,TableName      NVARCHAR(128) NOT NULL
      ,index_id       INT           NOT NULL
      ,IndexName      NVARCHAR(128) NOT NULL
      ,IndexType      VARCHAR(300)  NOT NULL
      ,Fill_Factor    INT           NOT NULL
      ,UserSeeks      BIGINT        NULL
      ,UserScans      BIGINT        NULL
      ,UserLookups    BIGINT        NULL
      ,UserReads      BIGINT        NULL
      ,UserWrites     BIGINT        NULL
      ,ReadWriteDiff  BIGINT        NULL
      ,LastUserSeek   DATETIME      NULL
      ,LastUserScan   DATETIME      NULL
      ,LastUserLookup DATETIME      NULL
      ,LastUserUpdate DATETIME      NULL);

    SELECT @i = MAX(#DBs.rn)
    FROM #DBs
    WHERE 1 = 1;

    WHILE @i > 0
      BEGIN
        SELECT @DBName = #DBs.DataBaseName
        FROM #DBs
        WHERE 1 = 1
              AND @i = #DBs.rn;

        SET @sql = CONCAT('USE [',@DBName,']',CHAR(10)
                    ,'INSERT INTO #Results (DatabaseName,TableName,index_id,IndexName,IndexType,Fill_Factor,UserSeeks,UserScans,UserLookups,UserReads,UserWrites,ReadWriteDiff,LastUserSeek,LastUserScan,LastUserLookup,LastUserUpdate)
    SELECT DB_NAME(DB_ID()) 
          ,OBJECT_NAME(i.object_id)
          ,i.index_id
          ,ISNULL(i.name, ''HEAP'') 
          ,i.type_desc AS IndexType
          ,i.fill_factor
          ,s.user_seeks 
          ,s.user_scans 
          ,s.user_lookups 
          ,s.user_seeks + s.user_scans + s.user_lookups
          ,s.user_updates 
          ,(s.user_seeks + s.user_scans + s.user_lookups) - s.user_updates
          ,s.last_user_seek 
          ,s.last_user_scan 
          ,s.last_user_lookup 
          ,s.last_user_update 
    FROM sys.dm_db_index_usage_stats AS s
         INNER JOIN sys.indexes AS i ON s.object_id = i.object_id
                                        AND i.index_id = s.index_id
    WHERE 1 =1 
          AND OBJECTPROPERTY(s.object_id, ''IsUserTable'') = 1
          AND s.database_id = DB_ID()
          AND i.object_id = OBJECT_ID(''',@TableName,''')');

        EXEC (@sql);

        SET @i = @i - 1;

      END;

    IF @OutPut = 0
      BEGIN
        SELECT i.index_id
              ,i.index_name AS IndexName
              ,i.index_keys
              ,i.included_columns
              ,s.SizeKB
              ,#Results.UserSeeks
              ,#Results.UserScans
              ,#Results.UserLookups
              ,#Results.UserReads
              ,#Results.UserWrites
              ,#Results.ReadWriteDiff
              ,#Results.Fill_Factor
              ,i.filter_definition
              ,#Results.LastUserSeek
              ,#Results.LastUserScan
              ,#Results.LastUserLookup
              ,#Results.LastUserUpdate
              ,i.is_disabled
              ,DB_NAME() AS DatabaseName
              ,#Results.TableName
              ,i.index_description
              ,i.columns_in_tree
              ,i.columns_in_leaf
        FROM #Index AS i
             LEFT OUTER JOIN #Results ON i.index_id = #Results.index_id
             INNER JOIN #size AS s ON s.index_id = i.index_id
        WHERE 1 = 1
              AND ( @IndexName = ''
                    OR i.index_name = QUOTENAME(@IndexName))
        ORDER BY i.index_id;
      END;
    ELSE IF @OutPut = 1
      BEGIN
        SELECT #Results.DatabaseName
              ,#Results.index_id
              ,#Results.IndexName
              ,#Results.Fill_Factor
              ,#Results.UserSeeks
              ,#Results.UserScans
              ,#Results.UserLookups
              ,#Results.UserReads
              ,#Results.UserWrites
              ,#Results.ReadWriteDiff
              ,#Results.LastUserSeek
              ,#Results.LastUserScan
              ,#Results.LastUserLookup
              ,#Results.LastUserUpdate
              ,#Results.IndexType
              ,#Results.TableName
        FROM #Results
        WHERE 1 = 1
              AND ( @IndexName = ''
                    OR IndexName = @IndexName)
        ORDER BY
          #Results.DatabaseName
         ,#Results.index_id;
      END;
    ELSE IF @OutPut = 2
      BEGIN
        INSERT INTO DBA_Utilities.dbo.IndexUsageTemp (index_id
                                                     ,IndexName
                                                     ,index_keys
                                                     ,included_columns
                                                     ,SizeKB
                                                     ,UserSeeks
                                                     ,UserScans
                                                     ,UserLookups
                                                     ,UserReads
                                                     ,UserWrites
                                                     ,ReadWriteDiff
                                                     ,Fill_Factor
                                                     ,filter_definition
                                                     ,LastUserSeek
                                                     ,LastUserScan
                                                     ,LastUserLookup
                                                     ,LastUserUpdate
                                                     ,is_disabled
                                                     ,DatabaseName
                                                     ,TableName
                                                     ,index_description
                                                     ,columns_in_tree
                                                     ,columns_in_leaf)
        SELECT i.index_id
              ,i.index_name AS IndexName
              ,i.index_keys
              ,i.included_columns
              ,s.SizeKB
              ,#Results.UserSeeks
              ,#Results.UserScans
              ,#Results.UserLookups
              ,#Results.UserReads
              ,#Results.UserWrites
              ,#Results.ReadWriteDiff
              ,#Results.Fill_Factor
              ,i.filter_definition
              ,#Results.LastUserSeek
              ,#Results.LastUserScan
              ,#Results.LastUserLookup
              ,#Results.LastUserUpdate
              ,i.is_disabled
              ,DB_NAME() AS DatabaseName
              ,#Results.TableName
              ,i.index_description
              ,i.columns_in_tree
              ,i.columns_in_leaf
        FROM #Index AS i
             LEFT OUTER JOIN #Results ON i.index_id = #Results.index_id
             INNER JOIN #size AS s ON s.index_id = i.index_id
        WHERE 1 = 1
              AND ( @IndexName = ''
                    OR i.index_name = QUOTENAME(@IndexName));

      END;

  END;
GO
EXEC sys.sp_MS_marksystemobject 'sp_helpindexUsage';
GO
