# Google Sign-In Setup (Android)

This app currently fails with `ApiException: 10` when Android OAuth is not fully configured.

## 1) Firebase Console configuration
1. Open Firebase Console -> Project Settings -> Android app `com.example.restaurant_customer`.
2. Add certificate fingerprints for the keystore(s) used to run the app.
3. Required fingerprints:
   - Debug SHA-1: `B8:DF:94:0A:B5:3B:80:6C:26:2A:26:21:EC:51:58:7D:00:EF:33:39`
   - Debug SHA-256: `39:79:72:BE:53:68:58:B2:0A:E7:7A:E8:67:D9:AF:62:73:D6:7F:A7:DF:DE:25:81:8F:C6:67:6E:9F:87:28:0A`
4. If you use a release keystore, also add release SHA-1/SHA-256.

## 2) Google OAuth client
1. In Google Cloud Console -> APIs & Services -> Credentials, ensure an Android OAuth client exists for package `com.example.restaurant_customer` and matching SHA-1.
2. Ensure a Web client exists and use its client ID as `GOOGLE_SERVER_CLIENT_ID` in `.env`.

## 3) Refresh local config
1. Download a fresh `google-services.json` from Firebase.
2. Replace `android/app/google-services.json`.
3. Verify `oauth_client` is not empty in that file.

## 4) Clean + run
```bash
flutter clean
flutter pub get
flutter run
```

## Useful commands
Debug keystore fingerprints:
```bash
keytool -list -v -alias androiddebugkey -keystore %USERPROFILE%\.android\debug.keystore -storepass android -keypass android
```
