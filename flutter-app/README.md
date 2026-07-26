# flutter-app

FCM 푸시 알림을 수신하고 BLE 로 ESP32 와 페어링하는 Flutter 앱. Android + iOS.

> **이 스냅샷에는 `lib/` 와 `pubspec.yaml` 만 있습니다.** `android/` · `ios/` 스캐폴딩은
> `flutter create` 가 생성하는 보일러플레이트라 제외했습니다. 실행해보려면 아래 "초기화" 대로
> 프로젝트를 만든 뒤 `lib/main.dart` 와 `pubspec.yaml` 을 덮어쓰면 됩니다.

## 빌드 — 서버 주소는 `--dart-define` 으로 주입

서버 주소는 소스에 박지 않는다. `lib/main.dart` 의 `serverBaseUrl` 은
`String.fromEnvironment('PUSH_BASE_URL')` 이며, 정의하지 않고 실행하면 시동 시
`StateError` 로 즉시 실패한다 (조용히 통신만 실패하는 상황을 막기 위함).

```bash
flutter run   --dart-define=PUSH_BASE_URL=https://<push-host>
flutter build apk --release --dart-define=PUSH_BASE_URL=https://<push-host>
```

끝에 슬래시를 붙이지 말 것 — 코드가 `'$serverBaseUrl/devices'` 처럼 이어 붙인다.

VS Code 에서는 `.vscode/launch.json` 의 `"toolArgs"` 에 넣어두면 매번 타이핑할 필요가 없다
(`.vscode/` 는 `.gitignore` 대상이라 커밋되지 않는다).

## 초기화

```bash
flutter create --org com.example.pushrelay --platforms=android,ios .
# 그 뒤 이 저장소의 lib/main.dart · pubspec.yaml 로 덮어쓰기
flutter pub get
```

BLE 페어링에 `flutter_blue_plus` 를 쓰므로 Android 는 `AndroidManifest.xml` 에
`BLUETOOTH_SCAN` · `BLUETOOTH_CONNECT` (API 31+), iOS 는 `Info.plist` 에
`NSBluetoothAlwaysUsageDescription` 이 필요하다.

## Firebase 연동

1. [Firebase 콘솔](https://console.firebase.google.com/)에서 프로젝트 생성
2. Android 앱 등록 → `google-services.json` 다운로드 → `android/app/`에 배치
3. iOS 앱 등록 → `GoogleService-Info.plist` 다운로드 → `ios/Runner/`에 배치
4. `flutterfire configure` 로 `firebase_options.dart` 생성
5. `main.dart`에서:
   ```dart
   await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
   final token = await FirebaseMessaging.instance.getToken();
   // token을 서버 POST /devices 로 전송m
   ```

## iOS 추가 설정

- Apple Developer 계정 필요 ($99/년)
- APNs Auth Key 발급 → Firebase 콘솔에 등록
- `ios/Runner/Info.plist`에 background modes 추가
