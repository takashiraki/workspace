#!/bin/sh
set -e

if [ "$APP_ENV" = "prod" ]; then
    # Doctrine が入っていない構成 (WEBAPP=0 等) でも起動できるよう、コマンドがあるときだけ migrate
    if php bin/console list --raw | grep -q '^doctrine:migrations:migrate '; then
        php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration
    fi
    php bin/console cache:clear --env=prod --no-debug
    php bin/console assets:install --env=prod

    # cache:clear 等はrootで実行されるため、Apacheワーカー(www-data)が
    # 実行時に書き込めるよう所有権を渡す(var/logはgitで管理されておらず
    # イメージ内に存在しないことがあるため、先に作成しておく)
    mkdir -p var/cache var/log
    chown -R www-data:www-data var/cache var/log
fi

exec docker-php-entrypoint apache2-foreground
