# Codex Account Switcher Spike

개인·회사 ChatGPT 로그인의 Codex 인증 전환 가능성을 검증하기 위한 macOS Swift CLI Core와 메뉴바 앱이다.

> 비공식 개인 Spike다. OpenAI의 공식 제품이나 지원 도구가 아니다.

현재 CLI Spike와 실환경 기능 검증은 완료됐고 ADR-027에 따라 `MenuBarExtra` MVP 개발이 승인됐다. B-010 정식 증거는 MVP 완료·배포 전 인수 게이트로 남아 있다.

## 현재 범위

구현됨:

- opaque `auth.json` 검증과 redacted secret 타입
- 최대 3개 프로필 registry와 exact 7-field recovery journal
- `0600` 파일, `0700` store, `flock`, `fsync` + same-directory atomic rename
- 공식 Codex App Server JSONL handshake와 `account/read`
- 공식 앱 signature/Team ID 검사, 정상 종료·실행 adapter
- libproc 기반 process 분류
- switch/rollback/recovery 상태 머신
- 진단 CLI: `inspect`, `profiles list`, `recovery status`
- 첫 활성 계정 A capture: TTY 확인, process gate, refresh 전 private backup, 이메일 검증, rollback
- 추가 계정 B/C capture, 중복·네 번째 계정 차단, 실패 rollback, 등록 전 활성 프로필 자동 복귀
- 수동 재로그인 뒤 현재 활성 인증을 같은 이메일의 저장 프로필에 동기화
- 저장 프로필 `switch --target`, 정상 종료, 격리 검증·refresh, 원자 교체, 재실행·검증, 실패 rollback
- debug build의 post-launch 검증 실패 주입과 source 자동 롤백 실검증
- `rollbackFailed` journal의 이전 프로필을 명시적으로 복구하는 `recovery restore`
- 수동 복구의 완전 성공·앱 실행 미확인·journal 완료 불확실 typed outcome과 phase/expected-active finalization evidence gate
- fake 3계정 카드와 확인 흐름을 가진 `MenuBarExtra` UI 프로토타입
- CLI private file store와 제품 Keychain을 분리한 credential backend 경계, generic-password CRUD와 plaintext fallback 금지
- `MenuBarExtra`의 실제 `LocalCLIDataProvider`·Keychain 주입과 Spike에서 분리된 제품 metadata store
- 메뉴바의 명시적 현재 로그인 등록, 추가 등록 후 기존 active 유지, recovery 상태의 mutation 차단
- 메뉴바의 명시적 현재 활성 인증 저장, 실행 전 수동 종료 확인, 성공·복구 차단 상태 표시
- 메뉴바 recovery pending phase와 journal의 정확한 이전 프로필 표시, blocked 상태의 fail-closed 안내
- 메뉴바 `rollbackFailed` transaction+이전 프로필에 묶인 수동 복구, 명시 확인, launch 미확인 재시도 금지, journal 불확실 STOP
- 메뉴바 전환의 durable journal phase 기반 실시간 진행 문구와 완료·실패 후 상태 정리
- 메뉴바 `needsRelogin` 비활성 카드의 exact-ID 확인, 검증된 저장본 갱신, 대상 즉시 활성화, 불확실 상태 재시도 차단
- 메뉴바 상태 조회 전 미완료 journal 자동 복구, 불확실 상태 STOP, 복구 중 앱 자동 실행 금지
- 메뉴바의 native 비동기 잔존 앱 프로세스 2차 확인, 취소 기본, 종료 전 exact snapshot 대상에만 `SIGTERM` 1회
- Command Line Tools만으로 만드는 ad-hoc 서명 `.app`, 고정 경로 설치·LaunchAgent 자동 실행·보존형 제거
- 번들·설치 실행파일의 random synthetic Keychain create/read/update/read/delete/notFound smoke; 제품 service·실제 auth 접근 0회

아직 구현·노출하지 않음:

- 실계정 제품 flow의 Keychain 검증, ad-hoc 재빌드 ACL과 잠금·접근 거부 정책 검증
- 5시간·주간 사용량 표시

capture 명령은 앱을 자동 종료하지 않는다. 첫 capture는 현재 인증을 갱신·저장한다. 추가 capture는 새 계정을 저장한 뒤 `~/.codex/auth.json`을 등록 전 활성 프로필로 원자 복구하고 ChatGPT 앱을 해당 계정으로 다시 실행한다. 모든 auth 변경은 외부 Terminal의 대화형 확인과 process gate 뒤에만 수행한다.

## 빌드와 테스트

현재 개발 Mac에서는 Swift 6.2.3과 기본 macOS 26.2 SDK 조합에 module mismatch가 있어, 설치돼 있다면 검증된 macOS 15.4 SDK를 우선 사용한다. 다른 Mac에서는 활성 Xcode SDK를 자동 탐색한다. 필요하면 `SWITCHER_SDKROOT`로 SDK 경로를 지정할 수 있다.

```sh
./Scripts/dev.sh build
./Scripts/dev.sh test
./Scripts/build-app.sh
./Scripts/install-app.sh
```

`install-app.sh`는 `~/Applications/CodexAccountSwitcher.app`과 `~/Library/LaunchAgents/local.codex.account-switcher.plist`만 소유권 확인 후 교체한다. 제거는 `./Scripts/uninstall-app.sh`이며 Application Support, Keychain, 로그는 보존한다. 현재 ad-hoc 서명은 코드 변경 뒤 기존 Keychain item 접근 확인 또는 거부가 발생할 수 있으므로 update-safe identity로 간주하지 않는다.

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

## CLI

```sh
./Scripts/dev.sh run inspect
./Scripts/dev.sh run profiles list
./Scripts/dev.sh run recovery status
```

### 첫 계정 A 저장

앱과 독립 Codex CLI를 정상 종료한 뒤 외부 Terminal에서 실행한다.

```sh
./Scripts/dev.sh run profile capture --label A
```

### 추가 계정 B/C 저장 후 기존 활성 계정 자동 복귀

1. `profiles list`에서 복귀할 기존 프로필이 `active=true`, `recovery status`가 `recovery=none`인지 확인한다.
2. 공식 ChatGPT UI에서 아직 등록하지 않은 계정 B 또는 C로 로그인한다.
3. ChatGPT 앱과 독립 Codex CLI를 정상 종료한다.
4. `inspect`의 세 process count가 모두 `0`인지 확인한다.
5. 외부 Terminal에서 새 계정을 capture한다.

```sh
./Scripts/dev.sh run inspect
./Scripts/dev.sh run profile capture --label B
# 세 번째 계정이면 --label C
./Scripts/dev.sh run profiles list
./Scripts/dev.sh run recovery status
```

성공 결과는 등록 전 프로필 `active=true`, 새 프로필 `active=false`, `recovery=none`이다. ChatGPT 앱은 등록 전 활성 계정으로 다시 열린다.

프롬프트에 `CAPTURE`를 입력해야 진행한다. 현재 검증된 ChatGPT 앱은 `26.721.41059`/`5848`, `26.721.81911`/`5973`이다. `application=incompatible`, `process_blocked`, 다른 build는 hard gate다. `account_already_registered`면 미등록 계정 로그인부터 다시 한다. `profile_already_exists`면 3개 상한에 도달한 상태다. `rollback_failed`, `recovery=pending`, `recovery=blocked`면 재실행하지 말고 상태를 보존한다.

### 수동 A 재로그인 후 저장본 동기화

앱과 독립 Codex CLI를 종료하고 `inspect`의 세 process count가 모두 `0`인지 확인한 뒤 실행한다.

```sh
./Scripts/dev.sh run profile sync-active
```

`SYNC`를 입력해야 진행한다. 현재 `auth.json`의 이메일이 registry 활성 프로필과 정확히 일치할 때만 해당 저장본을 교체한다. 현재 `auth.json`, 다른 프로필 저장본, registry는 변경하지 않는다. 저장 후 검사가 실패하면 기존 활성 저장본을 복구한다. verifier 종료를 확인하지 못하면 private store의 격리 workspace를 보존하고 `recovery=blocked`로 표시한다.

### 메뉴바에서 비활성 계정 재로그인 반영

`재로그인 필요`인 비활성 B를 공식 Codex 앱에서 다시 로그인한 뒤 앱과 독립 Codex CLI·IDE 프로세스를 모두 종료한다. 메뉴바의 B 카드를 눌러 확인하면 exact B identity와 갱신된 auth blob을 검증·저장하고 B를 즉시 활성 프로필로 커밋한다. 성공 뒤 앱은 자동 실행하지 않으므로 직접 연다.

확인 전이나 finalization이 불명확한 상태에서 자동 재시도하지 않는다. 메뉴바가 복구 필요 또는 상태 불명확을 표시하면 앱을 열거나 다른 계정 작업을 하지 않는다. Core가 A로 안전 롤백하고 recovery가 없을 때만 사용자가 B 로그인 상태를 고친 뒤 다시 시도할 수 있다.

메뉴바는 시작과 mutation 실패 뒤 상태를 새로 읽을 때 자동 복구를 먼저 한 번 시도하고, 그 다음 profile과 recovery 상태를 읽는다. 자동 복구는 공식 앱을 실행하지 않는다. CLI `recovery status`는 일반 auth/registry 복구를 시작하지 않는 관찰 명령이며, 이미 증명된 journal finalization 정리만 재개할 수 있다.

### 저장된 계정으로 전환

독립 Codex CLI를 종료한 뒤 외부 Terminal에서 실행한다. 실행 중인 ChatGPT 앱은 정상 종료를 요청한다. 1초 뒤에도 종료 전 확인된 앱 소유 프로세스가 남으면 추가 확인을 표시하고, 사용자가 `TERMINATE`를 입력한 경우에만 `SIGTERM`을 한 번 보낸다.

```sh
./Scripts/dev.sh run switch --target B
```

`SWITCH`를 입력해야 진행한다. 1초 뒤 앱 소유 프로세스가 남으면 `TERMINATE`를 추가로 입력해야 한다. 현재 계정 저장본 갱신 → 대상 저장본 격리 검증·갱신 → `auth.json` 원자 교체 → 앱 재실행 → 대상 이메일 검증 순서로 처리한다. `recovery_required` 또는 `rollback_failed`면 재실행하지 말고 `recovery status`를 확인한다.

### Post-launch 자동 롤백 실검증

debug build에서만 B-011 검증 실패를 1회 주입할 수 있다. 일반 전환처럼 실제 target 인증을 설치하고 앱을 실행하지만, target PID 확인 직후 검증 실패를 발생시켜 기존 source rollback 경로를 실행한다. 실제 `auth.json`을 수동 훼손하지 않는다.

현재 A가 활성이라면 외부 Terminal에서 실행한다.

```sh
./Scripts/dev.sh run switch --target B --test-post-launch-rollback
```

`ROLLBACK_TEST`를 입력해야 진행한다. 잔존 앱 프로세스가 있으면 forward와 rollback 종료에서 각각 `TERMINATE` 확인이 나올 수 있다. 성공 출력은 `rollback_test=passed`와 A `active=true`다. 이어서 다음을 확인한다.

```sh
./Scripts/dev.sh run inspect
./Scripts/dev.sh run profiles list
./Scripts/dev.sh run recovery status
```

A 활성, B 비활성, `recovery=none`이어야 한다. `rollback_failed`, `recovery=pending`, `recovery=blocked`면 다시 실행하지 말고 상태를 보존한다. release build에는 실패 주입 명령이 포함되지 않는다.

### rollbackFailed 수동 복구

`recovery status`가 `phase=rollbackFailed`일 때만 journal의 이전 프로필을 명시적으로 복구한다. 새 전환이나 수동 파일 복사를 먼저 하지 않는다.

```sh
./Scripts/dev.sh run recovery restore --profile A
```

`RESTORE`를 입력하고, 잔존 앱 소유 프로세스 확인이 나오면 `TERMINATE`를 입력한다. process gate → stale verifier를 private `recovery-evidence`로 격리 → 저장된 A 검증 → 공용 auth 원자 복구 → A 이메일 검증 → registry A commit → capture 임시 artifact 정리 → journal 삭제 → 앱 실행 순서다. 등록된 B 프로필·저장본과 stale verifier 증거는 보존한다.

- `recovery=restored`: 복구와 앱 PID 확인 완료. A `active=true`, `recovery status`는 `recovery=none`이어야 한다.
- `error=application_launch_unconfirmed`: auth·registry 복구와 journal 내구 삭제는 완료됐다. restore를 재실행하지 말고 `recovery status`가 `none`인지 확인한 뒤 앱 실행만 별도로 처리한다.
- `error=recovery_uncertain`: journal unlink/parent `fsync` 완료를 단정할 수 없어 앱을 실행하지 않는다. 공통 mutation gate가 finalization evidence의 journal phase/expected active 조합·registry·검증 당시 active auth digest·잔존 artifact를 재검증한다. journal이 남았으면 내구 삭제하고, 없으면 store directory를 `fsync`한 뒤 상태를 다시 확인해 evidence를 제거한다. 이 절차가 끝나 `recovery status=none`일 때만 계속한다.

## 안전 규칙

- 실제 credential, token, cookie를 repo·로그·테스트 fixture에 넣지 않는다.
- `auth.json` 원문, raw App Server stderr, 전체 process argv/environment를 출력하지 않는다.
- 공식 앱과 관련 writer가 완전히 종료되기 전 auth를 쓰지 않는다.
- 독립 Codex CLI를 자동 종료하지 않는다.
- 종료 대기 중 확인한 exact 앱 소유 프로세스만 1초 유예와 별도 사용자 확인 뒤 `SIGTERM`한다.
- `SIGKILL`, `kill -9`, 독립·분류 불명 프로세스 자동 종료는 사용하지 않는다.
- 실제 앱 종료·계정 전환은 Codex 앱 내부 task가 아니라 외부 Terminal에서 수행한다.

전체 제품 결정과 Runbook은 [`docs/00_README.md`](docs/00_README.md)를 따른다.
