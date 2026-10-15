//! SyncNotes server library — auth, storage, sync protocol.

pub mod auth;
pub mod blocks;
pub mod files;
pub mod protocol;
pub mod state;
pub mod storage;
pub mod sync;

pub use state::AppState;
pub use storage::Storage;

/// Build the HTTP/WebSocket router.
pub fn build_router(state: AppState) -> axum::Router {
    use axum::routing::{get, post};
    axum::Router::new()
        .route("/health", get(sync::health))
        .route("/api/register", post(sync::register))
        .route("/api/login", post(sync::login))
        .route("/ws", get(sync::ws_handler))
        .route("/api/files", axum::routing::put(files::upload))
        .route("/api/files/:id", get(files::download))
        .layer(axum::extract::DefaultBodyLimit::max(files::MAX_FILE_BYTES))
        .layer(tower_http::cors::CorsLayer::permissive())
        .with_state(state)
}
