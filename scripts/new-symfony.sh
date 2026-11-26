#!/usr/bin/env bash
# Symfony アプリを apps/<NAME> に作成し、コンテナ起動まで行う
#   usage: [WEBAPP=1|0] [DOMAIN=..] [HOST=..] scripts/new-symfony.sh <NAME>
#     WEBAPP=1 (デフォルト): symfony/webapp-pack (Twig / Doctrine / AssetMapper 等) を入れる
#     WEBAPP=0             : symfony/skeleton のみ (API / CLI 向けの最小構成)
set -euo pipefail

NAME=${1:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/templates/php/symfony"
APP_DIR="$ROOT/apps/$NAME"
WEBAPP=${WEBAPP:-1}

# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

# .env 末尾の「###> workspace/docker ###」ブロックに compose 用の値を書く
# (既存のブロックは消してから書き直す。macOS の awk は -v に複数行を渡せないため追記方式)
write_compose_env() {
  local f="$APP_DIR/.env" tmp
  tmp=$(mktemp)
  awk '
    /^###> workspace\/docker ###$/ { skip = 1; next }
    /^###< workspace\/docker ###$/ { skip = 0; next }
    !skip { print }
  ' "$f" > "$tmp"
  cat >> "$tmp" <<EOF
###> workspace/docker ###
# docker compose 用 (compose は .env しか読まないためここに置く。秘密情報は .env.local へ)
CONTAINER_NAME=$NAME
VIRTUAL_HOST=$APP_HOST
LETSENCRYPT_HOST=$LE_HOST
LETSENCRYPT_EMAIL=$LE_EMAIL
TZ=$TZ
OTEL_ENABLED=false
OTEL_SERVICE_NAME=$NAME
HOST_PROJECT_PATH=$APP_DIR
###< workspace/docker ###
EOF
  cat "$tmp" > "$f" && rm -f "$tmp"
}

validate_new_app "$NAME" "$APP_DIR" symfony
DB_NAME=${NAME//-/_}
TZ=${TZ:-Asia/Tokyo}
resolve_app_url "$NAME"
info "URL: $APP_URL"
load_mysql_env

# ---- 1. Symfony 作成 ------------------------------------------------------------
info "Symfony を作成: apps/$NAME"
mkdir -p "$ROOT/apps"
composer_run "$ROOT/apps" create-project symfony/skeleton "$NAME" --no-interaction

# Flex のレシピが compose.yaml / compose.override.yaml (専用 Postgres や Mailpit) を
# 生成しないようにする。DB / メールはワークスペース共通のインフラを使う
composer_run "$APP_DIR" config --json extra.symfony.docker false

if [[ "$WEBAPP" == 1 ]]; then
  info "webapp-pack をインストール"
  composer_run "$APP_DIR" require webapp --no-interaction
fi

# ---- 2. テンプレートをコピー --------------------------------------------------
info "Docker 関連ファイルをコピー"
cp -R "$TEMPLATE"/. "$APP_DIR"/
chmod +x "$APP_DIR/.docker/entrypoint.sh"

# ---- 3. DB を作成 (MySQL が起動していれば) -------------------------------------
DB_READY=0
create_app_database "$DB_NAME" && DB_READY=1

# ---- 4. 環境変数を設定 ----------------------------------------------------------
# .env は git 管理されるファイルなので、compose 用の値だけを置く (compose は .env しか読まない)
# 秘密情報やローカル固有の接続先は .env.local (git 管理外) に置く
info ".env / .env.local を設定"

write_compose_env

LOCAL_ENV="$APP_DIR/.env.local"
env_set "$LOCAL_ENV" DEFAULT_URI "$APP_URL"
if [[ -n "$MYSQL_USER" ]]; then
  env_set "$LOCAL_ENV" DATABASE_URL \
    "\"mysql://$(urlencode "$MYSQL_USER"):$(urlencode "$MYSQL_PASSWORD")@my_database:3306/$DB_NAME?serverVersion=$MYSQL_SERVER_VERSION&charset=utf8mb4\""
fi
env_set "$LOCAL_ENV" MAILER_DSN "smtp://mail:1025"

# ---- 5. 起動 ------------------------------------------------------------------
info "コンテナをビルド・起動"
cd "$APP_DIR"
docker compose up -d --build

# vendor は名前付きボリューム (vendor-store) なので、コンテナ内でも install が必要
info "app コンテナ内で composer install"
docker compose exec -T app composer install --no-interaction

if [[ "$DB_READY" == 1 ]] &&
   docker compose exec -T app php bin/console list --raw | grep -q '^doctrine:migrations:migrate '; then
  info "migrate"
  docker compose exec -T app php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration
fi

info "完了: $APP_URL  (apps/$NAME)"
