# =============================================================================
#  Convenience Makefile for the zot role.
# =============================================================================
SHELL := /bin/bash

PLAYBOOK        ?= install-zot.yml
INVENTORY       ?= inventory.ini
TEST_INVENTORY  ?= tests/inventory
TEST_PLAYBOOK   ?= tests/localhost-test.yml

.DEFAULT_GOAL := help

.PHONY: help deps lint yamllint ansible-lint syntax check test clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deps: ## Install the optional collections (htpasswd/ufw)
	ansible-galaxy collection install -r requirements.yml

lint: yamllint ansible-lint ## Run every linter

yamllint: ## Check YAML style
	yamllint .

ansible-lint: ## Check Ansible best practices (production profile)
	ansible-lint

syntax: ## Syntax-check the playbooks
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --syntax-check
	ansible-playbook -i $(TEST_INVENTORY) $(TEST_PLAYBOOK) --syntax-check

check: ## Dry-run the install playbook
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --check --diff

test: ## Run the role test on this machine (needs sudo, Ubuntu 24.04)
	ansible-playbook -i $(TEST_INVENTORY) $(TEST_PLAYBOOK)

clean: ## Remove caches and temporary artifacts
	rm -rf .cache .tmp *.retry
