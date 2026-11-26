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
