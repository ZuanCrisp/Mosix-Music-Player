use super::UsbOutputFormat;

/// Completes underruns without putting PCM zero words into a DSD stream.
/// DoP markers describe wire frames, so they must continue through silence too.
pub fn finish_transfer(
    bytes: &mut [u8],
    real_bytes: usize,
    format: &UsbOutputFormat,
    marker: &mut u8,
) {
    bytes[real_bytes..].fill(if format.encoding == "pcm" { 0 } else { 0x69 });
    if format.encoding == "dop" {
        let subslot = format.subslot as usize;
        let frame = subslot * format.channels as usize;
        for chunk in bytes.chunks_exact_mut(frame) {
            for sample in chunk.chunks_exact_mut(subslot) {
                sample[subslot - 1] = *marker;
                if subslot == 4 {
                    sample[0] = 0;
                }
            }
            *marker ^= 0xff;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn format(encoding: &str, subslot: u8) -> UsbOutputFormat {
        UsbOutputFormat {
            sample_rate: 176400,
            channels: 2,
            bits: 24,
            subslot,
            encoding: encoding.into(),
        }
    }
    #[test]
    fn dop_markers_alternate_across_transfers_and_underruns() {
        let mut marker = 5;
        let mut first = [1, 2, 0, 3, 4, 0];
        finish_transfer(&mut first, 6, &format("dop", 3), &mut marker);
        assert_eq!(first, [1, 2, 5, 3, 4, 5]);
        let mut second = [0; 12];
        finish_transfer(&mut second, 0, &format("dop", 3), &mut marker);
        assert_eq!(
            second,
            [
                0x69, 0x69, 0xfa, 0x69, 0x69, 0xfa, 0x69, 0x69, 5, 0x69, 0x69, 5
            ]
        );
        assert_eq!(marker, 0xfa);
    }
    #[test]
    fn dop32_padding_and_channel_markers_match() {
        let mut data = [0, 1, 2, 0, 0, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        finish_transfer(&mut data, 8, &format("dop", 4), &mut 5);
        assert_eq!(
            data,
            [
                0, 1, 2, 5, 0, 3, 4, 5, 0, 0x69, 0x69, 0xfa, 0, 0x69, 0x69, 0xfa
            ]
        );
    }
    #[test]
    fn native_dsd_and_pcm_keep_original_data_and_use_different_silence() {
        for (encoding, silence) in [("pcm", 0), ("dsd_be", 0x69), ("dsd_le", 0x69)] {
            let mut bytes = [
                1, 2, 3, 4, 5, 6, 7, 8, 255, 255, 255, 255, 255, 255, 255, 255,
            ];
            finish_transfer(&mut bytes, 8, &format(encoding, 4), &mut 5);
            assert_eq!(bytes[..8], [1, 2, 3, 4, 5, 6, 7, 8]);
            assert_eq!(bytes[8..], [silence; 8]);
        }
    }
}
