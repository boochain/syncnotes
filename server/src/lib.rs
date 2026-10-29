//! SyncNotes server library — auth, storage, sync protocol.
//!
//! Wire traffic is sealed (see `seal`). Plaintext lives only in this process
//! and in the clients after they decrypt.

pub mod admin;
pub mod auth;
pub mod blocks;
pub mod files;
pub mod protocol;
pub mod paths;
pub mod recovery;
pub mod seal;
pub mod sealed;
pub mod state;
pub mod storage;
pub mod sync;
pub mod trash;

pub use state::AppState;
pub use storage::Storage;

/// Build the HTTP/WebSocket router.
///
/// `/health` is the only plaintext route and carries no user content (it
/// publishes the server static key). Everything else is ciphertext.
pub fn build_router(state: AppState) -> axum::Router {
    use axum::routing::{get, post};
    axum::Router::new()
        .route("/health", get(sync::health))
        .route("/api/seal", post(sealed::handle))
        .route("/api/blob", post(files::blob))
        .route("/api/register", post(sealed::reject_plain))
        .route("/api/login", post(sealed::reject_plain))
        .route("/api/logout", post(sealed::reject_plain))
        .route("/api/recover", post(sealed::reject_plain))
        .route("/api/recovery-code", post(sealed::reject_plain))
        .route("/api/change-password", post(sealed::reject_plain))
        .route("/ws", get(sync::ws_handler))
        .route("/api/files", axum::routing::put(sealed::reject_plain))
        .route("/api/files/:id", get(sealed::reject_plain))
        .layer(axum::extract::DefaultBodyLimit::max(files::max_http_body()))
        .layer(tower_http::cors::CorsLayer::permissive())
        .with_state(state)
}
