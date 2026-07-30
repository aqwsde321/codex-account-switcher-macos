# Codex 계정 전환 기능 흐름

- 상태: Swift CLI Spike 범위 구현 완료, 메뉴바 앱 구현 전
- 기준일: 2026-07-28
- 대상: macOS 공식 Codex 앱용 별도 메뉴바 helper
- 선행 단계: Swift CLI Spike

## 1. 기능 요약

### 목적

한 Mac의 기본 `~/.codex`를 개인·회사 계정이 공유하면서, 인증 파일만 계정별로 보관하고 안전하게 전환한다.

전환의 핵심 순서는 다음과 같다.

1. 공식 Codex 앱 정상 종료
2. 앱 소유 프로세스 종료 확인
3. 독립 Codex CLI/app-server 존재 여부 확인
4. 현재 계정의 갱신된 인증 저장
5. 대상 인증 검증 및 `~/.codex/auth.json` 원자 교체
6. 공식 앱 재실행
7. App Server가 보고하는 이메일 확인
8. 성공 커밋 또는 이전 계정으로 자동 롤백

### 제품 성격

이 제품은 편의용 계정 전환기다. 계정 사이의 로컬 데이터 격리를 제공하지 않는다.

공유되는 범위에는 대화·task, session, SQLite, history, 설정, skills, MCP 설정, worktree와 기타 `CODEX_HOME` 상태가 포함될 수 있다. 회사 정책상 개인 계정으로 회사 task 내용을 보내면 안 되는 환경에서는 이 제품을 사용하면 안 된다.

### 진입 조건

- macOS에 공식 `/Applications/Codex.app` 또는 동일 bundle identifier의 앱이 설치돼 있다.
- MVP는 환경변수로 변경한 `CODEX_HOME`이 아니라 기본 `~/.codex`만 지원한다.
- 파일 기반 `auth.json`을 읽고 쓸 수 있다.
- ChatGPT 로그인 계정이며 App Server `account/read`가 이메일을 반환한다.
- 등록된 프로필은 최대 두 개다.

### 완료 조건

- 대상 이메일이 App Server 응답과 일치한다.
- 실제 공식 앱에서 동일 task를 열 수 있다.
- 해당 task에 대상 계정으로 실제 메시지를 보내 응답을 받을 수 있다.
- Spike에서는 A→B→A 왕복을 3회 연속 성공해야 한다.

올바른 인증 전환이 확인됐는데도 account/task ownership 구조 때문에 동일 task를 다른 계정에서 재개할 수 없으면 Spike NO-GO다. Helper·verifier·process 구현 실패는 수정 후 전체 검증을 다시 수행한다. 내용을 복사해 새 task를 만드는 우회는 제품 요구를 충족하지 않는다.

## 2. 사용자 유형 및 분기 기준

### 사용자 유형

| 유형 | 설명 | 권한/책임 |
|---|---|---|
| 로컬 사용자 | 개인·회사 계정을 가진 Mac 사용자 | 계정 등록, 전환 승인, 실제 task 검증 |
| Helper | Swift CLI Spike 또는 메뉴바 앱 | 프로세스 게이트, 인증 교체, 검증, 롤백 |
| 공식 Codex 앱 | bundle id `com.openai.codex`인 데스크톱 앱 | task UI, 자체 app-server와 인증 사용 |
| 독립 Codex 프로세스 | Terminal·IDE 등에서 별도로 실행된 CLI/app-server | 자동 종료 대상이 아니며 전환 차단 원인 |
| 회사 관리자/정책 | 관리형 workspace 정책의 소유자 | 로그인 방식·workspace·데이터 처리 제약 |

### 주요 분기 기준

| 조건 | 처리 |
|---|---|
| 대상이 현재 활성 프로필 | 인증을 다시 쓰거나 앱을 재시작하지 않고 Codex 창만 활성화 |
| Codex 앱 실행 중 | 항상 사용자에게 정상 종료 확인을 표시 |
| Codex 앱 이미 종료됨 | 종료 확인 없이 전환하고 성공 후 앱 실행 |
| 정상 종료 후 앱 소유 process가 남음 | 1초 뒤 별도 확인; 승인 시 exact identity에만 `SIGTERM` 1회, 거부·잔존 시 중단 |
| 독립 CLI/app-server가 존재함 | PID와 가능한 작업 경로를 보여주고 전환 차단 |
| 현재 이메일이 활성 등록 프로필과 다름 | 외부 로그인 변경으로 간주하고 전환 차단 |
| 현재 이메일이 미등록 이메일 | 명시적 등록 또는 변경 폐기 중 하나를 사용자가 선택해야 함 |
| 대상 토큰 만료·폐기 | 이전 계정으로 롤백, 대상 프로필 유지, 재로그인 필요 표시 |
| 대상 이메일 불일치 | 새 앱을 정상 종료한 뒤 자동 롤백 |
| 롤백 검증 실패 | 앱을 실행하지 않은 안전 정지 상태 유지, 수동 복구 안내 |
| Codex 업데이트 감지 | 호환성 검사를 먼저 수행하고 경고 후 제한적으로 시도 |
| bundle/auth/App Server 계약 파손 | 즉시 차단; 인증 파일을 변경하지 않음 |

## 3. 전체 플로우 초안

```mermaid
flowchart TD
    A["사용자가 계정 카드 선택"] --> B{"현재 활성 계정인가?"}
    B -- "예" --> C["Codex 창 활성화"]
    B -- "아니오" --> D["파일 lock 획득"]
    D --> N["journal preparing 기록"]
    N --> E["호환성·현재 신원 검사"]
    E --> F{"Codex 앱 실행 중인가?"}
    F -- "예" --> G["정상 종료 확인"]
    G --> H["정상 종료 요청·1초 대기"]
    F -- "아니오" --> H2
    H --> H2{"exact 앱 소유 잔존이 있는가?"}
    H2 -- "아니오" --> I
    H2 -- "예" --> H3{"TERMINATE 승인?"}
    H3 -- "예" --> H4["SIGTERM 1회"]
    H4 --> I
    H3 -- "아니오" --> K
    I --> J{"독립 CLI 또는 잔존 앱 프로세스가 있는가?"}
    J -- "예" --> K["인증 무변경·전환 차단"]
    J -- "아니오" --> L["현재 토큰 갱신·현재 프로필 저장"]
    L --> M["대상 인증을 격리 홈에서 사전 검증"]
    M --> O["auth.json 원자 교체"]
    O --> P["공식 Codex 앱 실행"]
    P --> Q["대상 이메일 검증"]
    Q --> R{"일치하는가?"}
    R -- "예" --> S["activeProfile 커밋·journal 삭제"]
    R -- "아니오" --> T["새 앱 정상 종료"]
    T --> U["이전 auth 원자 복구"]
    U --> V["이전 이메일 검증"]
    V --> W{"복구 성공인가?"}
    W -- "예" --> X["이전 계정 앱 재실행·실패 보고"]
    W -- "아니오" --> Y["앱 미실행·수동 복구 안내"]
```

### 3.1 최초 계정 등록

1. Helper가 앱 설치 위치, bundle id, 버전, build, bundled Codex 실행 파일을 확인한다.
2. 기본 `~/.codex/auth.json`의 존재, 일반 파일 여부, JSON 유효성, 권한을 검사한다.
3. 사용자가 앱 종료를 승인한다. 이미 종료됐다면 이 단계는 생략한다.
4. 공식 앱과 앱 소유 app-server가 모두 종료됐는지 확인한다.
5. 독립 Codex 프로세스가 있으면 중단한다.
6. Helper가 소유한 짧은 app-server로 `account/read(refreshToken: true)`를 호출한다.
7. 응답이 ChatGPT 계정이고 이메일이 존재하는지 확인한다.
8. 최신 `auth.json`을 첫 프로필에 저장한다.
   - Spike: 전용 비밀 디렉터리의 `0600` 파일
   - 제품: macOS Keychain
9. secret-free registry에 프로필 ID, 레이블, 이메일, plan 표시값, 생성 시각을 저장한다.
10. 최초 프로필을 활성 프로필로 설정하고 원래 실행 상태에 따라 앱을 다시 연다.

### 3.2 두 번째 계정 등록

1. 첫 프로필의 최신 인증이 안전하게 저장돼 있는지 확인한다.
2. 사용자가 명시적으로 두 번째 계정 추가를 시작한다.
3. 공식 `codex login` 또는 공식 로그인 UI로 다른 ChatGPT 계정에 로그인한다.
4. Helper가 활성 이메일이 기존 프로필과 다르고 아직 등록되지 않았음을 감지한다.
5. 자동 덮어쓰지 않고 다음 행동을 요구한다.
   - 새 프로필로 등록
   - 현재 외부 로그인 변경을 폐기하고 기존 프로필 복구
6. 등록을 선택하면 두 번째 프로필 인증을 검증·저장한다.
7. MVP의 2계정 제한을 적용한다.
8. 등록 완료 후 자동으로 원래 첫 계정으로 돌아간다.

후속 버전에서는 격리된 임시 `CODEX_HOME`의 App Server 로그인 흐름으로 두 번째 계정을 추가할 수 있다. 이 기능은 기본 전환 Spike가 통과한 뒤에만 추가한다.

### 3.3 일반 계정 전환

1. 사용자가 비활성 계정 카드를 선택한다.
2. Helper가 단일 전환 lock을 비차단 방식으로 획득한다.
3. crash recovery journal이 남아 있으면 새 전환보다 복구를 먼저 수행한다.
4. 새 journal을 `preparing`으로 기록한다.
5. 현재 앱 버전과 검증된 버전의 호환성을 확인한다.
6. 현재 활성 이메일이 registry의 활성 프로필 이메일과 일치하는지 확인한다.
7. 앱이 실행 중이면 정상 종료 확인을 표시한다.
8. journal을 `quitRequested`로 내구성 있게 갱신한 뒤 정상 종료를 요청한다.
9. 1초 뒤에도 남은 종료 전 확인된 exact 앱 소유 프로세스가 있으면 별도 확인을 표시하고, `TERMINATE` 승인 시에만 `SIGTERM`을 한 번 보낸다.
10. root 앱 PID, 기존 자식 PID, 독립 CLI/app-server를 포함한 전체 process gate가 깨끗하면 `quiescent`를 기록한다.
11. 차단 프로세스가 있으면 인증을 건드리지 않고 journal을 내구성 있게 삭제한 뒤 중단한다.
12. `refreshingCurrent`를 먼저 기록한 뒤 기본 `~/.codex`의 Helper 소유 App Server에서 `account/read(refreshToken: true)`를 호출한다.
13. verifier 종료와 현재 이메일 일치를 확인하고 갱신된 active auth를 현재 configured credential-store 항목에 저장한 뒤 `currentSaved`를 기록한다.
14. `validatingTarget`을 기록한 뒤 대상 저장본을 격리 홈에서 `refreshToken: false`로 신원 확인하고 이어서 `refreshToken: true`로 online refresh한다.
15. 두 응답이 대상 이메일과 완전 일치하고 verifier 종료와 갱신본의 configured credential-store 저장까지 성공하면 `targetValidated`를 기록한다. 실패하면 active auth를 바꾸지 않는다. 명시적 인증 거부만 `재로그인 필요`, 네트워크·서버 오류는 재시도 가능한 검증 실패, credential-store write 실패는 저장소 오류로 표시한다.
16. 이전 인증의 복구 가능성을 재확인하고, 같은 디렉터리의 임시 파일을 이용해 `~/.codex/auth.json`을 원자 교체한다.
17. journal을 `authReplaced`로 갱신한다.
18. 공식 앱을 bundle identifier로 다시 실행하고 journal을 `targetLaunched`로 갱신한다.
19. `verifyingTarget`에서 현재 active auth를 격리 verifier로 읽어 대상 이메일을 검증하고 일치하면 `targetVerified`로 갱신한다.
20. `activeProfileId`를 내구성 있게 대상 프로필로 커밋한 뒤 journal을 unlink하고 parent directory를 `fsync`한다.

### 3.4 전환 실패와 자동 롤백

`authReplaced` 이전 실패는 대상 rollback이 아니라 현재 계정 정상화다. `refreshingCurrent` 중 실패해 active auth가 손상·불명확하면 저장된 이전 blob을 복원하고 이전 이메일을 검증한다. 대상 검증·저장 실패처럼 active가 검증된 이전 계정인 경우 journal을 내구성 있게 삭제하고, 사용자가 전환 때문에 앱을 종료했다면 이전 계정으로 다시 실행한다.

1. 대상 앱이 시작됐다면 정상 종료를 요청한다.
2. 새 앱/app-server 프로세스가 완전히 종료됐는지 확인한다.
3. 독립 프로세스가 새로 나타났다면 파일 복구를 중지한다.
4. 이전 인증을 `auth.json`에 원자 복구한다.
5. 짧은 Helper 소유 app-server로 이전 이메일을 확인한다.
6. 이전 프로필 registry를 내구성 있게 커밋한다.
7. journal을 unlink하고 parent directory를 `fsync`한다.
8. 내구성 정리가 끝난 후에만 이전 계정으로 공식 앱을 재실행한다.
9. 대상 프로필은 삭제하지 않는다. 명시적 인증 거부일 때만 `재로그인 필요`, 그 밖의 실패는 원인에 맞는 재시도 상태로 유지한다.
10. 복구 어느 단계든 실패하면 공식 앱을 실행하지 않고 journal과 안전한 수동 복구 안내를 남긴다.

### 3.5 시작 시 crash recovery

1. Helper 시작 시 secret-free journal 존재 여부를 확인한다.
2. journal을 완전히 읽어 schema와 허용 phase를 검증한다. 잘리거나 모순된 저널이면 자동 쓰기 없이 STOP한다.
3. journal 단계와 현재 `auth.json`의 검증 가능한 이메일을 비교한다.
4. `refreshingCurrent`에서 중단됐다면 process gate 후 active auth가 이전 이메일로 유효한 경우 refresh를 다시 완료해 저장하고, 그렇지 않으면 저장된 이전 blob을 복원·검증한다. 어느 분기든 source를 정상화한 뒤 전환을 안전 취소한다.
5. `currentSaved` 또는 `validatingTarget`이면 source를 검증하고 전환을 안전 취소한다. `targetValidated` 이후 target 교체 가능성이 있으면 source rollback을 우선한다.
6. `targetVerified`와 active target이 모두 명백한 경우에만 registry의 target 커밋을 마무리한다.
7. 그 외에는 이전 프로필 복구를 우선한다. crash 후 `authReplaced`에서 target launch를 재개하는 forward recovery는 하지 않는다.
8. 어떤 이메일인지 검증할 수 없거나 프로세스가 남아 있으면 자동 쓰기를 하지 않는다.
9. 복구 실패 상태에서는 새 전환을 차단한다.

## 4. 상태 전이 초안

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> preparing: 비활성 프로필 선택
    preparing --> awaitingQuitConfirmation: 앱 실행 중
    preparing --> checkingProcesses: 앱 종료 상태
    awaitingQuitConfirmation --> quitting: 사용자 승인
    awaitingQuitConfirmation --> idle: 사용자 취소
    quitting --> checkingProcesses: 정상 종료 또는 승인된 SIGTERM 완료
    quitting --> blocked: SIGTERM 거부 또는 종료 실패
    checkingProcesses --> blocked: 잔존/독립 프로세스 발견
    checkingProcesses --> refreshingCurrent: 차단 프로세스 없음
    refreshingCurrent --> validatingTarget
    validatingTarget --> replacingAuth
    replacingAuth --> launchingTarget
    launchingTarget --> verifyingTarget
    verifyingTarget --> committed: 이메일 일치
    verifyingTarget --> rollingBack: 불일치/실패
    launchingTarget --> rollingBack: 실행 실패
    replacingAuth --> rollingBack: 교체 후 오류
    rollingBack --> rolledBack: 이전 이메일 검증 성공
    rollingBack --> rollbackFailed: 복구 실패
    committed --> idle
    rolledBack --> idle
    blocked --> idle: 원인 해소
    rollbackFailed --> recovering: 사용자 수동 복구
    recovering --> idle: 이전 계정 검증 성공
```

### 상태와 지속 여부

| 상태 | 디스크 journal | `auth.json` 변경 가능 | 앱 실행 가능 |
|---|---:|---:|---:|
| `idle` | 없음 | 아니오 | 예 |
| `preparing` | 있음 | 아니오 | 기존 상태 유지 |
| `quitting` | 있음 | 아니오 | 종료 중 |
| `blocked` | 오류 기록만 | 아니오 | 기존 인증이면 재실행 가능 |
| `refreshingCurrent` | 있음 | token refresh로 변경 가능 | 아니오 |
| `validatingTarget` | 있음 | 아니오 | 아니오 |
| `replacingAuth` | 있음 | 예 | 아니오 |
| `launchingTarget` | 있음 | 이미 변경됨 | 대상 앱만 |
| `verifyingTarget` | 있음 | 이미 변경됨 | 대상 앱 실행 중 |
| `committed` | 삭제 직전 | 대상 인증 | 예 |
| `rollingBack` | 있음 | 이전 인증으로 변경 | 검증 전에는 아니오 |
| `rollbackFailed` | 유지 | 불명확 | 아니오 |

## 5. 토큰·임시 저장 초안

### 공용 활성 인증

- 위치: `~/.codex/auth.json`
- 파일 권한: 정확히 `0600`을 목표로 한다.
- symlink, 디렉터리, group/other 쓰기 가능 파일은 거부한다.
- 파일 내용이나 토큰은 로그·리포트·오류 메시지에 포함하지 않는다.

### Spike 저장

- repo 및 결과 문서 디렉터리 밖의 전용 로컬 비밀 디렉터리를 사용한다.
- 디렉터리는 `0700`, 프로필 파일은 `0600`이다.
- Spike 종료 후 사용자가 명시적으로 정리할 수 있어야 한다.
- SHA-256, 크기, 수정 시각은 증거로 남길 수 있지만 인증 원문은 남기지 않는다.

### 제품 저장

- 계정별 인증 blob은 macOS Keychain에 저장한다.
- 디스크에는 활성 계정의 `~/.codex/auth.json`만 materialize한다.
- registry와 journal은 secret-free JSON이다.
- Keychain이 잠겼거나 접근이 거절되면 인증을 변경하지 않고 중단한다.

### token refresh 규칙

- 현재 계정에서 떠나기 직전에 `account/read(refreshToken: true)`를 사용한다.
- 반환 이메일이 활성 프로필과 일치할 때만 갱신된 `auth.json`을 저장한다.
- 대상 저장본은 격리 홈에서 `refreshToken: false`로 신원을 먼저 확인하고 `refreshToken: true`로 online refresh한다.
- 두 응답의 이메일이 대상과 일치하고 갱신된 blob의 configured credential-store 저장까지 성공한 경우에만 그 최신본을 적용한다.
- `refreshToken: false`는 신원 사전 확인일 뿐 폐기 여부를 증명하지 않는다. `true` 실패가 네트워크·서버 오류라면 token 폐기로 단정하지 않는다.
- 다른 이메일이 나오면 알려진 프로필을 자동 덮어쓰지 않는다.

### journal 최소 필드

```json
{
  "schemaVersion": 1,
  "transactionId": "UUID",
  "phase": "authReplaced",
  "previousProfileId": "UUID",
  "targetProfileId": "UUID",
  "startedAt": "RFC3339 timestamp",
  "updatedAt": "RFC3339 timestamp"
}
```

이메일, 토큰, 인증 JSON, 쿠키, raw command line은 journal에 저장하지 않는다.

persisted journal phase는 다음 이름으로 통일한다.

```text
preparing → quitRequested → quiescent → refreshingCurrent → currentSaved
→ validatingTarget → targetValidated
→ authReplaced → targetLaunched → verifyingTarget → targetVerified
```

롤백은 `rollbackStarted`, 자동 복구 불능은 `rollbackFailed`다. 성공 시 `targetVerified`에서 registry를 커밋한 뒤 journal을 삭제한다. 앞 절의 `idle`, `blocked`, `committed`, `rolledBack` 등은 UI/runtime 상태이며 persisted journal phase가 아니다.

### journal·registry 내구성

- 두 파일은 각각 같은 디렉터리의 `0600` 임시 파일에 완전히 쓴다.
- file `fsync` → atomic rename → parent directory `fsync`를 완료해야 해당 기록이 지속된 것으로 본다.
- phase 기록은 그 phase가 보호하는 다음 side effect보다 먼저 지속한다.
- 성공은 registry의 대상 커밋을 먼저 지속한 뒤 journal unlink → parent directory `fsync` 순으로 마친다.
- active auth 변경 전 취소·차단은 journal unlink → parent directory `fsync`로 안전 취소한다.
- write, `fsync`, rename, unlink 중 하나라도 실패하면 다음 side effect로 진행하지 않는다.

## 6. 기존 코드·공식 외부 응답 정합성 체크

### 공식 문서와 일치하는 부분

- Codex는 기본적으로 `~/.codex/auth.json` 또는 OS credential store에 로그인 정보를 캐시한다.
- file 저장 모드에서는 `CODEX_HOME/auth.json`을 사용한다.
- 공식 문서는 브라우저가 있는 장비의 `auth.json`을 다른 신뢰 장비로 복사하는 절차를 설명한다.
- ChatGPT managed 인증은 사용 중 토큰을 자동 갱신한다.
- App Server는 newline-delimited JSON을 사용하며 `initialize` 후 `initialized`가 필요하다.
- `account/read`는 `refreshToken` 옵션과 ChatGPT 이메일·plan 정보를 제공한다.

### 현재 설치본에서 확인된 부분

- 앱 경로: `/Applications/Codex.app`
- bundle identifier: `com.openai.codex`
- 표시 버전/build: `26.721.41059` / `5848`
- 메인 실행 파일: `Contents/MacOS/ChatGPT`
- bundled CLI: `Contents/Resources/codex`
- bundled CLI 버전: `codex-cli 0.146.0-alpha.3.1`
- App Server stdio는 LF-delimited JSON이고 `account/read`가 설치 스키마에 존재한다.
- 현재 기본 `~/.codex/auth.json`은 일반 `0600` 파일로 관찰됐다. 내용은 출력하지 않았다.

### 아직 실증되지 않은 핵심 가정

1. 완전 종료 후 `auth.json` 교체를 공식 앱이 새 로그인으로 채택하는가?
2. Electron/Chromium 상태가 이전 계정을 다시 덮어쓰지 않는가?
3. A가 만든 동일 task를 B가 열고 실제 메시지를 보낼 수 있는가?
4. B에서 다시 A로 돌아왔을 때 같은 task를 계속 사용할 수 있는가?

이 네 항목은 문서로 확정할 수 없으며 실제 계정 Spike가 유일한 통과 근거다.

## 7. 확인 필요한 핵심 엣지케이스

### Blocker

| 항목 | 판정 |
|---|---|
| 동일 task의 계정 간 실제 재개 | ownership 구조상 불가하면 Spike NO-GO 및 제품 구현 중단; Helper 결함은 수정 후 전체 재검증 |
| 앱 종료 뒤 app-server/helper 잔존 | 남으면 인증 변경 금지 |
| 대상/이전 이메일 검증 불가 | 성공 처리 금지 |
| 롤백 실패 | 앱 재실행 금지, 수동 복구 필요 |
| 관리 정책이 특정 workspace를 강제 | 해당 조합 전환 중단 |

### Important

| 항목 | 처리 |
|---|---|
| 토큰 회전 | 떠나는 현재 계정의 이메일을 확인한 뒤 최신 저장본 반영 |
| 외부 `codex login` | 미등록 이메일 자동 덮어쓰기 금지 |
| 앱 업데이트 | bundle/auth/App Server 계약 호환성 사전 검사 |
| 두 helper 동시 실행 | OS 파일 lock으로 하나만 허용 |
| 독립 CLI 중간 등장 | 파일 교체·롤백 전마다 재검사 |
| 이메일 대소문자·공백 | App Server가 등록 때 반환한 문자열과 완전 일치; 임의 정규화 없음 |

### Reference

- 사용량과 초기화 시각 표시는 후속 기능이다.
- 3개 이상 계정은 내부 배열 모델을 유지하되 MVP UI/등록은 2개로 제한한다.
- custom `CODEX_HOME`, App Store sandbox, 자동 업데이트는 MVP 범위 밖이다.

## 8. 다음 단계

이 문서의 flow에는 미확정 제품 선택이 없다. 남은 blocker는 실제 Spike 결과다.

다음 단계는 이 흐름을 기준으로 Swift CLI Spike를 구현하고, 실제 두 계정으로 black-box 검증하는 것이다. 메뉴바 앱 구현은 Spike가 통과한 뒤에만 시작한다.

플로우 문서를 기준으로 다음 단계는 별도 API 상세 리뷰입니다. 다만 이 제품은 신규 서버 API를 설계하지 않고 공식 App Server를 소비하므로 API 상세 리뷰를 생략하고, `05_technical_design.md`의 로컬 프로세스·파일 트랜잭션 구현 설계 검증으로 이어간다.
