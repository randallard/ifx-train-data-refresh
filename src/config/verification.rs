use serde::Deserialize;

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct VerificationConfig {
    pub logging: LoggingConfig,
    pub checksums: ChecksumConfig,
    pub record_counts: RecordCountConfig,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct LoggingConfig {
    pub directory: String,
    pub prefix: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct ChecksumConfig {
    pub enabled: bool,
    pub algorithm: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct RecordCountConfig {
    pub enabled: bool,
    pub sample_tables: Vec<String>,
}
