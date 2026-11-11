use miniz_oxide::deflate::core::{
    CompressorOxide, TDEFLFlush, TDEFLStatus, compress, create_comp_flags_from_zip_params,
};

const LEVEL: i32 = 1;
const RAW: i32 = 0;
const STRATEGY: i32 = 0;

pub(crate) struct Deflate {
    compressor: Box<CompressorOxide>,
    out: Vec<u8>,
}

impl std::fmt::Debug for Deflate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Deflate").finish_non_exhaustive()
    }
}

impl Deflate {
    pub(crate) fn new() -> Deflate {
        Deflate {
            compressor: Box::new(CompressorOxide::new(create_comp_flags_from_zip_params(
                LEVEL, RAW, STRATEGY,
            ))),
            out: Vec::new(),
        }
    }

    pub(crate) fn with_deflated<R>(
        &mut self,
        prefix: &[u8],
        body: &[u8],
        send: impl FnOnce(&[u8]) -> R,
    ) -> R {
        let Deflate { compressor, out } = self;
        compressor.reset();
        let start = prefix.len();
        let guess = start
            .saturating_add(body.len() / 2)
            .max(start.saturating_add(64));
        if out.len() < guess {
            out.resize(guess, 0);
        }
        if let Some(head) = out.get_mut(..start) {
            head.copy_from_slice(prefix);
        }
        let mut at = start;
        let mut input = body;
        loop {
            let (status, taken, written) = compress(
                compressor,
                input,
                out.get_mut(at..).unwrap_or_default(),
                TDEFLFlush::Finish,
            );
            input = input.get(taken..).unwrap_or_default();
            at = at.saturating_add(written);
            if status != TDEFLStatus::Okay {
                break;
            }
            out.resize(out.len().saturating_mul(2), 0);
        }
        send(out.get(..at).unwrap_or_default())
    }
}
