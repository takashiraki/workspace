#!/usr/bin/env bash
# ワークスペースの初期化: ルート .env とインフラ各 .env を作成・更新する
#   usage: DOMAIN=hogehoge.localhost [LETSENCRYPT_EMAIL=..] scripts/init.sh
#
#   - DOMAIN 未指定なら既存の .env の値、それも無ければ入力を求める
#   - ドメインに関わる値 (VIRTUAL_HOST 等) は毎回 DOMAIN に合わせて上書き
#   - それ以外の値は空のときだけデフォルトを入れる (既存の値・パスワードは変えない)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

ROOT_ENV="$ROOT/.env"
INFRA="$ROOT/infra"

# ---- ルート .env ----------------------------------------------------------------
FRESH=0
[[ -f "$ROOT_ENV" ]] || { cp "$ROOT/.env.example" "$ROOT_ENV"; FRESH=1; }

# 引数 > (初回なら入力) > 既存 .env の値
if [[ -z "${DOMAIN:-}" ]]; then
  if [[ "$FRESH" == 1 && -t 0 ]]; then
    read -r -p "メインドメイン [localhost]: " input
    DOMAIN=${input:-localhost}
  else
    DOMAIN=$(env_get "$ROOT_ENV" DOMAIN)
    DOMAIN=${DOMAIN:-localhost}
  fi
fi
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "ドメインの形式が正しくありません: $DOMAIN"

LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-$(env_get "$ROOT_ENV" LETSENCRYPT_EMAIL)}
if ! is_local_domain "$DOMAIN" && [[ -z "$LETSENCRYPT_EMAIL" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Let's Encrypt 用メールアドレス: " LETSENCRYPT_EMAIL
  fi
  [[ -n "$LETSENCRYPT_EMAIL" ]] || warn "LETSENCRYPT_EMAIL が未設定です (アプリ作成時に必要)"
fi

env_set "$ROOT_ENV" DOMAIN "$DOMAIN"
env_set "$ROOT_ENV" LETSENCRYPT_EMAIL "$LETSENCRYPT_EMAIL"
env_default "$ROOT_ENV" TZ "Asia/Tokyo"
TZ_VALUE=$(env_get "$ROOT_ENV" TZ)

info "DOMAIN=$DOMAIN"

# インフラ .env を用意 (無ければ .env.example から)
prepare() {
  local dir="$INFRA/$1"
  [[ -d "$dir" ]] || { warn "$1 がありません (make init で submodule を取得)"; return 1; }
  [[ -f "$dir/.env" ]] || { [[ -f "$dir/.env.example" ]] && cp "$dir/.env.example" "$dir/.env" || : > "$dir/.env"; }
  echo "$dir/.env"
}

declare -a URLS=()

# ---- mailpit --------------------------------------------------------------------
if f=$(prepare docker_mailpit); then
  env_set     "$f" VIRTUAL_HOST "mailpit.$DOMAIN"
  env_set     "$f" VIRTUAL_PORT 8025
  env_default "$f" TZ "$TZ_VALUE"
  env_default "$f" MP_MAX_MESSAGES 5000
  env_default "$f" MP_DATABASE /data/mailpit.db
  env_default "$f" MP_SMTP_AUTH_ACCEPT_ANY 1
  env_default "$f" MP_SMTP_AUTH_ALLOW_INSECURE 1
  URLS+=("Mailpit      http://mailpit.$DOMAIN")
fi

# ---- redis (Redis Insight) ------------------------------------------------------
if f=$(prepare docker_redis); then
  env_set "$f" VIRTUAL_HOST "redis.$DOMAIN"
  env_set "$f" VIRTUAL_PORT 5540
  URLS+=("RedisInsight http://redis.$DOMAIN")
fi

# ---- prometheus / grafana / tempo -----------------------------------------------
if f=$(prepare docker_prometheus); then
  # コンテナ名は prometheus.yml / grafana の datasource が参照している名前に合わせる
  env_default "$f" PROMETHEUS_CONTAINER_NAME my_prometheus
  env_default "$f" GRAFANA_CONTAINER_NAME    my_grafana
  env_default "$f" TEMPO_CONTAINER_NAME      my-tempo
  env_set "$f" PROMETHEUS_VIRTUAL_HOST "prometheus.$DOMAIN"
  env_set "$f" PROMETHEUS_VIRTUAL_PORT 9090
  env_set "$f" GRAFANA_VIRTUAL_HOST    "grafana.$DOMAIN"
  env_set "$f" GRAFANA_VIRTUAL_PORT    3000
  env_set "$f" TEMPO_VIRTUAL_HOST      "tempo.$DOMAIN"
  env_set "$f" TEMPO_VIRTUAL_PORT      3200
  URLS+=("Prometheus   http://prometheus.$DOMAIN")
  URLS+=("Grafana      http://grafana.$DOMAIN")
  URLS+=("Tempo        http://tempo.$DOMAIN")
fi

# ---- mysql (ドメイン無関係。空の項目だけ埋める) ---------------------------------
if f=$(prepare docker_mysql); then
  env_default "$f" MYSQL_HOST localhost
  env_default "$f" MYSQL_USER app
  env_default "$f" MYSQL_PASSWORD "$(random_password)"
  env_default "$f" MYSQL_ROOT_PASSWORD "$(random_password)"
  env_default "$f" DB_PORT 3306
fi

# ---- 結果 ------------------------------------------------------------------------
info "インフラの URL (make infra-up 後)"
for u in "${URLS[@]}"; do echo "  $u"; done

if ! is_local_domain "$DOMAIN"; then
  warn "Mailpit / RedisInsight / Prometheus 等の管理画面が $DOMAIN で外部公開されます。"
  warn "infra/docker_proxy_network/.htpasswd で Basic 認証をかけることを検討してください。"
fi
