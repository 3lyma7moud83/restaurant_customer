# Restaurant Customer (Flutter Web + Supabase)

Production-ready Flutter Web app for restaurant discovery, cart flow, and order tracking.

## Local development

1. Copy `.env.example` to `.env` and fill in real values.
2. Generate runtime env asset:
   - `bash scripts/build.sh` (also runs full web build), or
   - manually create `assets/env/app.env` using the same keys in `.env.example`.
3. Run:
   - `flutter pub get`
   - `flutter run -d chrome`

## Vercel deployment

`vercel.json` is configured to:
- run `bash scripts/build.sh`
- output from `build/web`
- rewrite SPA routes to `index.html`

Set these Vercel Environment Variables (Production + Preview):
- `APP_ENV` (`prod` recommended on Vercel)
- `SUPABASE_URL` (required)
- `SUPABASE_ANON_KEY` (required)
- `MAPBOX_TOKEN` (required)
- `GOOGLE_SERVER_CLIENT_ID` (optional)
- `GOOGLE_IOS_CLIENT_ID` (optional)
- `GOOGLE_WEB_CLIENT_ID` (optional)
- `FIREBASE_API_KEY` (optional, required only if Firebase features enabled)
- `FIREBASE_PROJECT_ID` (optional)
- `FIREBASE_MESSAGING_SENDER_ID` (optional)
- `FIREBASE_STORAGE_BUCKET` (optional)
- `FIREBASE_ANDROID_APP_ID` (optional)
- `FIREBASE_IOS_APP_ID` (optional)
- `FIREBASE_IOS_BUNDLE_ID` (optional)
- `FIREBASE_WEB_APP_ID` (optional)
- `FIREBASE_AUTH_DOMAIN` (optional)
- `FIREBASE_MEASUREMENT_ID` (optional)
- `FIREBASE_WEB_VAPID_KEY` (optional)

`scripts/build.sh` fails fast on Vercel if required variables are missing, so broken builds are caught before deploy.

## Security notes

- `assets/env/app.env` is generated at build/runtime and is ignored in git.
- Do not commit server-side secrets. This app should only use public client keys (e.g., Supabase anon key, Mapbox public token).
