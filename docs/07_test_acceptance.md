# Codex 계정 전환기 테스트·인수 기준

## 0. 문서 상태

- 상태: 메뉴바 MVP 개발 GO, 엄격한 MVP 완료·배포 GO 판정 전
- 대상: Swift CLI core Spike와 후속 Swift 메뉴바 앱
- 실제 계정, 실제 이메일, 인증값 포함 금지
- 이 문서의 helper 명령 표기는 설계 당시 **예정 인터페이스**다. 실제 CLI 명령은 `README.md`, 현재 실행 결과는 `04_spike_runbook.md` §18을 따른다.

## 1. 최상위 성공 조건

다음 시나리오를 민감정보 없는 하나의 task에서 3회 연속 완료해야 Spike PASS다.

```text
A에서 동일 task 생성·실제 요청 성공
→ B로 전환·B 이메일 검증·동일 task 실제 요청 성공
→ A로 복귀·A 이메일 검증·동일 task 실제 요청 성공
× 3회 연속
```

동일 task의 객관적 ID가 유지되어야 한다. 화면 제목, 복사된 history, 새 task, fork는 대체 증거가 아니다.

한 검증 run에서는 task를 기준선에서 정확히 한 번만 생성하고, 세 cycle 모두 그 ID를 사용한다.

**B에서 account/task ownership 구조 때문에 동일 task를 열거나 실제 메시지를 성공시킬 수 없으면 즉시 Spike NO-GO다. 이 경우 제품 구현을 중단하며, 대화 복제 방식으로 요구사항을 바꾸지 않는다.** helper·이메일·process 구현 실패는 FIX-AND-RETEST로 분리한다.

## 2. 판정 용어

### PASS

- 관찰 결과가 모든 예상 결과와 일치한다.
- 인증 교체 사례는 target 이메일 검증까지 끝나야 한다.
- 롤백 사례는 source 이메일 재검증까지 끝나야 한다.
- 실제 계정 사례는 secret-free evidence가 남아야 한다.

### FAIL

- 예상 결과와 실제 결과가 다르다.
- 안전 상태로 롤백되었고 재현·수정 가능한 helper 결함은 해당 case FAIL 후 수정 대상으로 둔다.
- helper, 이메일 verifier, process classifier, 앱 launch 같은 구현 실패는 FAIL/FIX-AND-RETEST다. 수정 후 3-cycle 전체를 처음부터 다시 수행한다.
- task 미노출, ID 변경, account/task ownership 거부 같은 **구조적 same-task 실패**는 최상위 Spike NO-GO다.

### STOP

추가 실행이 인증 손상·오판·정보 노출 위험을 높이는 상태다. 즉시 mutation을 멈추고 조사한다.

- 롤백 실패 또는 현재 계정 불명
- `auth.json` symlink/소유자 이상/알 수 없는 format
- 등록되지 않은 이메일 감지
- 잔존 Codex 프로세스를 분류하거나 종료 확인할 수 없음
- App Server identity contract 확인 불가
- bundle ID/auth 경로 등 핵심 호환성 변경
- token/auth 원문이 로그나 저장소에 노출
- journal과 실제 상태가 모순됨
- malformed/torn journal, 알 수 없는 schema/phase

STOP은 자동으로 제품 가설 FAIL을 뜻하지 않는다. 다만 안전 상태를 복구하고 원인을 해소하기 전에는 어떤 후속 case도 수행하지 않는다.

### INCONCLUSIVE

동일 task ID를 객관적으로 확인할 수 없는 등 증거가 부족한 경우다. PASS로 승격할 수 없으며, 관측 방법을 보강하기 전까지 STOP과 동일하게 후속 실계정 왕복을 멈춘다.

## 3. 테스트 계층과 격리

| 계층 | 인증 | 파일 경로 | 앱/프로세스 | 목적 |
|---|---|---|---|---|
| Unit | fake bytes/fixtures | 메모리·임시 경로 | fake | 순수 로직과 state machine |
| Integration | 가짜 auth JSON | 임시 `CODEX_HOME` | fake/stub App Server와 process adapter | 파일 transaction, rollback, orchestration |
| Black-box | 실제 A/B/C | 실제 기본 `~/.codex` | 공식 Codex 앱 | 제품 가설과 실제 호환성 |
| Update | 가짜+필요 시 실제 | 먼저 임시, gated real run | 업데이트된 공식 앱 | 호환성 회귀 |

Unit/Integration test는 실제 `~/.codex/auth.json`을 읽거나 쓰지 않는다. 실계정 Black-box만 명시적 승인과 runbook 절차 아래 기본 경로를 사용한다.

## 4. 공통 불변조건

모든 case에 적용한다.

- 동시에 하나의 switch transaction만 허용
- process gate 통과 전 auth mutation 없음
- source 이메일 일치 전 source profile 갱신 없음
- `refreshingCurrent` durable 후 기본 홈 Helper App Server의 `account/read(refreshToken: true)` 실행
- target은 격리 홈에서 `account/read(refreshToken: false)` identity→`account/read(refreshToken: true)` validity/refresh→동일 이메일→configured credential store durable save
- post-launch는 active auth copy를 격리 홈에서 `account/read(refreshToken: false)`로 검증하고 private Electron IPC를 사용하지 않음
- 일반 switch의 persisted phase 순서는 `preparing→quitRequested→quiescent→refreshingCurrent→currentSaved→validatingTarget→targetValidated→authReplaced→targetLaunched→verifyingTarget→targetVerified`
- rollback phase는 `rollbackStarted`, 자동 복구 불능은 `rollbackFailed`
- journal 필드는 정확히 `schemaVersion, transactionId, phase, previousProfileId, targetProfileId, startedAt, updatedAt`
- 모든 journal/registry write는 same-directory `0600` temp→file fsync→atomic rename→parent fsync 후 다음 side effect 진행
- 일반 switch의 target active-ID commit은 target 이메일 일치와 `targetVerified` durability 전 없음. 재로그인만 exact B credential 저장과 A-active registry의 B marker 해제 뒤 private `validatingTarget→targetVerified`를 허용하며 active ID는 그 뒤 commit
- 성공 registry가 durable한 뒤 journal unlink→parent fsync
- auth mutation 전 취소/차단은 journal unlink→parent fsync로 durable cleanup
- 프로필 삭제는 inactive exact target만 허용하고 `profile-removal` marker→Keychain→registry→marker 순서를 유지하며 active auth는 쓰지 않음
- 실행 중 일반 switch 실패 후 롤백은 source auth 복원→source 이메일 검증→registry previous durable commit→journal durable delete→source 앱 재실행 순서. 시작 자동 복구는 앱 미실행
- 종료 전 확인한 exact 앱 소유 잔존도 1초 유예와 별도 승인 뒤에만 `SIGTERM` 1회
- `SIGKILL` 없음
- 독립 CLI/task 자동 종료 없음
- 전환된 기본 auth는 이후 새로 시작하는 기본 Codex CLI에도 적용됨
- CLI Spike 비활성 auth는 repo 밖 `0700` private directory의 `0600` file; 제품 MVP 비활성 auth는 사용자 기본 file-based Keychain
- 제품의 persistent 평문 active auth file은 `~/.codex/auth.json` 하나
- 격리 verifier auth copy는 `0600` 임시 파일이며 verifier 종료 후 제거
- 로그/journal에 token, cookie, JWT, 전체 auth, 실제 이메일, raw command line 없음
- MVP 등록 가능 계정은 최대 3개이며 내부 profile model은 배열 기반
- 이미 활성인 계정 선택은 auth write와 restart를 발생시키지 않음

## 5. Unit 테스트 매트릭스

| ID | 대상/입력 | 기대 결과 | 필수 |
|---|---|---|---|
| U-001 | 정상 state transition | canonical 11 phase 순서만 허용 | 예 |
| U-002 | 단계 건너뛰기·역행 | transaction 거부, mutation 없음 | 예 |
| U-003 | 두 switch 동시 요청 | 하나만 lock 획득, 다른 요청은 대기/거부 | 예 |
| U-004 | 등록 이메일과 동일한 `account/read` 결과 | identity match | 예 |
| U-005 | case/공백/alias가 다른 이메일 | exact mismatch; trim·case-fold·alias 정규화 없음 | 예 |
| U-006 | email null/account null | 검증 실패 | 예 |
| U-007 | 등록되지 않은 이메일 | external login 상태, 자동 덮어쓰기 없음 | 예 |
| U-008 | source 이메일 mismatch | source auth 저장 및 switch 차단 | 예 |
| U-009 | 이미 활성인 target 선택 | activate-window action만 생성 | 예 |
| U-010 | 앱이 닫힌 상태의 target 선택 | quit confirmation 없이 process gate→switch→launch 계획 | 예 |
| U-011 | profile model에 세 항목 등록 | 세 항목 허용, 순서와 active ID 보존 | 예 |
| U-012 | profile array encode/decode | 순서와 opaque ID 보존, auth는 metadata에 없음 | 예 |
| U-013 | journal serialization | 고정 7필드만 존재; build/email/secret/추가 필드 없음 | 예 |
| U-014 | token/JWT/cookie/email 포함 error | 출력 전에 redaction, 실제 이메일 마스킹 | 예 |
| U-015 | raw command line 포함 process error | allowlist field만 기록 | 예 |
| U-016 | target 명시 auth/revocation 실패 | profile 유지, `re-login required` 상태 | 예 |
| U-017 | update build 변경 | warning과 compatibility gate 요구 | 예 |
| U-018 | rollback 대상 선택 | transaction source만 선택; 추측 금지 | 예 |
| U-019 | rollback 실패 | terminal STOP, 자동 재시도 loop 없음 | 예 |
| U-020 | task ID 비교 | 완전 동일 ID만 same-task PASS | 예 |
| U-021 | 동일 제목·다른 ID | FAIL | 예 |
| U-022 | 3회 왕복 counter | 완전한 A→B→A만 1회, 정확히 3회 필요 | 예 |
| U-023 | 구조적 same-task 중간 실패 | 즉시 NO-GO, 성공 횟수로 은폐하지 않음 | 예 |
| U-024 | masked email formatter | local/domain 원문이 로그에 남지 않음 | 예 |
| U-025 | network timeout 분류 | retryable error; revoked/re-login으로 단정하지 않음 | 예 |
| U-026 | helper/email/process 중간 실패 | FAIL/FIX-AND-RETEST; 수정 후 cycle 1부터 재실행 | 예 |
| U-027 | rollback phase | `rollbackStarted`, 실패 시 `rollbackFailed`만 persisted | 예 |
| U-028 | malformed/torn journal decode | 자동 삭제·추정 없이 STOP | 예 |
| U-029 | 네 번째 profile 등록 | 상한 오류, 기존 model 손상 없음 | 예 |
| U-030 | 메뉴바 현재 로그인 등록 | label 원문으로 Core capture 1회, 완료 뒤 profile·active 상태 재조회 | 예 |
| U-031 | 메뉴바 등록 partial failure와 pending recovery | durable profile 재조회, 등록·전환 추가 mutation 0회 | 예 |
| U-032 | 추가 등록 commit 뒤 앱 launch 실패, recovery 없음 | 새 profile 재조회, 등록 완료·launch 실패 안내, 등록 폼 닫힘 | 예 |
| U-033 | 메뉴바 활성 인증 수동 동기화 | startup 자동 호출 0회, Core sync 1회, profile·recovery 재조회, 성공 안내 | 예 |
| U-034 | 메뉴바 활성 인증 sync 뒤 recovery blocked | STOP 안내, sync·등록·전환 추가 mutation 0회 | 예 |
| U-035 | 메뉴바 `rollbackFailed` 상태 | journal previous profile ID로 정확한 이전 계정 표시 | 예 |
| U-036 | 메뉴바 일반 pending·blocked 상태 | pending phase 표시, blocked 불명확 STOP, mutation 없음 | 예 |
| U-037 | 수동 복구 뒤 앱 실행 확인 실패 | 복구 profile typed payload와 launch 미확인 outcome 분리, restore 재시도 금지 | 예 |
| U-038 | 수동 복구 journal 완료 불확실 | 성공 payload·앱 launch 없음, recovery 불확실 outcome | 예 |
| U-039 | 메뉴바 `rollbackFailed` 수동 복구 | exact transaction+previous ID, dialog dismiss 뒤 snapshot 전달, Core lock 안 재검증, stale 확인 mutation 0회 | 예 |
| U-040 | 메뉴바 복구 뒤 앱 launch 미확인 | 이전 계정 active와 recovery none 재확인, restore 재시도 0회, 앱만 수동 실행 안내 | 예 |
| U-041 | 메뉴바 journal 완료 불확실 | 재조회가 blocked면 등록·sync·전환·restore 추가 mutation 0회, none이면 앱 미실행 안내 | 예 |
| U-042 | 메뉴바 전환 진행 표시 | durable journal 성공 뒤 canonical phase 순서로만 표시, 확인 취소·활성 무변경 경로 callback 0회, 완료 뒤 상태 제거 | 예 |
| U-043 | 메뉴바 재로그인 카드 확인 | inactive `needsRelogin`만 별도 snapshot, 취소 0회, exact ID Core 호출 1회, normal switch 0회 | 예 |
| U-044 | 재로그인 확인 뒤 상태 변경 | profile/recovery 재조회, stale 확인 Core 호출 0회 | 예 |
| U-045 | 재로그인 성공·finalization 불확실 | recovery none+B 단일 active+marker 해제일 때만 성공 또는 재확인, 앱 수동 실행 안내 | 예 |
| U-046 | 재로그인 Core throw | durable B commit은 성공 재확인, A 안전 rollback은 수동 재시도, pending은 STOP·재호출 0회 | 예 |
| U-047 | transient 조회 실패와 wrong-ID outcome | catch 재조회 뒤에도 payload exact ID 검증, 불일치 blocked·성공 표시 없음 | 예 |
| U-048 | 메뉴바 시작 자동 복구 순서 | recovery 시도→profile 조회→read-only status 조회, stopped/throw도 상태 조회 뒤 fail-closed, 앱 launch 0회 | 예 |
| U-049 | 메뉴바 잔존 프로세스 2차 확인 | native async 응답을 기다리고 취소는 signal 0회; 종료 전 exact 후보만 승인하며 새·독립 process는 확인 callback·signal 0회 | 예 |
| U-050 | 메뉴바 비활성 계정 삭제 확인 | inactive exact snapshot만 확인, 취소·활성·stale 상태 Core 호출 0회 | 예 |
| U-051 | 삭제 Core throw 뒤 상태 재조회 | target 부재+recovery none+단일 active일 때만 완료 재확인, 그 밖에는 실패 또는 STOP | 예 |
| U-052 | 삭제 성공 UI | 대상 카드 제거, 기존 active 하나 유지, 로컬 저장본 삭제 안내 | 예 |

## 6. Integration 테스트 매트릭스

모든 파일 test는 test runner가 만든 임시 directory에서 수행한다. 실제 홈 경로를 fixture로 넘기면 test가 먼저 실패해야 한다.

| ID | 주입 조건/동작 | 기대 결과 | 필수 |
|---|---|---|---|
| I-001 | 정상 source→target 교체 | 같은 directory temp write 후 atomic rename, target bytes 일치 | 예 |
| I-002 | temp write 실패 | 기존 active auth byte 보존 | 예 |
| I-003 | chmod 실패 | rename 전 중단, 기존 파일 보존 | 예 |
| I-004 | file flush 실패 | rename 전 중단, 기존 파일 보존 | 예 |
| I-005 | rename 실패 | 기존 파일 보존, temp 정리 가능 | 예 |
| I-006 | 설치 후 byte mismatch | launch 전 실패와 source 롤백 | 예 |
| I-007 | target auth malformed/empty | active auth mutation 전 거부 | 예 |
| I-008 | active auth가 symlink | STOP, target write 없음 | 예 |
| I-009 | owner/mode 부적합 | STOP 또는 안전한 명시 복구; 묵시 진행 없음 | 예 |
| I-010 | 전환·등록 정상 종료 1초 뒤 exact 앱 소유 잔존 | 별도 확인 후 승인 시 해당 PID만 `SIGTERM` 1회 | 예 |
| I-011 | 독립 CLI PID 존재 | PID/cwd 안내, 자동 kill 없음, write 없음 | 예 |
| I-012 | helper 소유 verifier만 존재 | verifier 정상 종료 확인 후 gate 통과 | 예 |
| I-013 | current refresh 시작 | `refreshingCurrent` durable 후에만 기본 홈 Helper App Server `refreshToken: true` 호출 | 예 |
| I-014 | current refresh 성공 | source 이메일 일치→PID 종료→갱신 blob configured-store durable save→`currentSaved` | 예 |
| I-015 | target false identity mismatch | true refresh 미호출, active source 불변, profile 보존·`re-login required` | 예 |
| I-016 | target false 일치 후 true auth 실패 | active source 불변, profile 보존, `re-login required` | 예 |
| I-017 | target false/true 중 network 실패 | active source 불변, retryable; revoked로 분류하지 않음 | 예 |
| I-018 | target validation 성공 | isolated false→true→동일 이메일→refresh blob configured-store durable save→`targetValidated` | 예 |
| I-019 | post-launch identity 검증 | active auth copy→isolated Helper verifier false→target 이메일→`targetVerified` | 예 |
| I-020 | post-launch verifier dependency spy | private Electron IPC 호출 0회 | 예 |
| I-021 | post-launch 이메일 mismatch | target app 종료→source 롤백→source 검증 | 예 |
| I-022 | app launch 실패 | source 롤백, target 미활성 | 예 |
| I-023 | rollback source 검증 실패 | `rollbackFailed`, STOP, 앱 재실행 반복 없음 | 예 |
| I-024 | B 등록 성공 | B configured-store 저장 후 A 자동 복구·A 검증 | 예 |
| I-025 | B가 A와 같은 이메일 | 등록 거부, A 유지 | 예 |
| I-026 | B 등록 도중 실패 | A 자동 복구 또는 명확한 STOP | 예 |
| I-027 | 이미 활성인 account 선택 | 파일 write 0회, restart 0회 | 예 |
| I-028 | 앱 닫힌 상태 정상 switch | process gate 후 swap·launch·검증 | 예 |
| I-029 | journal temp/file fsync 실패 | 다음 side effect 0회, 기존 durable journal 유지 | 예 |
| I-030 | journal rename 실패 | 다음 side effect 0회, 기존 durable journal 유지 | 예 |
| I-031 | journal parent fsync 실패 | phase 완료로 간주하지 않고 다음 side effect 0회 | 예 |
| I-032 | registry fsync/rename/parent fsync 실패 | journal 보존, 성공 표시·journal 삭제 없음 | 예 |
| I-033 | 성공 후 journal unlink 실패 | journal 보존, 다음 시작에서 `targetVerified` 재판정 | 예 |
| I-034 | journal unlink 후 parent fsync 실패 | 완료로 단정하지 않고 recovery에서 registry/active 재검증 | 예 |
| I-035 | 사용자가 종료 확인 취소 | auth mutation 0회, journal unlink+parent fsync 완료 | 예 |
| I-036 | process gate 차단 | switch는 auth mutation 0회+journal durable delete; capture는 비동기 기존 credential 검증 뒤에도 재검사해 새 credential·marker·journal 0개, 독립 process 불변 | 예 |
| I-037 | malformed/torn/unknown journal | 자동 삭제·복구 없이 STOP | 예 |
| I-038 | 두 process가 같은 transaction 재개 | 단일 lock, 중복 rename/launch 없음 | 예 |
| I-039 | 진단 error에 auth blob 포함 | persisted log에 민감값 0건 | 예 |
| I-040 | credential backend 검사 | Spike는 private `0600` file store, 제품은 사용자 기본 file-based Keychain; backend 혼용 없음 | 예 |
| I-041 | current true refresh 도중 실패 | `rollbackStarted` durable→마지막 검증 source 복원·이메일 확인 | 예 |
| I-042 | `currentSaved` 뒤 target validation 실패 | active source 유지 확인→registry previous→journal durable cleanup | 예 |
| I-043 | `SIGTERM` 뒤 앱 소유 process 잔존 또는 identity 변경 | switch 차단, active auth unchanged | 예 |
| I-044 | 사용자가 잔존 앱 process `SIGTERM` 거부 | signal 0회, auth·registry 불변, journal 내구 삭제 | 예 |
| I-045 | A/B 등록 상태에서 C capture | C 저장 후 등록 시작 전 active 복원, A/B/C credential 보존 | 예 |
| I-046 | 세 프로필 상태에서 네 번째 capture | auth·credential·registry·journal mutation 0회 | 예 |
| I-047 | 제3 프로필이 있는 `rollbackFailed` 복구 | previous 복구, 무관한 프로필과 credential 보존 | 예 |
| I-048 | 수동 복구 commit 뒤 앱 launch 실패 | exit 1과 `application_launch_unconfirmed`, previous active·auth와 journal 내구 삭제 보존 | 예 |
| I-049 | journal unlink가 보이나 parent `fsync` 실패 | exit 1과 `recovery_uncertain`, durable phase/profile+auth-digest evidence 보존, registry/auth digest 불일치나 fsync 실패 시 blocked·mutation 0회; 모두 재검증 뒤에만 none | 예 |
| I-050 | evidence 저장 뒤 journal unlink 전 중단 | 무관한 phase/profile은 blocked+양쪽 보존, exact 또는 `rollbackStarted` evidence/`rollbackFailed` journal 조합이면 status 선행 없이 공통 mutation gate가 cleanup 재개 | 예 |
| I-051 | exact B 수동 로그인 뒤 재로그인 반영 | B credential·marker 해제·active ID를 순서대로 내구 저장, B 활성, journal 없음, 앱 launch 0회 | 예 |
| I-052 | 재로그인 B identity mismatch | A credential·active ID 검증 복원, B 기존 저장본·marker 보존 | 예 |
| I-053 | 재로그인 중 process 또는 recovery 존재 | verifier·credential·registry mutation 0회 | 예 |
| I-054 | 재로그인 verifier 종료 미확인 | 첫 child 전 `validatingTarget` journal 존재, recovery pending, workspace-only 상태 없음 | 예 |
| I-055 | refresh 응답 B 뒤 공용 auth file identity 변경 | B 저장본을 덮지 않고 A rollback, journal 정리 | 예 |
| I-056 | 재로그인 journal finalization 불확실 | 자동 재시도·앱 launch 없음, restart 재조정이 exact B 상태에서만 recovery none | 예 |
| I-057 | `targetVerified` 재시작, registry A 또는 B | exact B면 target commit 또는 중복 registry write 없는 finalization, 앱 launch 0회 | 예 |
| I-058 | `validatingTarget` 재로그인 재시작 | 미저장 B와 저장·marker 해제 B를 구분해 A 복원, B의 검증 상태 보존, 앱 launch 0회 | 예 |
| I-059 | `targetVerified` target mismatch와 불확실성 | typed `target-unverified`만 A rollback, process·registry race·verifier 종료 미확인은 STOP·unsafe write 0회 | 예 |
| I-060 | phase/registry/marker 모순과 `rollbackFailed` | 모순은 상태 보존 STOP, terminal phase는 locator·workspace·auth·registry side effect 0회 | 예 |
| I-061 | `refreshingCurrent` 복구 실패 | `rollbackStarted→rollbackFailed` 내구 기록, 다음 자동 복구는 terminal STOP | 예 |
| I-062 | 번들 Keychain host smoke | exact ad-hoc bundled executable이 random service/profile의 synthetic blob을 create→read→update→read→delete→notFound; cleanup 성공, 제품 service·실제 auth 접근 0회 | 예 |
| I-063 | 비활성 프로필 정상 삭제 | 삭제 marker→target credential 삭제→registry 삭제→marker 삭제, active credential·auth 불변 | 예 |
| I-064 | 활성 프로필 삭제 요청 | typed 거부, credential·registry·active auth mutation 0회 | 예 |
| I-065 | Keychain 삭제 거부·중단 뒤 재시작 | marker와 registry 보존, 다음 복구가 credential·registry 정리를 멱등 완료 | 예 |
| I-066 | 삭제 marker와 switch journal 공존 | 명시·자동 switch 복구 mutation 0회, 두 artifact 보존 STOP | 예 |

I-062는 custom debug harness 129개와 별도의 host integration smoke다. 현재 build bundle과 `~/Applications` 설치본에서 각각 통과했지만, ad-hoc 재빌드 뒤 기존 item ACL·잠금·접근 거부·실계정 제품 flow는 입증하지 않는다.

## 7. 공식 앱 Black-box 매트릭스

실행 전 실제 이메일은 test sheet에 쓰지 않고 `profile-a`, `profile-b`, `profile-c`로만 표기한다. 화면 캡처는 이메일과 다른 sidebar 내용을 가린다.

| ID | 시나리오 | PASS 기준 | 실패 행동 |
|---|---|---|---|
| B-001 | compatibility preflight | bundle ID/path/App Server identity 계약 확인, auth mutation 0회 | STOP |
| B-002 | A 등록 | A 이메일 확인, profile-a Spike private-store 저장·registry durability 확인 | STOP |
| B-003 | B 등록 후 A 자동 복귀 | 서로 다른 이메일, profile-b Spike private-store 저장, 최종 A 검증 | 자동 A 롤백 또는 STOP |
| B-004 | 실행 중 앱에서 switch 취소 | 앱·auth·active 계정 변화 없음, journal durable cleanup | case FAIL |
| B-005 | 앱 정상 종료 switch | 필요 시 별도 승인 후 exact 앱 소유 잔존만 `SIGTERM`, quiescent 뒤 target 설치·검증 | 자동 롤백 |
| B-006 | 이미 닫힌 앱에서 switch | 잔존 process 없음, target 실행·검증 | 자동 롤백 |
| B-007 | 이미 활성인 계정 클릭 | 창 활성화만, restart/write 없음 | case FAIL |
| B-008 | 외부 `codex login`으로 미등록 계정 감지 | switch 차단, 등록/폐기 결정 요구 | STOP |
| B-009 | 앱 완전 종료·재실행 후 계정 유지 | 마지막 committed 이메일 유지 | 자동 롤백/FAIL |
| B-010 | 한 task의 동일 ID로 3회 왕복 | §8의 모든 단계와 실제 메시지 성공 | 구조적 실패면 **NO-GO/제품 중단** |
| B-011 | 의도적 post-launch target 검증 실패 | source 자동 롤백·source 이메일 확인 | STOP if rollback fails |
| B-012 | 최종 A 정리 | A 활성·재실행 유지, verifier/lock 없음 | STOP |
| B-013 | target 사전 검증 실패 | active source 불변, profile 보존, 오류 정확 분류 | case FAIL |
| B-014 | post-launch 검증 transport | active copy의 isolated Helper verifier false, private IPC 0회 | STOP |
| B-015 | C 등록 후 기존 active 복귀 | C 저장, 등록 시작 전 active 이메일 복원, A/B/C 보존 | 자동 롤백 또는 STOP |
| B-016 | 세 프로필 수동 전환 | A→B→C→A 각 단계 이메일·UI active 일치 | 자동 롤백/FAIL |
| B-017 | `needsRelogin` B 수동 재로그인 | 공식 앱 B 로그인·전체 종료 뒤 메뉴바 1회 확인, B active·marker 해제·앱 미실행 | A 자동 롤백 또는 STOP |

### 7.1 B-015~B-016 실행 절차

`04_spike_runbook.md`의 A/B 실행 기록은 수정하지 않는다. 별도 clean run에서 §4~§6의 안전 원칙·preflight·백업을 다시 적용하고 다음을 수행한다.

1. A/B가 등록된 상태에서 B를 active로 검증하고 registry·credential 보존 여부의 기준선을 기록한다.
2. 공식 로그인으로 C를 활성화한 뒤 C를 등록한다. 완료 후 B가 다시 active이고 journal·capture marker가 없는지 확인한다.
3. A→B→C→A를 순서대로 전환한다. 각 단계에서 `account/read` 이메일과 UI active 카드가 같은 별칭을 가리키는지 확인한다.
4. A/B/C profile ID·순서와 credential 보존 여부가 기준선 기대와 일치하는지 확인한다. 실제 이메일·인증 bytes·digest는 기록하지 않는다.

실패 시 다음 단계로 진행하지 않는다. 자동 rollback이 검증되지 않으면 STOP하고 공식 앱을 다시 열지 않는다.

### 7.2 B-017 실행 절차

실제 인증 폐기가 필요한 사전조건은 전용 테스트 계정에서만 만든다. auth 원문을 수동 편집해 `needsRelogin` 상태를 위조하지 않는다.

1. A active, B inactive·`needsRelogin`, recovery none을 확인한다.
2. 공식 Codex 앱에서 B로 로그인한 뒤 앱과 독립 Codex CLI·IDE를 모두 정상 종료하고 process gate가 깨끗한지 확인한다.
3. 메뉴바의 B 카드를 한 번 선택하고 재로그인 반영을 확인한다.
4. B 하나만 active, B marker 해제, recovery none, 공식 앱 미실행을 확인한다.
5. 공식 앱을 직접 열고 `account/read`가 B 이메일과 완전 일치하는지 확인한다.

pending·blocked 또는 결과 불일치면 확인을 반복하지 않고 상태를 보존한다.

## 8. 동일 task 핵심 인수 시나리오

### 준비

- A/B 등록과 A 자동 복귀 완료
- 비민감 전용 workspace
- 공개 가능한 nonce 생성
- 공식 task/thread ID 관측 방법 확인
- task create/copy/fork 이벤트를 구분할 방법 확인
- 이 run에서 task 생성은 기준선의 1회뿐이라는 test record

ID를 신뢰성 있게 관측할 수 없으면 실행하지 않고 INCONCLUSIVE/STOP 처리한다.

### 기준선

| 단계 | 활성 계정 | 동작 | 필수 증거 |
|---|---|---|---|
| 0-1 | A | 이 run의 task를 한 번만 생성 | 기준 task ID |
| 0-2 | A | `cycle-0-a` 실제 메시지 전송 | 요청·응답 완료, A 이메일 검증 |

### Cycle 1~3

각 cycle에서 아래 8단계를 그대로 반복한다.

| 단계 | 동작 | PASS 기준 |
|---|---|---|
| N-1 | A→B 전환 | B 이메일 검증 성공 |
| N-2 | 기존 task 열기 | 기준 task ID와 동일, create/fork 없음 |
| N-3 | `cycle-N-b` 실제 메시지 | 요청과 응답 완료 |
| N-4 | history 확인 | 이전 A 메시지와 새 B 메시지가 한 chain에 존재 |
| N-5 | B→A 전환 | A 이메일 검증 성공 |
| N-6 | 기존 task 열기 | 같은 기준 task ID |
| N-7 | `cycle-N-a` 실제 메시지 | 요청과 응답 완료 |
| N-8 | history 확인 | 해당 cycle의 A/B 요청·응답 모두 한 chain에 존재 |

### 구조적 same-task 실패 — 즉시 NO-GO

- B 계정 sidebar/API에서 task를 찾을 수 없음
- 같은 task ID 접근 거부
- message submission이 account/task ownership 오류
- task ID 변경 또는 숨은 복제
- UI에 history가 보여도 B 요청이 task ownership/account 경계로 거부됨
- A 복귀 후 B 메시지가 동일 history에 없음

이 실패는 신규 task 생성, text copy, fork로 우회하지 않는다. source A를 복구하고 증거를 정리한 뒤 제품 구현을 중단한다.

### 구현 실패 — FIX-AND-RETEST

이메일 verifier, process classifier, 앱 launch, journal I/O, 일시적 network 오류처럼 task 구조를 증명하지 못하는 실패는 case FAIL이다. 안전 복구 후 원인을 수정하고 **cycle 1부터 전체 3-cycle을 새 clean run으로 다시 실행**한다. 실패한 cycle 다음부터 이어 세지 않는다. 새 run에서도 task는 기준선에서 하나만 생성한다.

## 9. 독립 CLI/task 테스트

| ID | 시나리오 | PASS 기준 | 필수 |
|---|---|---|---|
| P-001 | 장시간 Codex CLI task 실행 중 switch | switch 차단, CLI 계속 실행, auth write 0회 | 예 |
| P-002 | 차단 안내 | PID와 사용자 확인용 cwd 표시, raw command line 미표시 | 예 |
| P-003 | 사용자가 CLI 정상 종료 후 재시도 | gate 통과 후 정상 switch | 예 |
| P-004 | 독립 `codex app-server` 실행 중 | 자동 kill 없이 차단 | 예 |
| P-005 | helper가 띄운 verifier 종료 중 | 소유 PID만 정상 정리, 다른 process 불변 | 예 |
| P-006 | 분류 불가능한 `codex` process | 안전 차단 | 예 |
| P-007 | Codex와 무관한 유사 이름 process | false positive 없이 진행 | 예 |
| P-008 | PPID 1의 bundle 내부 `browser_crashpad_handler`만 잔존 | `Versions/Current`의 canonical bundle 내부 regular executable 및 정적 서명이 유효하고 실행 process의 exact path·name·signing identifier·Team ID가 모두 맞으면 진행, 아니면 STOP | 예 |

어떤 case에서도 `kill -9`, 독립 process, 분류 불명 process 자동 종료를 PASS 방법으로 사용하지 않는다.

## 10. Crash/reboot 테스트

각 checkpoint에서 process 종료 또는 crash를 주입하고 helper를 다시 시작한다. 인증 bytes는 출력하지 않고 active가 source/target 어느 fixture와 동일한지만 검사한다.

| ID | crash 지점 | 재시작 기대 결과 | 판정 |
|---|---|---|---|
| C-001 | `preparing` 전 | transaction 없음, active 불변 | PASS |
| C-002 | `quitRequested` | process gate 재확인, auth mutation 없음 | PASS |
| C-003 | `quiescent` | exact source는 안전 취소, exact target은 source rollback, 다른 신원·판독 불가는 STOP | PASS/STOP |
| C-004 | `refreshingCurrent` durable, verifier 시작 전 | source refresh/save 또는 stored source 복원 후 안전 취소 | PASS |
| C-005 | current true refresh 후, source store save 전 | source 이메일 확인 후 refresh/save 또는 stored source 복원, 그 뒤 안전 취소 | PASS |
| C-006 | source store save 후, `currentSaved` 전 | round-trip·source 검증 후 안전 취소 | PASS |
| C-007 | `currentSaved` | exact source는 latest source 확인 뒤 안전 취소, exact target은 source rollback, 다른 신원·판독 불가는 STOP | PASS/STOP |
| C-008 | `validatingTarget` durable, false 호출 전 | verifier 정리·source 검증·안전 취소, forward switch 없음 | PASS |
| C-009 | target false 성공 후, true 호출 전 | verifier 정리·source 검증·안전 취소, forward switch 없음 | PASS |
| C-010 | target true 성공 후, target store save 전 | active source 불변 확인·안전 취소, forward switch 없음 | PASS |
| C-011 | target store save 후, `targetValidated` 전 | refreshed target 보존 가능, source 검증·안전 취소, forward switch 없음 | PASS |
| C-012 | `targetValidated`, active replace 전 | source 확인 후 안전 취소 가능 | PASS |
| C-013 | active replace 후, `authReplaced` journal 전 | actual active target 감지→source rollback | PASS |
| C-014 | `authReplaced` | process 실행 중이면 종료 없이 STOP, gate가 깨끗하면 source 롤백·앱 미실행 | PASS/STOP |
| C-015 | `targetLaunched`/`verifyingTarget` | process 실행 중이면 종료 없이 STOP, 사용자가 종료한 뒤 source 롤백·앱 미실행 | PASS/STOP |
| C-016 | `targetVerified`, registry commit 전 | exact target은 registry durable commit; typed `target-unverified`만 source rollback, process·registry race·verifier 종료 미확인·내구성 불확실은 STOP | PASS/STOP |
| C-017 | registry commit 후 journal delete 전/중 | target·registry 재검증→journal unlink+parent fsync, 중복 launch/write 없음 | PASS |
| C-018 | `rollbackStarted` 또는 rollback 설치 중 | source 복구·검증을 idempotent하게 완료하거나 `rollbackFailed` STOP | PASS/STOP |
| C-019 | malformed/torn/unknown journal | 자동 삭제·추정 없이 STOP | PASS |
| C-020 | journal과 active/registry 모순 | 해소 불가하면 STOP | PASS |
| C-021 | macOS reboot after active replace | 앱 자동 실행 전에 recovery gate와 source rollback | PASS |
| C-022 | 재로그인 `validatingTarget`, B 저장·marker 해제 전/후 | target 식별 뒤 A 복원, 검증된 B 상태 보존, 앱 launch 0회 | PASS |
| C-023 | 재로그인 `targetVerified`, active ID commit 전/후 | exact B forward commit 또는 중복 write 없는 finalization; 불확실은 STOP | PASS/STOP |
| C-024 | `refreshingCurrent` 복구 실패 뒤 재시작 | `rollbackFailed` terminal 유지, 자동 재시도 side effect 0회 | STOP |

current refresh crash window에서는 refresh 실행 여부를 phase만으로 추측하지 않는다. 안전하면 기본 홈 Helper App Server의 true refresh와 configured-store save를 완료하고, 그렇지 않으면 마지막 durable source blob을 복원한다. 어느 분기든 source를 검증한 뒤 전환을 안전 취소한다. source 이메일 재검증까지 실패하면 `rollbackFailed`/STOP이며 성공 rollback으로 계산하지 않는다. crash recovery가 forward switch를 재개할 수 있는 유일한 정상 phase는 검증이 끝난 `targetVerified`다.

## 11. 만료·폐기 token 테스트

실제 token 폐기는 계정 상태에 영향을 주므로 별도 승인 없이는 fake App Server/fixture로 수행한다. 실계정 case가 필요하면 전용 테스트 계정을 사용한다.

| ID | 상태 | PASS 기준 | 필수 |
|---|---|---|---|
| R-001 | target token expired during isolated true validation | active source 불변, profile 보존, `re-login required` | 예 |
| R-002 | target token explicitly revoked | active source 불변, profile 보존, `re-login required` | 예 |
| R-003 | target logged out response | active source 불변, profile 유지, 자동 삭제 없음 | 예 |
| R-004 | source가 전환 전 이미 expired | source identity 확인 불가로 switch 차단 | 예 |
| R-005 | target 재로그인 성공 | 명시 사용자 동작 후 profile 교체, 기존 profile silent overwrite 없음 | 예 |
| R-006 | rollback source도 invalid | 앱 재실행 없이 terminal STOP, 수동 복구 안내 | 예 |
| R-007 | target validation network/DNS/offline 실패 | retryable 상태, profile 보존, revoked 단정 없음 | 예 |
| R-008 | prevalidation 뒤 post-launch auth 실패 | `rollbackStarted`→source 복구·검증 | 예 |
| R-009 | current refresh network 실패 | 검증된 source 복원, source revoked 단정 없음 | 예 |

## 12. Codex 업데이트 호환성 테스트

| ID | 변화 | 기대 결과 | 필수 |
|---|---|---|---|
| UP-001 | build만 변경, 계약 동일 | 경고→preflight→guarded switch→이메일 검증 | 예 |
| UP-002 | bundle identifier 변경 | switch 전 STOP | 예 |
| UP-003 | auth 기본 경로 변경 | switch 전 STOP | 예 |
| UP-004 | auth file이 directory/symlink/새 저장소로 변경 | switch 전 STOP | 예 |
| UP-005 | auth schema 변경, 저장 blob unreadable | mutation 전 STOP | 예 |
| UP-006 | App Server `account/read` 제거/변경 | mutation 전 STOP | 예 |
| UP-007 | process tree 변경으로 독립 CLI 분류 불가 | process gate STOP | 예 |
| UP-008 | guarded target launch 후 identity mismatch | 자동 source 롤백 | 예 |
| UP-009 | update 후 rollback source 검증 | source 이메일 일치해야만 복구 PASS | 예 |
| UP-010 | 다음 동일 build switch | 경고 반복 정책이 설계값과 일치 | 아니오 |

업데이트 테스트에서 한 번 성공했다고 bundle ID, process gate, identity 검증을 이후 생략하지 않는다.

## 13. 등록·계정 수 테스트

| ID | 시나리오 | PASS 기준 |
|---|---|---|
| A-001 | 실행 중 최초 A 등록 | 명시 확인→정상 종료→기본 홈 true refresh·이메일 검증→durable capture→A로 앱 재실행 |
| A-002 | 실행 중 B 등록 | 명시 확인→정상 종료→exact 잔존 승인·`SIGTERM` 1회→B capture→A 자동 복귀·재실행 |
| A-003 | B 등록 취소 | A profile/active auth 유지 |
| A-004 | B 등록 실패 | A 자동 롤백 또는 명시 STOP |
| A-005 | 기존 profile ID 중복 | 덮어쓰기 전 명시 확인 또는 거부 |
| A-006 | 외부 로그인으로 unknown email | 등록/폐기 선택 전 switch 차단 |
| A-007 | C 등록 | C 저장 후 등록 시작 전 active 복귀, 기존 A/B 보존 |
| A-008 | 네 번째 계정 등록 | 무변경 거부, 기존 A/B/C 불변 |
| A-009 | 3계정 model fixture | profile array가 세 항목을 안전하게 round-trip |
| A-010 | 비활성 B 삭제 취소 | B profile·Keychain item 유지, A active·현재 로그인 불변 |
| A-011 | 비활성 B 삭제 승인 | B profile·Keychain item 제거, A active·현재 로그인·OpenAI 계정 불변 |
| A-012 | 삭제한 B 재등록 | B로 공식 로그인 후 같은 라벨·이메일 등록 성공, 새 profile ID, 등록 시작 전 active 복귀 |

2026-08-02 실제 설치본에서 A-011 PASS를 확인했다. 비활성 B 삭제 뒤 B 카드가 사라졌고 A가 단일 active로 유지됐으며 현재 Codex 로그인과 recovery 오류가 바뀌지 않았다. A-010과 A-012는 미검증이다.

MVP는 최대 3개 계정을 노출하며 `personalAuth`, `workAuth` 같은 고정 secret field로 구현하지 않는다.

## 14. 롤백 테스트

각 실패 지점에 fault injection을 넣어 source 복구를 확인한다.

| ID | 실패 지점 | PASS 기준 |
|---|---|---|
| RB-001 | target stage | active source 불변 |
| RB-002 | target rename 직후 | source 원자 복구→이메일 검증→registry previous durable→journal durable delete→source 앱 재실행 |
| RB-003 | app launch | source 원자 복구→이메일 검증→registry previous durable→journal durable delete→source 앱 재실행 |
| RB-004 | app readiness | source 원자 복구→이메일 검증→registry previous durable→journal durable delete→source 앱 재실행 |
| RB-005 | post-launch account/read timeout | `rollbackStarted` durable→source 복구→이메일 검증→registry previous durable→journal durable delete→source 앱 재실행 |
| RB-006 | post-launch target email mismatch | `rollbackStarted` durable→source 복구→이메일 검증→registry previous durable→journal durable delete→source 앱 재실행 |
| RB-007 | verifier 종료 실패 | process gate가 auth 복구 전 차단, STOP |
| RB-008 | target 앱 정상 종료 실패 | active 파일 재교체 금지, STOP |
| RB-009 | source auth 파일 missing/corrupt | 앱 실행 금지, STOP |
| RB-010 | source account/read mismatch | rollback 실패로 STOP |
| RB-011 | rollback registry previous write 실패 | journal 보존, 성공 표시 없음, STOP 또는 안전 재시도 |
| RB-012 | rollback journal unlink/parent fsync 실패 | 다음 시작에서 source·registry 재검증 후 durable cleanup |

자동 롤백 PASS는 파일 copy 성공이 아니라 **source 이메일 검증 성공**이다.

## 15. 보안·로그 테스트

| ID | 검사 | PASS 기준 |
|---|---|---|
| S-001 | 저장소 전체 secret scan | auth/token/cookie/실제 이메일 0건 |
| S-002 | helper metadata/isolated home directory mode | `0700` |
| S-003 | transient verifier auth copy mode | `0600`, 종료 후 제거 |
| S-004 | active atomic temp mode | rename 전부터 `0600` |
| S-005 | symlink race fixture | unsafe target 감지·STOP |
| S-006 | diagnostic log snapshot | allowlist field만 존재 |
| S-007 | error serialization | nested auth/header/token redaction |
| S-008 | journal snapshot | 고정 7필드만 존재; build/email/secret 없음 |
| S-009 | UI error | 실제 token·auth JSON 미노출 |
| S-010 | screenshot evidence | 이메일/다른 task/sidebar 내용 마스킹 |
| S-011 | credential storage | Spike private store는 `0700`/`0600`; 제품 inactive auth는 사용자 기본 file-based Keychain이고 persistent active 평문은 하나 |
| S-012 | working directory 표시 | UI에는 필요 범위만, persisted log에는 민감 경로 없음 |
| S-013 | journal/registry atomic temp | same directory, mode `0600`, file·parent fsync 계약 준수 |
| S-014 | isolated verifier cleanup | transient auth copy와 임시 홈 제거, private IPC 사용 0회 |

## 16. Evidence 요구사항

각 manual/black-box case 결과에는 다음을 남긴다.

- case ID
- 시작/종료 timestamp
- Codex version/build
- source/target opaque profile ID
- 마스킹 이메일과 `account/read` match 여부
- 각 switch phase 결과
- rollback 발생 여부와 source 재검증 결과
- task ID
- cycle별 nonce와 request completion 여부
- PASS/FAIL/STOP 및 정제된 사유

다음은 남기지 않는다.

- 실제 이메일
- 인증 파일 원문 또는 일부
- token hash를 포함한 token fingerprint
- raw App Server frame
- raw shell command line
- 회사 workspace의 전체 path

## 17. Spike Go/No-Go

### 개발 GO — 메뉴바 앱 구현 진행

2026-07-30 사용자 확인상 동일 task의 A↔B 기능 왕복 3회와 메시지 응답이 완료됐고 B-011 자동 롤백을 확인했다. B-010의 cycle nonce와 단계별 task ID 증거는 보존하지 않아 정식 PASS로 기록하지 않는다. ADR-027에 따라 사용자가 증거 형식 공백을 수용하고 메뉴바 MVP 구현을 승인했다.

### 엄격한 GO — MVP 완료·배포

아래가 모두 충족되어야 한다.

- 공식 앱 Black-box B-001~B-017 PASS
- process gate와 독립 CLI P-001~P-008 PASS 또는 P-008의 명시적 안전 조건 충족
- Integration I-001~I-062 PASS
- 동일 task B-010: A→B→A 3회 연속 실제 메시지 PASS
- 모든 전환에서 이메일 검증 PASS
- secret exposure 0건

기존 A/B CLI 실증에서 남은 형식 항목은 B-010의 §16 증거다. 3계정·재로그인 MVP는 메뉴바 구현 뒤 B-015~B-017도 통과해야 한다. 개발 중 구조적 same-task 실패가 확인되면 아래 NO-GO를 즉시 적용한다. 현재 A/B 결과는 `04_spike_runbook.md` §18에 기록한다.

### NO-GO — 제품 구현 중단

다음 중 하나면 즉시 NO-GO다.

- 동일 task가 B에 보이지 않음
- 동일 task가 보여도 account/task ownership 구조 때문에 B 계정 요청이 거부됨
- B 요청 후 A로 돌아왔을 때 같은 history로 이어지지 않음
- task ID가 바뀌거나 copy/fork가 필요함
- account/task ownership 경계 때문에 동일 task 요청이 거부됨

### FIX-AND-RETEST

제품 가설은 유지되지만 helper 구현 결함인 경우다.

- UI 표시 오류
- 정상 종료 timeout 조정 필요
- 이메일 verifier 구현 오류
- 로그 마스킹 결함
- 원자 writer/fault recovery 결함
- process classifier false positive
- 앱 launch orchestration 오류
- 일시적 network 실패

반드시 수정 후 관련 unit→integration을 통과하고, black-box 동일 task 검증은 cycle 1부터 전체 3-cycle을 새 clean run으로 다시 수행한다. 구조적 same-task 실패를 이 범주로 낮추지 않는다.

### TERMINAL STOP

- rollback source 이메일 검증 실패
- active account를 판정할 수 없음
- 인증값 노출
- 호환성 핵심 계약 변경
- process가 살아 있어 안전한 auth 복구 불가
- malformed/torn journal 또는 지원하지 않는 journal schema/phase

이 경우 앱을 자동 재실행하거나 auth를 반복 교체하지 않는다. source secret을 보존하고 수동 복구 절차로 넘긴다.

## 18. MVP 릴리스 인수 기준

메뉴바 앱이 릴리스 후보가 되려면 다음까지 충족해야 한다.

- 전체 Unit 필수 case PASS
- 전체 Integration 필수 case PASS
- 독립 CLI, crash/reboot, revoked token, rollback 필수 case PASS
- 현재 Codex build의 update compatibility case PASS
- A/B/C 최대 3계정 등록과 수동 switch UX PASS
- 이미 활성 계정 클릭 시 no-op+창 활성화 PASS
- `needsRelogin` 비활성 계정의 exact-ID 수동 재로그인 반영과 B 활성화 PASS
- 앱 종료 확인 취소 시 mutation 0회
- 제품 inactive profile auth가 Keychain에만 존재하고 persistent active auth file은 하나
- 실제 인증정보가 저장소·로그·crash report에 0건
- clean install과 재부팅 후 미완료 journal 복구 PASS
- 동일 task 3회 왕복 black-box를 릴리스 build로 재통과
