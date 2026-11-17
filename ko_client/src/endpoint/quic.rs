use std::io;
use std::sync::Mutex;

use boring::ssl::SslContextBuilder;

pub(crate) struct Quic {
    pub(crate) config: Mutex<quiche::Config>,
}

impl std::fmt::Debug for Quic {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Quic").finish_non_exhaustive()
    }
}

impl Quic {
    pub(crate) fn new(context: SslContextBuilder) -> io::Result<Self> {
        let mut config =
            quiche::Config::with_boring_ssl_ctx_builder(quiche::PROTOCOL_VERSION, context)
                .map_err(io::Error::other)?;
        config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .map_err(io::Error::other)?;
        config.set_initial_max_data(16 << 20);
        config.set_initial_max_stream_data_bidi_local(1 << 20);
        config.set_initial_max_stream_data_bidi_remote(1 << 20);
        config.set_initial_max_stream_data_uni(1 << 20);
        config.set_initial_max_streams_bidi(128);
        config.set_initial_max_streams_uni(16);
        config.set_active_connection_id_limit(4);
        Ok(Self {
            config: Mutex::new(config),
        })
    }
}
