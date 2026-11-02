# BLE LCD 리모컨 (안드로이드 앱)

장치(JDY-33-BLE 등)에 BLE로 연결해서 LCD 화면을 받아 보여주고, 4×4 키패드로 키 코드를 보내는 앱입니다.

- 화면: `app/src/main/assets/index.html` (휴대폰용 HTML 그대로)
- 블루투스: `BleManager.kt` (안드로이드 기본 BLE — 앱 WebView는 웹 블루투스를 지원하지 않아서 네이티브로 처리)
- 지원: Android 8.0 이상 · 대상 API 36 (Google Play 2026-08-31 요구사항)

## APK 만드는 방법

### 방법 1 — GitHub에서 자동으로 만들기 (PC에 아무것도 설치 안 해도 됨)
1. GitHub에서 새 저장소를 만들고 이 폴더의 파일을 모두 올립니다. (`.github` 폴더 포함)
2. 저장소의 **Actions** 탭에서 `Build APK` 작업이 끝날 때까지 기다립니다 (약 3~5분).
3. 완료된 작업을 열고 아래 **Artifacts**의 `BLE-LCD-Remote-apk`를 내려받아 압축을 풀면 `BLE-LCD-Remote.apk`가 나옵니다.

### 방법 2 — Android Studio
1. Android Studio에서 **Open**으로 이 폴더를 엽니다. (처음 열 때 필요한 파일을 자동으로 내려받습니다)
2. 메뉴 **Build → Build App Bundle(s) / APK(s) → Build APK(s)**
3. 결과: `app/build/outputs/apk/debug/app-debug.apk`


## 결과 파일 두 가지
| 파일 | 용도 |
|---|---|
| `BLE-LCD-Remote.apk` | 휴대폰에 **바로 설치**해서 쓰는 파일 (테스트용) |
| `BLE-LCD-Remote.aab` | **Google Play Console에 올리는** 파일. 휴대폰에 직접 설치는 안 됨 |

Actions 작업 화면 아래 **Artifacts**에서 각각 내려받습니다.
AAB는 아래 서명 키를 등록해야 만들어집니다.

## AAB 서명 키 등록 (처음 한 번)
1. `play-upload-key.zip`의 `GitHub-Secrets-등록값.txt`를 엽니다.
2. GitHub 저장소 → **Settings → Secrets and variables → Actions → New repository secret**
3. 파일에 적힌 4개(`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`)를 하나씩 등록합니다.
4. Actions 탭에서 마지막 작업을 열고 **Re-run all jobs** → `BLE-LCD-Remote-aab`가 생깁니다.

⚠️ `upload-keystore.jks`와 비밀번호는 앱을 업데이트할 때마다 필요합니다. 잃어버리지 말고, 저장소에는 올리지 마세요.
(Play Console에서 "Play 앱 서명"을 쓰면 키를 잃어버려도 구글에 업로드 키 재설정을 요청할 수 있습니다.)

## versionCode
빌드할 때마다 Actions 실행 번호로 자동으로 올라갑니다. Play에는 이전보다 큰 versionCode만 올릴 수 있어서, 항상 새로 빌드한 AAB를 올리면 됩니다.

## 휴대폰에 설치
1. APK 파일을 휴대폰으로 옮깁니다 (카카오톡 나에게 보내기, USB, 구글 드라이브 등).
2. 파일을 눌러 설치합니다. "출처를 알 수 없는 앱" 허용을 물으면 허용합니다.
3. 처음 **연결**을 누르면 "근처 기기" 권한을 묻습니다 → 허용.
   (Android 11 이하는 위치 권한을 묻고, 위치(GPS)가 켜져 있어야 장치가 검색됩니다.)

## 수정할 때
- 화면/동작을 바꾸려면 `app/src/main/assets/index.html`만 고치고 다시 빌드하면 됩니다.
- 브라우저용 `ble-lcd-mobile.html`과 같은 파일이라, PC 크롬에서 열어 먼저 확인할 수 있습니다.
- 앱 이름: `app/src/main/res/values/strings.xml`
- 아이콘: `app/src/main/res/drawable/ic_launcher_foreground.xml`

## 프로토콜 (앱에 고정된 값)
- 패킷: `13 02 cnt cmd[data]… crc 03`, cnt = cmd~data 바이트 수
- CRC: CRC-8 (다항식 0x07, 초기값 0), cnt 바이트부터 cnt개
- 색상: 0=빨강, 1=흰색 · 문자열: 0x00으로 끝남, EUC-KR
- 화면 요청 `0x30`, 키 코드 `0x31 key` (키 코드는 앱 설정에서 변경 가능)

---

# 아이폰(iOS) 앱

`ios/` 폴더가 아이폰용 앱입니다. 화면은 안드로이드와 같은 `app/src/main/assets/index.html`을 그대로 쓰고, 블루투스만 아이폰 기능(CoreBluetooth)으로 처리합니다.

- 지원: iOS 15 이상 · 아이폰 세로 화면
- 코드: `ios/BleLcdRemote/*.swift`, 프로젝트 설정: `ios/project.yml` (XcodeGen)

## IPA 만들기 (GitHub Actions, Mac 필요 없음)
`.github/workflows/build-ios.yml`이 GitHub의 Mac 빌드 서버에서 IPA를 만듭니다.
Actions → **Build iOS IPA** → 작업 아래 **Artifacts**의 `BLE-LCD-Remote-ipa` → `BLE-LCD-Remote-unsigned.ipa`

※ 공개(Public) 저장소는 무료. 비공개 저장소는 Mac 빌드가 무료 사용량을 10배로 차감합니다.

## 아이폰에 설치 (서명 필요)
이 IPA는 **서명 전** 파일이라 그대로는 설치되지 않습니다.

### 무료: Sideloadly (Windows) + Apple ID
1. PC에 Sideloadly와 iTunes(웹 설치 버전, Microsoft Store 버전 아님)를 설치합니다.
2. 아이폰을 USB로 연결 → Sideloadly에 IPA를 끌어놓고 Apple ID 입력 → Start
3. 아이폰: **설정 → 개인정보 보호 및 보안 → 개발자 모드** 켜기 (iOS 16 이상, 재시동)
4. 아이폰: **설정 → 일반 → VPN 및 기기 관리**에서 내 Apple ID를 신뢰
- 무료 Apple ID는 **7일마다** 다시 설치해야 하고, 최대 3개 앱까지 됩니다.

### 유료: Apple Developer Program (연 $99)
기간 제한 없이 설치하거나 TestFlight·App Store로 배포할 수 있습니다. 가입 후 인증서와 프로비저닝 프로필을 GitHub Secrets에 등록하면 서명된 IPA를 자동으로 만들도록 워크플로를 확장할 수 있습니다.
