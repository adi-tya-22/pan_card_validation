-- 0) Safety: drop existing objects in dependency order
IF OBJECT_ID('dbo.vw_valid_invalid_pans','V') IS NOT NULL DROP VIEW dbo.vw_valid_invalid_pans;
IF OBJECT_ID('dbo.fn_check_sequence','FN') IS NOT NULL DROP FUNCTION dbo.fn_check_sequence;
IF OBJECT_ID('dbo.fn_check_adjacent_repetition','FN') IS NOT NULL DROP FUNCTION dbo.fn_check_adjacent_repetition;
IF OBJECT_ID('dbo.pan_numbers_dataset_cleaned','U') IS NOT NULL DROP TABLE dbo.pan_numbers_dataset_cleaned;
IF OBJECT_ID('dbo.stg_pan_numbers_dataset','U') IS NOT NULL DROP TABLE dbo.stg_pan_numbers_dataset;
GO

/* -----------------------------------------------------------
   1) Staging table (original dataset)
   ----------------------------------------------------------- */
CREATE TABLE dbo.stg_pan_numbers_dataset
(
    pan_number VARCHAR(MAX) NULL
);
GO

/* -----------------------------------------------------------
   2) Data quality checks (exploration)
   ----------------------------------------------------------- */

-- Missing data
SELECT *
FROM dbo.stg_pan_numbers_dataset
WHERE pan_number IS NULL;

-- Duplicates (excluding NULLs)
SELECT pan_number, COUNT(1) AS cnt
FROM dbo.stg_pan_numbers_dataset
WHERE pan_number IS NOT NULL
GROUP BY pan_number
HAVING COUNT(1) > 1;

-- Distinct rows
SELECT DISTINCT pan_number
FROM dbo.stg_pan_numbers_dataset;

-- Leading/trailing spaces
SELECT *
FROM dbo.stg_pan_numbers_dataset
WHERE pan_number <> LTRIM(RTRIM(pan_number))
  AND pan_number IS NOT NULL;

-- Not upper-case
SELECT *
FROM dbo.stg_pan_numbers_dataset
WHERE pan_number IS NOT NULL
  AND pan_number <> UPPER(pan_number);

/* -----------------------------------------------------------
   3) Cleaned table (upper + trim + not null/blank + distinct)
   ----------------------------------------------------------- */
SELECT DISTINCT
    UPPER(LTRIM(RTRIM(pan_number))) AS pan_number
INTO dbo.pan_numbers_dataset_cleaned
FROM dbo.stg_pan_numbers_dataset
WHERE pan_number IS NOT NULL
  AND LTRIM(RTRIM(pan_number)) <> '';
GO

/* -----------------------------------------------------------
   4) Helper functions (T-SQL)
   ----------------------------------------------------------- */

-- 4a) Adjacent repetition check:
-- Returns 1 if any adjacent characters are the same; else 0
CREATE FUNCTION dbo.fn_check_adjacent_repetition (@p_str VARCHAR(MAX))
RETURNS BIT
AS
BEGIN
    DECLARE @i INT = 1,
            @len INT = LEN(@p_str);
    WHILE @i < @len
    BEGIN
        IF SUBSTRING(@p_str, @i, 1) = SUBSTRING(@p_str, @i + 1, 1)
            RETURN 1;
        SET @i += 1;
    END
    RETURN 0;
END;
GO

-- 4b) Strictly increasing sequence check:
-- Returns 1 if the entire string is sequential by +1 in ASCII; else 0
CREATE FUNCTION dbo.fn_check_sequence (@p_str VARCHAR(MAX))
RETURNS BIT
AS
BEGIN
    DECLARE @i INT = 1,
            @len INT = LEN(@p_str);
    IF @len <= 1 RETURN 1; -- by definition a 0/1-length string is sequential
    WHILE @i < @len
    BEGIN
        IF ASCII(SUBSTRING(@p_str, @i + 1, 1)) - ASCII(SUBSTRING(@p_str, @i, 1)) <> 1
            RETURN 0;
        SET @i += 1;
    END
    RETURN 1;
END;
GO

/* -----------------------------------------------------------
   5) Valid / Invalid PAN classification view
   Rules enforced:
   - Exactly 10 characters
   - First 5 are letters, next 4 are digits, last 1 is a letter
   - No adjacent repetition anywhere in the PAN
   - First 5 are not a straight alphabetical sequence (e.g., ABCDE)
   - Next 4 are not a straight numeric sequence (e.g., 1234)
   ----------------------------------------------------------- */
CREATE VIEW dbo.vw_valid_invalid_pans
AS
WITH cte_cleaned_pan AS
(
    SELECT DISTINCT pan_number
    FROM dbo.pan_numbers_dataset_cleaned
),
cte_valid_pan AS
(
    SELECT c.pan_number
    FROM cte_cleaned_pan AS c
    WHERE dbo.fn_check_adjacent_repetition(c.pan_number) = 0
      AND dbo.fn_check_sequence(SUBSTRING(c.pan_number, 1, 5)) = 0
      AND dbo.fn_check_sequence(SUBSTRING(c.pan_number, 6, 4)) = 0
      -- Enforce exact mask: 5 letters + 4 digits + 1 letter, total length = 10
      AND LEN(c.pan_number) = 10
      AND SUBSTRING(c.pan_number,1,5) NOT LIKE '%[^A-Z]%'
      AND SUBSTRING(c.pan_number,6,4) NOT LIKE '%[^0-9]%'
      AND SUBSTRING(c.pan_number,10,1) NOT LIKE '%[^A-Z]%'
)
SELECT 
    cln.pan_number,
    CASE WHEN vld.pan_number IS NULL THEN 'Invalid PAN' ELSE 'Valid PAN' END AS status
FROM cte_cleaned_pan AS cln
LEFT JOIN cte_valid_pan AS vld
  ON vld.pan_number = cln.pan_number;
GO

/* -----------------------------------------------------------
   6) Summary report
   ----------------------------------------------------------- */
WITH cte AS
(
    SELECT
        (SELECT COUNT(*) FROM dbo.stg_pan_numbers_dataset) AS total_processed_records,
        SUM(CASE WHEN vw.status = 'Valid PAN' THEN 1 ELSE 0 END) AS total_valid_pans,
        SUM(CASE WHEN vw.status = 'Invalid PAN' THEN 1 ELSE 0 END) AS total_invalid_pans
    FROM dbo.vw_valid_invalid_pans AS vw
)
SELECT 
    total_processed_records,
    total_valid_pans,
    total_invalid_pans,
    total_processed_records - (total_valid_pans + total_invalid_pans) AS missing_incomplete_PANS
FROM cte;
GO

/* -----------------------------------------------------------
   7) Optional: Single-LIKE mask alternative (reference)
   If preferred, in cte_valid_pan you can replace the three SUBSTRING/NOT LIKE checks
   with the following simpler single LIKE + length check:

   AND LEN(c.pan_number) = 10
   AND c.pan_number LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][A-Z]'

   Keep the adjacent-repetition and sequence checks as they are.
   ----------------------------------------------------------- */
