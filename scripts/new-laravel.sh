#!/usr/bin/env bash
# Laravel アプリを apps/<NAME> に作成し、コンテナ起動まで行う
#   usage: scripts/new-laravel.sh <NAME>
set -euo pipefail

NAME=${1:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/templates/php/laravel"
APP_DIR="$ROOT/apps/$NAME"
MYSQL_ENV="$ROOT/infra/docker_mysql/.env"

info() { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# .env の KEY を VALUE に設定する (コメントアウトされた行も対象。無ければ追記)
set_env() {
  local key=$1 value=$2 file="$APP_DIR/.env" tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ "^#? ?" k "=" { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ---- 入力チェック ------------------------------------------------------------
[[ -n "$NAME" ]] || die "NAME を指定してください (例: make laravel NAME=blog)"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]+$ ]] || die "NAME は英小文字・数字・-・_ で2文字以上にしてください: $NAME"
[[ ! -e "$APP_DIR" ]] || die "$APP_DIR は既に存在します"
docker info >/dev/null 2>&1 || die "Docker が起動していません"

DB_NAME=${NAME//-/_}

# ---- 1. Laravel 作成 (ホストに PHP 不要) --------------------------------------
info "Laravel を作成: apps/$NAME"
mkdir -p "$ROOT/apps"
docker run --rm -u "$(id -u):$(id -g)" \
  -v "$ROOT/apps":/app -w /app \
  -e COMPOSER_CACHE_DIR=/tmp/composer-cache \
  composer:2 create-project laravel/laravel "$NAME"

# ---- 2. テンプレートをコピー --------------------------------------------------
info "Docker 関連ファイルをコピー"
cp -R "$TEMPLATE"/. "$APP_DIR"/

# ---- 3. .env を設定 -----------------------------------------------------------
info ".env を設定"

# compose 用
set_env CONTAINER_NAME    "$NAME"
set_env DOCKER_PATH       ""
set_env REPOSITORY        "."
set_env HOST_PROJECT_PATH "$APP_DIR"
set_env VIRTUAL_HOST      "$NAME.localhost"
set_env LETSENCRYPT_HOST  ""
set_env LETSENCRYPT_EMAIL ""
set_env LETSENCRYPT_TEST  ""
set_env CERT_NAME         ""
set_env TZ                "Asia/Tokyo"
set_env OTEL_ENABLED      "false"
set_env OTEL_SERVICE_NAME "$NAME"

# Laravel 用
set_env APP_NAME "$NAME"
set_env APP_URL  "http://$NAME.localhost"

set_env DB_CONNECTION mysql
set_env DB_HOST       my_database
set_env DB_PORT       3306
set_env DB_DATABASE   "$DB_NAME"
if [[ -f "$MYSQL_ENV" ]]; then
  # shellcheck disable=SC1090
  MYSQL_USER=$(grep -E '^MYSQL_USER=' "$MYSQL_ENV" | cut -d= -f2-)
  MYSQL_PASSWORD=$(grep -E '^MYSQL_PASSWORD=' "$MYSQL_ENV" | cut -d= -f2-)
  MYSQL_ROOT_PASSWORD=$(grep -E '^MYSQL_ROOT_PASSWORD=' "$MYSQL_ENV" | cut -d= -f2-)
  set_env DB_USERNAME "$MYSQL_USER"
  set_env DB_PASSWORD "$MYSQL_PASSWORD"
else
  warn "$MYSQL_ENV がないため DB_USERNAME / DB_PASSWORD は未設定です"
fi

set_env REDIS_HOST my_redis
set_env MAIL_MAILER smtp
set_env MAIL_HOST   mail
set_env MAIL_PORT   1025

# ---- 4. DB を作成 (MySQL が起動していれば) -------------------------------------
if docker ps --format '{{.Names}}' | grep -qx my_database && [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  info "データベース $DB_NAME を作成"
  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" my_database mysql -uroot -e \
    "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
     GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$MYSQL_USER'@'%'; FLUSH PRIVILEGES;"
  DB_READY=1
else
  warn "my_database が起動していないため DB 作成と migrate をスキップします (make infra-up 後に再実行してください)"
  DB_READY=0
fi

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

info "完了: http://$NAME.localhost  (apps/$NAME)"
