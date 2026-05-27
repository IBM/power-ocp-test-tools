# Makefile for EchoPulse multi-architecture builds using Podman

# Variables
IMAGE_NAME ?= echopulse
IMAGE_TAG ?= latest
REGISTRY ?= localhost
FULL_IMAGE_NAME = $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

# Platforms
PLATFORMS = linux/amd64,linux/ppc64le

.PHONY: help
help: ## Show this help message
	@echo "EchoPulse Build Targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build multi-arch image and create manifest
	@echo "Building multi-architecture images..."
	podman build --platform=linux/amd64 -t $(FULL_IMAGE_NAME)-amd64 -f Containerfile .
	podman build --platform=linux/ppc64le -t $(FULL_IMAGE_NAME)-ppc64le -f Containerfile .
	@echo "Creating manifest..."
	podman manifest create $(FULL_IMAGE_NAME) || podman manifest rm $(FULL_IMAGE_NAME) && podman manifest create $(FULL_IMAGE_NAME)
	podman manifest add $(FULL_IMAGE_NAME) $(FULL_IMAGE_NAME)-amd64
	podman manifest add $(FULL_IMAGE_NAME) $(FULL_IMAGE_NAME)-ppc64le
	@echo "Multi-arch build complete: $(FULL_IMAGE_NAME)"

.PHONY: build-amd64
build-amd64: ## Build only amd64 image
	@echo "Building amd64 image..."
	podman build --platform=linux/amd64 -t $(FULL_IMAGE_NAME)-amd64 -f Containerfile .
	@echo "Build complete: $(FULL_IMAGE_NAME)-amd64"

.PHONY: build-ppc64le
build-ppc64le: ## Build only ppc64le image
	@echo "Building ppc64le image..."
	podman build --platform=linux/ppc64le -t $(FULL_IMAGE_NAME)-ppc64le -f Containerfile .
	@echo "Build complete: $(FULL_IMAGE_NAME)-ppc64le"

.PHONY: push
push: ## Push multi-arch manifest to registry
	@echo "Pushing manifest to registry..."
	podman manifest push $(FULL_IMAGE_NAME) docker://$(FULL_IMAGE_NAME)
	@echo "Push complete: $(FULL_IMAGE_NAME)"

.PHONY: push-amd64
push-amd64: ## Push only amd64 image
	@echo "Pushing amd64 image..."
	podman push $(FULL_IMAGE_NAME)-amd64
	@echo "Push complete: $(FULL_IMAGE_NAME)-amd64"

.PHONY: push-ppc64le
push-ppc64le: ## Push only ppc64le image
	@echo "Pushing ppc64le image..."
	podman push $(FULL_IMAGE_NAME)-ppc64le
	@echo "Push complete: $(FULL_IMAGE_NAME)-ppc64le"

.PHONY: build-and-push
build-and-push: build push ## Build and push multi-arch images

.PHONY: inspect
inspect: ## Inspect the multi-arch manifest
	@echo "Inspecting manifest..."
	podman manifest inspect $(FULL_IMAGE_NAME)

.PHONY: clean
clean: ## Remove local images and manifests
	@echo "Cleaning up local images..."
	-podman rmi $(FULL_IMAGE_NAME)-amd64 2>/dev/null || true
	-podman rmi $(FULL_IMAGE_NAME)-ppc64le 2>/dev/null || true
	-podman manifest rm $(FULL_IMAGE_NAME) 2>/dev/null || true
	@echo "Cleanup complete"

.PHONY: test-local
test-local: ## Build and run locally (current architecture)
	@echo "Building for local architecture..."
	podman build -t $(IMAGE_NAME):test -f Containerfile .
	@echo "Running container..."
	podman run --rm -p 8080:8080 -e TARGET_URL=https://httpbin.org/status/200 $(IMAGE_NAME):test

.PHONY: cargo-build
cargo-build: ## Build Rust binary locally
	cargo build --release

.PHONY: cargo-test
cargo-test: ## Run Rust tests
	cargo test

.PHONY: cargo-clean
cargo-clean: ## Clean Rust build artifacts
	cargo clean

.PHONY: deploy-manifests
deploy-manifests: ## Deploy to Kubernetes/OpenShift
	@echo "Deploying to Kubernetes..."
	kubectl apply -f manifests/

.PHONY: undeploy-manifests
undeploy-manifests: ## Remove from Kubernetes/OpenShift
	@echo "Removing from Kubernetes..."
	kubectl delete -f manifests/ --ignore-not-found=true

.PHONY: logs
logs: ## Show pod logs
	kubectl logs -f echopulse-pod

.PHONY: status
status: ## Show deployment status
	@echo "Pod status:"
	kubectl get pod echopulse-pod
	@echo ""
	@echo "Services:"
	kubectl get svc -l app=echopulse
	@echo ""
	@echo "Routes (OpenShift):"
	-oc get route echopulse-route 2>/dev/null || echo "Not on OpenShift or route not found"

# OpenShift-specific targets
.PHONY: build-openshift
build-openshift: ## Build and push to OpenShift internal registry
	$(eval REGISTRY := image-registry.openshift-image-registry.svc:5000/echopulse)
	$(MAKE) build-and-push REGISTRY=$(REGISTRY)

.PHONY: all
all: cargo-test build ## Run tests and build multi-arch images

.DEFAULT_GOAL := help
