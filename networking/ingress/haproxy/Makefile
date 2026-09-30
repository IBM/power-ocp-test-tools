IMAGE_NAME ?= haproxy-custom
IMAGE_TAG ?= latest

.PHONY: help
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the container image from Containerfile
	podman build -t $(IMAGE_NAME):$(IMAGE_TAG) -f Containerfile .

.PHONY: setup
setup: ## Start haproxy setup
	bash ./haproxy.sh setup

.PHONY: destroy
destroy: ## Stop and teardown haproxy
	bash ./haproxy.sh destroy

.PHONY: test
test: ## Run the haproxy test script
	bash ./haproxy.sh

.DEFAULT_GOAL := help
