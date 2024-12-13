use serde::Deserialize;

#[derive(Debug, Deserialize, PartialEq)]
pub struct ExportConfig {
    pub random_seed: u64,
}
