use std::collections::HashMap;
use crate::error::Error;
use regex::Regex;

#[derive(Clone, Debug, PartialEq)]
pub struct TableInfo {
    pub unl_file: String,
    pub fields: Vec<String>,
}

pub fn parse_sql_file(sql: &str) -> Result<HashMap<String, TableInfo>, Error> {
    let mut tables = HashMap::new();
    
    // Regular expressions for parsing
    let unl_file_re = Regex::new(r#"\{\s*unload\s+file\s+name\s*=\s*(\S+\.unl)\s*"#)
        .map_err(|e| Error::Processing(format!("Invalid regex: {}", e)))?;
    
    let create_table_re = Regex::new(r#"(?s)create\s+table\s+"informix"\.?"?([^"\s]+)"?\s*\((.*?)\)\s*extent"#)
        .map_err(|e| Error::Processing(format!("Invalid regex: {}", e)))?;
    
    let field_re = Regex::new(r#"(?m)^\s*"?([^",\s]+)"?\s+(?:serial|integer|varchar|char|date|datetime|decimal|blob|set)[^,]*"#)
        .map_err(|e| Error::Processing(format!("Invalid regex: {}", e)))?;
    
    // Split into table blocks
    let blocks: Vec<&str> = sql.split("{ TABLE").collect();
    
    for block in blocks.iter().skip(1) { // Skip first empty block
        // Extract UNL filename
        let unl_file = match unl_file_re.captures(block) {
            Some(caps) => caps.get(1).unwrap().as_str().to_string(),
            None => continue, // Skip if no UNL file found
        };
        
        // Extract table name and fields
        if let Some(table_caps) = create_table_re.captures(block) {
            let table_name = table_caps.get(1).unwrap().as_str().to_string();
            let fields_section = table_caps.get(2).unwrap().as_str();
            
            // Extract field names
            let fields: Vec<String> = field_re.captures_iter(fields_section)
                .filter_map(|caps| caps.get(1))
                .map(|m| m.as_str().to_string())
                .collect();
            
            if fields.is_empty() {
                return Err(Error::Processing(format!("No fields found in table {}", table_name)));
            }
            
            tables.insert(table_name, TableInfo { unl_file, fields });
        }
    }
    
    if tables.is_empty() {
        return Err(Error::Processing("No valid tables found in SQL file".to_string()));
    }
    
    Ok(tables)
}

#[test]
fn test_parse_create_table_statements() {
    let sql = r#"
        { DATABASE test_live  delimiter | }

        { TABLE "informix".customers row size = 429 number of columns = 6 index size = 0 }
        { unload file name = custo00100.unl number of rows = 73 }
        create table "informix".customers 
        (
            id serial not null,
            first_name varchar(50),
            last_name varchar(50),
            email varchar(100),
            address varchar(200),
            phone varchar(20)
        ) extent size 16 next size 16 lock mode row;

        { TABLE "informix".employees row size = 432 number of columns = 6 index size = 0 }
        { unload file name = emplo00101.unl number of rows = 53 }
        create table "informix".employees 
        (
            id serial not null,
            customer_id integer,
            name varchar(100),
            email varchar(100),
            address varchar(200),
            phone varchar(20)
        ) extent size 16 next size 16 lock mode row;
    "#;

    let result = parse_sql_file(sql).unwrap();
    
    let expected = {
        let mut tables = HashMap::new();
        
        tables.insert(
            "customers".to_string(),
            TableInfo {
                unl_file: "custo00100.unl".to_string(),
                fields: vec![
                    "id".to_string(),
                    "first_name".to_string(),
                    "last_name".to_string(),
                    "email".to_string(),
                    "address".to_string(),
                    "phone".to_string(),
                ],
            }
        );
        
        tables.insert(
            "employees".to_string(),
            TableInfo {
                unl_file: "emplo00101.unl".to_string(),
                fields: vec![
                    "id".to_string(),
                    "customer_id".to_string(),
                    "name".to_string(),
                    "email".to_string(),
                    "address".to_string(),
                    "phone".to_string(),
                ],
            }
        );
        
        tables
    };

    assert_eq!(result, expected);
}

#[test]
fn test_parse_table_with_complex_fields() {
    let sql = r#"
        { TABLE "informix".complex_table row size = 500 number of columns = 8 index size = 0 }
        { unload file name = compl00102.unl number of rows = 100 }
        create table "informix".complex_table 
        (
            id serial not null,
            decimal_field decimal(10,2),
            date_field date,
            timestamp_field datetime year to fraction(5),
            blob_field blob,
            list_field set(integer not null),
            varying_field varchar(255, 512),
            fixed_field char(10)
        ) extent size 16 next size 16 lock mode row;
    "#;

    let result = parse_sql_file(sql).unwrap();
    
    let expected = {
        let mut tables = HashMap::new();
        
        tables.insert(
            "complex_table".to_string(),
            TableInfo {
                unl_file: "compl00102.unl".to_string(),
                fields: vec![
                    "id".to_string(),
                    "decimal_field".to_string(),
                    "date_field".to_string(),
                    "timestamp_field".to_string(),
                    "blob_field".to_string(),
                    "list_field".to_string(),
                    "varying_field".to_string(),
                    "fixed_field".to_string(),
                ],
            }
        );
        
        tables
    };

    assert_eq!(result, expected);
}

#[test]
fn test_error_handling() {
    // Test missing unload file name
    let sql = r#"
        { TABLE "informix".missing_unl row size = 100 number of columns = 2 index size = 0 }
        create table "informix".missing_unl 
        (
            id serial not null,
            name varchar(50)
        ) extent size 16 next size 16 lock mode row;
    "#;
    assert!(parse_sql_file(sql).is_err());

}