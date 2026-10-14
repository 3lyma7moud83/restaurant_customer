#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log() {
  printf '[build] %s\n' "$1"
}

ensure_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    log "Using flutter from PATH: $(command -v flutter)"
    return
  fi

  local sdk_dir="${FLUTTER_SDK_DIR:-$ROOT_DIR/.flutter-sdk}"
  local channel="${FLUTTER_CHANNEL:-stable}"

  if [ ! -x "$sdk_dir/bin/flutter" ]; then
    log "Flutter SDK not found. Cloning \"$channel\" channel..."
    rm -rf "$sdk_dir"
    git clone --depth 1 -b "$channel" https://github.com/flutter/flutter.git "$sdk_dir"
  fi

  export PATH="$sdk_dir/bin:$PATH"
  log "Using flutter from $sdk_dir/bin/flutter"
}

load_local_env() {
  if [ "${VERCEL:-}" = "1" ]; then
    return
  fi

  if [ -f ".env" ]; then
    # shellcheck disable=SC1091
    set -a
    . ".env"
    set +a
    log "Loaded local .env variables."
  fi
}

write_runtime_env_asset() {
  local env_file="assets/env/app.env"
  local is_ci="${CI:-}"
  local is_vercel="${VERCEL:-}"

  mkdir -p "assets/env"

  local required_vars=(
    "SUPABASE_URL"
    "SUPABASE_ANON_KEY"
    "MAPBOX_TOKEN"
    "FIREBASE_API_KEY"
    "FIREBASE_PROJECT_ID"
    "FIREBASE_MESSAGING_SENDER_ID"
    "FIREBASE_ANDROID_APP_ID"
    "FIREBASE_WEB_APP_ID"
    "FIREBASE_AUTH_DOMAIN"
    "FIREBASE_WEB_VAPID_KEY"
  )
  local missing=()
  local key
  for key in "${required_vars[@]}"; do
    if [ -z "${!key:-}" ]; then
      missing+=("$key")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    if [ "$is_vercel" = "1" ] || [ "$is_ci" = "true" ]; then
      log "Missing required environment variables: ${missing[*]}"
      log "Set them in Vercel Project Settings -> Environment Variables."
      exit 1
    fi

    if [ -f "$env_file" ]; then
      log "Keeping existing $env_file (missing vars: ${missing[*]})."
      return
    fi

    if [ -f ".env.example" ]; then
      cp ".env.example" "$env_file"
      log "Created placeholder $env_file from .env.example for local builds."
      return
    fi

    log "Cannot create $env_file because required vars are missing: ${missing[*]}"
    exit 1
  fi

  local app_env="${APP_ENV:-}"
  if [ -z "$app_env" ]; then
    if [ "$is_vercel" = "1" ] || [ "$is_ci" = "true" ]; then
      app_env="prod"
    else
      app_env="dev"
    fi
  fi

  cat > "$env_file" <<EOF
APP_ENV=$app_env
MAPBOX_TOKEN=${MAPBOX_TOKEN}
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
GOOGLE_SERVER_CLIENT_ID=${GOOGLE_SERVER_CLIENT_ID:-}
GOOGLE_IOS_CLIENT_ID=${GOOGLE_IOS_CLIENT_ID:-}
GOOGLE_WEB_CLIENT_ID=${GOOGLE_WEB_CLIENT_ID:-}
FIREBASE_API_KEY=${FIREBASE_API_KEY:-}
FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID:-}
FIREBASE_MESSAGING_SENDER_ID=${FIREBASE_MESSAGING_SENDER_ID:-}
FIREBASE_STORAGE_BUCKET=${FIREBASE_STORAGE_BUCKET:-}
FIREBASE_ANDROID_APP_ID=${FIREBASE_ANDROID_APP_ID:-}
FIREBASE_IOS_APP_ID=${FIREBASE_IOS_APP_ID:-}
FIREBASE_IOS_BUNDLE_ID=${FIREBASE_IOS_BUNDLE_ID:-}
FIREBASE_WEB_APP_ID=${FIREBASE_WEB_APP_ID:-}
FIREBASE_AUTH_DOMAIN=${FIREBASE_AUTH_DOMAIN:-}
FIREBASE_MEASUREMENT_ID=${FIREBASE_MEASUREMENT_ID:-}
FIREBASE_WEB_VAPID_KEY=${FIREBASE_WEB_VAPID_KEY:-}
EOF

  log "Generated $env_file from environment variables."
}

write_firebase_messaging_worker_config() {
  # Keep this validation with the writer as a defence in depth measure.  The
  # runtime-env writer above validates the wider application configuration,
  # but this asset must never be emitted with an empty Firebase config if this
  # function is reused or its call order changes.
  local worker_required_vars=(
    "FIREBASE_API_KEY"
    "FIREBASE_PROJECT_ID"
    "FIREBASE_MESSAGING_SENDER_ID"
    "FIREBASE_WEB_APP_ID"
    "FIREBASE_AUTH_DOMAIN"
  )
  local worker_missing=()
  local key
  for key in "${worker_required_vars[@]}"; do
    if [ -z "${!key:-}" ]; then
      worker_missing+=("$key")
    fi
  done

  if [ ${#worker_missing[@]} -gt 0 ]; then
    log "Cannot generate web/firebase-messaging-config.js; missing required Firebase variables: ${worker_missing[*]}"
    exit 1
  fi

  cat > "web/firebase-messaging-config.js" <<EOF
// Generated at build time. Firebase web configuration is public client config.
self.__firebaseMessagingConfig = {
  apiKey: "${FIREBASE_API_KEY:-}", authDomain: "${FIREBASE_AUTH_DOMAIN:-}",
  projectId: "${FIREBASE_PROJECT_ID:-}", storageBucket: "${FIREBASE_STORAGE_BUCKET:-}",
  messagingSenderId: "${FIREBASE_MESSAGING_SENDER_ID:-}", appId: "${FIREBASE_WEB_APP_ID:-}",
  measurementId: "${FIREBASE_MEASUREMENT_ID:-}"
};
EOF
}

build_web() {
  flutter config --enable-web
  flutter pub get
  flutter build web --release --pwa-strategy=none
}

ensure_flutter
load_local_env
write_runtime_env_asset
write_firebase_messaging_worker_config
build_web
