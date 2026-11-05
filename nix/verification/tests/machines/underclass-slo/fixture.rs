//! Isolated synthetic provider and private account seed for native SLO tests.
use axum::{
    Json, Router,
    body::{Body, Bytes},
    extract::{DefaultBodyLimit, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::post,
};
use serde::Deserialize;
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use underclass::{
    models::{Account, AccountStatus, BackendId, now_ms},
    store::Store,
};

#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Case {
    Slow,
    #[default]
    Complete,
    Unterminated,
    Error,
    Hold,
    Json,
}

#[derive(Deserialize)]
struct Request {
    #[serde(default)]
    slo_case: Case,
}

struct Fixture {
    directory: PathBuf,
    calls: AtomicU64,
}

/// @cc [owner:ghuntley,label:verification;security] underclass-local-provider-fixture
/// Only bounded synthetic requests MAY select a closed scenario. Fixture state
/// MUST contain numeric call counts and hold markers, never request content.
async fn respond(State(fixture): State<Arc<Fixture>>, Json(request): Json<Request>) -> Response {
    let calls = fixture.calls.fetch_add(1, Ordering::SeqCst) + 1;
    if std::fs::write(fixture.directory.join("calls"), calls.to_string()).is_err() {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    let content = [(axum::http::header::CONTENT_TYPE, "text/event-stream")];
    match request.slo_case {
        Case::Slow => {
            tokio::time::sleep(Duration::from_secs(12)).await;
            (content, "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n").into_response()
        }
        Case::Complete => (
            content,
            "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n",
        )
            .into_response(),
        Case::Unterminated => (
            content,
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"synthetic\"}\n\n",
        )
            .into_response(),
        Case::Error => (content, "data: {\"type\":\"error\"}\n\ndata: [DONE]\n\n").into_response(),
        Case::Json => Json(serde_json::json!({"output_text":"synthetic"})).into_response(),
        Case::Hold => {
            if std::fs::write(fixture.directory.join("holding"), b"").is_err() {
                return StatusCode::SERVICE_UNAVAILABLE.into_response();
            }
            let stream = futures::stream::unfold((false, fixture), |(sent, fixture)| async move {
                if !sent {
                    return Some((
                        Ok::<Bytes, std::io::Error>(Bytes::from_static(
                            b"data: {\"type\":\"response.output_text.delta\"}\n\n",
                        )),
                        (true, fixture),
                    ));
                }
                loop {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            });
            (content, Body::from_stream(stream)).into_response()
        }
    }
}

/// @cc [owner:ghuntley,label:verification] underclass-synthetic-account-seed
/// Seeding MUST use the real pinned Store and a synthetic, unexpired Codex
/// account. This helper MUST exist only in the isolated fixture package.
fn seed(directory: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let store = Store::open(&directory.join("pool.db"))?;
    let timestamp = now_ms();
    store.upsert_account(&Account {
        id: "synthetic-account".into(),
        backend: BackendId::Codex,
        label: "synthetic".into(),
        refresh_token: Some("synthetic-refresh".into()),
        access_token: Some("synthetic-access".into()),
        expires_at: timestamp + 86_400_000,
        token_refreshed_at: timestamp,
        account_id: Some("synthetic-account".into()),
        residency: None,
        enterprise_url: None,
        plan: None,
        disabled_reason: None,
        status: AccountStatus::Healthy,
        reset_at: 0,
        created_at: timestamp,
        updated_at: timestamp,
    });
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments.as_slice() {
        [command, directory] if command == "seed" && Path::new(directory).is_absolute() => {
            seed(Path::new(directory))
        }
        [command, directory] if command == "serve" && Path::new(directory).is_absolute() => {
            let state = Arc::new(Fixture {
                directory: directory.into(),
                calls: AtomicU64::new(0),
            });
            let app = Router::new()
                .route("/responses", post(respond))
                .layer(DefaultBodyLimit::max(65_536))
                .with_state(state);
            let listener = tokio::net::TcpListener::bind("127.0.0.1:8081").await?;
            axum::serve(listener, app).await?;
            Ok(())
        }
        _ => Err("expected seed or serve with absolute fixture directory".into()),
    }
}
