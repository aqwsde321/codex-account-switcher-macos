# 구현 인수인계

- 상태: CLI Spike 검증 완료, ADR-027에 따라 메뉴바 MVP 개발 승인
- 기준일: 2026-07-30
- 코드: 저장소 루트 `.`
- 중요: 외부 Terminal에서 A↔B 기능 왕복 3회, 수동 A 복구 2회, B-011 자동 롤백을 완료했다. B-010 형식 증거는 보존하지 않았으며 ADR-027에 따라 개발에는 수용하고 MVP 완료·배포 전 게이트로 유지한다.

## 1. 새 task에서 시작하는 방법

새 Codex task는 먼저 다음 순서로 읽는다.

1. `00_README.md`
2. `02_decision_record.md`
3. `03_feature_flow.md`
4. `05_technical_design.md`
5. `06_security_and_recovery.md`
6. `07_test_acceptance.md`
7. 구현하려는 단계에 따라 `01_product_requirements.md` 또는 `04_spike_runbook.md`

새 task 시작 prompt 권장문:

```text
`docs/00_README.md`부터 문서 세트를 읽고,
ADR-027과 기존 안전 결정을 유지한 채 Step 9 메뉴바 MVP를 구현해줘.
검증된 CodexAccountCore를 재사용하고 먼저 UI adapter 성공 기준을 대조해.
실제 auth.json 교체와 Codex 앱 종료는 외부 Terminal 실행 게이트 전까지 하지 마.
```

## 2. 현재 작업 상태

완료:

- 요구사항 grilling 및 의사결정 확정
- 공식 Codex 인증/App Server 문서 확인
- 설치된 앱 metadata·서명·bundled CLI 확인
- App Server JSONL handshake를 빈 임시 `CODEX_HOME`에서 실측
- 현재 앱 process tree를 읽기 전용으로 실측
- 상세 설계·Runbook·테스트 기준 문서화
- SwiftPM Core/CLI/custom async test harness 생성
- opaque credential, strict registry/journal, durable file store와 lock 구현
- App Server protocol/session, app signature gate, libproc process classifier 구현
- switch/rollback/recovery 상태 머신 구현
- 읽기 전용 CLI 세 명령 구현
- 첫 계정 A capture의 TTY 확인, process gate, refresh 전 backup, isolated identity 검증, rollback 구현
- 추가 계정 capture, 중복 계정 차단, 동일 capture lock/journal의 실패 rollback·등록 전 active 복귀, 최대 3개 허용·네 번째 무변경 거부 구현
- 저장 프로필 일반 switch의 정상 종료·격리 검증·원자 교체·재실행·검증·rollback adapter 구현
- `CodexAccountMenuBar` target, fake 3계정 카드와 active/inactive 선택 모델 구현
- credential backend 경계, CLI private file store 명시 연결, Keychain generic-password CRUD와 plaintext fallback 금지 구현
- fake credential만 사용하는 88개 debug 테스트 통과
- 실제 read-only inspect에서 사용자 auth와 helper store 무변경 확인
- `rollbackFailed` 수동 복구 CLI와 실환경 A 복구 2회 완료
- debug 전용 B-011 실패 주입에서 source 자동 롤백과 최종 A 복귀 확인

미완료:

- 메뉴바 앱의 실제 Core provider 연결
- 진행·복구·재로그인 상태 UI
- MVP 완료·배포 전 `07_test_acceptance.md` §16 형식의 동일 task 왕복 증거 보존

허용 build는 `/Applications/ChatGPT.app` `26.721.41059`/`5848`, `26.721.81911`/`5973`이다. 현재 설치된 `26.721.81911`/`5973`은 signature/build gate를 통과해 `application=ready`이며 auth-changing 명령 실검증을 완료했다.

재개 명령과 구현 범위는 루트 `README.md`를 먼저 읽는다.

## 3. source of truth 우선순위

충돌 시 다음 순서를 따른다.

1. 사용자의 이후 명시적 변경 요청
2. `02_decision_record.md`의 확정 결정
3. `03_feature_flow.md`와 `06_security_and_recovery.md`의 불변조건
4. `05_technical_design.md`
5. `01_product_requirements.md`
6. `04_spike_runbook.md`, `07_test_acceptance.md`
7. 최초 첨부 문서

최초 첨부의 다음 내용은 최종 합의에 의해 폐기됐다.

- Mobius 전체 포크
- userId/workspaceAccountId 필수 식별
- 사용량을 전환 성공 판정에 사용
- custom `CODEX_HOME` MVP 지원
- 사용자 선택 force quit/`SIGKILL` 옵션
- 동일 task 실패 시 복제 우회

## 4. 고정된 제품 결정

- 공용 기본 `~/.codex`; 인증만 계정별 분리
- 보안 격리 제품이 아니라 편의 전환기
- ChatGPT 이메일로 프로필 신원 검증
- MVP 등록은 최대 3개 계정
- 내부 프로필 모델은 배열
- 공식 앱은 정상 종료만 사용
- 독립 CLI는 자동 종료하지 않고 전환 차단
- 대상 실패 시 이전 계정 자동 롤백
- 롤백 검증 실패 시 공식 앱 미실행
- Spike credential은 private `0600` 파일
- 제품의 비활성·저장 프로필 credential은 macOS Keychain이며, 제품 평문 예외는 활성 `~/.codex/auth.json` 하나뿐
- UI보다 Swift CLI Spike 우선
- 새 소형 Swift 앱; Mobius는 참고만
- MVP UI는 활성 이메일·수동 전환만
- 사용량은 후속
- 올바른 인증 전환 뒤 account/task ownership 구조 때문에 동일 task를 B에서 재개하지 못하면 제품 중단; Helper 결함은 수정 후 전체 재검증
- A→B→A 실제 메시지 왕복 3회 연속 성공 필요

전환 journal의 exact schema는 `schemaVersion`, `transactionId`, `phase`, `previousProfileId`, `targetProfileId`, `startedAt`, `updatedAt` 일곱 필드다. build, 이메일, 인증 비밀은 넣지 않는다. canonical persisted phase는 다음과 같다.

```text
preparing → quitRequested → quiescent → refreshingCurrent → currentSaved
→ validatingTarget → targetValidated → authReplaced → targetLaunched
→ verifyingTarget → targetVerified
```

롤백 phase는 `rollbackStarted`, `rollbackFailed`만 사용한다.

이 항목을 구현 편의를 이유로 다시 열지 않는다. 실제 환경이 불가능함을 증명할 때만 사용자에게 재결정을 요청한다.

## 5. 로컬 환경 재확인

다음은 읽기 전용 검사다.

```text
swift --version
plutil -p /Applications/ChatGPT.app/Contents/Info.plist
codesign -dv --verbose=4 /Applications/ChatGPT.app
/Applications/ChatGPT.app/Contents/Resources/codex --version
/Applications/ChatGPT.app/Contents/Resources/codex app-server --help
stat -f 'mode=%Sp size=%z modified=%Sm' ~/.codex/auth.json
```

주의:

- `auth.json`에 `cat`, `sed`, 일반 `jq .`를 실행하지 않는다.
- 필요한 경우 JSON key path만 조사하고 값은 출력하지 않는다.
- process 조사에서 전체 argv/environment를 출력하지 않는다.

문서 작성 당시 관찰값:

```text
Bundle ID: com.openai.codex
Version/build: 26.721.41059 / 5848
Main executable: Contents/MacOS/ChatGPT
Bundled Codex: Contents/Resources/codex
Bundled CLI: codex-cli 0.146.0-alpha.3.1
Swift: 6.2.3
auth.json mode: 0600
```

앱은 언제든 업데이트될 수 있으므로 구현 시작 시 다시 확인한다.

## 6. 권장 작업 위치

```sh
gh repo clone aqwsde321/codex-account-switcher-spike
cd codex-account-switcher-spike
```

실제 인증 파일은 저장소 안에 절대 저장하지 않는다.

## 7. 구현 단계와 각 검증

### Step 1. SwiftPM Core skeleton

구현:

- Core library
- CLI executable
- test target
- protocol 기반 system adapter seam

검증:

- `./Scripts/dev.sh build`
- `./Scripts/dev.sh test`
- 실제 `~/.codex`를 읽지 않는 기본 test

### Step 2. 안전한 auth file/storage 계층

구현:

- opaque credential blob
- JSON 구조 검증
- 권한·owner·symlink 검사
- SHA-256 metadata
- `0600` temp + `fsync` + atomic rename
- private Spike store
- exact-schema journal과 registry
- journal/registry의 same-directory `0600` temp→file `fsync`→rename→parent `fsync`
- registry 내구 commit 뒤 journal unlink→parent `fsync`
- file lock

검증:

- fake auth fixture만 사용
- `0600`/`0700`, symlink, rename/file-fsync/parent-fsync failure, concurrent lock 테스트
- malformed/torn journal STOP, pre-auth cancel/block의 durable journal deletion 테스트
- test output secret scan

### Step 3. App Server client

구현:

- bundled executable 탐색
- Pipe 기반 LF JSON framing
- initialize response 대기 후 initialized
- ID correlation과 notification 무시/수용
- `account/read`
- stderr 별도 drain, timeout
- 대상/사후 검증용 임시 `CODEX_HOME`
- `refreshingCurrent` 내구 기록 뒤 기본 `~/.codex`에서 현재 active auth를 `account/read(refreshToken: true)`로 갱신하는 verifier mode
- target 격리 홈의 `account/read(false)` 식별→같은 이메일 확인→`account/read(true)` 갱신→갱신 blob configured credential store 저장
- 재실행 후 공용 active auth를 격리 홈에 복사해 `account/read(false)`로 판독하는 verifier mode
- private Electron IPC 비사용

검증:

- 빈 임시 홈에서 `account:null` 응답
- fragmented/multiple-line parser test
- EOF race test
- unknown field/notification test
- target `false` mismatch/null이면 `true` 호출·active write·credential overwrite가 모두 없는지 테스트
- 명시적 target auth 거부는 재로그인, network/server 실패는 retryable, credential-store write 실패는 저장소 오류로 분류하며 모두 active auth 불변·프로필 보존인지 테스트
- timeout/네트워크 실패를 revoked로 오분류하지 않는 테스트
- 사후 격리 `false` 검증이 공용 auth 이메일만 입증한다는 결과 타입 테스트
- 실제 A/B auth의 식별·refresh·사후 이메일 검증 완료

### Step 4. 앱·프로세스 adapter

구현:

- bundle id 탐색
- metadata/signature gate
- `NSRunningApplication.terminate()`
- 1초 유예 뒤 종료 대기 중 확인한 exact 앱 소유 잔존은 별도 승인 후에만 `SIGTERM`
- libproc process snapshot·ancestry·path 분류
- independent CLI 차단
- NSWorkspace launch/activate

검증:

- process classification pure test
- 실제 환경에서는 inspect-only 출력
- `SIGKILL`·독립 process kill 호출이 codebase에 없는지 검색

### Step 5. transaction과 recovery

구현:

- exact-schema journal state machine
- canonical phase 순서: `preparing`→`quitRequested`→`quiescent`→`refreshingCurrent`→`currentSaved`→`validatingTarget`→`targetValidated`→`authReplaced`→`targetLaunched`→`verifyingTarget`→`targetVerified`
- 각 phase를 다음 side effect 전에 file `fsync`→rename→parent `fsync`로 내구 기록
- current 기본 홈 `true` refresh/save 뒤 target 격리 `false` identity→`true` refresh/save 순서
- atomic switch
- post-launch active auth copy 기반 격리 `false` verification
- rollback
- startup recovery

검증:

- 각 canonical phase와 `rollbackStarted`/`rollbackFailed` failure injection
- journal/registry temp write, file `fsync`, rename, parent `fsync`, unlink 실패 injection
- torn/malformed journal에서 auth/registry mutation과 launch가 0회인지 검증
- 취소·호환성/process pre-auth 차단에서 journal unlink와 parent `fsync` 순서 검증
- `refreshingCurrent` crash 시 source-valid이면 refresh/save를 완료하고, missing/corrupt/mismatch이면 configured-store source를 복원한다. 어느 분기든 source 검증 후 전환 안전 취소
- `validatingTarget` crash/실패 시 verifier 정리→active source·registry previous 확인→안전 취소. target 프로필/갱신본 보존, forward switch 없음
- crash recovery는 `targetVerified`에서만 target commit을 완료할 수 있고 `authReplaced` 이하에서는 forward launch를 재개하지 않음
- registry 내구 commit 완료 후에만 journal unlink, 이후 parent `fsync` 검증
- 대상 불일치 시 source 복원→이메일 검증→registry previous durable commit→journal unlink+parent `fsync`→source 앱 재실행 순서
- rollback 실패 시 launch 호출 없음
- registry/auth/journal 정합성 property test 또는 table-driven test

### Step 6. 비파괴 CLI 검증

구현 명령:

- `inspect`
- `profiles list`
- `recovery status`

검증:

- 이메일 마스킹
- auth/token/raw stderr/raw argv 미출력
- 실제 파일 변경 없음
- 현재 Codex task를 종료하지 않음

### Step 7. 실제 계정 등록

이 단계부터 사용자의 명시적 상호작용이 필요하다.

- 계정 A capture: 외부 Terminal에서 완료
- 공식 로그인으로 계정 B 전환: 완료
- 계정 B capture와 계정 A 자동 복귀: 외부 Terminal에서 완료

일반 전환 명령 `switch --target <profile-id-or-label>`은 구현·fake fixture·실계정 기능 왕복 검증을 마쳤다.

각 auth-changing 명령 전에 현재 앱 종료와 정확한 영향을 사용자에게 보여준다.

### Step 8. black-box Spike

개발 전 CLI 재실행은 ADR-027에 따라 생략한다. 아래 절차는 MVP 완료·배포 전 B-010 정식 증거를 확보할 때 외부 Terminal에서 수행한다. Codex 앱 내부에서 자기 자신을 종료하는 tool call로 실행하지 않는다.

1. 비민감 기준 task를 계정 A에서 정확히 한 번 만든다.
2. 기준 task ID를 기록하고 A의 `cycle-0-a` 메시지와 응답을 완료한다.
3. Cycle 1~3 각각에서 외부 Terminal helper로 B로 전환한다.
4. 다시 열린 공식 앱에서 기준과 정확히 같은 task ID를 열고 create/copy/fork가 없음을 확인한다.
5. B의 `cycle-N-b` 실제 메시지와 응답을 완료한다.
6. 외부 Terminal에서 A로 복귀한다.
7. 같은 기준 task ID에서 A의 `cycle-N-a` 실제 메시지와 응답을 완료한다.
8. 각 cycle의 A/B 요청·응답이 한 history에 이어짐을 확인한다.
9. 같은 ID로 위 전체 왕복을 3회 연속 수행한다. cycle마다 새 task를 만들지 않는다.
10. 매 단계 이메일, build, phase, 파일 hash/mtime, process gate를 secret-free report에 기록한다.

같은 task ID의 접근·실제 요청·단일 history가 구조적으로 실패하면 즉시 NO-GO이며 복사/fork로 우회하지 않는다. 이메일 검증, process classifier, writer, recovery 등 Helper 결함이면 수정한 뒤 baseline 생성부터 전체 3-cycle Spike를 새로 시작한다. Helper 결함을 구조적 same-task 실패로 오분류하지 않는다.

### Step 9. 메뉴바 앱

ADR-027의 개발 승인에 따라 시작한다. B-010 정식 증거 공백은 릴리스 게이트로 남긴다.

현재 1~3은 완료됐다. 4의 실제 Core provider·상태 연결이 다음 작업이다.

구현 순서:

1. `CodexAccountMenuBar` executable target과 `MenuBarExtra` shell을 추가한다.
2. fake provider로 세 프로필 카드와 활성 표시를 검증한다. 이미 활성인 카드는 auth write/restart 없이, 앱 실행 중이면 activate 1회, 닫혀 있으면 verify 후 launch한다.
3. Core의 credential backend 경계를 연결해 CLI는 기존 private file store, 제품은 Keychain을 사용하게 한다. plaintext fallback은 금지한다.
4. view model은 문자열 CLI 출력이 아닌 typed Core API를 호출하고 quit 확인·단계·안전한 오류를 연결한다. UI에 전환 로직을 복제하지 않는다.
5. 시작 시 journal recovery와 `needsRelogin` 표시를 연결한다.

첫 구현 slice의 성공 기준:

- `MenuBarExtra` target이 build된다.
- fake 세 프로필에서 활성 카드 1개와 비활성 카드 2개가 구분된다.
- 실행 중인 활성 카드 선택은 auth write/restart 0회, activate 1회다.
- 닫힌 상태의 활성 카드 선택은 auth write 0회, verify 후 launch 1회다.
- 비활성 카드 선택은 확인 전 mutation 0회다.
- 테스트에서 실제 `~/.codex/auth.json`, Keychain, 공식 앱을 건드리지 않는다.

credential backend slice의 완료 기준:

- CLI는 `FileCredentialStore`를 명시적으로 사용하고 기존 `0700`/`0600` 저장 계약을 유지한다.
- 제품 backend는 profile UUID를 account key로 쓰는 Keychain generic-password item만 사용한다.
- Keychain item은 동기화하지 않고 `WhenUnlockedThisDeviceOnly` 접근성을 사용한다.
- Keychain 접근 실패는 안전한 typed error로 중단되며 plaintext fallback이 없다.
- credential load 실패 시 active auth, registry, capture marker가 바뀌지 않는다.
- 실제 Keychain item과 서명 identity 검증은 메뉴바 provider 연결·배포 검증에서 수행한다.

## 8. 실제 switch를 이 task 안에서 실행하면 안 되는 이유

현재 Codex agent는 종료 대상인 공식 Codex 앱 안에서 실행된다. 이 task가 살아 있는 동안 tool call로 앱을 종료하면 실행 중인 agent와 tool session도 끊길 수 있다.

따라서:

- 구현·비파괴 inspect는 Codex task에서 가능
- 실제 quit/switch/relaunch는 사용자가 외부 Terminal에서 실행
- 앱 재실행 후 사용자가 같은 task로 돌아와 결과를 전달
- 그 자체가 task 지속성 Spike의 일부

## 9. 결과 artifact

실제 Spike가 생성할 결과는 인증 원문 없이 다음 구조를 목표로 한다.

```text
artifacts/
├── environment.json
├── process-snapshots.jsonl
├── switch-events.jsonl
└── spike-result.md
```

포함 가능:

- app version/build
- masked email
- profile UUID
- auth SHA-256/크기/mtime
- PID/PPID/executable category/cwd
- transaction phase/duration/error code
- 사용자가 확인한 same-task 메시지 marker 결과

포함 금지:

- auth/token/cookie/header
- 전체 argv/environment
- task 본문이나 코드
- 실제 회사 데이터

## 10. Definition of Done

### CLI Spike 구현 완료

- 모든 unit/integration test 통과
- 실제 홈을 바꾸지 않는 inspect/dry-run 통과
- 보안 체크리스트 통과
- recovery failure injection 통과

### 실증 Spike 엄격 PASS 기준

- A/B 이메일 전환 검증
- 앱 재실행 후 auth 지속
- 한 번 만든 동일 task ID에서 A→B→A 실제 메시지 왕복 3회 연속
- 이전 auth로 되돌아가는 현상 없음
- rollback drill 성공
- 실제 secret 없는 결과 report

### 제품 진행 가능

ADR-027에 따라 메뉴바 앱 구현은 승인됐다. B-010 정식 증거는 MVP 완료·배포 전에 필요하다. 개발 중 같은 task ID 접근·실제 요청·단일 history가 구조적으로 FAIL하면 공용 `CODEX_HOME + auth.json 교체` 제품은 중단한다. Helper 결함은 수정 후 검증한다. 계정별 전체 환경 분리는 자동 대안으로 구현하지 않고 별도 제품 결정으로 돌린다.

## 11. 구현 중 멈춰야 하는 조건

- 공식 스키마에서 `account/read` 또는 이메일이 사라짐
- file credential mode를 확실히 적용할 수 없음
- 앱 관련 auth writer를 완전히 종료·분류할 수 없음
- 실제 auth를 repo/test log에 노출할 위험 발생
- rollback 검증을 구현할 수 없음
- same-task 요구를 새 task 복제로 바꿔야만 진행 가능
- 회사 managed policy가 계정 전환을 금지

이 경우 코드를 우회 확장하지 말고 증거와 함께 사용자에게 보고한다.

## 12. 공식 근거

- Codex Authentication: `https://learn.chatgpt.com/docs/auth.md`
- Codex App Server: `https://learn.chatgpt.com/docs/app-server.md`
- Codex configuration reference: `https://learn.chatgpt.com/docs/config-file/config-reference`
- Codex open source app-server: `https://github.com/openai/codex/tree/main/codex-rs/app-server`

공식 문서가 업데이트될 수 있으므로 구현 재개 시 최신 문서를 다시 가져와 필요한 계약만 재확인한다.
