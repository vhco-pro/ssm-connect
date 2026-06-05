# SSM Connect — developer task runner.
# Thin wrapper around scripts/run.sh so common actions are `make <target>`.

.DEFAULT_GOAL := help
SCRIPT := ./scripts/run.sh
DERIVED := .build/DerivedData

.PHONY: help run rebuild test generate clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

run: ## Regenerate project, build, and launch the app
	$(SCRIPT)

rebuild: ## Wipe build products, then full rebuild + launch
	$(SCRIPT) --clean

test: ## Run the unit test suite
	$(SCRIPT) --test

generate: ## Regenerate SSMConnect.xcodeproj from project.yml
	xcodegen generate

clean: ## Remove build products (no rebuild)
	rm -rf "$(DERIVED)/Build/Products" "$(DERIVED)/Build/Intermediates.noindex"
