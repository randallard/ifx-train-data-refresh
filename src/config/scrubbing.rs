use serde::Deserialize;

#[derive(Debug, Deserialize, PartialEq)]
pub struct ScrubbingConfig {
    pub random_names: Vec<RandomNameConfig>,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct RandomNameConfig {
    pub table: String,
    pub fields: Vec<String>,
    pub style: String,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct StandardizeConfig {
    pub address: StandardizeField,
    pub phone: StandardizeField,
    pub email: StandardizeField,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct StandardizeField {
    pub value: String,
    pub fields: Vec<TableField>,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct TableField {
    pub table: String,
    pub field: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scrubbing_config_parsing() {
        let config_str = r#"
            random_names:
                - table: customers
                  fields: [first_name, last_name]
                  style: github
                - table: employees
                  fields: [name]
                  style: github
        "#;

        let config: ScrubbingConfig = serde_yaml::from_str(config_str).unwrap();
        assert_eq!(config.random_names.len(), 2);
        assert_eq!(config.random_names[0].table, "customers");
        assert_eq!(config.random_names[0].fields, vec!["first_name", "last_name"]);
        assert_eq!(config.random_names[0].style, "github");
    }

    #[test]
    fn test_standardize_config_parsing() {
        let config_str = r#"
            address:
                value: "123 Training St, Test City, ST 12345"
                fields:
                    - table: customers
                      field: address
            phone:
                value: "555-0123"
                fields:
                    - table: customers
                      field: phone
            email:
                value: "test@example.com"
                fields:
                    - table: customers
                      field: email
        "#;

        let config: StandardizeConfig = serde_yaml::from_str(config_str).unwrap();
        assert_eq!(config.address.value, "123 Training St, Test City, ST 12345");
        assert_eq!(config.phone.value, "555-0123");
        assert_eq!(config.email.value, "test@example.com");
    }
}
