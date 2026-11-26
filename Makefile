# ------------------------------------------------------------------------------
# 開発環境ワークスペース
#   make help で一覧表示
# ------------------------------------------------------------------------------

# ワークスペース設定 (.env)。make 引数で上書き可: make laravel NAME=blog DOMAIN=example.com
-include .env
DOMAIN            ?= localhost
LETSENCRYPT_EMAIL ?=
TZ                ?= Asia/Tokyo
HOST              ?=
WEBAPP            ?= 1
export DOMAIN LETSENCRYPT_EMAIL TZ HOST

# 起動順 (proxy を先頭に)。make infra-up INFRA="docker_mysql docker_redis" で絞り込み可
INFRA ?= docker_proxy_network docker_mysql docker_redis docker_mailpit docker_prometheus
NETWORKS := my_infra_network my_proxy_network

.DEFAULT_GOAL := help
.PHONY: help init config network infra-up infra-down infra-ps laravel symfony up down restart logs ps shell vendor-sync apps build

help: ## このヘルプを表示
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ---- セットアップ -------------------------------------------------------------

init: ## submodule 取得と .env 作成 (make init DOMAIN=hogehoge.localhost)。再実行でドメイン変更
	git submodule update --init --recursive
	@DOMAIN="$(if $(filter command line,$(origin DOMAIN)),$(DOMAIN))" ./scripts/init.sh

config: ## 現在のワークスペース設定を表示
	@echo "DOMAIN            = $(DOMAIN)"
	@echo "LETSENCRYPT_EMAIL = $(LETSENCRYPT_EMAIL)"
	@echo "TZ                = $(TZ)"

network: ## 外部ネットワークを作成 (既にあれば何もしない)
	@for n in $(NETWORKS); do \
	  docker network inspect $$n >/dev/null 2>&1 || docker network create $$n; \
	done

# ---- インフラ -----------------------------------------------------------------

infra-up: network ## インフラを起動 (.env 未作成のものはスキップ)
	@for d in $(INFRA); do \
	  if [ -f infra/$$d/.env.example ] && [ ! -f infra/$$d/.env ]; then \
	    printf "\033[33m[skip] %s: .env がありません (cp infra/%s/.env.example infra/%s/.env して値を設定)\033[0m\n" $$d $$d $$d; \
	    continue; \
	  fi; \
	  printf "\033[36m==> %s\033[0m\n" $$d; \
	  (cd infra/$$d && docker compose up -d) || exit 1; \
	done

infra-down: ## インフラを停止
	@for d in $(INFRA); do \
	  printf "\033[36m==> %s\033[0m\n" $$d; \
	  (cd infra/$$d && docker compose down); \
	done

infra-ps: ## インフラの状態を表示
	@for d in $(INFRA); do (cd infra/$$d && docker compose ps); done

# ---- アプリ作成 ---------------------------------------------------------------

laravel: network ## Laravel アプリを作成 (make laravel NAME=blog [DOMAIN=.. | HOST=..])
	@./scripts/new-laravel.sh "$(NAME)"

symfony: network ## Symfony アプリを作成 (make symfony NAME=shop [WEBAPP=0] [DOMAIN=.. | HOST=..])
	@WEBAPP="$(WEBAPP)" ./scripts/new-symfony.sh "$(NAME)"

apps: ## 作成済みアプリの一覧
	@ls -1 apps 2>/dev/null || echo "(なし)"

# ---- アプリ操作 (NAME 必須) ----------------------------------------------------

APP_DIR = apps/$(NAME)
define require_name
	@if [ -z "$(NAME)" ] || [ ! -d "$(APP_DIR)" ]; then \
	  echo "NAME を指定してください (例: make $@ NAME=blog)"; exit 1; \
	fi
endef

up: network ## アプリを起動 (make up NAME=blog)
	$(require_name)
	cd $(APP_DIR) && docker compose up -d

down: ## アプリを停止
	$(require_name)
	cd $(APP_DIR) && docker compose down

restart: ## アプリを再起動
	$(require_name)
	cd $(APP_DIR) && docker compose restart

build: ## アプリを再ビルドして起動 (OTEL_ENABLED 切り替え時など)
	$(require_name)
	cd $(APP_DIR) && docker compose up -d --build

logs: ## アプリのログを表示
	$(require_name)
	cd $(APP_DIR) && docker compose logs -f

ps: ## アプリの状態を表示
	$(require_name)
	cd $(APP_DIR) && docker compose ps

shell: ## app コンテナに入る
	$(require_name)
	cd $(APP_DIR) && docker compose exec app bash

vendor-sync: ## ホスト側 vendor を composer.lock に合わせる (補完用)
	$(require_name)
	cd $(APP_DIR) && docker compose run --rm local-composer install
