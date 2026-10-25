//! Block modes retained for the existing extension API and media transforms.

use aes::cipher::{Block, BlockCipherDecrypt, BlockCipherEncrypt, KeyInit};
use zeroize::Zeroizing;

pub enum BlockCipher {
    Aes128(Box<aes::Aes128>),
    Aes192(Box<aes::Aes192>),
    Aes256(Box<aes::Aes256>),
    Blowfish(Box<blowfish::Blowfish>),
}

impl BlockCipher {
    pub fn new(algorithm: &str, key: &[u8]) -> Result<Self, String> {
        Ok(match algorithm {
            "aes" => match key.len() {
                16 => Self::Aes128(Box::new(
                    aes::Aes128::new_from_slice(key).expect("AES-128 key"),
                )),
                24 => Self::Aes192(Box::new(
                    aes::Aes192::new_from_slice(key).expect("AES-192 key"),
                )),
                32 => Self::Aes256(Box::new(
                    aes::Aes256::new_from_slice(key).expect("AES-256 key"),
                )),
                size => return Err(format!("crypto/aes: invalid key size {size}")),
            },
            "blowfish" => {
                if key.is_empty() || key.len() > 56 {
                    return Err(format!("crypto/blowfish: invalid key size {}", key.len()));
                }
                // Go accepts 1–56 bytes; RustCrypto starts at four. Repeating a
                // short key preserves Blowfish's cyclic key expansion exactly.
                let key = Zeroizing::new(if key.len() < 4 {
                    key.repeat(4_usize.div_ceil(key.len()))
                } else {
                    key.to_vec()
                });
                Self::Blowfish(Box::new(
                    blowfish::Blowfish::new_from_slice(&key).expect("Blowfish key"),
                ))
            }
            _ => return Err(format!("unsupported block cipher algorithm: {algorithm}")),
        })
    }

    pub fn block_size(&self) -> usize {
        if matches!(self, Self::Blowfish(_)) {
            8
        } else {
            16
        }
    }

    /// CBC requires aligned input; CTR increments the entire big-endian counter
    /// and can transform a partial final block. Input is an owned Rust snapshot.
    pub fn transform(
        &self,
        data: &mut [u8],
        iv: &[u8],
        mode: &str,
        decrypt: bool,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        let size = self.block_size();
        if iv.len() != size {
            return Err(format!("iv must be {size} bytes"));
        }
        if mode != "cbc" && mode != "ctr" {
            return Err(format!("unsupported block cipher mode: {mode}"));
        }
        if mode == "cbc" && !data.len().is_multiple_of(size) {
            return Err(format!("input length must be a multiple of {size} bytes"));
        }
        match self {
            Self::Aes128(cipher) => transform(cipher.as_ref(), data, iv, mode, decrypt, check),
            Self::Aes192(cipher) => transform(cipher.as_ref(), data, iv, mode, decrypt, check),
            Self::Aes256(cipher) => transform(cipher.as_ref(), data, iv, mode, decrypt, check),
            Self::Blowfish(cipher) => transform(cipher.as_ref(), data, iv, mode, decrypt, check),
        }
    }
}

fn transform<C: BlockCipherEncrypt + BlockCipherDecrypt>(
    cipher: &C,
    data: &mut [u8],
    iv: &[u8],
    mode: &str,
    decrypt: bool,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    let mut state = Block::<C>::try_from(iv).expect("validated IV length");
    for (index, chunk) in data.chunks_mut(iv.len()).enumerate() {
        if index % 1024 == 0 {
            check()?;
        }
        if mode == "ctr" {
            let mut block = state.clone();
            cipher.encrypt_block(&mut block);
            for (byte, mask) in chunk.iter_mut().zip(block.iter()) {
                *byte ^= mask;
            }
            for byte in state.iter_mut().rev() {
                *byte = byte.wrapping_add(1);
                if *byte != 0 {
                    break;
                }
            }
        } else if decrypt {
            let encrypted = Block::<C>::try_from(&*chunk).expect("aligned encrypted block");
            let mut block = encrypted.clone();
            cipher.decrypt_block(&mut block);
            for ((byte, plain), previous) in chunk.iter_mut().zip(block.iter()).zip(state.iter()) {
                *byte = plain ^ previous;
            }
            state = encrypted;
        } else {
            for (byte, previous) in chunk.iter_mut().zip(state.iter()) {
                *byte ^= previous;
            }
            let block = <&mut Block<C>>::try_from(chunk).expect("aligned plaintext block");
            cipher.encrypt_block(block);
            state.clone_from(block);
        }
    }
    check()
}

pub fn pad(data: &mut Vec<u8>, block_size: usize) {
    let count = block_size - data.len() % block_size;
    data.resize(data.len() + count, count as u8);
}

pub fn unpad(data: &mut Vec<u8>, block_size: usize) -> Result<(), String> {
    if data.is_empty() || !data.len().is_multiple_of(block_size) {
        return Err("invalid padded payload length".into());
    }
    let count = usize::from(*data.last().expect("nonempty padded data"));
    if count == 0
        || count > block_size
        || count > data.len()
        || data[data.len() - count..]
            .iter()
            .any(|byte| usize::from(*byte) != count)
    {
        return Err("invalid PKCS7 padding".into());
    }
    data.truncate(data.len() - count);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_cipher_upgrade_preserves_known_ciphertexts_and_inverse() {
        for (algorithm, key, expected) in [
            ("aes", vec![0; 16], "66e94bd4ef8a2c3b884cfa59ca342b2e"),
            ("aes", vec![0; 24], "aae06992acbf52a3e8f4a96ec9300bd7"),
            ("aes", vec![0; 32], "dc95c078a2408989ad48a21492842087"),
            ("blowfish", vec![0; 8], "4ef997456198dd78"),
        ] {
            let cipher = BlockCipher::new(algorithm, &key).unwrap();
            let iv = vec![0; cipher.block_size()];
            for mode in ["cbc", "ctr"] {
                let mut data = iv.clone();
                cipher
                    .transform(&mut data, &iv, mode, false, &|| Ok(()))
                    .unwrap();
                assert_eq!(crate::binary::encode(&data, "hex").unwrap(), expected);
                cipher
                    .transform(&mut data, &iv, mode, true, &|| Ok(()))
                    .unwrap();
                assert_eq!(data, iv);
            }
        }
    }
}
