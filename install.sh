#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Needs Linux, git, and OCI runtime with Compose v2; 
# `just` is installed into ~/.local/bin if it's missing.
#
# Settings, as environment variables:
#   RUNDOC_DIR    where to put it (default: ./rundoc)
#   RUNDOC_REF    the branch or tag to clone (default: main)
#   RUNDOC_ADMIN  the first admin's login (default: your user name)
#   RUNDOC_START  0 sets everything up without starting it (default: 1)
#
# Run it again to update the checkout and start it again. It never changes an
# existing .env or config/doc.local.toml.

set -euo pipefail

say() { printf 'rundoc: %s\n' "$*"; }
fail() { printf 'rundoc: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required: install it, then run this again"; }

# 24 random bytes as hex: safe in a .env file and inside a postgres:// URL
secret() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Everything runs from main, so a `curl | bash` has read the whole script
# before any of it runs, and nothing below can swallow the rest of it.
main() {
  local repo="https://github.com/colwill/doc"
  local dir="${RUNDOC_DIR:-rundoc}"
  local ref="${RUNDOC_REF:-main}"
  local admin="${RUNDOC_ADMIN:-${USER:-admin}}"
  local start="${RUNDOC_START:-1}"

  [ "$(uname -s)" = "Linux" ] || fail "Rundoc runs on Linux with Docker; this is $(uname -s). The README covers other setups: $repo#readme"
  need git
  need docker
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is missing: install the docker-compose-plugin package"
  if [ "$start" != "0" ]; then
    docker info >/dev/null 2>&1 || fail "can't reach Docker: start it, or add yourself to the docker group and log in again"
  fi
  printf '%s' "$admin" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' \
    || fail "'$admin' isn't a login Rundoc accepts: set RUNDOC_ADMIN to letters, digits, '.', '_' or '-'"

  if [ -d "$dir/.git" ]; then
    say "updating $dir"
    git -C "$dir" pull --quiet --ff-only || say "couldn't fast-forward $dir, so it stays as it is"
  elif [ -e "$dir" ]; then
    fail "$dir already exists and isn't a Rundoc checkout: set RUNDOC_DIR to install somewhere else"
  else
    say "cloning $repo into $dir"
    git clone --quiet --depth 1 --branch "$ref" "$repo" "$dir"
  fi
  cd "$dir"
  umask 077

  if [ -f .env ]; then
    say "keeping your .env"
  else
    # each password appears twice: on its own, and in the connection URL that uses it
    local su owner app data
    su=$(secret) owner=$(secret) app=$(secret) data=$(secret)
    sed -e "s|^POSTGRES_SUPERUSER_PASSWORD=.*|POSTGRES_SUPERUSER_PASSWORD=$su|" \
        -e "s|^DOC_OWNER_PASSWORD=.*|DOC_OWNER_PASSWORD=$owner|" \
        -e "s|^DOC_APP_PASSWORD=.*|DOC_APP_PASSWORD=$app|" \
        -e "s|^DOC_DATA_PASSWORD=.*|DOC_DATA_PASSWORD=$data|" \
        -e "s|//doc_owner:[^@]*@|//doc_owner:$owner@|" \
        -e "s|//doc_app:[^@]*@|//doc_app:$app@|" \
        -e "s|//doc_data:[^@]*@|//doc_data:$data@|" \
        .env.example > .env.new
    # a setting still on its default, not a comment that mentions one
    if grep -v '^[[:space:]]*#' .env.new | grep -q 'dev-only-change-me'; then
      rm -f .env.new
      fail ".env.example has a password this installer doesn't know about: copy it to .env, change every password, and run this again"
    fi
    mv .env.new .env
    say "wrote .env with a fresh password for every database account"
  fi

  if [ -f config/doc.local.toml ]; then
    say "keeping config/doc.local.toml"
  else
    printf '# Written by the Rundoc installer. It is laid over config/doc.toml, and git ignores it.\n[bootstrap]\nadmins = ["%s"]\n' "$admin" > config/doc.local.toml
    say "made $admin the first admin, in config/doc.local.toml"
  fi

  if ! command -v just >/dev/null 2>&1; then
    if [ "$start" = "0" ]; then
      say "just isn't installed: get it from https://just.systems before you run 'just up'"
    else
      need curl
      say "installing just into ~/.local/bin"
      mkdir -p "$HOME/.local/bin"
      curl --proto '=https' --tlsv1.2 -fsSL https://just.systems/install.sh | bash -s -- --to "$HOME/.local/bin"
      export PATH="$HOME/.local/bin:$PATH"
    fi
  fi

  if [ "$start" = "0" ]; then
    say "set up in $dir; start it with: cd $dir && just up"
    return
  fi

  say "starting Rundoc. The first run compiles everything in Docker, which takes a while."
  just up </dev/null

  cat <<EOF

Rundoc is running, on the ports in $dir/.env:
  http://127.0.0.1:8081           Rundoc
  http://127.0.0.1:8080/api/v1    the API, for the doc CLI and MCP clients
  http://127.0.0.1:3900           Grafana

Sign in first as $admin, with the one-time password this prints:
  cd $dir && docker compose --env-file .env -f crates/core/docker-compose.yaml run --rm --entrypoint cat backend /secrets/first-sign-in

Back up the secrets volume: it holds the key every stored plugin secret is
encrypted under. Stop Rundoc with: cd $dir && just down
EOF
}

main "$@"
