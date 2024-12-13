use serde::Deserialize;

#[derive(Debug, Deserialize, PartialEq)]
pub struct VerificationConfig {
    pub logging: LoggingConfig,
    pub checksums: ChecksumConfig,
    pub record_counts: RecordCountConfig,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct LoggingConfig {
    pub directory: String,
    pub prefix: String,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct ChecksumConfig {
    pub enabled: bool,
    pub algorithm: String,
}

#[derive(Debug, Deserialize, PartialEq)]
pub struct RecordCountConfig {
    pub enabled: bool,
    pub sample_tables: Vec<String>,
}
