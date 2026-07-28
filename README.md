# Codex Account Switcher Spike

개인·회사 ChatGPT 로그인의 Codex 인증 전환 가능성을 검증하기 위한 macOS Swift CLI Core다.

> 비공식 개인 Spike다. OpenAI의 공식 제품이나 지원 도구가 아니다.

## 현재 범위

구현됨:

- opaque `auth.json` 검증과 redacted secret 타입
- 최대 2개 프로필 registry와 exact 7-field recovery journal
- `0600` 파일, `0700` store, `flock`, `fsync` + same-directory atomic rename
- 공식 Codex App Server JSONL handshake와 `account/read`
- 공식 앱 signature/Team ID 검사, 정상 종료·실행 adapter
- libproc 기반 process 분류
- switch/rollback/recovery 상태 머신
- 읽기 전용 CLI: `inspect`, `profiles list`, `recovery status`

아직 구현·노출하지 않음:

- 프로필 A/B 실제 capture 명령
- concrete auth-changing transaction/recovery adapter
- `switch`, manual recovery 명령
- 메뉴바 UI

따라서 현재 실행 파일은 공식 앱을 종료하거나 `~/.codex/auth.json`을 변경하지 않는다. 실제 전환 Step 7은 concrete adapter와 외부 Terminal confirmation gate를 별도 구현·검증한 뒤 진행한다.

## 빌드와 테스트

현재 개발 Mac에서는 Swift 6.2.3과 기본 macOS 26.2 SDK 조합에 module mismatch가 있어, 설치돼 있다면 검증된 macOS 15.4 SDK를 우선 사용한다. 다른 Mac에서는 활성 Xcode SDK를 자동 탐색한다. 필요하면 `SWITCHER_SDKROOT`로 SDK 경로를 지정할 수 있다.

```sh
./Scripts/dev.sh build
./Scripts/dev.sh test
```

다른 Mac에서 SDK를 직접 지정하는 예:

```sh
SWITCHER_SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" ./Scripts/dev.sh test
```

표준 `swift test` 대신 custom async executable harness를 사용한다. 현재 Command Line Tools에서 `XCTest`/`Testing` module을 사용할 수 없기 때문이다. 정상 Xcode toolchain이 설치되면 `.testTarget` 복귀를 재검토한다.

## 다른 Mac에서 이어서 작업

GitHub CLI와 Xcode 또는 Command Line Tools를 설치한 뒤:

```sh
gh auth login -h github.com
gh repo clone aqwsde321/codex-account-switcher-spike
cd codex-account-switcher-spike
./Scripts/dev.sh test
```

실제 `auth.json`과 로컬 프로필 저장소는 Git으로 이동하지 않는다. 새 Mac에서는 실제 Spike 단계에서 계정을 다시 안전하게 등록해야 한다.

## 읽기 전용 CLI

```sh
./Scripts/dev.sh run inspect
./Scripts/dev.sh run profiles list
./Scripts/dev.sh run recovery status
```

`inspect` 출력의 `application=incompatible`은 hard gate다. 현재 `/Applications/Codex.app`은 OS signature 검증에서 `invalid signature (code or signature have been modified)`로 판정됐다. 공식 앱 재설치 또는 업데이트 후 signature가 유효해질 때까지 auth-changing 기능을 연결하거나 실행하면 안 된다.

## 안전 규칙

- 실제 credential, token, cookie를 repo·로그·테스트 fixture에 넣지 않는다.
- `auth.json` 원문, raw App Server stderr, 전체 process argv/environment를 출력하지 않는다.
- 공식 앱과 관련 writer가 완전히 종료되기 전 auth를 쓰지 않는다.
- 독립 Codex CLI를 자동 종료하지 않는다.
- force quit, `SIGKILL`, `kill -9`를 사용하지 않는다.
- 실제 앱 종료·계정 전환은 Codex 앱 내부 task가 아니라 외부 Terminal에서 수행한다.

전체 제품 결정과 Runbook은 [`docs/00_README.md`](docs/00_README.md)를 따른다.
