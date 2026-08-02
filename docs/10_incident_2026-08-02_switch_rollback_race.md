# 2026-08-02 전환 실행·롤백 경합

## 결론

A→B 전환에서 B 인증 교체와 B 앱 실행은 성공했다. 그러나 앱 실행 직후 PID를 한 번만 확인해 LaunchServices 등록 지연을 실행 실패로 오판한 가능성이 매우 높다. 이어진 롤백은 정상 종료 snapshot 뒤 생성된 B 앱 자식을 즉시 차단해 A 인증 복원 전에 `rollbackFailed`로 끝났다.

그 결과 제품 상태가 `registry=A`, `active auth=B`, `journal=rollbackFailed`로 분리됐다. 메뉴의 A 복구 버튼도 `MenuBarExtra`에 붙은 SwiftUI 확인창이 즉시 dismiss되면서 Core 복구를 호출하지 못했다.

이 문서의 A/B는 익명 별칭이다. 이메일, profile ID, transaction ID, token, credential 원문은 기록하지 않았다.

## 사용자 관찰 순서

1. 메뉴에서 B를 선택했다.
2. 공식 Codex 앱이 닫혔다.
3. Keychain 승인을 두 번 완료했다.
4. Codex가 다시 열리지 않은 것처럼 보였다.
5. 메뉴는 A 활성과 A 복구 필요를 표시했다.
6. A 복구 버튼은 눌러도 반응이 없었다.
7. 사용자가 Codex를 직접 열자 실제 로그인은 B였다.

## 보존 상태

2026-08-02 KST 읽기 전용 확인 결과다.

| 항목 | 값 |
|---|---|
| journal phase | `rollbackFailed` |
| journal 시작 | `10:05:45` |
| journal 마지막 갱신 | `10:05:58` |
| registry 활성 | A |
| 사용자 확인 실제 로그인 | B |
| 설치 Codex | `26.727.51351` / `6119`, 실제 검사 `application=ready` |

진단 중 제품 registry, 공용 auth, journal, Keychain item은 쓰지 않았다. 샌드박스 내부 코드서명 검사는 false negative를 냈으며, 실제 권한의 `./Scripts/dev.sh run inspect`로 설치 앱이 정상임을 재확인했다.

## 시스템 타임라인

| 시각 | 관찰 | 판정 |
|---|---|---|
| `10:05:57.592` | B 앱 launch 요청 | 확정 |
| `10:05:57.625~.639` | B 앱 process 생성 | 확정 |
| `10:05:57.778~.779` | LaunchServices check-in·등록 | 확정 |
| `10:05:57.790~.834` | switcher process/signature scan 재개 | 롤백 진입과 일치하는 추정 |
| `10:05:58.131` | B 앱 Service 자식 생성 | 확정 |
| `10:05:58.211` | 메뉴 앱이 이미 `rollbackFailed` journal 판독 | 확정 |
| `10:05:58.287` | B 앱이 Quit AppleEvent 처리 | 확정 |
| `10:05:58.644` | B 앱 정상 종료 | 확정 |

Keychain 접근은 B launch 전인 `10:05:57.528` 이후 관찰되지 않았다. 따라서 롤백은 A credential을 읽는 `restorePreviousCredential`까지 도달하지 못했다. `active auth=B`, `registry=A`와 일치한다.

## 원인 경계

### 1. 실행 PID 가시성 경합

`CodexAppLifecycle.launch`는 `NSWorkspace` completion에서 받은 PID를 반환한다. 기존 `launchTarget`과 `launchPrevious`는 그 PID가 전역 running application 목록에 있는지 즉시 한 번만 확인했다.

이번 로그에는 process 생성과 LaunchServices 등록 사이 약 140ms 간격이 있다. post-launch verifier process 실행 흔적은 없어, 단발 PID 확인이 false negative를 내고 롤백으로 진입했을 가능성이 가장 높다. 당시 PID 조회 반환값 자체는 로그에 없어 이 최초 오류만 `매우 유력`으로 남긴다.

수정 `86e8eac`은 앱을 다시 실행하지 않고 동일한 양수 PID가 최대 4.75초 안에 보이는지만 제한적으로 확인한다. 대상 실행과 이전 계정 재실행이 같은 경계를 사용한다.

### 2. 종료 중 생성된 앱 자식 즉시 차단

기존 `waitForAppQuiescence`는 종료 snapshot에 없던 blocking process를 한 번 발견하면 즉시 실패했다. 정상 종료 중 생성된 앱 Service도 예외가 아니어서, B가 Quit 요청을 처리하고 실제 종료되기 전에 롤백을 terminal 상태로 만들었다.

수정 `fa022e3`은 새 process가 `.appOwnedBlocker`일 때만 auth를 쓰지 않고 자연 종료를 기다린다. 새 process를 SIGTERM 대상에 추가하지 않는다. 독립 Codex, helper-owned probe, 분류 불명 process는 즉시 차단하며, 앱 자식이 계속 남으면 기존 120 poll timeout 뒤 실패한다. 이후 mutation gate도 그대로 다시 확인한다.

### 3. 복구 확인창 소멸

복구 버튼은 `MenuBarExtra` 내부 Button에 `.confirmationDialog`를 붙였다. transient 메뉴 window가 닫히면 binding이 `cancelRecovery()`를 호출해 exact confirmation snapshot을 지웠다. Core 복구 action은 실행되지 않았다. 과거 등록 확인창과 같은 AppKit 제약이다.

수정 `8f5de1f`은 등록과 같은 native `NSAlert`를 사용한다. 취소가 기본 버튼이며, 사용자가 복구를 명시 선택할 때만 지역에 보존한 exact profile·transaction snapshot을 Core에 전달한다.

## 회귀 검증

실행 PID 테스트는 launch 뒤 running PID 응답을 `[] → [] → [PID]`로 지연한다.

```text
수정 전: error=rollback_failed
수정 후: target active, auth=stored target, journal 없음, launch 1회
```

기존 B-011 post-launch rollback 테스트에는 종료 snapshot 뒤 transient Codex Service 자식을 추가했다. 수정 전 동일 경계에서 롤백이 실패하며, 수정 후 transient 자식에는 SIGTERM을 보내지 않고 기존에 확인된 target root만 사용자 승인 경계로 종료한 뒤 A를 복원한다.

최종 결과:

```text
./Scripts/dev.sh test
PASS 140 tests
```

기존 persistent app child, independent Codex, 분류 불명 process 차단 테스트도 통과했다. 설치 앱에서의 실제 A 복구와 A→B 재전환은 아직 수행하지 않았다.

## 현재 조치와 다음 단계

현재 사용자는 B로 Codex를 직접 연 상태다. 수동 B 로그아웃은 저장된 B refresh 가능성을 무효화할 수 있으므로 먼저 하지 않는다.

1. 최신 소스로 메뉴바 앱을 build/install한다.
2. 메뉴의 A 복구를 눌러 native 확인창 표시와 취소 기본값을 확인한다.
3. 복구를 명시 승인한다. 메뉴 앱이 Codex를 정상 종료하고 A 인증을 검증·복원해야 한다.
4. Keychain 요청이 나오면 설치 앱 접근을 승인한다.
5. Codex를 직접 열어 A 로그인, 메뉴 A 활성, journal 부재를 확인한다.
6. A→B 전환을 다시 실행해 PID 지연 경합이 재발하지 않는지 확인한다.

복구 완료 전에는 계정 카드, 동기화, 등록을 실행하지 않는다. 제품 journal을 수동 삭제하거나 auth/Keychain을 직접 복사하지 않는다.
