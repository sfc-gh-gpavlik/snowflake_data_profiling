/********************************************************************************************************
*                                                                                                       *
*                                       Snowflake Data Profiler                                         *
*                                                                                                       *
*  Copyright (c) 2020 Snowflake Computing Inc. All rights reserved.                                     *
*                                                                                                       *
*  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in  *
*. compliance with the License. You may obtain a copy of the License at                                 *
*                                                                                                       *
*                               http://www.apache.org/licenses/LICENSE-2.0                              *
*                                                                                                       *
*  Unless required by applicable law or agreed to in writing, software distributed under the License    *
*  is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or  *
*  implied. See the License for the specific language governing permissions and limitations under the   *
*  License.                                                                                             *
*                                                                                                       *
*  Copyright (c) 2020 Snowflake Computing Inc. All rights reserved.                                     *
*                                                                                                       *
********************************************************************************************************/

-- TOTAL COUNT FOR EACH TABLE (Done)
-- ESTIMATE OF TOTAL NON-NULL, NON-BLANK ROWS FOR A COLUMN, SHOULD ALSO HAVE RATIO (Done)
-- Percentage of total blanks/nulls -- (Done - by calculation)
-- TOTALLY OPTIONAL WHERE CLAUSE -- ESPECIALLY BY DATE (To do)

-- Create the schema
create or replace schema DATA_PROFILING;

-- Create table to persist column profiling results
create or replace table DATA_PROFILING_COLUMN_STATISTICS(
"DATABASE_NAME"         string,
"SCHEMA_NAME"           string,
"TABLE_NAME"            string,
"COLUMN_NAME"           string,
"DATA_TYPE"             string,
"CHARACTER_MAX_LENGTH"  number,
"NUMERIC_PRECISION"     number,
"NUMERIC_SCALE"         number,
"DATETIME_PRECISION"    number,
"PROFILE_TIMESTAMP"     timestamp_tz,
"TOTAL_COUNT"           number,
"SAMPLE_COUNT"          number,
"NULL_COUNT"            number,
"CARDINALITY"           number,
"IS_UNIQUE"             boolean,
"FLOAT_COUNT"           number,
"INTEGER_COUNT"         number,
"DECIMAL_COUNT"         number,
"BOOLEAN_COUNT"         number,
"TIMESTAMP_COUNT"       number,
"DATE_COUNT"            number,
"TIME_COUNT"            number,
"BLANK_VALUES"          number,
"MIN_LENGTH"            number,
"AVG_LENGTH"            float,
"MAX_LENGTH"            number,
"IS_NUMERIC"            boolean,
"IS_INTEGER"            boolean,
"MIN_VALUE"             string,
"MAX_VALUE"             string,
"VALUE_CARDINALITY"     number,
"INFORMATION_DENSITY"   float,
"MOST_COMMON_VALUES"    variant,
"PUNCTUATION_COUNT"     number,
"NON_ASCII_COUNT"       number,
"NON_PRINTABLE_COUNT"   number,
"MULTI_LINE_COUNT"      number
);

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- UDF to convert to timestamp when they're in multiple different formats
create or replace function TRY_MULTI_TIMESTAMP(STR string)
returns timestamp
language SQL
as
$$
    case
        when STR RLIKE '[A-Za-z]{3} \\d{2} \\d{4} \\d{1,2}:\\d{2}:\\d{2}' then try_to_timestamp(left(STR, 20), 'MON DD YYYY HH24:MI:SS')
        when STR RLIKE '\\d{1,4}-\\d{1,2}-\\d{2} \\d{1,2}:\\d{2}:\\d{2} [A|P][M]' then try_to_timestamp(STR, 'YYYY-MM-DD HH12:MI:SS AM')
        when STR RLIKE '\\d{1,2}/\\d{1,2}/\\d{4}' then try_to_timestamp(STR, 'mm/dd/yyyy')
        when STR RLIKE '\\d{1,2}\\/\\d{1,2}\\/\\d{4} \\d{1,2}:\\d{2}:\\d{2} [A-Za-z]{2}' then try_to_timestamp(STR, 'MM/DD/YYYY HH12:MI:SS AM')
        when STR RLIKE '\\d{1,2}\\/\\d{1,2}\\/\\d{4} \\d{1,2}:\\d{2}' then try_to_timestamp(STR, 'MM/DD/YYYY HH24:MI')
        when STR RLIKE '[A-Za-z]{3}, \\d{1,2} [A-Za-z]{3} \\d{4} \\d{1,2}:\\d{1,2}:\\d{1,2} [A-Za-z]{3}' then try_to_timestamp(left(STR, len(STR) - 4) || ' ' || '00:00', 'DY, DD MON YYYY HH:MI:SS TZH:TZM')   -- From Snowflake "LIST" command
        when STR RLIKE '\\d{1,2}/\\d{1,2}/\\d{2} \\d{1,2}:\\d{2} [A|P][M]' then try_to_timestamp(STR, 'MM/DD/YY HH12:MI AM')
        when STR RLIKE '[A-Za-z]{3} [A-Za-z]{3} \\d{2} \\d{4} \\d{1,2}:\\d{2}:\\d{2} GMT.*' then try_to_timestamp(left(replace(substr(STR, 5), 'GMT', ''), 26), 'MON DD YYYY HH:MI:SS TZHTZM')  -- Javascript
        else try_to_timestamp(STR) -- Final try without format specifier.
    end
$$;

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

create or replace function DATA_PROFILING_INFER_TYPES("SAMPLE_COUNT"        float,
                                                      "NULL_COUNT"          float,
                                                      "CARDINALITY"         float,
                                                      "IS_UNIQUE"           boolean,
                                                      "FLOAT_COUNT"         float,
                                                      "INTEGER_COUNT"       float,
                                                      "DECIMAL_COUNT"       float,
                                                      "BOOLEAN_COUNT"       float,
                                                      "TIMESTAMP_COUNT"     float,
                                                      "DATE_COUNT"          float,
                                                      "TIME_COUNT"          float,
                                                      "BLANK_VALUES"        float,
                                                      "AVG_LENGTH"          float,
                                                      "IS_NUMERIC"          boolean,
                                                      "IS_INTEGER"          boolean,
                                                      "MIN_VALUE"           string,
                                                      "MAX_VALUE"           string,
                                                      "VALUE_CARDINALITY"   float,
                                                      "INFORMATION_DENSITY" float,
                                                      "MOST_COMMON_VALUES"  variant
                                                       )
returns table (INFERRED_TYPE string, CONFIDENCE_LEVEL string, INFORMATION_ENTROPY float, ENTROPY_RATIO float)
language javascript
as
$$
{
    processRow: function f(row, rowWriter, context){

    class DataType{}
    class Entropy{}
    
    var entropy = CalculateEntropy(row.VALUE_CARDINALITY, row.MOST_COMMON_VALUES);
    
    var dataType =
        InferDataType(row.SAMPLE_COUNT,        row.NULL_COUNT,    row.CARDINALITY,   row.IS_UNIQUE,       row.FLOAT_COUNT,
                      row.INTEGER_COUNT,       row.DECIMAL_COUNT, row.BOOLEAN_COUNT, row.TIMESTAMP_COUNT, row.DATE_COUNT,
                      row.TIME_COUNT,          row.BLANK_VALUES,  row.AVG_LENGTH,    row.IS_NUMERIC,      row.IS_INTEGER,
                      row.MIN_VALUE,           row.MAX_VALUE,	   row.VALUE_CARDINALITY, 
                      row.INFORMATION_DENSITY, row.MOST_COMMON_VALUES);
    
    rowWriter.writeRow({INFERRED_TYPE: dataType.InferredType, CONFIDENCE_LEVEL: dataType.ConfidenceLevel, 
                        INFORMATION_ENTROPY: entropy.informationEntropy, ENTROPY_RATIO: entropy.entropyRatio});

/********************************************************************************************************
*                                                                                                       *
*  Start of UDTF Logic Area                                                                             *
*                                                                                                       *
********************************************************************************************************/

function CalculateEntropy(cardinality, mostCommonValues) {

class Entropy {}
entropy = new Entropy();

    if (cardinality < 2 || cardinality > 16) {
        entropy.informationEntropy = NaN;
        entropy.entropyRatio = NaN;
    } else {
        var maxPossibleEntropy = -1 * Math.log2(1/cardinality);
        var occurrences = new Array(cardinality + 1);
        var prevalence = new Array(cardinality + 1);
        var totalOccurrences = 0;
        var ent = 0;
        
        for(var i = 1; i <= cardinality; i++){
            occurrences[i] = mostCommonValues[i > 9 ? i : "0" + i].COUNT;
            totalOccurrences += occurrences[i];
        }
        
        for(var i = 1; i <= cardinality; i++){
            prevalence[i] = occurrences[i] / totalOccurrences;
            ent += (Math.log2(prevalence[i]) * prevalence[i]);
        }
        
        entropy.informationEntropy = -1 * ent;
        entropy.entropyRatio = -1 * ent / maxPossibleEntropy;
    }

    return entropy;
}

function InferDataType(sampleCount, nullCount, cardinality, isUnique, floatCount, integerCount, decimalCount, booleanCount, timestampCount,
                       dateCount, timeCount, blankValues, avgLength, isNumeric, isInteger, minValue, maxValue, valueCardinality,
                       informationDensity, mostCommonValues){

    var dataType = new DataType();
    var vals = [];
    
    // ------------- Boolean first
    if (valueCardinality == 2){
        vals.push(mostCommonValues["01"].VALUE.toUpperCase());
        vals.push(mostCommonValues["02"].VALUE.toUpperCase());
        try{
            vals.push(mostCommonValues["03"].VALUE.toUpperCase());
        }
        catch(err){}
        if(
            (vals.includes("Y") && vals.includes("N")) ||
            (vals.includes("YES") && vals.includes("NO")) ||
            (vals.includes("T") && vals.includes("F")) ||
            (vals.includes("TRUE") && vals.includes("FALSE")) ||
            (vals.includes(1) && vals.includes(0))
           ){
            dataType.InferredType = "BOOLEAN";
            dataType.ConfidenceLevel = "Very high";
            return dataType;
        }
    }
    
    // ------------- Integer next
    if (isInteger){
        dataType.InferredType = "INTEGER";
        dataType.ConfidenceLevel = "Very high";
        return dataType;
    }
    
    // ------------- Float next
    if (isNumeric && !isInteger){
        dataType.InferredType = "FLOAT";
        dataType.ConfidenceLevel = "High";
        return dataType; 
    }
    
    // ------------- Date next
    if (timestampCount > floatCount && timestampCount / (sampleCount - nullCount) > .995 && dateCount == timestampCount){
        dataType.InferredType = "DATE";
        dataType.ConfidenceLevel = "Very High";
        return dataType;
    }
    
    // ------------- Timestamp next
    if (timestampCount > floatCount && timestampCount / (sampleCount - nullCount) > .995){
        dataType.InferredType = "TIMESTAMP";
        dataType.ConfidenceLevel = "Very High";
        return dataType;
    }
    
    // ------------- Time next
    if (timeCount > integerCount){
        dataType.InferredType = "TIME";
        dataType.ConfidenceLevel = "Very High";
        return dataType;
    }
    
    // ------------- If not a strict type, default to TEXT
    dataType.InferredType = "TEXT";
    dataType.ConfidenceLevel = "-";
    return dataType;
}

/********************************************************************************************************
*                                                                                                       *
*  End of UDTF Logic Area                                                                               *
*                                                                                                       *
********************************************************************************************************/
    }
}
$$;

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

create or replace procedure DATA_PROFILE_COLUMNS(
                                                    DATABASE_PATTERN    string,
                                                    SCHEMA_PATTERN      string,
                                                    TABLE_PATTERN       string,
                                                    COLUMN_PATTERN      string,
                                                    SAMPLING_STRATEGY   string,
                                                    SAMPLING_VALUE      float,
                                                    REPROFILE_DAYS      float,
                                                    MAX_RUN_MINUTES     float,
                                                    WHERE_CLAUSE        string
)
returns variant
language javascript
as
$$
/********************************************************************************************************
*                                                                                                       *
* Stored procedure to profile columns                                                                   *
*                                                                                                       *
* @param  {string}  DATABASE_FILTER:    The filter for the database(s) to profile, Use LIKE % for all.  *
* @param  {string}  SCHEMA_FILTER:      The filter for the schema(s) to profile, Use LIKE % for all.    *
* @param  {string}  TABLE_FILTER:       The filter for the table(s) to profile, Use LIKE % for all.     *
* @param  {string}  COLUMN_FILTER:      The filter for the column(s) to profile. Use LIKE % for all.    *
* @param  {string}  SAMPLING_STRATEGY:  The name of the table that controls this procedure              *
* @param. {float}   SAMPLING_VALUE:     The number of rows to sample                                    *
* @param  {float}   REPROFILE_DAYS:     The number of days between re-profiling a column.               *
* @param  {float}   MAX_RUN_MINUTES:    The maximum run time allowed for a new pass to start            *
* @return {variant}:                    A JSON with statistics from the execution.                      *
*                                                                                                       *
********************************************************************************************************/

const PROFILE_TABLE = "DATA_PROFILING_COLUMN_STATISTICS";

/********************************************************************************************************
*                                                                                                       *
*  Class definitions                                                                                    *
*                                                                                                       *
********************************************************************************************************/

class Account {
    constructor(databases){
        this.databases = databases;
    }
}

class Database {
    constructor(name) {
        this.name = name;
    }
}

class Query{
    constructor(statement){
        this.statement = statement;
    }
}

class TableStats{
    constructor(database, schema, table){
        this.database = database;
        this.schema = schema;
        this.table = table;
    }
}

/********************************************************************************************************
*                                                                                                       *
*  Main function.                                                                                       *
*                                                                                                       *
********************************************************************************************************/

var endTime = new Date().getTime() + MAX_RUN_MINUTES * 60000;
var isEndTime = 0;
var out = {};
var sampleSQL = getSampleMethodSQL(SAMPLING_STRATEGY, SAMPLING_VALUE);
var whereClause = getWhereClause(WHERE_CLAUSE);
var parameterError = CheckParameters(DATABASE_PATTERN,
                                     SCHEMA_PATTERN,
                                     TABLE_PATTERN,
                                     COLUMN_PATTERN,
                                     SAMPLING_STRATEGY,
                                     REPROFILE_DAYS,
                                     MAX_RUN_MINUTES,
                                     WHERE_CLAUSE,
                                     sampleSQL);
if(parameterError != "No_Errors"){
    out["Parameter_Error"] = parameterError;
    return out;
}

var account = GetDatabasesInAccount(DATABASE_PATTERN);
var rs;
var pass = 0;
var col = 0;
var values = '';
var tableStats = new TableStats("", "", "");

try{
    for (var i = 0; i < account.databases.length; i++){
        rs = GetResultSet(GetColumnSQL(account.databases[i].name, SCHEMA_PATTERN, TABLE_PATTERN, COLUMN_PATTERN, PROFILE_TABLE, REPROFILE_DAYS));
        while (rs.next()){
            col++;
            if (pass++ > 0) values += ',\n'
            tableStats = GetTableStats(tableStats, rs); 
            values += GetColumnProfile(rs, tableStats.rowCount, sampleSQL);
            if (pass == 100) {
                InsertFindings(values, PROFILE_TABLE);
                pass = 0;
                values = '';
            }
            if (new Date().getTime() >= endTime){
                out["Termination_Reason"] = "Time_Limit";
                isEndTime = 1;
                break;
            }
        }
        if (!isEndTime){
            out["Termination_Reason"] = "Profiled_All_Specified_Columns";
        }
        if (values != '') InsertFindings(values, PROFILE_TABLE);
    }
}
catch(err){
    out["Termination_Reason"] = "Error";
    out["Error"] = err.message;
}
out["Columns_Profiled"] = col;
return out;

/********************************************************************************************************
*                                                                                                       *
*  Helper functions.                                                                                    *
*                                                                                                       *
********************************************************************************************************/

function GetTableStats(tableStats, rs) {

    var database = rs.getColumnValue("TABLE_CATALOG");
    var schema   = rs.getColumnValue("TABLE_SCHEMA");
    var table    = rs.getColumnValue("TABLE_NAME");
    var ts = tableStats;

    if(database.localeCompare(ts.database) != 0 || schema.localeCompare(ts.schema) != 0 || table.localeCompare(ts.table) != 0) {
        ts.database = database;
        ts.schema = schema;
        ts.table = table;
        ts.rowCount = ExecuteSingleValueQuery("ROW_COUNT",
        `select ROW_COUNT from "${database}".INFORMATION_SCHEMA.TABLES where TABLE_SCHEMA = '${schema}' and TABLE_NAME = '${table}';`);
    }
    return ts;
}

function InsertFindings(values, profileTable) {
    var sql = GetInsertSQL(values, PROFILE_TABLE);
    ExecuteNonQuery(sql);
}

function GetColumnProfile(colRS, rowCount, samplingStrategy){
    var sql = getProfileSQL(colRS.getColumnValue("TABLE_CATALOG"),
                            colRS.getColumnValue("TABLE_SCHEMA"),
                            colRS.getColumnValue("TABLE_NAME"),
                            colRS.getColumnValue("COLUMN_NAME"),
                            colRS.getColumnValue("DATA_TYPE"),
                            colRS.getColumnValue("CHARACTER_MAX_LENGTH"),
                            colRS.getColumnValue("NUMERIC_PRECISION"),
                            colRS.getColumnValue("NUMERIC_SCALE"),
                            colRS.getColumnValue("DATETIME_PRECISION"),
                            rowCount,
                            samplingStrategy,
                            whereClause
                            );
    var query = GetQuery(sql);
    return InsertValueMatchingSchema(query);
}

function InsertValueMatchingSchema(query){    
    var s = "(";
    var colPass = 0;
    var rowPass = 0;
    
    while(query.resultSet.next()){
        for (var i = 1; i <= query.statement.getColumnCount(); i++){
            if (colPass++ != 0) s += ",";
            s += WrapInsertValue(query.resultSet.getColumnValueAsString(i), query.resultSet.getColumnSqlType(i));
         }
        colPass = 0;
        s += ")";
    }
    return s 
}

function GetDatabasesInAccount(databasePattern){
    var db = ExecuteSingleValueQuery("name", "show databases");
    var i = 0;
    var dbRS = GetResultSet(`select DATABASE_NAME from "${db}".INFORMATION_SCHEMA.DATABASES where rlike (DATABASE_NAME, '${databasePattern}');`);
    var databases = [];
    var db;
    while (dbRS.next()){
        db = new Database(dbRS.getColumnValue("DATABASE_NAME"));
        databases.push(db);
    }
    return new Account(databases);
}

function GetColumnsRS(databaseName, schemaPattern, tablePattern, columnPattern){
    var colRS = GetResultSet()
}

/********************************************************************************************************
*                                                                                                       *
*  SQL functions                                                                                        *
*                                                                                                       *
********************************************************************************************************/

function GetResultSet(sql){
    cmd1 = {sqlText: sql};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    rs = stmt.execute();
    return rs;
}

function GetQuery(sql){
    cmd1 = {sqlText: sql};
    var query = new Query(snowflake.createStatement(cmd1));
    query.resultSet = query.statement.execute();
    return query;
}

function ExecuteNonQuery(queryString) {
    var out = '';
    cmd1 = {sqlText: queryString};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    rs = stmt.execute();
}

function ExecuteSingleValueQuery(columnName, queryString) {
    var out;
    cmd1 = {sqlText: queryString};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    rs = stmt.execute();
    rs.next();
    return rs.getColumnValue(columnName);
    return out;
}

function ExecuteFirstValueQuery(queryString) {
    var out;
    cmd1 = {sqlText: queryString};
    stmt = snowflake.createStatement(cmd1);
    var rs;

    rs = stmt.execute();
    rs.next();
    return rs.getColumnValue(1);
    return out;
}

function WrapInsertValue(value, dataType){
    if (value == 'null'){
        return 'NULL';
    }
    switch (dataType){
        case "TEXT":
            return "'" + escapeInsertString(value) + "'";
        case "OBJECT":
            return "'" + escapeInsertString(value) + "'";
        case "TIMESTAMP_TZ":
            return "'" + value + "'";
        case "TIMESTAMP":
            return "'" + value + "'";
        default: return value;
    }
}

function escapeInsertString(value) {
    var s = value.replace(/\\/g, "\\\\");
    s = s.replace(/'/g, "''" );
    s = s.replace(/"/g, '\\"');
    s = s.replace(/\s+/g, " ");
//  s = s.replace(/[^\x00-\x7F]/g, "");
    return s;
}


/********************************************************************************************************
*                                                                                                       *
*  Error and Exception Handling                                                                         *
*                                                                                                       *
********************************************************************************************************/
function CheckParameters(databasePattern,
                         schemaPattern,
                         tablePattern,
                         columnPattern,
                         samplingStrategy,
                         reprofileDays,
                         maxRunMinutes,
                         whereClause,
                         sampleSQL){
    if(databasePattern === ''){
        return "DATABASE_PATTERN must be a name of a database or a pattern used in a 'like' statement. Use % for all.";
    }
    if(schemaPattern === ''){
        return "SCHEMA_PATTERN must be a name of a schema or a pattern used in a 'like' statement. Use % for all.";
    }
    if(tablePattern === ''){
        return "TABLE_PATTERN must be a name of a table or a pattern used in a 'like' statement. Use % for all.";
    }
    if(columnPattern === ''){
        return "COLUMN_PATTERN must be a name of a column or a pattern used in a 'like' statement. Use % for all.";
    }
    if(samplingStrategy.toLowerCase().trim() != 'limit' && samplingStrategy.toLowerCase() != 'sample'){
        return "SAMPLING_STRATEGY supports only 'limit' or 'sample'.";
    }
    if(reprofileDays < 0){
        return "REPROFILE_DAYS must be greater than or equal to 0.";
    }
    if(maxRunMinutes <= 0){
        return "MAX_RUN_MINUTES must be greater than 0.";
    }
    if(sampleSQL == ""){
        return "Unsupported sampling strategy.";
    }
    if(whereClause.trim() != "" && samplingStrategy.toLowerCase().trim() == 'sample'){
        return "Where clause cannot be set with sampling strategy set to 'sample'.";
    }
    return "No_Errors";
}

/********************************************************************************************************
*                                                                                                       *
*  SQL Templates                                                                                        *
*                                                                                                       *
********************************************************************************************************/

function getWhereClause(whereClause) {
    var wc = whereClause.toLowerCase().trim();
    if (wc == "") {
        return "";
    } else {
        return "where " + wc;
    }
}

function getSampleMethodSQL(strategy, value) {

    var method = strategy.toLowerCase().trim();

    if (value <= 0) {
        return "";
    }

    switch(method) {
    
        case "limit":
            return `limit ${value}`;
        case "sample":
            return `sample (${value} rows)`;
        default:
            return "";
    }
}

function GetColumnSQL(database, schema, table, column, profileTable, reprofileDays){
sql = `
select  /* Snowflake Query Profiler */
        I."TABLE_CATALOG"               as "TABLE_CATALOG",
        I."TABLE_SCHEMA"                as "TABLE_SCHEMA",
        I."TABLE_NAME"                  as "TABLE_NAME",
        I."COLUMN_NAME"                 as "COLUMN_NAME",
        I."ORDINAL_POSITION"            as "ORDINAL_POSITION",
        I."DATA_TYPE"                   as "DATA_TYPE",
        I."CHARACTER_MAXIMUM_LENGTH"    as "CHARACTER_MAX_LENGTH",
        I."NUMERIC_PRECISION"           as "NUMERIC_PRECISION",
        I."NUMERIC_SCALE"               as "NUMERIC_SCALE",
        I."DATETIME_PRECISION"          as "DATETIME_PRECISION"
from    "${database}"."INFORMATION_SCHEMA"."COLUMNS" I
    left join "DATA_PROFILING"."${profileTable}" P
    on  P."DATABASE_NAME"   = I."TABLE_CATALOG" and
        P."SCHEMA_NAME"     = I."TABLE_SCHEMA"  and
        P."TABLE_NAME"      = I."TABLE_NAME"    and
        P."COLUMN_NAME"     = I."COLUMN_NAME"
where   (datediff(day, PROFILE_TIMESTAMP, current_timestamp()) >  ${reprofileDays} or PROFILE_TIMESTAMP is null) and
        I."TABLE_SCHEMA"    <> 'INFORMATION_SCHEMA'     and
        I."TABLE_CATALOG"   = '${database}'             and
        I."TABLE_SCHEMA"    rlike('${schema}')          and
        I."TABLE_NAME"      rlike('${table}')           and
        I."COLUMN_NAME"     rlike('${column}')
`;
return sql;
}

function getProfileSQL(database, schema, table, column, dataType, charMaxLength, numericPrecision, numericScale, datetimePrecision, rowCount, samplingStrategy, whereClause){
sql = `
with    /* Snowflake Query Profiler */
COL_XFORM(COL, COL_STRING, COL_DOUBLE, COL_INTEGER, COL_BOOLEAN, COL_TS, COL_DATE, COL_TIME) as
(
    select      "${column}"                         as COL,
                trim(to_varchar(COL))               as COL_STRING,
                try_to_double(COL_STRING)           as COL_DOUBLE,
                try_to_number(COL_STRING, 38, 0)    as COL_INTEGER,
                try_to_boolean(COL_STRING)          as COL_BOOLEAN,
                try_multi_timestamp(COL_STRING)     as COL_TS,
                date_trunc('DAY', COL_TS)           as COL_DATE,
                try_to_time(COL_STRING)             as COL_TIME
    from        "${database}"."${schema}"."${table}"
    ${whereClause}
    ${samplingStrategy}
),
STATS("DATABASE_NAME",
      "SCHEMA_NAME",
      "TABLE_NAME",
      "COLUMN_NAME",
      TOTAL_COUNT,
      SAMPLE_COUNT,
      NULL_COUNT,
      CARDINALITY,
      IS_UNIQUE,
      FLOAT_COUNT,
      INTEGER_COUNT,
      DECIMAL_COUNT,
      BOOLEAN_COUNT,
      TIMESTAMP_COUNT,
      DATE_COUNT,
      TIME_COUNT,
      BLANK_VALUES,
      MIN_LENGTH,
      AVG_LENGTH,
      MAX_LENGTH,
      IS_NUMERIC,
      IS_INTEGER,
      MIN_VALUE,
      MAX_VALUE,
      VALUE_CARDINALITY,
      INFORMATION_DENSITY,
      PUNCTUATION_COUNT,
      NON_ASCII_COUNT,
      NON_PRINTABLE_COUNT,
      MULTI_LINE_COUNT
) as
(
select      '${database}'                                   as "DB_NAME",
            '${schema}'                                     as "SCHEMA_NAME",
            '${table}'                                      as "TABLE_NAME",
            '${column}'                                     as "COLUMN_NAME",
            ${rowCount}                                     as TOTAL_COUNT,
            count(1)                                        as SAMPLE_COUNT,
            SAMPLE_COUNT - count(COL)                       as NULL_COUNT,
            count(distinct COL)                             as CARDINALITY,
            case 
                when  SAMPLE_COUNT = 0 then null
                else  SAMPLE_COUNT = CARDINALITY 
            end                                             as IS_UNIQUE,
            count(COL_DOUBLE)                               as FLOAT_COUNT,
            count(COL_INTEGER)                              as INTEGER_COUNT,
            zeroifnull(sum(
                case
                    when 
                        COL_DOUBLE is not null and
                        COL_DOUBLE <> COL_INTEGER
                    then 1
                    else 0
                end
            ))                                              as DECIMAL_COUNT,
            count(COL_BOOLEAN)                              as BOOLEAN_COUNT,
            count(COL_TS)                                   as TIMESTAMP_COUNT,
            sum(iff(COL_TS = COL_DATE, 1, 0))               as DATE_COUNT,
            count(COL_TIME)                                 as TIME_COUNT,
            zeroifnull(sum(iff(COL_STRING='',1,0)))         as BLANK_STRING,
            min(len(COL_STRING))                            as MIN_LENGTH,
            avg(length(COL_STRING))                         as AVG_LENGTH,
            max(len(COL_STRING))                            as MAX_LENGTH,
            case
                when SAMPLE_COUNT = 0 then null
                else (SAMPLE_COUNT-NULL_COUNT=FLOAT_COUNT)
                     and (FLOAT_COUNT>0)
            end                                             as IS_NUMERIC,
            IS_NUMERIC and (DECIMAL_COUNT = 0)              as IS_INTEGER,
            min(COL)::string                                as MIN_VALUE,
            max(COL)::string                                as MAX_VALUE,
            CARDINALITY - iff(BLANK_VALUES>0,1,0)           as VALUE_CARDINALITY,
            iff(SAMPLE_COUNT > 0, 
                VALUE_CARDINALITY / SAMPLE_COUNT, null)     as INFORMATION_DENSITY,
            sum(case when regexp_instr(COL_STRING,'[[:punct:]]')  > 0 then 1 else 0 end)      as PUNCTUATION_COUNT,
            sum(case when regexp_instr(COL_STRING,'[^[:ascii:]]') > 0 then 1 else 0 end)      as UNICODE_COUNT,
            sum(case when regexp_instr(COL_STRING,'[^[:print:]]') > 0 then 1 else 0 end)      as NON_PRINTABLE_COUNT,
            sum(case when charindex(COL_STRING,'\n') > 0 or charindex(COL_STRING,'\r') > 0 then 1 else 0 end) as HAS_LINE_FEED_COUNT
from        COL_XFORM
),
MC_K(MOST_COMMON_KEY) as
(
    select * from values ('01'),('02'),('03'),('04'),('05'),('06'),('07'),('08'),('09'),('10'),('11'),('12'),('13'),('14'),('15'),('16')
),
MC_V(MOST_COMMON_VALUE) as
(
select      object_construct(
                'VALUE', left(COL, 1024),
                'COUNT', count(COL),
                'RANK', row_number() over (order by count(COL) desc)
            ) 
from        COL_XFORM
group by    COL
order by    MOST_COMMON_VALUE:RANK::integer
limit       16
),
MOST_COMMON(MOST_COMMON_VALUES) as
(
select  object_agg(MC_K.MOST_COMMON_KEY, MC_V.MOST_COMMON_VALUE)
from    MC_K left join MC_V
    on  to_number(MC_K.MOST_COMMON_KEY) = to_number(MC_V.MOST_COMMON_VALUE:RANK)
)
select  '${database}',
        '${schema}',
        '${table}',
        '${column}',
        '${dataType}',
        ${charMaxLength},
        ${numericPrecision},
        ${numericScale},
        ${datetimePrecision},
        current_timestamp()::timestamp_tz as PROFILE_TIMESTAMP,
        TOTAL_COUNT,
        SAMPLE_COUNT,
        NULL_COUNT,
        CARDINALITY,
        IS_UNIQUE,
        FLOAT_COUNT,
        INTEGER_COUNT,
        DECIMAL_COUNT,
        BOOLEAN_COUNT,
        TIMESTAMP_COUNT,
        DATE_COUNT,
        TIME_COUNT,
        BLANK_VALUES,
        MIN_LENGTH, 
        AVG_LENGTH,
        MAX_LENGTH,
        IS_NUMERIC,
        IS_INTEGER,
        MIN_VALUE,
        MAX_VALUE,
        VALUE_CARDINALITY,
        INFORMATION_DENSITY,
        MOST_COMMON_VALUES,
        PUNCTUATION_COUNT,
        NON_ASCII_COUNT,
        NON_PRINTABLE_COUNT,
        MULTI_LINE_COUNT
from    STATS
    full outer join MOST_COMMON;
`;
return sql;
}

function GetInsertSQL(values, table){
sql = `
insert into ${table}
/* Snowflake Query Profiler */
select 
column1                 as "DATABASE_NAME",
column2                 as "SCHEMA_NAME",
column3                 as "TABLE_NAME",
column4                 as "COLUMN_NAME",
column5                 as "DATA_TYPE",
column6                 as "CHARACTER_MAX_LENGTH",
column7                 as "NUMERIC_PRECISION",
column8                 as "NUMERIC_SCALE",
column9                 as "DATETIME_PRECISION",
column10                as "PROFILE_TIMESTAMP",
column11                as "TOTAL_COUNT",
column12                as "SAMPLE_COUNT",
column13                as "NULL_COUNT",
column14                as "CARDINALITY",
column15                as "IS_UNIQUE",
column16                as "FLOAT_COUNT",
column17                as "INTEGER_COUNT",
column18                as "DECIMAL_COUNT",
column19                as "BOOLEAN_COUNT",
column20                as "TIMESTAMP_COUNT",
column21                as "DATE_COUNT",
column22                as "TIME_COUNT",
column23                as "BLANK_VALUES",
column24                as "MIN_LENGTH",
column25                as "AVG_LENGTH",
column26                as "MAX_LENGTH",
column27                as "IS_NUMERIC",
column28                as "IS_INTEGER",
column29                as "MIN_VALUE",
column30                as "MAX_VALUE",
column31                as "VALUE_CARDINALITY",
column32                as "INFORMATION_DENSITY",
parse_json(column33)    as "MOST_COMMON_VALUES",
column34                as "PUNCTUATION_COUNT",
column35                as "NON_ASCII_COUNT",
column36                as "NON_PRINTABLE_COUNT",
column37                as "MULTI_LINE_COUNT"
from (values

${values}

     );

`;
return sql;
}
$$;

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

create or replace table DATA_PROFILING_COLUMN_NAMES_REGEX(
                                                            IS_ENABLED          boolean     default true,
                                                            CONFIDENCE_RATIO    float,
                                                            RULE_NAME           string,
                                                            DESCRIPTION         string,
                                                            CATEGORIES          string,
                                                            REGEX               string,
                                                            REGEX_NEGATIVE      string default ''
);

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  
insert into DATA_PROFILING_COLUMN_NAMES_REGEX
                (CONFIDENCE_RATIO, RULE_NAME, DESCRIPTION, CATEGORIES, REGEX, REGEX_NEGATIVE)
values
(66.7,  'en_PRIMARY_KEY',       'a primary key',                'METADATA',         '\\bPK_|_PK\\b|\\bID\\b', NULL),
(50,    'en_FOREIGN_KEY',	    'a foreign key',	            'METADATA',	        '\\bFK_|_FK\\b|\\bPARENT_ID\\b', NULL),
(99,    'en_EMAIL',	            'emails',	                    'PII',	            '\\bEMAIL\\b|\\bEMAIL_|_EMAIL_|_EMAIL\\b', NULL),
(80,    'en_PHONE',	            'phone numbers',	            'PII,LOCATION',	    '\\bPHONE\\b|\\bPHONE_|_PHONE_|_PHONE\\b', NULL),
(80,    'en_US_SSN',	        'US Social Security numbers',	'PII',	            '\\bSSN\\b|\\bSSN_|_SSN_|_SSN\\b|SOCIAL_SECURITY', NULL),
(80,    'en_STREET_ADDRESS',    'street addresses',	            'PII,LOCATION',	    '\\bADDRESS\\b|\\bADDRESS_|_ADDRESS_|[A-DF-Z][A-Z][A-Z][A-Z][A-Z]_ADDRESS|[A-Z]{1,3}_ADDRESS\\b|ADDRESS1|ADDRESS2|BILLINGSTREET|SHIPPINGSTREET|BILLING_STREET|SHIPPING_STREET', 'WEB_ADDRESS|WEBADDRESS|MACADDRESS|MAC_ADDRESS|IPADDRESS|IP_ADDRESS|EMAIL'),
(80,    'en_FIRST_NAME',	    'first names',	                'PII',	            'FIRSTNAME|FIRST_NAME|FNAME|FIRST_NM|FRSTNM', NULL),
(80,    'en_LAST_NAME',	        'last names',	                'PII',	            'LASTNAME|LAST_NAME|LNAME|LAST_NM|LASTNM', NULL),
(80,    'en_MIDDLE_NAME',	    'middle names',	            '    PII',	            'MIDDLENAME|MIDDLE_NAME|MIDDLENAME|MIDDLENM', NULL),
(80,    'en_AREA_CODE',	        'phone area codes',	            'PII,LOCATION',	    'AREA_CODE|AREACODE', NULL),
(80,    'en_FAX',	            'fax numbers',	                'PII,LOCATION',	    '\\bFAX\\b|\\bFAX_|_FAX_|_FAX\\b', NULL),
(80,    'en_PHONE',	            'phone numbers',	            'PII,LOCATION',	    '\\bPHONE\\b|\\bPHONE_|_PHONE_|_PHONE\\b', NULL),
(80,    'en_DATE_OF_BIRTH',	    'dates of birth',	            'PII,DEMOGRAPHICS',	'DATEOFBIRTH|DATE_OF_BIRTH|\\bDOB\\b', NULL),
(80,    'en_DATE_OF_DEATH',	    'dates of death',	            'PII',	            'DATEOFDEATH|DATE_OF_DEATH', NULL),
(80,    'en_PAYMENT_CARD',	    'payment card numbers',	        'PII,FINANCIAL',	'CREDITCARD|CREDIT_CARD', NULL),
(80,    'en_INCOME',	        'imcome information',	        'PII,FINANCIAL',    '\\bINCOME\\b|HOUSEHOLD_INCOME|HOUSEHOLDINCOME|\\bMONTHLY_INCOME\\b|\\bYEARLY_INCOME\\b|\\bANNUAL_INCOME\\b', NULL),
(80,    'en_GENDER',            'gender information',	        'PII,DEMOGRAPHICS',	'GENDER|\\bSEX\\b|\\bSEX_|_SEX_|_SEX\\b', NULL),
(80,    'en_DRIVERS_LICENSE',	'drivers license numbers',	    'PII',	            'DRIVERSLICENSE|DRIVERS_LICENSE', NULL),
(90,    'en_COMMENTS_OR_NOTES',	'comments or notes',	        'NOTES',	        'COMMENTS|NOTES|DESCRIPTION', NULL),
(80,    'en_PRICING',	        'pricing information',	        'FINANCIAL',        'PRICING|PRICE', NULL),
(80,    'en_COSTING',	        'cost information',	            'FINANCIAL',        '\\bCOST\\b|\\bCOSTING\\b|\\bCOST_|_COST_|_COST\\b', NULL),
(80,    'en_TAX',	            'tax information',	            'FINANCIAL',	    '\\bTAX\\b|\\bTAX_|_TAX_|_TAX\\b', NULL),
(80,    'en_GEOLOCATION_DATA',	'geolocation data',	            'LOCATION',	        'LATITUDE|LONGITUDE', NULL),
(95,    'en_ZIP_POSTAL',	    'zip or postal codes',	        'LOCATION',	        '\\ZIP\\b|\\bZIP_|_ZIP_|_ZIP\\b|POSTALCODE|POSTAL_CODE', NULL),
(95,    'en_CITY',	            'city names',	                'LOCATION',	        '\\CITY\\b|\\CITY_|_CITY_|_CITY\\b', NULL),
(95,    'en_STATE_PROVINCE',    'state or province names',	    'LOCATION',	        '\\bSTATE\\b|\\bSTATE_|_STATE_|_STATE|STATE_PROVINCE|STATEPROVINCE|STATE_OR_PROVINCE\\b', NULL),
(95,    'en_DIAGNOSIS',	        'medical diagnoses',	        'PHI',	            '\\DIAGNOSIS\\b|\\bDIAGNOSIS_|_DIAGNOSIS_|_DIAGNOSIS\\b', NULL),
(95,    'en_CUSTOMER_ID',	    'customer IDs',	                'METADATA',	        '\\bCUSTOMER_ID\\bCUST_ID\\b|\\bCUSTOMERID\\b', NULL)
;

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

create or replace view DATA_PROFILE as
with
COLS(   "DATABASE_NAME",
        "SCHEMA_NAME",
        "TABLE_NAME",
        "COLUMN_NAME",
        "DATA_TYPE",
        CHARACTER_MAX_LENGTH,
        NUMERIC_PRECISION,
        NUMERIC_SCALE,
        DATETIME_PRECISION,
        PROFILE_TIMESTAMP,
        TOTAL_COUNT,
        SAMPLE_COUNT,
        NULL_COUNT,
        CARDINALITY,
        IS_UNIQUE,
        FLOAT_COUNT,
        INTEGER_COUNT,
        DECIMAL_COUNT,
        BOOLEAN_COUNT,
        TIMESTAMP_COUNT,
        DATE_COUNT,
        TIME_COUNT,
        BLANK_VALUES,
        MIN_LENGTH,
        AVG_LENGTH,
        MAX_LENGTH,
        IS_NUMERIC,
        IS_INTEGER,
        MIN_VALUE,
        MAX_VALUE,
        VALUE_CARDINALITY,
        INFORMATION_DENSITY,
        MOST_COMMON_VALUES,
        HAS_INFORMATION,
        INFERRED_TYPE,
        CONFIDENCE_LEVEL,
        PUNCTUATION_COUNT,
        NON_ASCII_COUNT,
        NON_PRINTABLE_COUNT,
        MULTI_LINE_COUNT,
        INFORMATION_ENTROPY,
        ENTROPY_RATIO
) as
(
select  "DATABASE_NAME",
        "SCHEMA_NAME",
        "TABLE_NAME",
        "COLUMN_NAME",
        "DATA_TYPE",
        CHARACTER_MAX_LENGTH,
        NUMERIC_PRECISION,
        NUMERIC_SCALE,
        DATETIME_PRECISION,
        PROFILE_TIMESTAMP,
        TOTAL_COUNT,
        SAMPLE_COUNT,
        NULL_COUNT,
        CARDINALITY,
        IS_UNIQUE,
        FLOAT_COUNT,
        INTEGER_COUNT,
        DECIMAL_COUNT,
        BOOLEAN_COUNT,
        TIMESTAMP_COUNT,
        DATE_COUNT,
        TIME_COUNT,
        BLANK_VALUES,
        MIN_LENGTH,
        AVG_LENGTH,
        MAX_LENGTH,
        IS_NUMERIC,
        IS_INTEGER,
        MIN_VALUE,
        MAX_VALUE,
        VALUE_CARDINALITY,
        INFORMATION_DENSITY,
        MOST_COMMON_VALUES,
        iff(SAMPLE_COUNT - (NULL_COUNT + BLANK_VALUES) > 0, true, false) as HAS_INFORMATION,
        INFERRED_TYPE,
        CONFIDENCE_LEVEL,
        PUNCTUATION_COUNT,
        NON_ASCII_COUNT,
        NON_PRINTABLE_COUNT,
        MULTI_LINE_COUNT,
        INFORMATION_ENTROPY,
        ENTROPY_RATIO
from DATA_PROFILING_COLUMN_STATISTICS, 
    lateral(table(DATA_PROFILING_INFER_TYPES(
        "SAMPLE_COUNT"::float,
        "NULL_COUNT"::float,
        "CARDINALITY"::float,
        "IS_UNIQUE",
        "FLOAT_COUNT"::float,
        "INTEGER_COUNT"::float,
        "DECIMAL_COUNT"::float,
        "BOOLEAN_COUNT"::float,
        "TIMESTAMP_COUNT"::float,
        "DATE_COUNT"::float,
        "TIME_COUNT"::float,
        "BLANK_VALUES"::float,
        "AVG_LENGTH",
        "IS_NUMERIC",
        "IS_INTEGER",
        "MIN_VALUE",
        "MAX_VALUE",
        "VALUE_CARDINALITY"::float,
        "INFORMATION_DENSITY"::float,
        "MOST_COMMON_VALUES"
    )))
)
select "DATABASE_NAME",
        "SCHEMA_NAME",
        "TABLE_NAME",
        "COLUMN_NAME",
        HAS_INFORMATION,
        VALUE_CARDINALITY as SAMPLE_VALUE_CARDINALITY,
        INFORMATION_DENSITY,
        "DATA_TYPE" as DEFINED_TYPE,
        INFERRED_TYPE,
        CONFIDENCE_LEVEL,
            DEFINED_TYPE <> INFERRED_TYPE and
            not (DEFINED_TYPE = 'NUMBER' and INFERRED_TYPE = 'INTEGER' and NUMERIC_SCALE = 0) and
            not (DEFINED_TYPE = 'TIMESTAMP_NTZ' and INFERRED_TYPE = 'TIMESTAMP') and
            not (DEFINED_TYPE = 'NUMBER' and INFERRED_TYPE = 'FLOAT' and NUMERIC_SCALE != 0) and
            CONFIDENCE_LEVEL <> '-' as HAS_TYPE_MISMATCH,
        MOST_COMMON_VALUES,
        MIN_VALUE,
        MAX_VALUE,
        CHARACTER_MAX_LENGTH,
        NUMERIC_PRECISION,
        NUMERIC_SCALE,
        DATETIME_PRECISION,
        PROFILE_TIMESTAMP,
        TOTAL_COUNT,                                                                                                                                -- New
        SAMPLE_COUNT,                                                                                                                               -- Renamed
        iff(SAMPLE_COUNT = 0, 0, TOTAL_COUNT / SAMPLE_COUNT) as SAMPLE_RATIO,                                                                       -- New
        NULL_COUNT as SAMPLED_NULL_COUNT,                                                                                                           -- Renamed
        BLANK_VALUES as SAMPLED_BLANK_VALUES,                                                                                                       -- Renamed
        round(SAMPLED_BLANK_VALUES + SAMPLED_NULL_COUNT * SAMPLE_RATIO) as ESTIMATED_TOTAL_NULL_COUNT,                                              -- New
        round(SAMPLED_BLANK_VALUES * SAMPLE_RATIO) as ESTIMATED_TOTAL_BLANK_COUNT,                                                                  -- New
        ESTIMATED_TOTAL_NULL_COUNT + ESTIMATED_TOTAL_BLANK_COUNT as ESTIMATED_TOTAL_FILLED_VALUES,                                                  -- New
        iff(SAMPLE_COUNT = 0, 0, (SAMPLE_COUNT - (SAMPLED_NULL_COUNT + SAMPLED_BLANK_VALUES)) / SAMPLE_COUNT) as ESTIMATED_RATIO_FILLED_VALUES,     --New
        CARDINALITY as SAMPLED_CARDINALITY,
        IS_UNIQUE,
        FLOAT_COUNT,
        INTEGER_COUNT,
        DECIMAL_COUNT,
        BOOLEAN_COUNT,
        TIMESTAMP_COUNT,
        DATE_COUNT,
        TIME_COUNT,
        MIN_LENGTH,
        AVG_LENGTH,
        MAX_LENGTH,
        IS_NUMERIC,
        IS_INTEGER,
        PUNCTUATION_COUNT,
        NON_ASCII_COUNT,
        NON_PRINTABLE_COUNT,
        MULTI_LINE_COUNT,
        INFORMATION_ENTROPY,
        ENTROPY_RATIO
from COLS; 

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

create or replace table DATA_PROFILING_COLUMN_NAME_FINDINGS(
                                                    "DATABASE_NAME"     string,
                                                    "SCHEMA_NAME"       string,
                                                    "TABLE_NAME"        string,
                                                    "COLUMN_NAME"       string,
                                                    "ORDINAL_POSITION"  string,
                                                    "RULE_NAME"         string,
                                                    "FINDING_TIME"      timestamp_tz default current_timestamp(),
                                                    "SEEMS_TO_HAVE"     string
);

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

create or replace procedure DATA_PROFILE_COLUMN_NAMES("DATABASE_PATTERN"           string,
                                                      "SCHEMA_PATTERN"             string,
                                                      "TABLE_PATTERN"              string,
                                                      "COLUMN_PATTERN"             string)
returns variant
language javascript
as
$$

/********************************************************************************************************
*                                                                                                       *
*  Class Definitions                                                                                    *
*                                                                                                       *
********************************************************************************************************/

class Account {
    constructor(databases){
        this.databases = databases;
    }
}

class Database {
    constructor(name) {
        this.name = name;
    }
}

class Query{
    constructor(statement){
        this.statement = statement;
    }
}

class Finding{}

class Results{}

/********************************************************************************************************
*                                                                                                       *
*  Main Function                                                                                        *
*                                                                                                       *
********************************************************************************************************/

var out = {};

try{
  r = GetFindings(DATABASE_PATTERN, SCHEMA_PATTERN, TABLE_PATTERN, COLUMN_PATTERN);
  out["Column_Name_Findings_Inserted"] = r.findings;
  out["Columns_Scanned"] = r.checked;
}
catch(err){
    out["Error"] = err.message;
}

return out;

/********************************************************************************************************
*                                                                                                       *
*  Helper functions                                                                                     *
*                                                                                                       *
********************************************************************************************************/

function InsertFindings(findings){

    var s;
    var pass = 0;
    var values = '';

    for (var i = 0; i < findings.length; i++){
        
        if(pass++ > 0) values += ",\n";
    
        values += "('" + findings[i].database + "','" + findings[i].schema + "','" + findings[i].tableName + "','" + findings[i].columnName + "'," +
                  findings[i].ordinalPosition + ",'" + findings[i].ruleName + "','" + findings[i].ruleComment + "')"
    }

    if (values === "") return;

    var sql = 
`insert into DATA_PROFILING_COLUMN_NAME_FINDINGS 
        ("DATABASE_NAME", "SCHEMA_NAME", "TABLE_NAME", "COLUMN_NAME", "ORDINAL_POSITION", "RULE_NAME", "SEEMS_TO_HAVE")
values ${values}`;

    ExecuteNonQuery(sql);
    return findings.length;
}

function GetFindings(databasePattern, schemaPattern, tablePattern, columnPattern){

    var finding;
    var findingBlock = [];
    var inserted = 0;
    var cols = 0;

    var query = ExecuteQuery(`select * from DATA_PROFILING_COLUMN_NAMES_REGEX where IS_ENABLED;`);
    var rxRules = QueryToJSON(query);

    var ruleNameCol     = rxRules.columnList.indexOf("RULE_NAME");
    var ruleRegexCol    = rxRules.columnList.indexOf("REGEX");
    var ruleRegexNegCol = rxRules.columnList.indexOf("REGEX_NEGATIVE");
    var ruleRegexDesc   = rxRules.columnList.indexOf("DESCRIPTION");
    var ruleHits = {};
    var rule, ruleRegex, ruleRegexNeg, isMatched;

    var account = GetDatabasesInAccount(databasePattern);
    for (var i = 0; i < account.databases.length; i++){
        query = ExecuteQuery(GetColumnSQL(account.databases[i], schemaPattern, tablePattern, columnPattern));
        while(query.resultSet.next()){
            cols++;
            for (rule = 0; rule < rxRules.values.length; rule++){
                isMatched = false;
                if(query.resultSet.getColumnValueAsString("TABLE_SCHEMA") != "INFORMATION_SCHEMA"){
                    ruleRegex = new RegExp(rxRules.values[rule][ruleRegexCol], "i");
                    if (query.resultSet.getColumnValueAsString(1).search(ruleRegex) != -1){
                        if (rxRules.values[rule][ruleRegexNegCol] != null){
                            ruleRegexNeg = new RegExp(rxRules.values[rule][ruleRegexNegCol], "i");
                            if (query.resultSet.getColumnValueAsString(1).search(ruleRegexNeg) == -1) {
                                isMatched = true;
                            }
                        }
                        else{
                            isMatched = true;  
                        }
                    }
                    if(isMatched){
                        finding = new Finding();
                        finding.ruleName        = rxRules.values[rule][ruleNameCol].toString();
                        finding.ruleComment     = rxRules.values[rule][ruleRegexDesc].toString();
                        finding.columnName      = query.resultSet.getColumnValueAsString("COLUMN_NAME");
                        finding.database        = account.databases[i].name;
                        finding.schema          = query.resultSet.getColumnValueAsString("TABLE_SCHEMA");
                        finding.tableName       = query.resultSet.getColumnValueAsString("TABLE_NAME");
                        finding.ordinalPosition = query.resultSet.getColumnValue("ORDINAL_POSITION");
                        findingBlock.push(finding);
                        if (findingBlock.length == 1000){
                            InsertFindings(findingBlock);
                            inserted += 1000;
                            findingBlock = [];
                        }
                    } // end if (isMatched)
                } // end if (regex match)
            } // end for (rule)
        } // end while (queryresult)
    } // end for (databases)
    if (findingBlock.length != 0){
        InsertFindings(findingBlock);
        inserted += findingBlock.length;
    }
results = new Results();
results.findings = inserted;
results.checked = cols;
return results;
}

/********************************************************************************************************
*                                                                                                       *
*  SQL Functions                                                                                        *
*                                                                                                       *
********************************************************************************************************/

function ExecuteNonQuery(queryString) {
    var out = '';
    cmd1 = {sqlText: queryString};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    rs = stmt.execute();
}

function QueryToJSON(query){
    var json = {};
    var col = [];
    var row = [];
    var r,c;
    for (c = 1; c <= query.statement.columnCount; c++){
        col.push(query.statement.getColumnName(c));
    }
    json["columnList"] = col;

    while(query.resultSet.next()){
        col = [];
        for (c = 1; c <= query.statement.columnCount; c++){
            col.push(query.resultSet.getColumnValue(c));
        }
        row.push(col);
    }
    json["values"] = row;
    return json;
}

function ExecuteQuery(sql){
    cmd1 = {sqlText: sql};
    var query = new Query(snowflake.createStatement(cmd1));
    query.resultSet = query.statement.execute();
    return query;
}

function WrapInsertValue(value, dataType){
    if (value == 'null'){
        return 'NULL';
    }
    switch (dataType){
        case "TEXT":
            return "'" + escapeInsertString(value) + "'";
        case "OBJECT":
            return "'" + escapeInsertString(value) + "'";
        case "TIMESTAMP_TZ":
            return "'" + value + "'";
        case "TIMESTAMP":
            return "'" + value + "'";
        default: return value;
    }
}

function escapeInsertString(value) {
    var s = value.replace(/\\/g, "\\\\");
    s = s.replace(/'/g, "''" );
    s = s.replace(/"/g, '\\"');
    s = s.replace(/\s+/g, " ");
//  s = s.replace(/[^\x00-\x7F]/g, "");
    return s;
}
  
function GetColumnSQL(database, schemaPattern, tablePattern, columnPattern){
sql=
`
select  COLUMN_NAME,
        TABLE_CATALOG,
        TABLE_SCHEMA,
        TABLE_NAME,
        ORDINAL_POSITION,
        DATA_TYPE
from "${database.name}"."INFORMATION_SCHEMA"."COLUMNS"
where   TABLE_SCHEMA rlike '${schemaPattern}' and
        TABLE_NAME   rlike '${tablePattern}'  and
        COLUMN_NAME  rlike '${columnPattern}'
`;
return sql;
}

function GetDatabasesInAccount(databasePattern){
    var db = ExecuteSingleValueQuery("name", "show databases");
    var i = 0;
    var dbRS = GetResultSet(`select DATABASE_NAME from "${db}".INFORMATION_SCHEMA.DATABASES where rlike (DATABASE_NAME, '${databasePattern}');`);
    var databases = [];
    var db;
    while (dbRS.next()){
        db = new Database(dbRS.getColumnValue("DATABASE_NAME"));
        databases.push(db);
    }
    return new Account(databases);
}

function ExecuteSingleValueQuery(columnName, queryString) {
    var out;
    cmd1 = {sqlText: queryString};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    rs = stmt.execute();
    rs.next();
    return rs.getColumnValue(columnName);
    return out;
}

function GetResultSet(sql){
    cmd1 = {sqlText: sql};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    rs = stmt.execute();
    return rs;
}
$$;

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

create or replace view DATA_PROFILE_COLUMN_NAMES as
select  D."DATABASE_NAME",
        D."SCHEMA_NAME",
        D."TABLE_NAME",
        D."COLUMN_NAME",
        D."SEEMS_TO_HAVE",
        D."RULE_NAME",
        R."CATEGORIES",
        D."ORDINAL_POSITION",
        D."FINDING_TIME"
from DATA_PROFILING_COLUMN_NAME_FINDINGS D
    left join DATA_PROFILING_COLUMN_NAMES_REGEX R on
        D.RULE_NAME = R.RULE_NAME;

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

create or replace table DATA_PROFILING_REGEXP_RULES(
    RULE_NAME               string      not null                comment 'Data Profiling regular expression rule name.',
    IS_ENABLED              boolean     not null default true   comment 'Flags whether Data Profiling will run this regular expression rule.',
    RULE_DESCRIPTION        string                              comment 'Description of a Data Profiling regular expresion rule.', 
    REGEX                   string      not null                comment 'The regular expression to run for a Data Profiling rule.',   
    REGEX_PARAMS            string      not null default 'im'   comment 'The regular expression parameters to use when running this Data Profiling rule.',
    CONFIDENCE_RATIO        float       not null default 1      comment 'Indicates the approximate accuracy of the regular expression Data Profiling rule.'
);

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

insert into DATA_PROFILING_REGEXP_RULES(CONFIDENCE_RATIO, RULE_NAME, RULE_DESCRIPTION, REGEX)
values
( 99.0,  'EMAIL',                'Email in any part of the text',                                       '\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4}\\b'),
( 80.0,  'NA_PHONE',             'Phone numbers formatted in the North American Numbering Plan',        '\\b[2-9]\\d{2}-\\d{3}-\\d{4}|\\([2-9]\\d{2}\\) \\d{3}-\\d{4}\\b'),
( 90.0,  'US_SSN',               'US Social Security numbers formatted as 123-45-6789',                 '\\b[1-8]\\d{2}-\\d{2}-\\d{4}\\b'),
( 80.0,  'IPV4',                 'IPv4 formatted as dotted quad such as 192.168.1.1',                   '\\b(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\b'),
( 95.0,  'MAC_ADDRESS',          'Media Access Control (MAC) address as hex pairs separated by colins', '\\b[0-9A-F]{2}\\:[0-9A-F]{2}\\:[0-9A-F]{2}\\:[0-9A-F]{2}\\:[0-9A-F]{2}\\:[0-9A-F]{2}\\b'),
( 99.0,  'NON_SECURE_HYPERLINK', 'Non-secure http or ftp hyperlink',                                    '\\b(http|ftp)://.*\\b'),
( 99.0,  'SECURE_HYPERLINK',     'Secure https or sftp hyperlink',                                      '\\b(https|sftp)://.*\\b'),
( 95.0,  'UNC_PATH',             'UNC (network share) path',                                            '\\\\[A-Z0-9\\._-]{1,64}'),
( 80.0,  'EN_STREET_ADDRESS',    'English language street addresses',                                   '\\b(\\d{1,5}\\s(\\b\\w*\\b\\s){1,2}(AVE|BLVD|CT|DR|EXPY|FWY|HWY|LN|LOOP|PKWY|PASS|PLZ|PT|RD|ST|TRL|VIS|WAY))|(P\\.?O\\.?\\sBOX\\s\\d{1,6})\\b'),
( 95.0,  'HL7_MESSAGE',          'HL-7 message in well-formatted form',                                 'MSH\\|\\^~\\\\&\\|'),
(100.0,  'UUID',                 'Universally (or globally) unique identifier, UUID or GUID',           '\\b[{|\(]?[0-9A-F]{8}[-]?([0-9A-F]{4}[-]?){3}[0-9A-F]{12}[\)|}]?\\b'),
( 90.0,  'WIN_FILE_PATH',        'Microsoft Windows local file path',                                   '\\b[A-Z]{1}:\\\\'),
( 80.0,  'COPYRIGHT',            'Copyright notice',                                                    '(\\xA9)|(\\(C\\))|(COPYRIGHT)'),
( 98.0,  'ISBN_13',              'International Standard Book Number version 13',                       '\\b\\d{3}-\\d-\\d{2}-\\d{6}-\\d\\b'),
( 50.0,  'SALESFORCE_ID',        'Salesforce ID or CaseSafeID',                                         '\\b[A-Z0-9]{15}\\b|\\b[A-Z0-9]{18}\\b')
;
-- NOTE: Salesforce IDs are 15-character base 62 numbers. CaseSafe IDs are used for products that are not case sensitive like Excel.

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  
select 'Installation of Data Profiling is complete.' as INSTALL_STATUS;  
