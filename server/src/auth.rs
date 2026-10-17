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

/// RFC 4648 base32 alphabet (no 0/1/8/9 to avoid O/I/B confusion).
const B32: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// One-time recovery code: 4 groups × 5 base32 chars = 100 bits of entropy (OS CSPRNG).
pub fn generate_recovery_code() -> String {
    use argon2::password_hash::rand_core::RngCore;
    let mut bytes = [0u8; 20];
    OsRng.fill_bytes(&mut bytes);
    let chars: Vec<char> = bytes.iter().map(|b| B32[(b & 31) as usize] as char).collect();
    chars
        .chunks(5)
        .map(|c| c.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join("-")
}

/// Canonical form used for hashing: uppercase, separators/spaces removed, common look-alikes fixed.
pub fn normalize_recovery_code(code: &str) -> String {
    code.chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .map(|c| match c.to_ascii_uppercase() {
            '0' => 'O',
            '1' => 'I',
            '8' => 'B',
            o => o,
        })
        .collect()
}

pub fn hash_recovery_code(code: &str) -> String {
    hash_password(&normalize_recovery_code(code))
}

/// Constant-time (argon2 + `subtle`-style compare inside the argon2 crate) verification.
pub fn verify_recovery_code(code: &str, hash: &str) -> bool {
    verify_password(&normalize_recovery_code(code), hash)
}

/// Burn the same argon2 work for unknown users / users without a code so response timing
/// doesn't reveal whether the account exists.
pub fn dummy_verify(input: &str) {
    static DUMMY: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    let h = DUMMY.get_or_init(|| hash_password("syncnotes-dummy-recovery"));
    let _ = verify_password(input, h);
}

/// Random human-typable temporary password for admin resets.
pub fn generate_temp_password() -> String {
    use argon2::password_hash::rand_core::RngCore;
    const A: &[u8] = b"abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789";
    let mut bytes = [0u8; 14];
    OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|b| A[(*b as usize) % A.len()] as char).collect()
}

pub fn validate_password(pw: &str) -> Result<(), &'static str> {
    if pw.chars().count() < 4 {
        return Err("密码至少 4 位");
    }
    if pw.len() > 256 {
        return Err("密码过长");
    }
    Ok(())
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
    fn recovery_code_format_and_normalize() {
        let c = generate_recovery_code();
        assert_eq!(c.len(), 23);
        assert_eq!(c.split('-').count(), 4);
        let h = hash_recovery_code(&c);
        assert!(verify_recovery_code(&c.to_lowercase().replace('-', " "), &h));
        assert!(!verify_recovery_code("AAAAA-AAAAA-AAAAA-AAAAA", &h));
        assert_ne!(generate_recovery_code(), c);
    }
    #[test]
    fn username_rules() {
        assert!(validate_username("bill").is_ok());
        assert!(validate_username("a").is_err());
        assert!(validate_username("bad name").is_err());
    }
}
