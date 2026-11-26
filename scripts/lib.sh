# scripts/ 共通の関数 (source して使う)

info() { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# env_set FILE KEY VALUE
#   KEY を VALUE に設定する (コメントアウトされた行も対象。無ければ追記)
env_set() {
  local file=$1 key=$2 value=$3 tmp
  [[ -f "$file" ]] || : > "$file"
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ "^#? ?" k "=" { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp" && cat "$tmp" > "$file" && rm -f "$tmp"
}

# env_get FILE KEY
env_get() {
  [[ -f "$1" ]] || return 0
  grep -E "^$2=" "$1" | tail -1 | cut -d= -f2-
}

# env_default FILE KEY VALUE
#   KEY が未設定 or 空のときだけ VALUE を設定する (既存の値は変えない)
env_default() {
  [[ -n "$(env_get "$1" "$2")" ]] || env_set "$1" "$2" "$3"
}

# ランダムなパスワード
random_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# *.localhost かどうか
is_local_domain() {
  [[ "$1" == localhost || "$1" == *.localhost ]]
}

# URL エンコード (DSN にパスワードを埋め込むとき用)
urlencode() {
  local s=$1 out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9._~-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# ==== アプリ作成の共通処理 =====================================================
# 呼び出し側で ROOT を定義しておくこと

# validate_new_app NAME APP_DIR FRAMEWORK
validate_new_app() {
  local name=$1 dir=$2 fw=$3
  [[ -n "$name" ]] || die "NAME を指定してください (例: make $fw NAME=blog)"
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]+$ ]] || die "NAME は英小文字・数字・-・_ で2文字以上にしてください: $name"
  [[ ! -e "$dir" ]] || die "$dir は既に存在します"
  docker info >/dev/null 2>&1 || die "Docker が起動していません"
}

# resolve_app_url NAME
#   DOMAIN / HOST / LETSENCRYPT_EMAIL から以下を決める:
#   APP_HOST SCHEME LE_HOST LE_EMAIL APP_URL
resolve_app_url() {
  local domain=${DOMAIN:-localhost}
  APP_HOST=${HOST:-$1.$domain}
  if is_local_domain "$APP_HOST"; then
    SCHEME=http; LE_HOST=""; LE_EMAIL=""
  else
    [[ -n "${LETSENCRYPT_EMAIL:-}" ]] || die "DOMAIN が localhost 以外のときは LETSENCRYPT_EMAIL が必要です (.env か引数で指定)"
    SCHEME=https; LE_HOST=$APP_HOST; LE_EMAIL=$LETSENCRYPT_EMAIL
  fi
  APP_URL="$SCHEME://$APP_HOST"
}

# load_mysql_env → MYSQL_USER MYSQL_PASSWORD MYSQL_ROOT_PASSWORD
load_mysql_env() {
  local f="$ROOT/infra/docker_mysql/.env"
  MYSQL_USER=$(env_get "$f" MYSQL_USER)
  MYSQL_PASSWORD=$(env_get "$f" MYSQL_PASSWORD)
  MYSQL_ROOT_PASSWORD=$(env_get "$f" MYSQL_ROOT_PASSWORD)
  [[ -n "$MYSQL_USER" ]] || warn "$f に MYSQL_USER がないため DB 接続情報は未設定です (make init を実行してください)"
}

# create_app_database DB_NAME
#   my_database が起動していれば DB を作成して MYSQL_USER に権限を付与する
#   MYSQL_SERVER_VERSION も取得する。成功で 0、スキップで 1
create_app_database() {
  local db=$1
  MYSQL_SERVER_VERSION=${MYSQL_SERVER_VERSION:-8.4}
  if ! docker ps --format '{{.Names}}' | grep -qx my_database || [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    warn "my_database が起動していないため DB 作成と migrate をスキップします (make infra-up 後に手動で実行してください)"
    return 1
  fi
  info "データベース $db を作成"
  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" my_database mysql -uroot -e \
    "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
     GRANT ALL PRIVILEGES ON \`$db\`.* TO '$MYSQL_USER'@'%'; FLUSH PRIVILEGES;"
  MYSQL_SERVER_VERSION=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" my_database \
    mysql -uroot -N -e 'SELECT VERSION()' 2>/dev/null | cut -d- -f1)
  MYSQL_SERVER_VERSION=${MYSQL_SERVER_VERSION:-8.4}
}

# composer_run DIR ARGS...
#   composer:2 コンテナで composer を実行 (ホストに PHP 不要)
#   キャッシュは $ROOT/.cache/composer に保持して2回目以降を速くする
composer_run() {
  local dir=$1; shift
  mkdir -p "$ROOT/.cache/composer"
  docker run --rm -u "$(id -u):$(id -g)" \
    -v "$dir":/app -w /app \
    -v "$ROOT/.cache/composer":/tmp/composer-cache \
    -e COMPOSER_CACHE_DIR=/tmp/composer-cache \
    composer:2 "$@"
}
