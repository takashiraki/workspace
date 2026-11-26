#!/usr/bin/env bash
# Node 系アプリを apps/<NAME> に作成し、開発サーバー起動まで行う
#   usage: FW=vue scripts/new-node.sh <NAME>
#
#   FW の設定は templates/node/frameworks.conf から読む
#   NODE_CREATE / NODE_DEV / NODE_PORT を指定すると設定より優先する (conf に無いものを一度だけ試すとき)
#   make からは CREATE= / DEV= / PORT= で渡す:
#     make node NAME=site CREATE="npm create astro@latest {NAME} -- --yes" \
#       DEV="npm run dev -- --host 0.0.0.0" PORT=4321
set -euo pipefail

NAME=${1:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/templates/node"
CONF="$TEMPLATE/frameworks.conf"
APP_DIR="$ROOT/apps/$NAME"
FW=${FW:-}

# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

set_env() { env_set "$APP_DIR/.env" "$1" "$2"; }

# conf_get FW KEY: frameworks.conf の [FW] セクションから KEY の値を取り出す
conf_get() {
  awk -v sec="[$1]" -v key="$2" '
    $0 == sec { in_sec = 1; next }
    /^\[/     { in_sec = 0 }
    in_sec && $0 ~ "^" key "[ \t]*=" { sub(/^[^=]*=[ \t]*/, ""); print; exit }
  ' "$CONF"
}
frameworks() { sed -n 's/^\[\(.*\)\]$/\1/p' "$CONF" | tr '\n' ' '; }

# ---- 設定の決定 ------------------------------------------------------------------
CREATE_CMD=${NODE_CREATE:-}
DEV_CMD=${NODE_DEV:-}
APP_PORT=${NODE_PORT:-}
if [[ -n "$FW" ]]; then
  grep -qx "\[$FW\]" "$CONF" || die "FW=$FW は frameworks.conf にありません (利用可能: $(frameworks))"
  CREATE_CMD=${CREATE_CMD:-$(conf_get "$FW" create)}
  DEV_CMD=${DEV_CMD:-$(conf_get "$FW" dev)}
  APP_PORT=${APP_PORT:-$(conf_get "$FW" port)}
fi
[[ -n "$CREATE_CMD" ]] || die "FW を指定してください (例: make node NAME=front FW=vue / 利用可能: $(frameworks))"
[[ -n "$APP_PORT" ]]   || die "ポートが決まりません (frameworks.conf の port か PORT=... を指定)"
CREATE_CMD=${CREATE_CMD//\{NAME\}/$NAME}

validate_new_app "$NAME" "$APP_DIR" "${FW:-node}"
TZ=${TZ:-Asia/Tokyo}
resolve_app_url "$NAME"
info "URL: $APP_URL  (${FW:-custom} / port $APP_PORT)"

# ---- 1. プロジェクト作成 (ホストに Node 不要) ------------------------------------
info "プロジェクトを作成: $CREATE_CMD"
mkdir -p "$ROOT/apps" "$ROOT/.cache/npm"
docker run --rm -u "$(id -u):$(id -g)" \
  -v "$ROOT/apps":/work -w /work \
  -v "$ROOT/.cache/npm":/cache \
  -e HOME=/tmp -e npm_config_cache=/cache -e npm_config_yes=true -e CI=1 \
  node:lts-alpine sh -c "$CREATE_CMD" </dev/null || true
if [[ ! -f "$APP_DIR/package.json" ]]; then
  # 空のディレクトリが残ると次回「既に存在します」で止まるので消しておく
  [[ -d "$APP_DIR" ]] && rmdir "$APP_DIR" 2>/dev/null || true
  die "apps/$NAME/package.json ができていません。create コマンドに質問を省略するオプションが付いているか確認してください"
fi

# ---- 2. テンプレートをコピー --------------------------------------------------
info "Docker 関連ファイルをコピー"
cp -R "$TEMPLATE"/. "$APP_DIR"/
rm -f "$APP_DIR/frameworks.conf"

# ---- 3. .env を設定 (compose 用) ----------------------------------------------
info ".env を設定"
set_env CONTAINER_NAME    "$NAME"
set_env VIRTUAL_HOST      "$APP_HOST"
set_env APP_PORT          "$APP_PORT"
set_env DEV_COMMAND       "$DEV_CMD"
set_env LETSENCRYPT_HOST  "$LE_HOST"
set_env LETSENCRYPT_EMAIL "$LE_EMAIL"
set_env TZ                "$TZ"

# .env を git 管理外に (テンプレートによっては .gitignore に入っていないため)
touch "$APP_DIR/.gitignore"
grep -qxE '\.env' "$APP_DIR/.gitignore" || printf '\n.env\n' >> "$APP_DIR/.gitignore"

# ---- 4. 依存インストール・起動 ---------------------------------------------------
cd "$APP_DIR"
info "イメージをビルド"
docker compose build
# 実行環境 (alpine) と同じイメージで install する (ネイティブバイナリを合わせるため)
info "npm install"
docker compose run --rm --no-deps app npm install
info "コンテナを起動"
docker compose up -d

info "完了: $APP_URL  (apps/$NAME)"
[[ -n "$DEV_CMD" ]] || warn "DEV_COMMAND が空のため開発サーバーは起動していません (make shell NAME=$NAME で入って起動)"
