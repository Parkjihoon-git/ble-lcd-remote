# BLE LCD 리모컨 (안드로이드 앱)

장치(JDY-33-BLE 등)에 BLE로 연결해서 LCD 화면을 받아 보여주고, 4×4 키패드로 키 코드를 보내는 앱입니다.

- 화면: `app/src/main/assets/index.html` (휴대폰용 HTML 그대로)
- 블루투스: `BleManager.kt` (안드로이드 기본 BLE — 앱 WebView는 웹 블루투스를 지원하지 않아서 네이티브로 처리)
- 지원: Android 8.0 이상

## APK 만드는 방법

### 방법 1 — GitHub에서 자동으로 만들기 (PC에 아무것도 설치 안 해도 됨)
1. GitHub에서 새 저장소를 만들고 이 폴더의 파일을 모두 올립니다. (`.github` 폴더 포함)
2. 저장소의 **Actions** 탭에서 `Build APK` 작업이 끝날 때까지 기다립니다 (약 3~5분).
3. 완료된 작업을 열고 아래 **Artifacts**의 `BLE-LCD-Remote-apk`를 내려받아 압축을 풀면 `BLE-LCD-Remote.apk`가 나옵니다.

### 방법 2 — Android Studio
1. Android Studio에서 **Open**으로 이 폴더를 엽니다. (처음 열 때 필요한 파일을 자동으로 내려받습니다)
2. 메뉴 **Build → Build App Bundle(s) / APK(s) → Build APK(s)**
3. 결과: `app/build/outputs/apk/debug/app-debug.apk`

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
