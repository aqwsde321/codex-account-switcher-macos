# Codex Account Switcher 문서 인덱스

- 문서 상태: 기준안 완료
- 구현 상태: A/B capture·동기화·일반 switch·rollbackFailed 수동 복구 CLI 완료
- 실제 검증: A↔B 기능 왕복 3회, 수동 A 복구 2회, B-011 자동 롤백 PASS
- 제품 단계: ADR-027에 따라 `MenuBarExtra` MVP 개발 승인
- 마지막 조사일: 2026-07-30

## 1. 결론

만들 제품은 다음이다.

> 개인·회사 ChatGPT 로그인의 Codex 인증을 전환하는 별도 macOS 메뉴바 helper. 하나의 기본 `~/.codex`를 공유하고 계정별 인증 blob만 보관한다. 계정 선택 시 공식 Codex 앱 정상 종료 → 프로세스 안전 게이트 → `auth.json` 원자 교체 → 앱 재실행 → 이메일 검증을 수행한다.

재사용 가능한 Swift CLI Core와 실제 전환·롤백 검증은 완료됐다. cycle nonce와 단계별 task ID 기록이 없어 B-010 정식 PASS는 보류하지만, ADR-027에 따라 이 증거 형식 공백을 수용하고 메뉴바 MVP 개발을 시작한다. B-010 정식 증거는 MVP 완료·배포 전 확보한다.

공식 문서상 file 기반 `CODEX_HOME/auth.json` 복사·재사용과 자동 token refresh는 지원되는 패턴이다. 그러나 다음 제품 핵심은 문서만으로 보장되지 않는다.

> A가 만든 정확히 같은 Codex task를 B에서 열고 실제 메시지를 보낸 뒤, A로 돌아와 같은 task에서 다시 메시지를 보낼 수 있는가?

비민감 전용 task를 A에서 한 번만 만든 뒤, 같은 task ID로 A→B→A 왕복을 3회 연속 성공해야 제품을 계속 만든다. 동일 task 재개가 구조적으로 실패하면 Spike FAIL이며 메뉴바 앱 구현을 중단한다. task 복사·fork·요약 이관으로 우회하지 않는다.

## 2. 문서 목록

| 문서 | 역할 | 언제 읽나 |
|---|---|---|
| [01_product_requirements.md](01_product_requirements.md) | 제품 목적, 범위, UX, 기능·비기능 요구 | 제품 전체 파악 |
| [02_decision_record.md](02_decision_record.md) | 확정 결정, 이유, 기각 대안, 재검토 조건 | 모든 새 구현 task의 필독 문서 |
| [03_feature_flow.md](03_feature_flow.md) | 등록·전환·롤백·crash recovery 흐름과 상태 | orchestration 구현 전 |
| [04_spike_runbook.md](04_spike_runbook.md) | 실제 계정 Spike 사전조건과 순서 | 외부 Terminal 실검증 전 |
| [05_technical_design.md](05_technical_design.md) | Swift 구조, App Server, process, file transaction | Core 구현 전 |
| [06_security_and_recovery.md](06_security_and_recovery.md) | 위협 모델, 비밀 저장, 원자성, 실패별 복구 | auth 관련 코드 구현·리뷰 전 |
| [07_test_acceptance.md](07_test_acceptance.md) | Unit/Integration/Black-box 테스트와 Go/No-Go | 테스트 작성·Spike 판정 시 |
| [08_implementation_handoff.md](08_implementation_handoff.md) | 새 task 재개 prompt, 구현 순서, 현재 상태 | 구현을 실제로 재개할 때 |

## 3. 권장 읽기 순서

### 새 task에서 Swift CLI를 구현할 때

```text
00 → 02 → 03 → 05 → 06 → 07 → 04 → 08
```

### 제품/UX를 검토할 때

```text
00 → 01 → 02 → 03
```

### 실제 두 계정 Spike를 실행할 때

```text
00 → 04 → 06 → 07
```

### 장애·복구를 다룰 때

```text
06 → 03 → 05 → 07
```

## 4. source of truth

문서끼리 충돌하면 다음 우선순위를 적용한다.

1. 이후 사용자의 명시적 변경
2. `02_decision_record.md`
3. `03_feature_flow.md`, `06_security_and_recovery.md`
4. `05_technical_design.md`
5. `01_product_requirements.md`
6. Runbook과 테스트 문서
7. 최초 첨부 문서

최초 첨부보다 최종 grilling 결정이 우선한다.

## 5. 다시 논의하지 않을 확정 결정

- 편의 전환기이며 보안 격리 제품이 아님
- 공용 기본 `~/.codex`; `auth.json`만 전환
- 서로 다른 이메일의 ChatGPT 로그인 두 개
- MVP identity는 App Server `account/read` 이메일 완전 일치
- 사용량은 identity 검증 수단이 아님
- Swift CLI Spike가 먼저, 메뉴바 앱은 나중
- 신규 소형 Swift 프로젝트; Mobius 전체 포크 안 함
- 앱 정상 종료 우선, 1초 뒤 exact 앱 소유 잔존은 별도 확인 후 `SIGTERM`; `SIGKILL` 없음
- 독립 CLI/app-server 자동 종료 없음; 발견 시 차단
- 앱 실행 중 전환은 매번 사용자 확인
- 전환은 `flock` + secret-free journal + atomic rename
- 떠나는 현재 계정의 갱신된 인증을 이메일 일치 때만 저장
- 대상 저장 인증은 격리 홈에서 이메일 확인 후 refresh까지 성공한 최신본만 저장·적용
- CLI Spike 비활성 인증은 repo 밖 `0700`/`0600` private file store, 제품 비활성 인증은 macOS Keychain; 제품의 평문 활성 인증 한 개만 `~/.codex/auth.json`에 materialize
- 대상 실패 시 이전 계정 자동 롤백
- 롤백 검증 실패 시 공식 앱을 실행하지 않음
- MVP 등록은 개인·회사 두 개, 내부 모델은 배열
- 두 번째 등록 후 원래 계정 자동 복귀
- 이미 활성인 카드 클릭은 무변경 + 창 활성화
- 앱이 닫혀 있으면 전환 후 실행
- 외부 미등록 로그인은 자동 덮어쓰기 금지
- 만료·폐기 프로필 자동 삭제 금지
- 사용량 UI는 후속
- 동일 task A→B→A 실제 메시지 왕복 3회 필수
- 올바른 인증 전환 뒤 구조적 same-task ownership 실패 시 제품 중단; Helper 결함은 수정 후 전체 재검증

## 6. 검증된 사실과 미검증 가설

### 공식 문서로 확인

- Codex는 로그인 정보를 `~/.codex/auth.json` 또는 OS credential store에 캐시한다.
- file mode는 `CODEX_HOME/auth.json`을 사용한다.
- 공식 문서는 신뢰 장비 사이에서 `auth.json`을 복사하는 절차를 설명한다.
- managed ChatGPT token은 Codex가 자동 갱신한다.
- App Server는 인증 상태 조회와 `account/read(refreshToken: ...)`를 제공한다.
- ChatGPT account 응답은 이메일과 plan을 제공한다.

공식 문서가 file credential mode를 지원한다는 사실은 데스크톱 앱이 현재 `auth.json`만을 권위 저장소로 사용한다는 보장은 아니다. 현재 Mac에 `auth.json`이 존재하지만, 데스크톱 앱이 Keychain/Electron 상태보다 이 파일을 우선하는지는 실제 Spike에서 검증한다. Helper가 사용자 `config.toml`을 몰래 바꿔 file mode를 강제하지 않는다.

### 현재 Mac에서 읽기 전용 확인

| 항목 | 값 |
|---|---|
| 앱 | `/Applications/ChatGPT.app` |
| bundle id | `com.openai.codex` |
| version/build | `26.721.81911` / `5973` |
| main executable | `Contents/MacOS/ChatGPT` |
| bundled Codex | `Contents/Resources/codex` |
| Swift | `6.2.3` |
| 현재 auth file mode | `0600` |

현재 설치본은 signature/build hard gate를 통과해 `application=ready`이며 auth-changing 명령 실검증을 완료했다.

빈 임시 `CODEX_HOME`에서 App Server를 실측해 다음을 확인했다.

- LF-delimited JSON framing
- `initialize` response 후 `initialized` 필요
- `account/read` 지원
- response ID correlation 필요
- notification이 response 사이에 올 수 있음
- stdin을 너무 일찍 닫으면 disconnect race 발생

현재 앱 process tree에서 main app, Service/Renderer, bundled Codex, node/code-mode child, 재부모화된 crashpad를 관찰했다. 상세 분류는 `05_technical_design.md`를 따른다.

### 실제 계정 확인 결과

- A↔B 기능 왕복 3회에서 UI와 실제 메시지가 교체된 인증을 채택했다.
- 같은 task를 복사·fork 없이 계속 사용하고 최종 A로 복귀했다.
- `rollbackFailed` 상태의 수동 A 복구를 2회 완료했다.
- B-011 실패 주입은 source 자동 롤백과 최종 A 복귀를 완료했다.
- cycle nonce와 객관적 task ID 증거를 보존하지 않아 B-010 정식 PASS는 보류한다.

## 7. 최상위 안전 불변조건

1. 관련 process가 살아 있으면 auth를 쓰지 않는다.
2. 독립 CLI를 자동 종료하지 않는다.
3. 종료 대기 중 확인한 exact 앱 소유 잔존도 별도 사용자 확인 없이는 `SIGTERM`하지 않는다. `SIGKILL`은 금지한다.
4. 현재 이메일이 등록 프로필과 다르면 해당 프로필 저장본을 갱신하지 않는다.
5. 실제 auth/token/cookie/raw command line을 출력·로그·commit하지 않는다.
6. 저널 단계는 다음 side effect 전에 원자적·내구성 있게 기록한다.
7. 대상 이메일 검증 전 성공을 커밋하지 않는다.
8. 실패 시 이전 이메일 검증까지 완료해야 롤백 성공이다.
9. 롤백을 검증할 수 없으면 앱을 실행하지 않는다.
10. 실제 Spike는 비민감 가짜 task만 사용한다.
11. 실제 앱 종료·전환은 Codex 앱 내부 agent가 아니라 외부 Terminal에서 수행한다.

## 8. 다음 작업

Swift CLI Core의 비파괴 기반 구현은 저장소 루트에 있다. 빌드·테스트·현재 제한은 [프로젝트 README](../README.md)를 따른다.

1. 완료: SwiftPM Core/CLI/test harness
2. 완료: credential/file/journal/lock, App Server, bundle/process, 상태 머신
3. 완료: custom async harness의 fake fixture 78개 테스트와 `inspect`/`profiles list`/`profile capture`/`profile sync-active`/`switch`/`recovery status`/`recovery restore`
4. 완료: 공식 ChatGPT 앱의 OS signature와 고정 build 검증
5. 완료: A/B registration coordinator, B 등록 후 A 자동 복귀, 외부 Terminal confirmation gate
6. 개발 승인: 사용자 확인상 동일 task 기능 왕복 완료, `07_test_acceptance.md` §16 형식 증거는 릴리스 게이트로 유지
7. 다음: 기존 Core를 재사용하는 `MenuBarExtra` MVP

구현 상세와 각 단계 검증은 `08_implementation_handoff.md`에 있다.

## 9. 새 task 시작 prompt

```text
`docs/00_README.md`부터 연결된 문서를 읽어.
`02_decision_record.md`의 ADR-027과 기존 안전 결정을 유지하고,
`08_implementation_handoff.md` Step 9의 `CodexAccountMenuBar` MVP를 구현해.
검증된 Core를 재사용하고 실제 Codex 앱 종료와 auth.json 교체는
외부 Terminal 실행 게이트로 남겨둬. B-010 정식 증거는 릴리스 전 확보해.
```

## 10. 공식 근거

- [Codex Authentication](https://learn.chatgpt.com/docs/auth.md)
- [Codex App Server](https://learn.chatgpt.com/docs/app-server.md)
- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Open-source Codex App Server](https://github.com/openai/codex/tree/main/codex-rs/app-server)

공식 문서는 업데이트될 수 있다. 새 구현 task에서는 최신 문서를 다시 가져와 필요한 계약만 재확인한다.

## 11. 문서 변경 규칙

- 결정이 바뀌면 먼저 `02_decision_record.md`에 근거와 재검토 trigger를 기록한다.
- flow가 바뀌면 `03_feature_flow.md`, recovery가 바뀌면 `06_security_and_recovery.md`를 함께 갱신한다.
- 구현 제약이 바뀌면 `05_technical_design.md`와 `07_test_acceptance.md`를 함께 갱신한다.
- 동일 task FAIL gate는 사용자가 제품 목적 자체를 변경하지 않는 한 완화하지 않는다.
- 실제 계정 값과 인증값을 문서에 추가하지 않는다.
