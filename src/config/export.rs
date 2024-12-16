use serde::Deserialize;

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct ExportConfig {
    pub random_seed: u64,
}
