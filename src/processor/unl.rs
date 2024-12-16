use std::path::Path;
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::collections::HashMap;
use crate::error::Error;
use crate::config::{Config, ScrubbingConfig, RandomNameConfig};
use crate::processor::sql::TableInfo;

// Struct to represent a row in a UNL file
#[derive(Debug, PartialEq)]
pub struct UnlRow {
    fields: Vec<String>,
}

impl UnlRow {
    pub fn get_field(&self, index: usize) -> Option<&str> {
        self.fields.get(index).map(|s| s.as_str())
    }

    pub fn set_field(&mut self, index: usize, value: String) -> Result<(), Error> {
        if index >= self.fields.len() {
            return Err(Error::Processing(format!(
                "Field index {} out of bounds for row with {} fields",
                index,
                self.fields.len()
            )));
        }
        self.fields[index] = value;
        Ok(())
    }
    
    pub fn from_line(line: &str) -> Result<Self, Error> {
        // Remove trailing pipe if it exists to avoid empty last field
        let line = line.strip_suffix('|').unwrap_or(line);
        Ok(UnlRow {
            fields: line.split('|').map(String::from).collect()
        })
    }

    pub fn to_line(&self) -> String {
        self.fields.join("|") + "|"  // UNL format requires trailing pipe
    }
}

pub struct UnlProcessor {
    config: Config,
    table_info: HashMap<String, TableInfo>,
    adjectives: Vec<String>,
    nouns: Vec<String>,
}

impl UnlProcessor {
    pub fn new(
        config: Config,
        table_info: HashMap<String, TableInfo>,
        adjectives: Vec<String>,
        nouns: Vec<String>,
    ) -> Self {
        Self {
            config,
            table_info,
            adjectives,
            nouns,
        }
    }

    pub fn process_file(&self, table_name: &str, input_path: &Path, output_path: &Path) -> Result<(), Error> {
        let file = File::open(input_path)?;
        let reader = BufReader::new(file);
        let output = File::create(output_path)?;
        let mut writer = BufWriter::new(output);

        for line in reader.lines() {
            let line = line?;
            let mut row = UnlRow::from_line(&line)?;
            self.process_row(table_name, &mut row)?;
            writeln!(writer, "{}", row.to_line())?;
        }

        writer.flush()?;
        Ok(())
    }

    fn process_row(&self, table_name: &str, row: &mut UnlRow) -> Result<(), Error> {
        // Apply random name scrubbing
        for config in &self.config.scrubbing.random_names {
            if config.table == table_name {
                for field in &config.fields {
                    if let Some(idx) = find_field_index_by_table(table_name, field, &self.table_info)? {
                        let new_name = self.generate_random_name(&config.style)?;
                        row.set_field(idx, new_name)?;
                    }
                }
            }
        }

        // Apply standardization
        self.apply_standardization(table_name, row)?;

        // Apply field combinations
        self.apply_combinations(table_name, row)?;

        Ok(())
    }

    fn generate_random_name(&self, style: &str) -> Result<String, Error> {
        use rand::seq::SliceRandom;
        let mut rng = rand::thread_rng();
        
        match style {
            "github" => {
                let adj = self.adjectives.choose(&mut rng)
                    .ok_or_else(|| Error::Processing("No adjectives available".to_string()))?;
                let noun = self.nouns.choose(&mut rng)
                    .ok_or_else(|| Error::Processing("No nouns available".to_string()))?;
                Ok(format!("{}-{}", adj, noun))
            }
            _ => Err(Error::Config(format!("Unsupported name style: {}", style)))
        }
    }

    fn apply_standardization(&self, table_name: &str, row: &mut UnlRow) -> Result<(), Error> {
        // Apply address standardization
        for field_config in &self.config.standardize.address.fields {
            if field_config.table == table_name {
                if let Some(idx) = find_field_index_by_table(table_name, &field_config.field, &self.table_info)? {
                    row.set_field(idx, self.config.standardize.address.value.clone())?;
                }
            }
        }

        // Apply phone standardization
        for field_config in &self.config.standardize.phone.fields {
            if field_config.table == table_name {
                if let Some(idx) = find_field_index_by_table(table_name, &field_config.field, &self.table_info)? {
                    row.set_field(idx, self.config.standardize.phone.value.clone())?;
                }
            }
        }

        // Apply email standardization
        for field_config in &self.config.standardize.email.fields {
            if field_config.table == table_name {
                if let Some(idx) = find_field_index_by_table(table_name, &field_config.field, &self.table_info)? {
                    row.set_field(idx, self.config.standardize.email.value.clone())?;
                }
            }
        }

        Ok(())
    }

    fn apply_combinations(&self, table_name: &str, row: &mut UnlRow) -> Result<(), Error> {
        for combo_config in &self.config.combination_fields {
            if combo_config.table == table_name {
                let mut combined_values = Vec::new();

                // Collect all source field values
                for field_config in &combo_config.fields {
                    if let Some(idx) = find_field_index_by_table(
                        table_name,
                        &field_config.source_field,
                        &self.table_info
                    )? {
                        let value = if field_config.random_style.is_empty() {
                            row.get_field(idx)
                                .ok_or_else(|| Error::Processing("Field index out of bounds".to_string()))?
                                .to_string()
                        } else {
                            self.generate_random_name(&field_config.random_style)?
                        };
                        combined_values.push(value);
                    }
                }

                // Combine values and set target field
                if let Some(target_idx) = find_field_index_by_table(
                    table_name,
                    &combo_config.target_field,
                    &self.table_info
                )? {
                    let combined = combined_values.join(&combo_config.separator);
                    row.set_field(target_idx, combined)?;
                }
            }
        }

        Ok(())
    }
}

// Function to find field index in a table schema
pub fn find_field_index(field_name: &str, table_fields: &[String]) -> Option<usize> {
    table_fields.iter().position(|f| f == field_name)
}

// Function to find field index using table name and field name
pub fn find_field_index_by_table(
    table_name: &str,
    field_name: &str,
    table_info: &HashMap<String, TableInfo>
) -> Result<Option<usize>, Error> {
    if let Some(table) = table_info.get(table_name) {
        Ok(find_field_index(field_name, &table.fields))
    } else {
        Err(Error::Processing(format!("Table '{}' not found", table_name)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;   
    use tempfile::NamedTempFile;
    use std::io::Write;

    // Helper function to create test table schema
    fn create_test_schema() -> Vec<String> {
        vec![
            "id".to_string(),
            "first_name".to_string(),
            "last_name".to_string(),
            "email".to_string(),
            "address".to_string(),
            "phone".to_string(),
        ]
    }

    // Helper function to create test TableInfo mapping
    fn create_test_table_info() -> HashMap<String, TableInfo> {
        let mut tables = HashMap::new();
        
        // Add customers table
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
        
        // Add employees table with different field names
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
    }

    fn create_test_row() -> UnlRow {
        UnlRow {
            fields: vec![
                "1001".to_string(),
                "Essential1".to_string(),
                "User1".to_string(),
                "essential1@example.com".to_string(),
                "123 Essential St".to_string(),
                "555-1001".to_string(),
            ],
        }
    }

    

    fn create_test_processor() -> UnlProcessor {
        // Create minimal test configuration
        let config = Config::from_str(include_str!("../../test_data/config.yml")).unwrap();
        
        // Create test table info
        let mut table_info = HashMap::new();
        table_info.insert(
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
            },
        );

        // Load test word lists
        let adjectives = vec!["happy".to_string(), "quick".to_string()];
        let nouns = vec!["fox".to_string(), "dog".to_string()];

        UnlProcessor::new(config, table_info, adjectives, nouns)
    }

    #[test]
    fn test_find_field_by_table() {
        let table_info = create_test_table_info();
        
        // Test finding fields in customers table
        assert_eq!(
            find_field_index_by_table("customers", "first_name", &table_info).unwrap(),
            Some(1)
        );
        assert_eq!(
            find_field_index_by_table("customers", "last_name", &table_info).unwrap(),
            Some(2)
        );
        
        // Test finding fields in employees table
        assert_eq!(
            find_field_index_by_table("employees", "name", &table_info).unwrap(),
            Some(2)
        );
        
        // Test finding non-existent field
        assert_eq!(
            find_field_index_by_table("customers", "nonexistent", &table_info).unwrap(),
            None
        );
        
        // Test finding field in non-existent table
        assert!(find_field_index_by_table("nonexistent", "name", &table_info).is_err());
    }

    #[test]
    fn test_find_scrubbing_fields_across_tables() {
        let table_info = create_test_table_info();
        
        // Test config for customers table
        let scrubbing_config = ScrubbingConfig {
            random_names: vec![
                RandomNameConfig {
                    table: "customers".to_string(),
                    fields: vec!["first_name".to_string(), "last_name".to_string()],
                    style: "github".to_string(),
                },
                RandomNameConfig {
                    table: "employees".to_string(),
                    fields: vec!["name".to_string()],
                    style: "github".to_string(),
                },
            ],
        };
        
        // Test customer fields
        let customer_config = &scrubbing_config.random_names[0];
        let customer_indices: Result<Vec<usize>, Error> = customer_config.fields
            .iter()
            .map(|field| find_field_index_by_table(&customer_config.table, field, &table_info))
            .collect::<Result<Vec<Option<usize>>, Error>>()
            .map(|v| v.into_iter().flatten().collect());
            
        assert_eq!(customer_indices.unwrap(), vec![1, 2]);
        
        // Test employee fields
        let employee_config = &scrubbing_config.random_names[1];
        let employee_indices: Result<Vec<usize>, Error> = employee_config.fields
            .iter()
            .map(|field| find_field_index_by_table(&employee_config.table, field, &table_info))
            .collect::<Result<Vec<Option<usize>>, Error>>()
            .map(|v| v.into_iter().flatten().collect());
            
        assert_eq!(employee_indices.unwrap(), vec![2]);
    }

    #[test]
    fn test_find_field_in_schema() {
        let schema = create_test_schema();
        
        // Test finding existing fields
        assert_eq!(find_field_index("first_name", &schema), Some(1));
        assert_eq!(find_field_index("last_name", &schema), Some(2));
        assert_eq!(find_field_index("email", &schema), Some(3));
        
        // Test finding non-existent field
        assert_eq!(find_field_index("nonexistent", &schema), None);
    }

    #[test]
    fn test_row_field_access() {
        let row = create_test_row();
        
        // Test getting existing fields
        assert_eq!(row.get_field(0), Some("1001"));
        assert_eq!(row.get_field(1), Some("Essential1"));
        
        // Test getting non-existent field
        assert_eq!(row.get_field(10), None);
    }

    #[test]
    fn test_row_field_modification() {
        let mut row = create_test_row();
        
        // Test setting existing field
        assert!(row.set_field(1, "NewName".to_string()).is_ok());
        assert_eq!(row.get_field(1), Some("NewName"));
        
        // Test setting out of bounds field
        assert!(row.set_field(10, "Invalid".to_string()).is_err());
    }

    #[test]
    fn test_find_scrubbing_fields() {
        let schema = create_test_schema();
        let config = RandomNameConfig {
            table: "customers".to_string(),
            fields: vec!["first_name".to_string(), "last_name".to_string()],
            style: "github".to_string(),
        };
        
        // Test finding all fields specified in config
        let field_indices: Vec<usize> = config.fields
            .iter()
            .filter_map(|field| find_field_index(field, &schema))
            .collect();
        
        assert_eq!(field_indices, vec![1, 2]);
    }

    #[test]
    fn test_find_nonexistent_scrubbing_fields() {
        let schema = create_test_schema();
        let config = RandomNameConfig {
            table: "customers".to_string(),
            fields: vec!["nonexistent1".to_string(), "nonexistent2".to_string()],
            style: "github".to_string(),
        };
        
        // Test finding non-existent fields
        let field_indices: Vec<usize> = config.fields
            .iter()
            .filter_map(|field| find_field_index(field, &schema))
            .collect();
        
        assert!(field_indices.is_empty());
    }

    #[test]
    fn test_process_file() -> Result<(), Error> {
        let processor = create_test_processor();

        // Create test input file
        let mut input_file = NamedTempFile::new()?;
        writeln!(input_file, "1001|John|Doe|john@example.com|123 Main St|555-1234|")?;
        writeln!(input_file, "1002|Jane|Smith|jane@example.com|456 Oak St|555-5678|")?;

        // Create output file
        let output_file = NamedTempFile::new()?;

        // Process the file
        processor.process_file(
            "customers",
            input_file.path(),
            output_file.path()
        )?;

        // Read and verify output
        let content = std::fs::read_to_string(output_file.path())?;
        let lines: Vec<&str> = content.lines().collect();

        // Verify number of output lines
        assert_eq!(lines.len(), 2);

        // Verify each line has been processed
        for line in lines {
            // Verify line ends with pipe
            assert!(line.ends_with('|'));
            
            // Split fields and verify count (6 fields + empty string after last pipe)
            let fields: Vec<&str> = line.split('|').collect();
            assert_eq!(fields.len(), 7, "Expected 6 fields plus empty string after final pipe");
            
            // Parse the line
            let row = UnlRow::from_line(line)?;
            
            // Verify standardized fields
            assert_eq!(row.get_field(4).unwrap(), "123 Training St, Test City, ST 12345");
            assert_eq!(row.get_field(5).unwrap(), "555-0123");
        }

        Ok(())
    }

    #[test]
    fn test_unl_row_parsing() -> Result<(), Error> {
        // Test parsing with trailing pipe
        let row = UnlRow::from_line("1|2|3|")?;
        assert_eq!(row.fields.len(), 3);
        assert_eq!(row.fields, vec!["1", "2", "3"]);

        // Test parsing without trailing pipe
        let row = UnlRow::from_line("1|2|3")?;
        assert_eq!(row.fields.len(), 3);
        assert_eq!(row.fields, vec!["1", "2", "3"]);

        Ok(())
    }

    #[test]
    fn test_unl_row_output() -> Result<(), Error> {
        let row = UnlRow {
            fields: vec!["1".to_string(), "2".to_string(), "3".to_string()]
        };
        assert_eq!(row.to_line(), "1|2|3|");
        Ok(())
    }
}