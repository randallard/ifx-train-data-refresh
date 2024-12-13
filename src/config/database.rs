use serde::Deserialize;

#[derive(Debug, Deserialize, PartialEq)]
pub struct DatabaseConfig {
    pub source: DbInstance,
    pub target: DbInstance,
    pub testing: TestingConfig,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct DbInstance {
    pub name: String,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct TestingConfig {
    pub test_live: String,
    pub temp_verify: String,
    pub verification_marker: String,
    pub cleanup_script: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_database_config_parsing() {
        let config_str = r#"
            source:
                name: test_live
            target:
                name: temp_verify
            testing:
                test_live: test_live
                temp_verify: temp_verify
                verification_marker: "VERIFY_TEST_STRING_XYZ_"
                cleanup_script: remove_verify_db.sh
        "#;

        let config: DatabaseConfig = serde_yaml::from_str(config_str).unwrap();
        assert_eq!(config.source.name, "test_live");
        assert_eq!(config.target.name, "temp_verify");
        assert_eq!(config.testing.verification_marker, "VERIFY_TEST_STRING_XYZ_");
        assert_eq!(config.testing.cleanup_script, "remove_verify_db.sh");
    }
}
