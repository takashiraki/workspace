FROM php:8.4-apache

RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && curl -1sLf 'https://dl.cloudsmith.io/public/symfony/stable/setup.deb.sh' | bash \
    && apt-get update \
    && apt-get install -y unzip libpq-dev git vim sqlite3 libsqlite3-dev libicu-dev gh tmux lazygit symfony-cli default-jdk graphviz fonts-ipafont \
    && pecl install xdebug redis \
    && docker-php-ext-enable xdebug redis \
    && docker-php-ext-install mysqli pdo_mysql opcache intl pcntl \
    && curl -Lo /usr/local/bin/phpactor https://github.com/phpactor/phpactor/releases/latest/download/phpactor.phar \
    && chmod +x /usr/local/bin/phpactor \
    && curl -Lo /usr/local/bin/php-cs-fixer https://github.com/PHP-CS-Fixer/PHP-CS-Fixer/releases/latest/download/php-cs-fixer.phar \
    && chmod +x /usr/local/bin/php-cs-fixer \
    && a2enmod rewrite

# OpenTelemetry 拡張は OTEL_ENABLED=true のときだけ入れる
# (フラグ切り替え時にこのレイヤーだけ再ビルドされるよう、上の RUN とは分けている)
ARG OTEL_ENABLED=false
RUN if [ "$OTEL_ENABLED" = "true" ]; then \
        pecl install opentelemetry \
        && docker-php-ext-enable opentelemetry; \
    fi

ARG APP_ENV=dev

COPY .docker/php.ini /usr/local/etc/php/php.ini
COPY .docker/php-prod.ini /usr/local/etc/php/php-prod.ini

RUN if [ "$APP_ENV" = "prod" ]; then \
        cp /usr/local/etc/php/php-prod.ini /usr/local/etc/php/php.ini; \
        docker-php-ext-disable xdebug; \
    fi; \
    rm -f /usr/local/etc/php/php-prod.ini

COPY .docker/000-default.conf /etc/apache2/sites-available/
COPY . /var/www/html/

COPY --from=node:22 /usr/local/bin /usr/local/bin
COPY --from=node:22 /usr/local/lib /usr/local/lib

WORKDIR /var/www/html

# prod: 依存インストールとアセットのビルド (コマンドが存在するものだけ実行)
RUN if [ "$APP_ENV" = "prod" ]; then \
        composer install --no-dev --optimize-autoloader --no-scripts \
        && has() { php bin/console list --raw | grep -q "^$1 "; } \
        && if has importmap:install;  then php bin/console importmap:install; fi \
        && if has tailwind:build;     then php bin/console tailwind:build --minify; fi \
        && if has asset-map:compile;  then php bin/console asset-map:compile; fi; \
    fi

COPY .docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["entrypoint.sh"]
