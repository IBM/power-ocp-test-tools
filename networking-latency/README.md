# EchoPulse

A lightweight, containerized Rust application designed for Kubernetes/OpenShift environments. EchoPulse acts as both an HTTP server (accepting traffic) and a background worker (initiating traffic), while actively reporting latency metrics.

## Features

- **HTTP Server**: Accepts incoming HTTP traffic on port 8080
  - `/health` - Liveness probe endpoint
  - `/ready` - Readiness probe endpoint
  - `/echo` - Echo endpoint that receives and returns payloads
- **Traffic Initiator**: Background task that sends HTTP POST requests with random payloads (1KB-200KB) every 60 seconds
- **Latency Reporting**: Measures and logs round-trip latency with payload sizes in structured JSON format
- **Multi-Architecture Support**: Builds for both `amd64` (x86_64) and `ppc64le` (PowerPC 64-bit LE)
- **Minimal Container**: Uses distroless base image for security and size optimization

## Architecture

```
                  +---------------------------------------------+
                  | OpenShift / Kubernetes Pod                  |
                  |                                             |
   NodePort ----> |  +------------------+                       |
   (Service 1)    |  |                  |                       |
                  |  |   HTTP Server    | <--- Route (Ingress)  |
                  |  |   (Port 8080)    |      (via Service 2)  |
                  |  +--------+---------+                       |
                  |           |                                 |
                  |           v (Logs latency every 1m)         |
                  |  +--------+---------+                       |
                  |  |  Async Traffic   |                       |
                  |  |    Initiator     | ------> Outbound WAN  |
                  |  +------------------+         (Egress Client)|
                  +---------------------------------------------+
```

## Prerequisites

- Rust 1.75 or later
- Docker with BuildKit support
- Kubernetes or OpenShift cluster
- `kubectl` or `oc` CLI tool

## Local Development

### Build the Application

```bash
cargo build --release
```

### Run Locally

```bash
# Set target URL (optional, defaults to https://httpbin.org/status/200)
export TARGET_URL="https://httpbin.org/delay/0"

# Run the application
cargo run --release
```

The server will start on `http://localhost:8080`.

### Test Endpoints

```bash
# Health check
curl http://localhost:8080/health

# Readiness check
curl http://localhost:8080/ready

# Echo endpoint (send a test payload)
echo "test payload" | curl -X POST http://localhost:8080/echo --data-binary @-
```

## Container Build

### Using Makefile (Recommended with Podman)

The project includes a comprehensive Makefile for building multi-architecture images with Podman:

```bash
# Show all available targets
make help

# Build multi-arch images (amd64 + ppc64le)
make build

# Build and push to registry
make build-and-push

# Build only specific architecture
make build-amd64
make build-ppc64le

# Push to registry
make push

# Build for OpenShift internal registry
make build-openshift

# Clean up local images
make clean

# Inspect the manifest
make inspect
```

**Customizing the build:**

```bash
# Custom image name and registry
make build IMAGE_NAME=myapp IMAGE_TAG=v1.0.0 REGISTRY=quay.io/myorg

# Build and push with custom settings
make build-and-push REGISTRY=docker.io/myuser IMAGE_NAME=echopulse IMAGE_TAG=latest
```

### Manual Build with Podman

Build for both `amd64` and `ppc64le` architectures:

```bash
# Build individual architecture images
podman build --platform=linux/amd64 -t echopulse:latest-amd64 .
podman build --platform=linux/ppc64le -t echopulse:latest-ppc64le .

# Create and populate manifest
podman manifest create echopulse:latest
podman manifest add echopulse:latest echopulse:latest-amd64
podman manifest add echopulse:latest echopulse:latest-ppc64le

# Push manifest to registry
podman manifest push echopulse:latest docker://your-registry/echopulse:latest
```

### Using Docker Buildx

For Docker users, build for both architectures:

```bash
# Create and use a new builder instance (one-time setup)
docker buildx create --name multiarch-builder --use
docker buildx inspect --bootstrap

# Build and push multi-arch image
docker buildx build \
  --platform linux/amd64,linux/ppc64le \
  -t your-registry/echopulse:latest \
  --push .
```

## Deployment to Kubernetes/OpenShift

### Quick Start with Makefile

```bash
# Deploy all resources
make deploy-k8s

# Check deployment status
make status

# View logs
make logs

# Remove deployment
make undeploy-k8s
```

### Manual Deployment

#### Create Namespace (OpenShift)

```bash
oc new-project echopulse
```

Or for Kubernetes:

```bash
kubectl create namespace echopulse
kubectl config set-context --current --namespace=echopulse
```

#### Deploy the Application

Deploy all resources:

```bash
# Deploy the pod
kubectl apply -f k8s/pod.yaml

# Deploy services
kubectl apply -f k8s/service-nodeport.yaml
kubectl apply -f k8s/service-default.yaml

# Deploy OpenShift route (OpenShift only)
oc apply -f k8s/route.yaml
```

Or deploy everything at once:

```bash
kubectl apply -f k8s/
```

### Verify Deployment

```bash
# Check pod status
kubectl get pods

# Check services
kubectl get services

# Check route (OpenShift)
oc get route

# View logs
kubectl logs echopulse-pod

# Follow logs in real-time
kubectl logs -f echopulse-pod
```

### Access the Application

**Via NodePort Service:**
```bash
# Get node IP
kubectl get nodes -o wide

# Access the service (replace NODE_IP with actual IP)
curl http://NODE_IP:30080/health
```

**Via OpenShift Route:**
```bash
# Get route URL
ROUTE_URL=$(oc get route echopulse-route -o jsonpath='{.spec.host}')

# Access the service
curl https://$ROUTE_URL/health
```

## Configuration

The application can be configured using environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `TARGET_URL` | URL to send periodic HTTP requests | `https://httpbin.org/status/200` |
| `RUST_LOG` | Logging level (trace, debug, info, warn, error) | `echopulse=info` |

To change the target URL, update the `env` section in `k8s/pod.yaml`:

```yaml
env:
- name: TARGET_URL
  value: "https://your-target-url.com/endpoint"
```

## Monitoring

### View Latency Metrics

The application logs latency metrics in structured JSON format:

```bash
kubectl logs echopulse-pod | grep latency_ms
```

Example output:
```json
{"timestamp":"2026-05-19T20:14:35Z","level":"INFO","target":"https://httpbin.org/status/200","latency_ms":142,"payload_size":102400,"response_size":102400}
```

The application now sends random payloads between 1KB and 200KB with each request, providing realistic network load testing.

### Health Checks

The application provides two health check endpoints:

- `/health` - Liveness probe (checks if the application is running)
- `/ready` - Readiness probe (checks if the application is ready to accept traffic)

These are automatically used by Kubernetes for pod health management.

## Troubleshooting

### Pod Not Starting

```bash
# Check pod events
kubectl describe pod echopulse-pod

# Check pod logs
kubectl logs echopulse-pod
```

### Image Pull Errors

If using OpenShift internal registry, ensure you're in the correct namespace:

```bash
oc project echopulse
```

For external registries, you may need to create an image pull secret:

```bash
kubectl create secret docker-registry regcred \
  --docker-server=your-registry.com \
  --docker-username=your-username \
  --docker-password=your-password
```

Then reference it in the pod spec:

```yaml
spec:
  imagePullSecrets:
  - name: regcred
```

### Network Issues

Check if the pod can reach the target URL:

```bash
kubectl exec echopulse-pod -- wget -O- https://httpbin.org/status/200
```

## Architecture Details

### Dependencies

- **tokio**: Async runtime with multi-threading support
- **axum**: Fast, ergonomic HTTP server framework
- **reqwest**: HTTP client for initiating traffic
- **tracing**: Structured logging and diagnostics
- **rand**: Random number generation for payload sizes

### Container Image

The multi-stage Dockerfile produces a minimal container:

1. **Build Stage**: Compiles the Rust binary with static linking
2. **Runtime Stage**: Uses distroless base image containing only the binary

Final image size: ~15-20 MB (depending on architecture)

### Security

- Runs as non-root user (UID 1001)
- Minimal attack surface (distroless base)
- No shell or package manager in runtime image
- Static binary with no external dependencies

## License

This project is provided as-is for demonstration purposes.

Built with IBM Bob


BUILDPLATFORM=linux/ppc64le make build-ppc64le