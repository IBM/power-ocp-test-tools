use axum::{
    routing::{get, post},
    Router,
    http::StatusCode,
    body::Bytes,
    extract::State,
};
use std::env;
use std::sync::Arc;
use std::time::Instant;
use tokio::time::{interval, Duration};
use tracing::{info, error};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use rand::Rng;

// Shared state for statistics
#[derive(Clone)]
struct AppState {
    stats: Arc<tokio::sync::Mutex<Stats>>,
}

#[derive(Default)]
struct Stats {
    requests_received: u64,
    bytes_received: u64,
    requests_sent: u64,
    bytes_sent: u64,
}

#[tokio::main]
async fn main() {
    // Initialize structured logging with JSON format
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "echopulse=info".into()),
        )
        .with(tracing_subscriber::fmt::layer().json())
        .init();

    info!("Starting EchoPulse application");

    // Get target URL from environment variable
    let target_url = env::var("TARGET_URL")
        .unwrap_or_else(|_| "http://echopulse-default-svc:8080".to_string());
    
    info!(target_url = %target_url, "Configured target URL");

    // Create shared state
    let state = AppState {
        stats: Arc::new(tokio::sync::Mutex::new(Stats::default())),
    };

    // Spawn background task for traffic initiation
    let state_clone = state.clone();
    tokio::spawn(async move {
        traffic_initiator(target_url, state_clone).await;
    });

    // Build HTTP server
    let app = Router::new()
        .route("/health", get(health_handler))
        .route("/ready", get(ready_handler))
        .route("/echo", post(echo_handler))
        .with_state(state);

    // Bind to 0.0.0.0:8080
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080")
        .await
        .expect("Failed to bind to port 8080");

    info!("HTTP server listening on 0.0.0.0:8080");

    // Start server
    axum::serve(listener, app)
        .await
        .expect("Server failed to start");
}

/// Health check endpoint for Kubernetes liveness probe
async fn health_handler() -> StatusCode {
    StatusCode::OK
}

/// Readiness check endpoint for Kubernetes readiness probe
async fn ready_handler() -> StatusCode {
    StatusCode::OK
}

/// Echo endpoint that receives payload and returns it
async fn echo_handler(
    State(state): State<AppState>,
    body: Bytes,
) -> (StatusCode, Bytes) {
    let size = body.len();
    
    // Update statistics
    {
        let mut stats = state.stats.lock().await;
        stats.requests_received += 1;
        stats.bytes_received += size as u64;
    }
    
    info!(
        bytes_received = size,
        "Received echo request"
    );
    
    (StatusCode::OK, body)
}

/// Generate random payload between 1KB and 200KB
fn generate_random_payload() -> Vec<u8> {
    let mut rng = rand::thread_rng();
    let size = rng.gen_range(1024..=204800); // 1KB to 200KB
    
    let mut payload = vec![0u8; size];
    rng.fill(&mut payload[..]);
    
    payload
}

/// Background task that initiates HTTP traffic every 60 seconds
async fn traffic_initiator(target_url: String, state: AppState) {
    info!("Traffic initiator started");
    
    // Create HTTP client
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .expect("Failed to create HTTP client");

    // Create interval ticker for 60 seconds
    let mut ticker = interval(Duration::from_secs(60));

    loop {
        ticker.tick().await;

        // Generate random payload
        let payload = generate_random_payload();
        let payload_size = payload.len();
        
        // Measure latency
        let start = Instant::now();
        
        match client.post(&target_url)
            .body(payload)
            .send()
            .await
        {
            Ok(response) => {
                let latency = start.elapsed();
                let latency_ms = latency.as_millis();
                
                // Try to read response body
                let response_size = match response.bytes().await {
                    Ok(bytes) => bytes.len(),
                    Err(_) => 0,
                };
                
                // Update statistics
                {
                    let mut stats = state.stats.lock().await;
                    stats.requests_sent += 1;
                    stats.bytes_sent += payload_size as u64;
                }
                
                info!(
                    target = %target_url,
                    latency_ms = latency_ms,
                    payload_size = payload_size,
                    response_size = response_size,
                    "Traffic initiated successfully"
                );
            }
            Err(e) => {
                let latency = start.elapsed();
                let latency_ms = latency.as_millis();
                
                error!(
                    target = %target_url,
                    latency_ms = latency_ms,
                    payload_size = payload_size,
                    error = %e,
                    "Traffic initiation failed"
                );
            }
        }
    }
}
