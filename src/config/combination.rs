use serde::Deserialize;

#[derive(Debug, Deserialize, PartialEq)]
pub struct CombinationFieldConfig {
    pub table: String,
    pub fields: Vec<SourceField>,
    pub separator: String,
    pub target_field: String,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct SourceField {
    pub source_field: String,
    pub random_style: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_combination_config_parsing() {
        let config_str = r#"
            table: projects
            fields:
                - source_field: name1
                  random_style: github
                - source_field: name2
                  random_style: github
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
