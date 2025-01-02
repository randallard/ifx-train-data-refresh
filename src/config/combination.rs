use serde::Deserialize;

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct CombinationFieldConfig {
    pub table: String,
    pub fields: Vec<SourceField>,
    pub separator: String,
    pub target_field: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct SourceField {
    pub source_field: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use crate::error::Error;
    use crate::config::{Config, StandardizeConfig};
    use crate::processor::sql::TableInfo;
    use crate::processor::unl::{UnlProcessor, UnlRow};
    use serde_yaml;
    
    #[test]
    fn test_combination_fields() -> Result<(), Error> {
        // Create test configuration with the correct combination_fields format
        let config_str = r#"
            databases:
                source: { name: test_live }
                target: { name: temp_verify }
                testing:
                    test_live: test_live
                    temp_verify: temp_verify
                    verification_marker: "VERIFY_TEST_STRING_XYZ_"
                    cleanup_script: remove_verify_db.sh
            export:
                random_seed: 42
            excluded_tables: []
            verification:
                logging:
                    directory: logs
                    prefix: verify_
                checksums:
                    enabled: true
                    algorithm: md5sum
                record_counts:
                    enabled: true
                    sample_tables: []
            scrubbing:
                random_names: []
            standardize:
                address: { value: "", fields: [] }
                phone: { value: "", fields: [] }
                email: { value: "", fields: [] }
            combination_fields:
                - table: projects
                  fields:
                    - source_field: name1
                    - source_field: name2
                  separator: " -&- "
                  target_field: combo_name
                - table: repositories
                  fields:
                    - source_field: owner_name
                    - source_field: repo_name
                  separator: "/"
                  target_field: full_path
        "#;
        let config = Config::from_str(config_str)?;
    
        // Create test table information
        let mut table_info = HashMap::new();
        table_info.insert(
            "projects".to_string(),
            TableInfo {
                unl_file: "proje00102.unl".to_string(),
                fields: vec![
                    "id".to_string(),
                    "customer_id".to_string(),
                    "project_name".to_string(),
                    "name1".to_string(),
                    "name2".to_string(),
                    "combo_name".to_string(),
                ],
            },
        );
        table_info.insert(
            "repositories".to_string(),
            TableInfo {
                unl_file: "repos00103.unl".to_string(),
                fields: vec![
                    "id".to_string(),
                    "project_id".to_string(),
                    "owner_name".to_string(),
                    "repo_name".to_string(),
                    "full_path".to_string(),
                ],
            },
        );
    
        // Create UnlProcessor with minimal word lists (not needed for combination testing)
        let processor = UnlProcessor::new(
            config,
            table_info,
            vec!["test".to_string()],
            vec!["test".to_string()],
        );
    
        // Test projects table combination
        let mut project_row = UnlRow {
            fields: vec![
                "1".to_string(),
                "1001".to_string(),
                "TestProject".to_string(),
                "FirstName1".to_string(),
                "LastName1".to_string(),
                "".to_string(),  // combo_name will be populated
            ],
        };
        processor.process_row("projects", &mut project_row)?;
        assert_eq!(
            project_row.get_field(5).unwrap(),
            "FirstName1 -&- LastName1",
            "Projects table combination failed"
        );
    
        // Test repositories table combination
        let mut repo_row = UnlRow {
            fields: vec![
                "1".to_string(),
                "1".to_string(),
                "OwnerA".to_string(),
                "RepoB".to_string(),
                "".to_string(),  // full_path will be populated
            ],
        };
        processor.process_row("repositories", &mut repo_row)?;
        assert_eq!(
            repo_row.get_field(4).unwrap(),
            "OwnerA/RepoB",
            "Repositories table combination failed"
        );
    
        Ok(())
    }
    
    #[test]
    fn test_combination_fields_errors() -> Result<(), Error> {
        // Create config with invalid field references
        let config_str = r#"
            databases:
                source: { name: test_live }
                target: { name: temp_verify }
                testing:
                    test_live: test_live
                    temp_verify: temp_verify
                    verification_marker: "VERIFY_TEST_STRING_XYZ_"
                    cleanup_script: remove_verify_db.sh
            export:
                random_seed: 42
            excluded_tables: []
            verification:
                logging:
                    directory: logs
                    prefix: verify_
                checksums:
                    enabled: true
                    algorithm: md5sum
                record_counts:
                    enabled: true
                    sample_tables: []
            scrubbing:
                random_names: []
            standardize:
                address: { value: "", fields: [] }
                phone: { value: "", fields: [] }
                email: { value: "", fields: [] }
            combination_fields:
                - table: projects
                  fields:
                    - source_field: nonexistent_field1
                    - source_field: nonexistent_field2
                  separator: " -&- "
                  target_field: combo_name
        "#;
        let config = Config::from_str(config_str)?;
    
        // Create table info with fields that don't match config
        let mut table_info = HashMap::new();
        table_info.insert(
            "projects".to_string(),
            TableInfo {
                unl_file: "proje00102.unl".to_string(),
                fields: vec![
                    "id".to_string(),
                    "customer_id".to_string(),
                    "project_name".to_string(),
                    "actual_field1".to_string(),
                    "actual_field2".to_string(),
                    "combo_name".to_string(),
                ],
            },
        );
    
        let processor = UnlProcessor::new(
            config,
            table_info,
            vec!["test".to_string()],
            vec!["test".to_string()],
        );
    
        let mut row = UnlRow {
            fields: vec![
                "1".to_string(),
                "1001".to_string(),
                "TestProject".to_string(),
                "Value1".to_string(),
                "Value2".to_string(),
                "".to_string(),
            ],
        };
    
        // Process should return error when source fields don't exist
        let result = processor.process_row("projects", &mut row);
        assert!(result.is_err(), "Should fail with nonexistent source fields");
    
        Ok(())
    }

    #[test]
    fn test_combination_config_parsing() {
        let config_str = r#"
            table: projects
            fields:
                - source_field: name1
                - source_field: name2
            separator: " -&- "
            target_field: combo_name
        "#;

        let config: CombinationFieldConfig = serde_yaml::from_str(config_str).unwrap();
        assert_eq!(config.table, "projects");
        assert_eq!(config.fields.len(), 2);
        assert_eq!(config.separator, " -&- ");
        assert_eq!(config.target_field, "combo_name");
    }

    
}
