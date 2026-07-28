# Codex 계정 전환 Spike 실행 Runbook

## 0. 문서 상태

- 상태: 구현 전 실행 설계
- 대상: macOS 공식 Codex 앱, 기본 `CODEX_HOME`인 `~/.codex`
- 목적: 개인 계정 A와 회사 계정 B의 인증을 교체하면서 **동일한 Codex task를 양쪽 계정에서 실제로 이어갈 수 있는지** 검증
- 실행 금지: 이 문서는 절차와 안전 기준을 정의한다. 현재 존재하지 않는 helper/CLI가 구현되어 있다고 가정하지 않는다.

이 문서의 `switcher ...` 표기는 모두 **예정 인터페이스**다. 실제 명령, 옵션, App Server 연결 방식은 구현·검증 후 확정한다. 문서에 적힌 예시를 현재 셸에서 실행하지 않는다.

## 1. 핵심 판정

Spike의 제품 가설은 다음 하나다.

> A가 만든 동일 task를 B가 열어 실제 메시지를 성공시키고, 다시 A가 같은 task에서 실제 메시지를 성공시킬 수 있다.

- A→B→A를 1회로 계산한다.
- 동일 task에서 3회 연속 왕복해야 PASS다.
- 화면 표시만 성공하거나, task 내용을 복사하거나, 새 task를 만들거나, fork하는 것은 실패다.
- B에서 account/task ownership 구조 때문에 동일 task를 열거나 메시지를 보낼 수 없다면 **즉시 Spike NO-GO이며 제품 구현을 중단한다.** 복사 기반 우회 제품으로 전환하지 않는다. helper·이메일·process 구현 실패는 수정 후 전체 3-cycle을 다시 검증한다.
- 테스트 task에는 회사 코드, 실제 고객 데이터, 자격 증명, 내부 문서 등 민감정보를 넣지 않는다.

## 2. 범위와 비범위

### 범위

- 공식 Codex 앱 정상 종료 요청
- 잔존 Codex 프로세스와 독립 CLI/task 감지
- 종료 후 현재 `auth.json`의 최신 상태 보존
- 대상 인증의 원자적 설치
- 공식 앱 재실행
- App Server `account/read` 결과의 이메일 일치 확인
- 실패 시 이전 계정 자동 롤백
- 동일 task A↔B 3회 수동 실검증
- 토큰이 없는 진단 로그와 증거 수집

이 switch는 데스크톱 앱만의 계정을 바꾸는 기능이 아니다. 이 Mac의 기본 `~/.codex/auth.json`을 바꾸므로, 전환 후 새로 시작하는 기본 Codex CLI 세션에도 같은 활성 계정이 적용된다. 이미 실행 중인 CLI/task는 자동 변경하거나 종료하지 않고 process gate에서 차단한다.

### 비범위

- 계정별 대화·SQLite·설정·workspace 격리
- App Store 배포
- 사용량/리셋 시각 UI
- 3개 이상 계정의 UI 제공
- 앱 또는 CLI 강제 종료
- 대화 복제/fork를 이용한 우회
- 커스텀 `CODEX_HOME`

## 3. 용어와 식별자

- 계정 A: 최초 활성 계정. Spike 종료 시 복구할 기본 계정
- 계정 B: 전환 대상인 두 번째 계정
- 프로필 ID: `profile-a`, `profile-b` 같은 비밀이 아닌 내부 식별자
- 기대 이메일: 등록 시 App Server `account/read`가 반환한 이메일. 사용자가 입력한 별칭이 아니다.
- active auth: 현재 `~/.codex/auth.json`
- profile auth: Spike 전용 private credential store의 계정별 인증 blob. 제품 MVP에서는 같은 추상화의 backend가 macOS Keychain으로 바뀐다.
- source: 전환 전 계정
- target: 전환할 계정

문서, 테스트 데이터, 커밋, 로그에는 실제 이메일을 넣지 않는다. 예시는 `a***@example.test`, `b***@example.test`처럼 마스킹한다.

## 4. 안전 원칙

1. **프로세스가 살아 있는 동안 `auth.json`을 교체하지 않는다.** Codex가 종료 과정에서 갱신 토큰을 다시 기록할 수 있기 때문이다.
2. 공식 앱에는 정상 종료만 요청한다. `kill -9`, 강제 종료, 독립 CLI 자동 종료를 사용하지 않는다.
3. 잔존 Codex 프로세스가 하나라도 분류되지 않으면 교체를 차단한다.
4. 전환 직전 source 이메일이 등록값과 일치할 때만 최신 active auth를 source 프로필에 다시 저장한다.
5. target 설치는 같은 파일시스템에서 임시 파일 생성→권한 설정→flush→원자 rename 순으로 한다.
6. target 이메일 검증 전에는 전환 성공으로 표시하지 않는다.
7. 실패하면 source 인증을 복원하고 source 이메일까지 다시 검증해야 롤백 성공이다.
8. 인증 내용, 토큰, 쿠키, JWT, 전체 `auth.json`, 원문 명령줄은 로그에 기록하지 않는다.
9. Spike 비활성 profile auth는 repo 밖 전용 `0700` 디렉터리의 `0600` 파일로만 저장하고 종료 후 명시적으로 정리한다. 제품 MVP에서는 비활성 profile auth를 Keychain에 저장하며, 그때 persistent 평문은 active `~/.codex/auth.json` 하나뿐이다.
10. verifier용 auth 복사본은 helper가 만든 격리 임시 홈에 `0600`으로 잠깐 materialize하고 verifier 종료 직후 제거한다. 이를 두 번째 persistent active auth로 사용하지 않는다.
11. journal과 registry의 모든 write는 다음 side effect 전에 durable해야 한다.
12. journal이 malformed, torn 또는 schema 불일치이면 자동 삭제·추정하지 않고 STOP한다.

## 5. 사전조건

### 환경

- macOS 공식 Codex 앱이 `/Applications/Codex.app`에 설치되어 있다.
- 예상 bundle identifier는 `com.openai.codex`다. 실제 값이 다르면 STOP한다.
- 기본 인증 경로 `~/.codex/auth.json`만 사용한다.
- `CODEX_HOME` 환경변수나 별도 프로필 경로를 사용하는 세션은 종료한다.
- `auth.json`은 현재 사용자 소유의 일반 파일이어야 한다. symlink, directory, 다른 사용자 소유 파일이면 STOP한다.
- A와 B는 서로 다른 ChatGPT 로그인 이메일이어야 한다.
- 두 계정 모두 테스트 요청을 보낼 수 있는 상태여야 한다.
- 테스트용 비민감 workspace와 task 문구를 미리 준비한다.

### 호환성 preflight

인증을 변경하기 전에 읽기 전용으로 다음을 확인한다.

- Codex 앱 bundle identifier, 버전, build
- `~/.codex`와 `auth.json`의 존재, 소유자, 파일 종류, 권한
- 현재 App Server가 `account/read`를 지원하는지
- `account/read`가 현재 계정의 이메일을 반환하는지
- Helper가 소유한 App Server를 기본 홈 또는 격리 임시 홈에서 목적에 맞게 실행·종료할 수 있는지

공식 데스크톱 앱의 private Electron IPC에는 연결하지 않는다. Helper 소유 App Server에서 `account/read`를 안정적으로 호출할 수 없다면 인증 교체를 시작하지 않고 STOP한다.

`account/read`는 모델 프롬프트가 아니다. 이 호출 자체를 task 연속성이나 모델 사용량 검증으로 간주하지 않는다.

## 6. Spike용 안전 백업 준비

### 저장 위치

- 비활성 A/B profile auth는 repo 밖 Spike 전용 private directory에 저장한다.
- directory mode는 `0700`, 각 profile file은 `0600`이며 파일명에는 이메일 대신 opaque profile ID를 쓴다.
- credential directory 경로와 auth 원문은 로그·리포트에 남기지 않는다.
- journal과 registry는 인증 blob이 없는 `0600` 파일이다.
- 제품의 영구 저장 설계와 달리 Spike 동안에는 private profile file 두 개와 active `~/.codex/auth.json`이 존재한다. 이를 제품 저장 방식으로 오해하지 않는다.
- 격리 verifier용 임시 홈과 auth 복사본은 각각 `0700`, `0600`으로 만들고 verifier 종료 후 제거한다.
- 로그에는 auth나 실제 이메일을 넣지 않는다.

### 원본 보존

초기 A를 등록하기 전 다음 상태를 보존한다.

- active auth의 byte-for-byte Spike private store 저장본
- 파일 mode와 소유자
- A의 기대 이메일을 secret-free registry에 저장하되 출력·로그에서는 마스킹
- 앱 버전/build
- 복구 기준 profile ID가 A인 durable registry 상태

인증 blob 유효성은 내용을 출력하지 않고 다음만 확인한다.

- 읽을 수 있는 JSON인지
- 비어 있지 않은지
- 복사 후 원본과 byte-for-byte 동일한지
- private store의 atomic write가 성공했고 다시 읽은 bytes가 원본과 동일한지

JWT를 디코딩하거나 token field를 로그에 출력해 신원을 추정하지 않는다. 신원은 App Server 응답으로만 확인한다.

## 7. 계정 등록

### 7.1 A 등록

1. 공식 Codex 앱이 A로 로그인된 상태인지 확인한다.
2. App Server `account/read`로 이메일을 읽는다.
3. 반환값이 없거나 예상한 A가 아니면 등록하지 않는다.
4. helper의 정상 종료 요청을 사용해 앱을 닫는다.
5. 종료 제한 시간 동안 기다린다.
6. 프로세스 게이트를 통과한 뒤 기본 `~/.codex`를 사용하는 Helper 소유 verifier에서 `account/read(refreshToken: true)`로 A 이메일을 다시 확인한다.
7. verifier가 갱신한 최신 active auth를 Spike private store의 `profile-a` 파일에 durable하게 저장한다.
8. JSON 가독성과 private-store round-trip 동일성을 확인한다.
9. A의 기대 이메일과 등록 완료 상태를 registry에 원자적으로 기록하고 durability를 확인한다.

예정 인터페이스 예시:

```text
[예정 인터페이스] switcher register-current --profile profile-a
```

### 7.2 B 등록

초기 Spike에서는 별도 `CODEX_HOME` 기반 자동 로그인을 구현하지 않는다. A를 먼저 안전하게 보존한 후 공식 Codex 로그인 흐름으로 B를 로그인하고 캡처한다.

1. `profile-a`가 완전하고 복구 가능함을 먼저 확인한다.
2. Codex 앱과 독립 Codex 프로세스가 모두 종료된 상태를 확인한다.
3. 사용자가 공식 interactive login 흐름으로 B에 로그인한다. 정확한 호출 방식은 당시 공식 앱/CLI 동작을 preflight한 뒤 사용한다.
4. 로그인 프로세스가 완전히 종료된 후 기본 `~/.codex`를 사용하는 Helper 소유 verifier의 `account/read(refreshToken: true)`로 B 이메일을 확인한다.
5. B 이메일이 A와 같으면 등록을 거부한다.
6. active auth를 Spike private store의 `profile-b` 파일에 durable하게 저장하고 JSON 가독성·round-trip 동일성을 확인한다.
7. 즉시 A 인증을 원자적으로 복구한다.
8. 복구된 active auth를 격리 임시 홈에 복사하고 Helper 소유 verifier의 `account/read(refreshToken: false)`로 A 이메일인지 확인한다.
9. registry의 active profile A를 durable하게 확인·기록하고 등록 journal을 durable delete한다.
10. 위 정리가 끝난 후에만 공식 앱을 A로 재실행한다.
11. A 복구까지 성공해야 B 등록을 완료로 기록한다.

예정 인터페이스 예시:

```text
[예정 인터페이스] switcher register-second --profile profile-b --restore profile-a
```

등록 중 사용한 공식 로그인 프로세스는 controlled exception이다. 캡처나 교체 전에는 반드시 종료되어야 하며, 이후 잔존하면 프로세스 게이트가 차단한다.

### 외부 로그인 감지

현재 `account/read` 이메일이 등록된 A/B 어느 쪽과도 일치하지 않으면 자동 저장하거나 덮어쓰지 않는다.

- 상태: `unregistered account detected`
- 허용 사용자 결정: 새 계정으로 명시 등록 또는 현재 변경 폐기 후 알려진 프로필 복구
- 자동 행동: 없음
- 이메일을 추측해 가까운 프로필과 연결하지 않는다.

## 8. 앱 정상 종료와 잔존 프로세스 게이트

### 정상 종료

- 실행 중인 공식 앱에 bundle identifier 기반 정상 종료를 요청한다.
- 사용자가 전환 확인을 취소하면 auth는 변경하지 않는다. 이미 `preparing` journal을 만들었다면 journal을 unlink하고 parent directory를 fsync해 취소를 durable하게 끝낸다.
- 설정된 제한 시간까지 앱과 helper process 종료를 기다린다.
- 제한 시간 초과 시 전환을 차단하고 사용자가 직접 종료하도록 안내한다.
- 강제 종료 버튼은 MVP에 두지 않는다.

### 프로세스 분류

단순히 프로세스 이름만 검색하지 않는다. 다음 정보를 조합한다.

- executable path
- parent/child 관계
- bundle executable 및 helper path
- PID
- working directory(사용자에게만 표시; 진단 로그에는 민감 경로를 남기지 않음)
- helper가 직접 띄운 verifier PID

Spike 기본 allow-list는 비어 있으므로, 최초에는 모든 앱 소유·bundle 내부 resident가 종료된 상태만 허용한다. `browser_crashpad_handler`는 별도 실증으로 auth 비관여가 확인되고 exact signed bundle path와 executable name 조합이 승인된 뒤에만 `approvedNonAuthResident`로 **blocker 집합 계산 전에** 제외할 수 있다. 경로·서명·이름 중 하나라도 다르면 차단한다. helper 소유의 단기 verifier가 있다면 명시적으로 닫고 PID 종료를 확인한다.

### 독립 CLI/task

공식 앱 종료 후에도 Codex CLI, app-server, 실행 중 task가 남아 있으면 다음처럼 처리한다.

- PID와 working directory를 사용자에게 표시한다.
- 자동 종료하지 않는다.
- auth 교체를 시작하지 않는다.
- 사용자가 해당 작업을 정상 종료한 후 다시 검사한다.

프로세스의 성격을 분류하지 못해도 안전 쪽으로 차단한다.

## 9. 원자적 auth 교체 계약

예정 persisted journal phase:

```text
preparing
→ quitRequested
→ quiescent
→ refreshingCurrent
→ currentSaved
→ validatingTarget
→ targetValidated
→ authReplaced
→ targetLaunched
→ verifyingTarget
→ targetVerified
```

롤백 phase는 `rollbackStarted`, 자동 복구 불능 phase는 `rollbackFailed`다. `committed`, `rolledBack`, `blocked`, `cancelled`는 진단/UI 상태일 수 있지만 persisted journal phase가 아니다.

### journal 고정 schema

journal에는 다음 7개 필드만 둔다.

```text
schemaVersion
transactionId
phase
previousProfileId
targetProfileId
startedAt
updatedAt
```

build, email, label, plan, auth, token, error 원문을 journal에 넣지 않는다. 필드 누락·추가, 알 수 없는 phase, parse 실패, torn write는 모두 STOP이다.

### journal·registry durable write

journal과 registry의 신규 생성·갱신은 항상 다음 순서다.

1. 대상 파일과 같은 directory에 새 temp file을 만든다.
2. temp mode를 `0600`으로 제한한다.
3. 전체 JSON을 기록한다.
4. temp file을 `fsync`한다.
5. temp를 최종 경로로 원자 rename한다.
6. parent directory를 `fsync`한다.

여섯 단계가 모두 성공한 뒤에만 다음 side effect를 시작한다. phase를 메모리에서 바꾸거나 temp에 쓰기만 한 것은 persisted transition이 아니다.

- 성공: `targetVerified` journal이 durable한 상태에서 registry의 active profile을 target으로 durable하게 쓴다. 그 뒤 journal을 unlink하고 parent directory를 fsync한다.
- 취소/차단: active auth를 건드리기 전이면 기존 계정을 유지하고 journal을 unlink한 뒤 parent directory를 fsync한다.
- journal unlink 또는 그 뒤 parent fsync 실패: 완료로 표시하지 않는다. 다음 시작에서 journal 존재 여부, registry, active 이메일을 함께 재판정한다.
- registry write 실패: journal을 삭제하지 않고 target 또는 source의 검증 가능한 상태에서 복구한다.

### 설치 절차

1. 전환 lock을 획득해 동시에 두 switch가 실행되지 않게 한다.
2. `preparing` journal을 durable하게 만든다.
3. source 이메일이 registry 등록값과 정확히 일치하는지 읽기 전용으로 확인한다. 실패하면 auth mutation 없이 journal을 durable delete한다.
4. 사용자에게 앱 종료 확인을 받는다. 취소하면 auth mutation 없이 journal을 durable delete한다.
5. `quitRequested`를 durable하게 기록한 뒤 공식 앱에 정상 종료를 요청한다.
6. 앱·자식·독립 Codex process가 모두 안전한 상태인지 확인한다.
7. 차단되면 auth mutation 없이 journal을 durable delete하고 종료한다.
8. `quiescent`를 durable하게 기록한다.
9. `refreshingCurrent`를 **먼저 durable하게 기록한 뒤** 기본 `~/.codex`를 사용하는 Helper 소유 App Server를 시작한다.
10. `account/read(refreshToken: true)`로 active auth를 제자리 갱신하고 source 이메일을 다시 확인한다.
11. Helper 소유 App Server PID 종료를 확인한다.
12. 갱신된 active auth를 source profile의 Spike private store에 durable하게 저장한다.
13. `currentSaved`를 durable하게 기록한다.
14. `validatingTarget`을 **먼저 durable하게 기록한다.**
15. target private-store blob을 격리 임시 홈에 복사하고 Helper 소유 App Server에서 `account/read(refreshToken: false)`를 호출해 identity를 사전 확인한다.
16. 사전 확인 이메일이 target 등록값과 같을 때만 같은 격리 홈에서 `account/read(refreshToken: true)`를 호출해 token 유효성과 refresh 가능성을 확인한다.
17. 두 응답의 이메일이 모두 target 등록값과 같아야 한다.
18. refresh된 target blob을 target profile의 Spike private store에 durable하게 저장한 뒤 격리 verifier와 임시 홈을 제거한다.
19. `targetValidated`를 durable하게 기록한다.
20. `~/.codex/auth.json`이 현재 사용자 소유 일반 파일이며 symlink가 아님을 다시 확인한다.
21. 검증·갱신된 target bytes를 `~/.codex`의 `0600` temp에 기록하고 file fsync→원자 rename→parent fsync한다.
22. 설치 bytes가 target과 동일한지 내용 출력 없이 확인한다.
23. `authReplaced`를 durable하게 기록한다.
24. 공식 Codex 앱을 실행하고 `targetLaunched`를 durable하게 기록한다.
25. 앱 readiness 후 `verifyingTarget`을 durable하게 기록한다.
26. 현재 active auth를 helper의 격리 임시 홈에 `0600`으로 복사한다.
27. Helper 소유 App Server에서 `account/read(refreshToken: false)`를 호출한다. 공식 앱의 private IPC는 사용하지 않는다.
28. 반환 이메일이 target 등록값과 정확히 일치하면 `targetVerified`를 durable하게 기록한다.
29. registry의 active profile을 target으로 durable하게 쓴다.
30. journal을 unlink하고 parent directory를 fsync한다.
31. verifier·임시 홈을 제거하고 lock을 해제한다.

예정 인터페이스 예시:

```text
[예정 인터페이스] switcher switch --to profile-b
```

`authReplaced` 전 target 검증 실패는 active auth를 바꾸지 않는다. profile은 보존한다. identity mismatch 또는 명시적 authentication/revocation 실패면 `re-login required`로 표시한다. timeout, DNS, offline 등 network 실패는 retryable error이며 token revoked로 단정하지 않는다.

`refreshingCurrent`에서 Helper App Server를 시작한 뒤에는 같은 source 계정이라도 active bytes가 갱신됐을 수 있다. 이후 오류는 journal을 단순 삭제하지 않는다. `rollbackStarted`를 durable하게 기록하고, 마지막 durable source private-store blob 또는 이메일 검증을 마친 새 source blob을 active에 원자 반영한 뒤 source 이메일을 확인한다.

`currentSaved` 뒤 target 검증이 실패해도 target active 교체는 없지만 current refresh mutation은 이미 있었다. active source와 current private-store blob의 일치·source 이메일·registry previous를 확인한 뒤 `rollbackStarted` 복구 경로로 transaction을 닫고 journal을 durable delete한다.

active auth rename 전 write·fsync·rename이 실패하면 기존 active auth를 유지한다. rename 이후 실패는 journal을 `rollbackStarted`로 durable하게 바꾼 뒤 source 복구 절차로 간다.

### 이메일 비교

- 등록 시와 전환 후 모두 `account/read`의 반환값을 사용한다.
- 사용자가 입력한 label이나 plan 이름을 신원으로 쓰지 않는다.
- 임의로 도메인 alias, `+tag`, local-part 대소문자를 정규화하지 않는다.
- 등록 시 저장한 API 반환 문자열과 전환 후 API 반환 문자열을 그대로 비교한다. 공백 제거·대소문자 변환 같은 보정은 하지 않는다.
- mismatch, null, logged-out 상태는 모두 실패다.

### 특수 UX

- 이미 활성인 계정 카드를 누르면 auth를 다시 쓰거나 앱을 재시작하지 않고 Codex 창만 활성화한다.
- Codex 앱이 이미 닫혀 있으면 종료 확인을 생략하되 잔존 프로세스 게이트는 수행하고, 교체 후 앱을 실행한다.

## 10. App Server 검증 계약

예정 client는 Helper가 직접 시작하고 PID를 추적하는 App Server만 사용한다. 공식 데스크톱 앱의 private Electron IPC에는 연결하지 않는다. protocol 초기화, readiness 신호, timeout 값은 구현 Spike에서 측정해 확정한다.

| 목적 | 홈 | 호출 | persistent auth 영향 |
|---|---|---|---|
| 떠나는 current 최신화 | 기본 `~/.codex` | `account/read(refreshToken: true)` | active를 갱신한 뒤 source Spike private store에 저장 |
| target identity 사전 확인 | 격리 임시 홈 | `account/read(refreshToken: false)` | 없음 |
| target 유효성·refresh 확인 | 같은 격리 임시 홈 | `account/read(refreshToken: true)` | refresh blob을 target Spike private store에 durable 저장 |
| 재실행 후 target 확인 | active auth를 복사한 격리 임시 홈 | `account/read(refreshToken: false)` | 없음 |

검증 성공 조건:

- 프로토콜 초기화 성공
- `account/read` method 지원
- account 존재
- email field 존재
- email이 target 기대값과 일치
- verifier process/socket이 정상 정리됨
- 격리 임시 홈이 제거됨

다음은 성공으로 인정하지 않는다.

- UI label만 target처럼 보임
- plan 종류만 일치
- `auth.json`의 token payload를 자체 해석한 결과
- rate limit 응답만 성공
- 앱이 launch됐지만 이메일 확인 불가

Helper 소유 verifier를 안전하게 실행·종료할 수 없다면 STOP한다. private Electron 상태나 비공식 IPC를 fallback으로 사용하지 않는다.

## 11. 동일 task A↔B 3회 수동 실검증

### 11.1 테스트 데이터

- 새 비민감 workspace를 사용한다.
- task 제목에는 테스트용 무작위 식별자만 쓴다.
- prompt에는 실제 개인정보, 회사명, 저장소 비밀을 넣지 않는다.
- 각 메시지는 `cycle-0-a`, `cycle-1-b` 같은 공개 가능한 nonce를 포함한다.

### 11.2 동일성 증명

가능하면 공식 App Server가 제공하는 동일 task/thread ID를 기록한다. ID는 opaque value로 취급한다.

PASS에는 다음이 모두 필요하다.

- 전환 전후 ID가 동일
- create, copy, import, duplicate, fork 동작이 없음
- 하나의 연속된 message history에 A와 B의 실제 요청·응답이 축적됨
- 각 요청이 완료 상태에 도달함

안정적인 ID를 관찰할 방법이 없다면 제목만 보고 PASS 처리하지 않는다. 해당 run은 `INCONCLUSIVE/STOP`이며 증명 방법을 먼저 마련한다.

### 11.3 기준선

1. A 활성 이메일을 App Server로 확인한다.
2. 이 검증 run에서 사용할 새 task를 **정확히 한 번만** 만든다.
3. `cycle-0-a`를 포함한 실제 메시지를 보내고 응답 완료를 확인한다.
4. task ID와 비민감 message sequence를 기록한다.

### 11.4 1회 왕복

1. A→B 전환을 실행한다.
2. B 이메일 검증 성공을 확인한다.
3. 공식 앱에서 기준선과 **동일한 task**를 연다.
4. task ID가 기준선과 동일한지 확인한다.
5. `cycle-N-b` 메시지를 보내고 실제 응답 완료를 확인한다.
6. B→A 전환을 실행한다.
7. A 이메일 검증 성공을 확인한다.
8. 같은 task ID를 다시 연다.
9. `cycle-N-a` 메시지를 보내고 실제 응답 완료를 확인한다.
10. 단일 history에 해당 cycle의 A/B 메시지와 응답이 모두 있는지 확인한다.

### 11.5 반복

- 위 절차를 `N=1`, `N=2`, `N=3`으로 연속 실행한다.
- 같은 run 안에서 task를 추가 생성하지 않는다. 세 cycle 모두 기준선의 한 task ID를 사용한다.
- 각 전환마다 앱 정상 종료, process gate, target 이메일 검증을 생략하지 않는다.
- 3회 종료 후 활성 계정은 A여야 한다.

helper 구현, 이메일 verifier, process classifier, 앱 launch, network 같은 비구조적 실패는 해당 case를 FAIL/FIX-AND-RETEST로 처리한다. 수정 후 cycle 중간에서 이어 세지 않고, 새 clean run의 기준선부터 전체 3-cycle을 다시 실행한다. 새 run에서는 다시 task 하나만 만든다.

### 11.6 구조적 same-task NO-GO

- B에서 task가 보이지 않음
- 접근 권한 오류
- 동일 ID를 열 수 없음
- 메시지 전송 시 task ownership/account 오류
- 앱이 조용히 새 ID를 생성
- local history만 보이고 B 요청이 task ownership/account 경계 때문에 실패
- A 복귀 후 B 메시지가 같은 history에 없음

이 중 하나라도 발생하면 구조적 same-task 실패다. 증거를 보존하고 source를 복구한 뒤 즉시 Spike NO-GO로 판정하고 제품 구현을 중단한다. 단순 network timeout, 이메일 verifier 결함, process 오분류는 이 목록에 넣지 않고 FAIL/FIX-AND-RETEST로 분리한다.

## 12. 실패와 자동 롤백

### 롤백 트리거

- target auth 설치 실패
- 앱 launch 또는 readiness timeout
- App Server 초기화 실패
- `account/read` 실패/null
- target 이메일 mismatch
- 예상하지 못한 앱 종료
- valid journal이 active replacement 이후 실패를 가리킴

malformed/torn/schema 불일치 journal은 롤백 대상을 추정할 수 없으므로 자동 롤백 트리거가 아니라 즉시 STOP 조건이다.

`validatingTarget` 중 identity mismatch, token 만료·폐기·로그아웃이 확인되면 아직 active auth를 target으로 바꾸지 않았으므로 target 교체 rollback은 필요 없다. active source와 registry previous를 유지하고 target profile을 보존한 채 `re-login required`로 표시한다. network 실패는 revocation으로 분류하지 않고 retryable failure로 끝낸다.

### 롤백 순서

1. `rollbackStarted`를 durable하게 기록한다.
2. 새로 시작한 verifier를 정상 종료한다.
3. 새로 실행한 Codex 앱에 정상 종료를 요청한다.
4. 잔존 프로세스 게이트를 확인한다.
5. source profile의 Spike private-store blob을 active auth의 원자 설치 절차로 복원한다.
6. active auth를 격리 임시 홈에 복사하고 Helper 소유 verifier의 `account/read(refreshToken: false)`로 source 이메일 일치를 확인한다.
7. registry의 active profile을 previous profile로 durable하게 유지·복구한다.
8. 비밀 없는 `rolledBack` 진단 event를 기록한다.
9. journal을 unlink하고 parent directory를 fsync한다.
10. 위 durable cleanup이 모두 끝난 후에만 공식 앱을 source 계정으로 다시 실행한다.
11. target profile은 삭제하지 않고 오류 종류에 맞는 상태를 표시한다.

target token이 명시적으로 만료·폐기된 경우 자동 삭제하지 않고 `re-login required`로 둔다. network 오류만으로 token이 폐기됐다고 표시하지 않는다. 사용자가 명시적으로 다시 로그인할 때만 교체한다.

### 롤백 자체가 실패한 경우

다음 순서를 정확히 지킨다.

- 더 이상 auth를 반복해서 교체하지 않는다.
- 앱을 재실행하지 않는다.
- 보존된 source profile auth를 유지한다.
- 가능하면 `rollbackFailed`를 durable하게 기록하고 journal과 마스킹 진단을 보존한다.
- 사용자에게 수동 복구 필요 상태를 명확히 표시한다.
- 어떤 계정이 활성일지 추측하지 않는다.

target 앱을 종료할 수 없어 process gate를 통과하지 못한 경우에도 파일을 덮어쓰지 않고 STOP한다.

## 13. crash/reboot 복구

journal은 §9의 고정 7필드만 가진다: `schemaVersion`, `transactionId`, `phase`, `previousProfileId`, `targetProfileId`, `startedAt`, `updatedAt`. build, email, secret은 금지한다.

재시작 시 journal을 읽기 전에 transaction lock을 획득한다. JSON parse 실패, 지원하지 않는 `schemaVersion`, 누락·추가 필드, torn content, 알 수 없는 phase는 자동 복구하지 않고 STOP한다.

재시작 시 예정 동작:

- journal 없음: 미완료 transaction 없음
- `preparing`~`quiescent`: process 상태와 active source 이메일을 확인한다. source가 맞으면 journal을 durable delete해 안전 취소하고, 원래 앱 실행 상태를 journal에 저장하지 않으므로 앱은 자동 재실행하지 않는다.
- `refreshingCurrent`: refresh가 실행됐는지 추측하지 않는다. process gate 후 안전하면 기본 홈 Helper App Server의 `refreshToken: true`와 source private-store save를 idempotent하게 완료하고, 그렇지 않으면 마지막 durable source private-store blob을 active에 복원한다. source 이메일·registry previous를 확인한 뒤 전환을 안전 취소한다. 둘 다 실패하면 `rollbackFailed` 후 STOP한다.
- `currentSaved`: durable source private-store blob을 active에 반영·검증하고 journal을 durable delete해 안전 취소한다.
- `validatingTarget`: 남은 verifier와 임시 홈을 정리하고 source active·registry previous를 확인한 뒤 전환을 안전 취소한다. 이미 갱신된 target private-store blob은 보존하되 forward switch를 재개하지 않는다. network 오류를 revoked로 바꾸지 않는다.
- `targetValidated`: active가 source인지 target인지 격리 verifier로 확인한다. source면 안전 취소하고, target이면 source rollback한다. 어느 쪽도 아니면 STOP한다.
- `authReplaced`: target launch를 재개하지 않는다. 앱이 우연히 실행됐는지도 확인해 정상 종료한 뒤 source rollback한다.
- `targetLaunched`~`verifyingTarget`: target 앱을 정상 종료한 뒤 source 롤백
- `targetVerified`: active target 이메일을 격리 verifier로 다시 확인한다. registry가 previous면 target으로 durable commit하고, 이미 target이면 중복 write 없이 확인한다. 그 뒤 journal을 unlink하고 parent directory를 fsync한다. 불명확하면 source rollback한다.
- `rollbackStarted`: source 복구·source 이메일 검증·registry previous durable write·journal durable delete를 idempotent하게 완료한 뒤 source 앱을 실행
- `rollbackFailed`: 자동 새 전환 금지, 수동 복구만 허용

복구 로직도 각 mutation 전 process gate를 통과해야 한다. journal phase만으로 active auth를 추정하지 않으며 journal, registry, active 이메일이 해소할 수 없이 모순되면 STOP한다.

## 14. Codex 업데이트 대응

앱 build가 마지막 성공 run과 달라지면 사용자에게 호환성 재검증 경고를 보여준다.

즉시 차단 조건:

- bundle identifier 변경
- `auth.json` 기본 경로 또는 파일 성격 변경
- 기존 auth blob이 새 버전에서 읽히지 않음
- App Server 초기화 또는 `account/read` contract 변경
- 프로세스 구조를 안전하게 분류할 수 없음

기본 구조가 유지되면 guarded attempt를 한 번 허용할 수 있다. target 검증 실패 시 즉시 자동 롤백한다. 업데이트 직후 첫 성공을 근거로 안전 검사를 영구 생략하지 않는다.

## 15. 증거와 로그

### 진단 로그 허용 항목

- timestamp
- transaction/case ID
- Codex version/build
- source/target opaque profile ID
- 마스킹 이메일
- switch phase와 duration
- 결과 코드와 정제된 error category
- process gate의 PID 수

### 금지 항목

- 전체 또는 일부 access/refresh/id token
- JWT payload
- cookie, authorization header
- `auth.json` 원문
- 실제 전체 이메일
- raw App Server frame 중 인증 데이터
- 전체 shell command line
- 사용자 홈이나 회사 저장소를 노출하는 전체 working directory

### 동일 task 증거

- task ID 또는 그 동일성을 판정할 수 있는 공식 식별자
- cycle별 message nonce와 완료 여부
- 각 단계의 마스킹 active email
- 앱 build
- 전환/롤백 결과

스크린샷에 실제 이메일이나 민감 sidebar/task가 보이면 원본을 문서에 첨부하지 않는다. 먼저 로컬에서 가리고, 공개 가능한 테스트 task만 남긴다.

## 16. 종료·정리 절차

1. 마지막 활성 계정을 A로 전환한다.
2. App Server `account/read`로 A 이메일을 확인한다.
3. 앱을 한 번 정상 종료·재실행한 뒤에도 A가 유지되는지 확인한다.
4. 잔존 helper verifier와 임시 process가 없는지 확인한다.
5. secret-free 결과 보고서만 저장소에 남긴다.
6. raw screenshot과 임시 debug frame을 삭제한다.
7. Spike private credential directory에 A/B profile auth 외 예상하지 못한 파일이 없는지 확인한다.
8. Spike 종료 후 사용자의 명시적 cleanup으로 private profile file을 제거한다. 현재 로그인을 유지하는 active `~/.codex/auth.json`은 자동 삭제하지 않는다.
9. APFS에서는 일반 삭제가 안전 삭제를 보장하지 않음을 기록한다. token을 무효화하려면 별도의 공식 logout/revoke 절차가 필요하지만, 이는 사용자의 명시 결정 없이 실행하지 않는다.
10. 비밀 없는 최종 event를 기록한다. registry가 durable함을 확인한 뒤 journal을 unlink하고 parent directory를 fsync한 다음 transaction lock을 해제한다.

## 17. 실행 체크리스트

### 시작 전

- [ ] 비민감 테스트 task/workspace 준비
- [ ] A/B가 서로 다른 이메일임을 확인
- [ ] bundle ID, app version/build 기록
- [ ] default `~/.codex`만 사용
- [ ] `auth.json` 일반 파일·소유자·권한 확인
- [ ] App Server `account/read` preflight 성공
- [ ] Spike profile은 repo 밖 `0700` directory의 `0600` file이며 제품 backend는 Keychain으로 분리됨
- [ ] metadata directory `0700`, journal/registry/temp `0600`
- [ ] journal 고정 7필드와 atomic durability 확인
- [ ] A 백업과 자동 복구 가능성 확인

### 계정 등록

- [ ] A 이메일 검증 후 profile-a 저장
- [ ] 공식 로그인 흐름으로 B 등록
- [ ] B 이메일이 A와 다름
- [ ] profile-b 저장
- [ ] A 자동 복원·이메일 검증 후 재실행

### 매 전환

- [ ] source 이메일 일치
- [ ] 사용자 종료 확인
- [ ] 정상 종료 성공
- [ ] 독립 CLI/task 없음
- [ ] `refreshingCurrent` durable 후 source refresh·Spike private store 저장
- [ ] target 격리 false→true 검증·갱신본 Spike private store 저장
- [ ] 검증된 target 원자 설치
- [ ] 앱 재실행
- [ ] active auth 복사본의 격리 `refreshToken: false`로 target 이메일 일치
- [ ] registry durable commit 후 journal unlink+parent fsync
- [ ] verifier 정리

### 핵심 검증

- [ ] A 기준 task 실제 메시지 성공
- [ ] cycle 1 B 메시지→A 메시지, 같은 ID
- [ ] cycle 2 B 메시지→A 메시지, 같은 ID
- [ ] cycle 3 B 메시지→A 메시지, 같은 ID
- [ ] 복사/fork/새 task 없음
- [ ] 최종 활성 계정 A

### 종료

- [ ] 강제 실패 1회로 자동 롤백 검증
- [ ] A 재실행 유지 확인
- [ ] secret-free evidence만 보존
- [ ] 격리 verifier 임시 auth/home 잔존 0건
