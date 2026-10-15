//! Password hashing and token generation.

use argon2::password_hash::{
    rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString,
};
use argon2::Argon2;
use rand::Rng;

pub fn hash_password(pw: &str) -> String {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(pw.as_bytes(), &salt)
        .expect("hash")
        .to_string()
}

pub fn verify_password(pw: &str, hash: &str) -> bool {
    PasswordHash::new(hash)
        .map(|h| Argon2::default().verify_password(pw.as_bytes(), &h).is_ok())
        .unwrap_or(false)
}

pub fn random_token() -> String {
    let bytes: [u8; 32] = rand::thread_rng().gen();
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn validate_username(u: &str) -> Result<(), &'static str> {
    if u.len() < 2 || u.len() > 32 {
        return Err("用户名长度需在 2-32 之间");
    }
    if !u
        .chars()
        .all(|c| c.is_alphanumeric() || c == '_' || c == '-')
    {
        return Err("用户名只能包含字母、数字、_ 和 -");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hash_roundtrip() {
        let h = hash_password("secret123");
        assert!(verify_password("secret123", &h));
        assert!(!verify_password("wrong", &h));
    }
    #[test]
    fn token_is_64_hex() {
        let t = random_token();
        assert_eq!(t.len(), 64);
        assert!(t.chars().all(|c| c.is_ascii_hexdigit()));
    }
    #[test]
    fn username_rules() {
        assert!(validate_username("bill").is_ok());
        assert!(validate_username("a").is_err());
        assert!(validate_username("bad name").is_err());
    }
}
