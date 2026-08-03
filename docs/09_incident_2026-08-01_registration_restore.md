# 2026-08-01 추가 계정 복원 실패

## 결론

> 2026-08-03 후속 결정: ADR-032부터 정상 추가 등록은 이전 계정을 자동 복원하지 않고 새 등록 계정을 active로 유지한다. 아래 내용은 기존 자동 복원 계약에서 발생한 장애와 당시 수정 기록이다. 기존 `rollbackFailed` 복구 호환성은 유지한다.

B 추가 등록 뒤 저장된 A 인증은 이메일 판독에는 성공했지만 온라인 token refresh에는 실패했다. 기존 복원 코드는 A를 `refreshToken: false`로만 확인하고 반환 credential도 사용하지 않은 채 저장된 원본을 공용 `auth.json`에 썼다. 공식 Codex 앱은 이 A 인증으로 세션을 갱신하지 못해 로그아웃 상태로 열렸다.

수정 코드는 A를 격리 홈에서 `refreshToken: true`로 갱신하고, 성공한 동일 blob을 Keychain과 공용 `auth.json`에 순서대로 저장한다. 갱신 실패 시 공용 인증을 바꾸거나 Codex를 실행하지 않고 `rollbackFailed` 증거를 보존한다.

이 문서의 A/B는 사용자 계정의 익명 별칭이다. 이메일, profile UUID, token, credential 원문은 기록하지 않았다.

## 사용자 관찰 순서

1. A가 등록·활성인 상태에서 B를 추가 등록했다.
2. Keychain 비밀번호 요청이 반복돼 비밀번호 입력 후 `항상 허용`을 선택했다.
3. 추가 등록 뒤 공식 Codex 앱이 로그인되지 않은 상태로 열렸다.
4. 사용자가 공식 Codex 앱에서 B로 직접 로그인했다.
5. 메뉴바 앱은 A를 활성으로 표시했지만 실제 공용 인증은 B였다.
6. B 카드를 선택하자 source A 검증이 실패해 journal이 `quiescent`에 남았다.

5~6단계의 중단은 불일치한 인증을 덮어쓰지 않는 안전 동작이다. 장애의 시작점은 3단계다.

## 보존 상태와 시각

2026-08-01 KST 읽기 전용 확인 결과다.

| 시각 | 관찰 |
|---|---|
| 16:40:05 | 제품 registry 변경. 프로필 2개, 활성 표시는 A, 두 프로필 모두 `needsRelogin=false` |
| 16:41:24 | 공용 `~/.codex/auth.json` 변경. identity는 B |
| 16:41:47 | A→B 전환 journal 시작 |
| 16:41:48 | journal이 `quiescent`로 갱신된 뒤 중단 |

현재 제품 상태는 `registry=A`, `active auth=B`, `journal=quiescent`다. 진단과 소스 수정 중 제품 registry, 공용 auth, journal, Keychain item은 쓰지 않았다.

## 격리 진단

### 안전 조건

- 제품 Keychain의 A credential은 읽기만 했다.
- credential은 임시 `0700` CODEX_HOME의 `0600 auth.json`에만 복제했다.
- 공식 앱에 포함된 Codex App Server를 사용했다.
- `refreshToken: false`와 `refreshToken: true`를 분리 실행했다.
- 출력은 성공 여부와 파일 변경 여부만 허용했다.
- 임시 probe 코드와 디렉터리는 실행 직후 삭제했다.

### 결과

```text
stored_a_probe=completed
without_refresh=valid
with_refresh=invalid
credential_rotated=false
```

`without_refresh=valid`는 저장본에서 A identity를 읽을 수 있다는 뜻이다. `with_refresh=invalid`는 공식 App Server가 그 저장본으로 갱신된 A 세션을 만들지 못했다는 뜻이다. 따라서 identity-only 검사는 앱 재실행 가능성을 보장하지 않는다.

공식 UI의 로그아웃이 A refresh token을 폐기했을 가능성이 높지만, 이번 probe만으로 폐기 주체까지 확정하지는 않는다. Keychain 반복 승인은 ad-hoc 개발 서명 ACL 문제로 추정하며 A refresh 실패와 동일 원인으로 확정하지 않았다.

## 코드 원인

관련 경로:

- `LocalCLIDataProvider.captureProfile`
- `ProfileCaptureCoordinator.capture`
- `LocalCLIDataProvider.performCommit`
- `LocalCLIDataProvider.restoreOriginalAfterCapture`
- `LocalCLIDataProvider.validatedCredential`

기존 `restoreOriginalAfterCapture`는 다음 순서였다.

1. journal을 `rollbackStarted`로 기록한다.
2. Keychain의 A 저장본을 읽는다.
3. 격리 홈에서 A를 `refreshToken: false`로 확인한다.
4. 검증 함수가 반환한 credential을 버린다.
5. 원래 A 저장 bytes를 공용 `auth.json`에 쓴다.
6. 다시 identity-only 확인 후 registry를 A로 복원하고 journal을 삭제한다.
7. Codex를 실행한다.

3단계는 이번 A 저장본도 통과한다. 그래서 복원과 journal 삭제가 성공으로 기록됐지만, Codex 실행 뒤 실제 refresh가 실패했다.

## 수정

`validatedCredential`에 기본값이 `false`인 `refreshToken` 인자를 추가했다. identity-only 검사가 필요한 기존 caller 동작은 바꾸지 않았다.

`restoreOriginalAfterCapture`만 다음 순서로 변경했다.

1. A 저장본을 격리 홈에서 `refreshToken: true`로 검증·갱신한다.
2. 갱신된 A를 Keychain에 저장하고 round-trip을 확인한다.
3. process/auth mutation gate를 다시 확인한다.
4. 같은 갱신 blob을 공용 `auth.json`에 원자 교체한다.
5. A identity, registry, journal을 기존 순서로 마무리한다.
6. 모든 단계가 끝난 뒤에만 Codex를 실행한다.

온라인 갱신이 실패하면 B 공용 인증을 유지하고 앱을 실행하지 않는다. B 등록본, capture marker, `rollbackFailed` journal을 남겨 이후 코드가 성공을 추측하지 못하게 한다.

## 회귀 테스트

수정 전 `./Scripts/dev.sh test` 결과:

```text
FAIL CLI capture stores a second profile and restores the first: restored first profile was not refreshed
FAIL CLI additional capture stops before restoring an unrefreshable previous credential: invalid A restore was accepted
```

새 회귀 테스트는 A의 identity-only 조회는 성공하지만 격리 `refreshToken: true`가 실패하도록 만든다. 다음을 검증한다.

- capture 결과가 `rollback_failed`
- 공용 B 인증과 저장 B가 동일
- 저장 A가 변경되지 않음
- registry에 A/B가 보존되고 B가 active
- capture marker와 `rollbackFailed` journal 보존
- Codex launch 0회
- verifier 임시 홈 제거

수정 후 결과:

```text
PASS CLI capture stores a second profile and restores the first
PASS CLI additional capture stops before restoring an unrefreshable previous credential
PASS 135 tests
```

## `quiescent` 복구 재시도

시작 자동 복구는 사용자 동의 없이 실행 중인 공식 앱을 종료하지 않는다. 그래서 앱이 실행 중이면 journal을 보존하고 STOP했지만, 메뉴바에는 비종결 pending을 다시 처리할 동작이 없어 `quiescent` 안내만 계속 남았다.

메뉴바에 `Codex 종료하고 복구 재시도`를 추가했다. 이 동작은 다음 제약을 유지한다.

- transaction lock을 잡은 뒤 화면에 표시된 exact transaction ID를 다시 확인한다.
- 공식 앱에 정상 종료를 요청하고, 종료 전 snapshot에 있던 exact 앱 소유 잔존 프로세스만 기존 별도 확인 뒤 `SIGTERM`한다.
- 새·독립·분류 불명 프로세스나 transaction 교체를 발견하면 auth·registry·journal을 바꾸지 않고 STOP한다.
- 앱 종료가 공용 auth를 갱신할 수 있으므로 종료 완료 뒤 auth를 다시 snapshot한다.
- 기존 recovery coordinator를 재사용하고 Codex는 자동 실행하지 않는다.
- `rollbackFailed`는 기존 이전 계정 수동 복구만 허용한다.

회귀 테스트는 시작 자동 복구가 프로세스를 종료하지 않는지, 명시적 재시도가 transaction lock 안에서 정상 종료하는지, 확인된 exact 잔존 PID만 종료하는지, stale transaction이 모든 상태를 보존하는지 검증한다.

## 진단 저장소 구분

개발 CLI와 설치 메뉴바 앱은 의도적으로 서로 다른 저장소와 credential backend를 사용한다.

- 개발 CLI: `~/Library/Application Support/CodexAccountSwitcherSpike`, private file credential store
- 설치 메뉴바 앱: `~/Library/Application Support/CodexAccountSwitcher`, Keychain credential store

따라서 `./Scripts/dev.sh run recovery status`의 `recovery=none`은 설치 메뉴바 앱의 journal이 없다는 뜻이 아니다. 이번 제품 상태는 제품 경로의 `switch-journal.json`을 별도로 읽어 `quiescent`임을 확인했다. 두 저장소를 복사하거나 합치지 않는다.

## 남은 작업

- 이 소스 수정은 현재 설치 앱에 아직 반영하지 않았다.
- 현재 `quiescent` 제품 상태는 수정 앱 설치 뒤 메뉴바의 명시적 복구 재시도로 처리한다. 설치와 복구 전 계정 카드·동기화·등록을 실행하지 않는다.
- 공식 로그아웃이 저장된 다른 계정의 refresh 가능성을 항상 없애는지 통제된 추가 등록 실험으로 확인해야 한다.
- 위 동작이 반복 확인되면 공식 앱에서 수동 로그아웃하는 추가 등록 UX를 중단하고, 기존 인증을 revoke하지 않는 별도 로그인 준비 또는 격리 로그인 흐름으로 ADR-016을 재검토한다.
- 갱신 성공 뒤에도 데스크톱 앱이 로그아웃 상태로 열릴 때만 `auth.json` 외 추가 데스크톱 세션 가설을 다시 조사한다.
