#!/usr/bin/env bash
# Laravel アプリを apps/<NAME> に作成し、コンテナ起動まで行う
#   usage: [DOMAIN=..] [HOST=..] scripts/new-laravel.sh <NAME>
set -euo pipefail

NAME=${1:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/templates/php/laravel"
APP_DIR="$ROOT/apps/$NAME"

# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

# アプリの .env の KEY を VALUE に設定する
set_env() { env_set "$APP_DIR/.env" "$1" "$2"; }

validate_new_app "$NAME" "$APP_DIR" laravel
DB_NAME=${NAME//-/_}
TZ=${TZ:-Asia/Tokyo}
resolve_app_url "$NAME"
info "URL: $APP_URL"
load_mysql_env

# ---- 1. Laravel 作成 ------------------------------------------------------------
info "Laravel を作成: apps/$NAME"
mkdir -p "$ROOT/apps"
composer_run "$ROOT/apps" create-project laravel/laravel "$NAME"

# ---- 2. テンプレートをコピー --------------------------------------------------
info "Docker 関連ファイルをコピー"
cp -R "$TEMPLATE"/. "$APP_DIR"/

# ---- 3. DB を作成 (MySQL が起動していれば) -------------------------------------
DB_READY=0
create_app_database "$DB_NAME" && DB_READY=1

# ---- 4. .env を設定 (Laravel と compose で共用。.env は git 管理外) -------------
info ".env を設定"

# compose 用
set_env CONTAINER_NAME    "$NAME"
set_env DOCKER_PATH       ""
set_env REPOSITORY        "."
set_env HOST_PROJECT_PATH "$APP_DIR"
set_env VIRTUAL_HOST      "$APP_HOST"
set_env LETSENCRYPT_HOST  "$LE_HOST"
set_env LETSENCRYPT_EMAIL "$LE_EMAIL"
set_env LETSENCRYPT_TEST  ""
set_env CERT_NAME         ""
set_env TZ                "$TZ"
set_env OTEL_ENABLED      "false"
set_env OTEL_SERVICE_NAME "$NAME"

# Laravel 用
set_env APP_NAME "$NAME"
set_env APP_URL  "$APP_URL"

set_env DB_CONNECTION mysql
set_env DB_HOST       my_database
set_env DB_PORT       3306
set_env DB_DATABASE   "$DB_NAME"
set_env DB_USERNAME   "$MYSQL_USER"
set_env DB_PASSWORD   "$MYSQL_PASSWORD"

set_env REDIS_HOST  my_redis
set_env MAIL_MAILER smtp
set_env MAIL_HOST   mail
set_env MAIL_PORT   1025

# ---- 5. 起動 ------------------------------------------------------------------
info "コンテナをビルド・起動"
cd "$APP_DIR"
docker compose up -d --build

# vendor は名前付きボリューム (vendor-store) なので、コンテナ内でも install が必要
info "app コンテナ内で composer install"
docker compose exec -T app composer install --no-interaction

if [[ "$DB_READY" == 1 ]]; then
  info "migrate"
  docker compose exec -T app php artisan migrate --force
fi

info "完了: $APP_URL  (apps/$NAME)"
