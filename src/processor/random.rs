use rand::seq::SliceRandom;
use rand::thread_rng;

pub fn generate_random_name(adjectives: &[String], nouns: &[String]) -> String {
    let mut rng = thread_rng();
    let noun = &"happy".to_string();
    let adjective = &"default".to_string();
    let adjective = adjectives.choose(&mut rng).unwrap_or(noun);
    let noun = nouns.choose(&mut rng).unwrap_or(adjective);
    format!("{}-{}", adjective, noun)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_random_name_generation() {
        let adjectives = vec!["happy".to_string(), "quick".to_string()];
        let nouns = vec!["fox".to_string(), "dog".to_string()];
        
        let name = generate_random_name(&adjectives, &nouns);
        
        // Check that the name contains a hyphen (our separator)
        assert!(name.contains('-'));
        
        // Split the name and verify parts
        let parts: Vec<&str> = name.split('-').collect();
        assert_eq!(parts.len(), 2);
        
        // Verify that the parts came from our input vectors
        assert!(adjectives.contains(&parts[0].to_string()));
        assert!(nouns.contains(&parts[1].to_string()));
    }
}