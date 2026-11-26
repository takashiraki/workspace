# Dev Workspace

A Docker-based development workspace that sets up shared infrastructure (reverse proxy, MySQL, Redis, Mailpit, Prometheus/Grafana/Tempo) and scaffolds ready-to-run applications with a single `make` command.

```bash
make init DOMAIN=hogehoge.localhost
make infra-up
make laravel NAME=blog     # → http://blog.hogehoge.localhost
```

## Features

- **One-command app scaffolding**: `make laravel NAME=blog` creates a Laravel project with `compose.yaml`, `Dockerfile` and PHP/Apache config already inside it, then builds and starts it.
- **No local PHP required**: Composer runs inside a container.
- **Domain-based routing**: Every app and infra UI is served at `<name>.<DOMAIN>` through nginx-proxy. Use `*.localhost` locally, or a real domain on a server with automatic Let's Encrypt certificates.
- **Shared infrastructure**: Apps connect to shared MySQL, Redis and Mailpit over external Docker networks. Each app and each infra service is an independent Compose project, so you can start and stop them separately.

## Requirements

- Docker (Docker Desktop on macOS)
- Docker Compose v2
- GNU Make
- Git

## Directory Structure

```
workspace/
├── Makefile                 # Entry point for every operation
├── .env.example             # Workspace settings (DOMAIN, LETSENCRYPT_EMAIL, TZ)
├── scripts/
│   ├── init.sh              # Generates root and infra .env files
│   ├── new-laravel.sh       # Scaffolds a Laravel app
│   └── lib.sh               # Shared helpers
├── templates/
│   └── php/laravel/         # Docker files copied into new Laravel apps
├── infra/                   # Git submodules, each one is a separate Compose project
│   ├── docker_proxy_network/
│   ├── docker_mysql/
│   ├── docker_redis/
│   ├── docker_mailpit/
│   └── docker_prometheus/
└── apps/                    # Generated apps (git-ignored, each has its own repo)
```

## Getting Started

### 1. Clone

```bash
git clone --recursive <this-repository-url> workspace
cd workspace
```

If you cloned without `--recursive`, `make init` fetches the submodules for you.

### 2. Initialize

```bash
make init DOMAIN=hogehoge.localhost
```

This command:

- fetches the submodules
- creates the root `.env`
- creates or updates the `.env` file of each infra service

If you run `make init` without `DOMAIN` for the first time, it asks you for one (the default is `localhost`).

### 3. Start the infrastructure

```bash
make infra-up
```

This creates the external networks (`my_infra_network`, `my_proxy_network`) if they don't exist, then starts the infra services in order, beginning with the proxy. Services without a `.env` file are skipped with a warning.

### 4. Create an app

```bash
make laravel NAME=blog
```

Open `http://blog.<DOMAIN>` in your browser.

## Domain Configuration

The main domain is stored in the root `.env` file.

| Setting | Apps | Infra UIs |
|---|---|---|
| `DOMAIN=localhost` (default) | `http://blog.localhost` | `http://mailpit.localhost` |
| `DOMAIN=hogehoge.localhost` | `http://blog.hogehoge.localhost` | `http://mailpit.hogehoge.localhost` |
| `DOMAIN=example.com` | `https://blog.example.com` | `http://mailpit.example.com` |

- **Changing the domain**: Run `make init DOMAIN=<new-domain>` again. Hostnames (`VIRTUAL_HOST`/`VIRTUAL_PORT`) are always rewritten. Other values in the infra `.env` files are only filled in when they are empty, so your own edits and existing passwords are kept.
- **Non-`localhost` domains**: Apps get HTTPS through Let's Encrypt. You need to set `LETSENCRYPT_EMAIL`, either in `.env` or with `make init DOMAIN=example.com LETSENCRYPT_EMAIL=you@example.com`.
- **Overriding per command**: Any setting can be overridden on the command line:

  ```bash
  make laravel NAME=blog DOMAIN=fuga.localhost
  make laravel NAME=blog HOST=www.example.org   # use an exact hostname
  ```

- **Checking the current settings**: Run `make config`.

### Infra service URLs

| Service | URL | Container port |
|---|---|---|
| Mailpit | `mailpit.<DOMAIN>` | 8025 |
| RedisInsight | `redis.<DOMAIN>` | 5540 |
| Prometheus | `prometheus.<DOMAIN>` | 9090 |
| Grafana | `grafana.<DOMAIN>` | 3000 |
| Tempo | `tempo.<DOMAIN>` | 3200 |

## Commands

Run `make help` to list every command.

### Workspace

| Command | Description |
|---|---|
| `make init [DOMAIN=..] [LETSENCRYPT_EMAIL=..]` | Fetch submodules and create or update the `.env` files |
| `make config` | Show the current workspace settings |
| `make network` | Create the external Docker networks if they don't exist |

### Infrastructure

| Command | Description |
|---|---|
| `make infra-up` | Start all infra services |
| `make infra-down` | Stop all infra services |
| `make infra-ps` | Show the status of the infra services |

To target only some services, pass `INFRA`:

```bash
make infra-up INFRA="docker_mysql docker_redis"
```

### Apps

| Command | Description |
|---|---|
| `make laravel NAME=<name>` | Create a new Laravel app in `apps/<name>` |
| `make apps` | List the apps |
| `make up NAME=<name>` | Start the app |
| `make down NAME=<name>` | Stop the app and remove its containers |
| `make restart NAME=<name>` | Restart the app's containers |
| `make build NAME=<name>` | Rebuild the image and start the app |
| `make logs NAME=<name>` | Follow the app's logs |
| `make ps NAME=<name>` | Show the status of the app's containers |
| `make shell NAME=<name>` | Open a bash shell in the `app` container |
| `make vendor-sync NAME=<name>` | Install `vendor/` on the host (for IDE completion) |

Each app command is a shortcut for `cd apps/<name> && docker compose ...`. Inside an app directory, you can use `docker compose` directly.

## What `make laravel` Does

1. Runs `composer create-project laravel/laravel` in a `composer:2` container.
2. Copies `templates/php/laravel/` into the new project.
3. Configures the app's `.env`, which is shared by Laravel and Docker Compose:
   - **Compose settings**: `CONTAINER_NAME`, `VIRTUAL_HOST`, `LETSENCRYPT_*`, `HOST_PROJECT_PATH`, `TZ`, `OTEL_ENABLED=false`
   - **Laravel settings**:
     - `APP_URL`
     - `DB_HOST=my_database`, with the credentials taken from `infra/docker_mysql/.env`
     - `REDIS_HOST=my_redis`
     - `MAIL_HOST=mail` and `MAIL_PORT=1025` (Mailpit)
4. Creates a database named after the app and grants privileges to it, if `my_database` is running. A `-` in the name becomes `_`.
5. Builds and starts the containers, runs `composer install` inside the `app` container, and runs `php artisan migrate` (only when the database was created).

App names must use lowercase letters, numbers, `-` and `_`, and be at least two characters long.

## App Container Notes

### `vendor/` lives in two places

- **Inside the container**: `vendor/` is a named volume (`vendor-store`), which keeps file access fast on macOS.
- **On the host**: A separate copy is installed by the `local-composer` service so that your editor can use it for completion and code navigation.

After you run `composer require` inside the container, update the host copy with:

```bash
make vendor-sync NAME=blog
```

### OpenTelemetry

OpenTelemetry is **off by default**. To turn it on, set this in the app's `.env` and rebuild:

```bash
OTEL_ENABLED=true
```

```bash
make build NAME=blog
```

`OTEL_ENABLED` controls two things:

- **At build time**: whether the `opentelemetry` PHP extension is installed
- **At runtime**: whether the SDK auto-loads (`OTEL_PHP_AUTOLOAD_ENABLED`)

When it is off, nothing is exported, so no errors are logged even if no collector is running.

If your project requires OpenTelemetry Composer packages, such as `open-telemetry/opentelemetry-auto-laravel`, keep `OTEL_ENABLED=true`. To pause exporting in that case, use `OTEL_SDK_DISABLED=true` instead; removing the extension would break Composer's platform check.

### Production build

The `Dockerfile` accepts an `APP_ENV` build argument. With `APP_ENV=prod`, it uses `.docker/php-prod.ini` and disables Xdebug:

```bash
cd apps/blog && docker compose build --build-arg APP_ENV=prod
```

## Troubleshooting

- **`*.localhost` does not resolve**: Chrome and Firefox resolve every `*.localhost` subdomain to `127.0.0.1`. Some tools and browsers (such as Safari or older `curl`) may not. Add the entries to `/etc/hosts`, or set up a wildcard with dnsmasq.
- **`network my_infra_network not found`**: Run `make network`. Every `make up`, `make infra-up` and `make laravel` also runs it.
- **An infra service is skipped by `make infra-up`**: Its `.env` file is missing. Run `make init`.
- **The database or migration step was skipped**: `my_database` was not running when the app was created. Run `make infra-up`, create the database, then run `make shell NAME=<name>` and `php artisan migrate`.

## Security

When `DOMAIN` is a public domain, the infra admin UIs (Mailpit, RedisInsight, Prometheus, Grafana, Tempo) are exposed without authentication and over plain HTTP. Protect them with Basic authentication via `infra/docker_proxy_network/.htpasswd`, or keep them off the public proxy.

## Updating Submodules

```bash
git submodule update --remote          # pull the latest commit of each infra repo
git add infra && git commit -m "Update infra submodules"
```
