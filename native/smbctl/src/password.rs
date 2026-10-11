//! Samba local passdb compatibility, NOT a replacement for NTLM authentication.
//! Microsoft NTOWF: MD4 of UTF-16LE password, without Unicode normalization.
//! This format is retained only to interoperate with the unchanged Samba server.
use crate::Result;
use md4::{Digest, Md4};
pub fn nt_hash(hex: &str) -> Result<String> {
    if hex.is_empty()
        || hex.len() > 2048
        || hex.len() & 1 != 0
        || !hex.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err("invalid password hex".into());
    }
    let bytes: Vec<u8> = hex
        .as_bytes()
        .chunks_exact(2)
        .map(|p| {
            let digit = |b: u8| {
                if b.is_ascii_digit() {
                    b - b'0'
                } else {
                    b.to_ascii_lowercase() - b'a' + 10
                }
            };
            digit(p[0]) * 16 + digit(p[1])
        })
        .collect();
    let password = std::str::from_utf8(&bytes).map_err(|_| "password is not valid UTF-8")?;
    if password.contains('\0') {
        return Err("NUL in password is unsupported".into());
    }
    let utf16: Vec<u8> = password.encode_utf16().flat_map(u16::to_le_bytes).collect();
    Ok(format!("{:X}", Md4::digest(&utf16)))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn known_nt_vector() {
        assert_eq!(
            nt_hash("70617373776f7264").unwrap(),
            "8846F7EAEE8FB117AD06BDD830B7586C"
        );
    }
    #[test]
    fn rejects_malformed_input() {
        for value in ["", "0", "gg", "ff", "c080", "00"] {
            assert!(nt_hash(value).is_err())
        }
        assert!(nt_hash(&"61".repeat(1025)).is_err());
    }
    #[test]
    fn legacy_helper_vectors() {
        for line in include_str!("password-vectors.txt").lines() {
            let (hex, expected) = line.split_once(' ').unwrap();
            assert_eq!(nt_hash(hex).unwrap(), expected);
        }
    }
}
