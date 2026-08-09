# 개발

- 기준일: 2026-08-09
- 상태: 메뉴바 앱과 로컬 설치 구현 완료, 공개 릴리스 준비 중

## 개발 환경 시작

일반 사용자는 README의 `curl` 설치 명령을 사용한다. 아래 절차는 소스를 수정할 개발자용이다.

```sh
git clone https://github.com/aqwsde321/codex-account-switcher-macos.git
cd codex-account-switcher-macos
./Scripts/dev.sh test
./Scripts/install-app.sh
```

필요 환경은 macOS 13 이상과 Xcode Command Line Tools 또는 Xcode다.

## 구조

| 경로 | 역할 |
|---|---|
| `Sources/CodexAccountCore` | 인증 저장, 프로세스 검사, 전환·롤백·복구 |
| `Sources/CodexAccountMenuBarModel` | 메뉴 상태와 사용량·카운트다운 계산 |
| `Sources/CodexAccountMenuBar` | SwiftUI `MenuBarExtra` UI |
| `Sources/CodexSleepGuardCore` | 배터리 임계값·`pmset` 상태 판정 |
| `Sources/CodexSleepGuard` | IOKit 이벤트 기반 root 자동 해제 서비스 |
| `Sources/CodexAccountSpike` | 진단·복구 CLI |
| `Tests/CodexAccountCoreTests` | fake credential 기반 자동 테스트 |
| `Scripts` | 빌드, 설치, 제거, 원격 bootstrap |

UI는 전환 로직을 구현하지 않고 `CodexAccountCore`의 typed API를 호출한다.

## 전환 흐름

1. 단일 파일 lock을 잡고 미완료 journal을 검사한다.
2. 설치 앱, 현재 계정, 저장 credential, 관련 프로세스를 확인한다.
3. 공식 Codex에 정상 종료를 요청하고 관련 프로세스가 사라질 때까지 기다린다.
4. 현재 계정 credential을 갱신·저장한다.
5. 격리된 임시 홈에서 대상 계정 이메일을 검증하고 갱신한다.
6. `~/.codex/auth.json`을 원자 교체한다.
7. 공식 Codex를 다시 열고 대상 계정을 검증한 뒤 active profile을 커밋한다.

대상 검증 이후 오류가 나면 이전 계정을 자동 롤백한다. 롤백 검증도 실패하면 앱을 다시 열지 않고 수동 복구 상태로 남긴다.

## 고정 규칙

- 기본 `~/.codex`만 지원하고 프로필은 최대 3개다.
- 계정 신원은 `account/read`의 exact 이메일 일치로 확인한다.
- 저장 credential은 `0700` 디렉터리의 `0600` private JSON만 사용한다.
- 독립 Codex CLI·IDE·분류 불명 프로세스가 있으면 인증을 바꾸지 않는다.
- 공식 앱은 정상 종료가 기본이다. 확인된 앱 소유 잔존 프로세스만 별도 승인 후 `SIGTERM` 한 번을 허용한다.
- `SIGKILL`, 숨은 force 옵션, 미등록 계정 자동 덮어쓰기는 금지한다.
- 배터리 자동 해제는 IOKit 이벤트 기반이며 `/usr/bin/pmset -a disablesleep 0`만 실행한다. 자동 활성화는 금지한다.

세부 보안 불변조건은 [SECURITY.md](SECURITY.md)를 따른다.

## 명령

```sh
# 전체 자동 테스트
./Scripts/dev.sh test

# read-only 환경 검사
./Scripts/dev.sh run inspect
./Scripts/dev.sh run profiles list

# 복구 상태 확인·명시적 복구
./Scripts/dev.sh run recovery status
./Scripts/dev.sh run recovery restore --profile <profile-id-or-label>

# release 앱 빌드·설치·제거
./Scripts/build-app.sh
./Scripts/install-app.sh
./Scripts/uninstall-app.sh

# 원격 bootstrap 자체 테스트
./Scripts/test-install-remote.sh
```

실제 계정 전환 명령은 공식 앱과 `auth.json`을 변경한다. 메뉴바 앱으로 검증하고 자동화된 개발 task 안에서 실행하지 않는다.

root LaunchDaemon을 설치·갱신·제거할 때만 관리자 인증을 요청한다. helper와 plist가 동일한 앱-only 갱신, 임계값 변경, 자동 해제에는 요청하지 않는다.

## 검증 상태

자동 검증:

- Swift 183개 테스트
- 원격 install·uninstall 분기와 잘못된 인자 거부
- 배터리 임계값·전원 상태·`pmset` 출력 정책 테스트
- release 앱과 자동 해제 서비스 빌드, plist lint, strict ad-hoc codesign

실계정 검증:

- A↔B 왕복 3회
- B 삭제·재등록 후 A→B→C→A
- 수동 이전 계정 복구 2회
- 실패 주입 자동 롤백
- 잠자기 방지 OFF/ON 재시작 유지

남은 릴리스 검증:

- 최신 공식 앱 대상 auth-changing 왕복
- 만료 계정 exact 재로그인
- 재부팅 후 미완료 journal 복구
- 잔존 프로세스 승인·결과창 실제 조작
- 실제 배터리 감소 알림에서 임계값 자동 해제와 재부팅 후 서비스 기동
- release 앱의 동일 task A↔B 왕복 증거 보존

## 공개 릴리스

1. 저장소 이름과 공개 URL을 확정한다.
2. LICENSE를 추가한다.
3. README와 `Scripts/install-remote.sh`의 저장소 경로를 맞춘다.
4. 다음 검증을 통과한다.

```sh
./Scripts/dev.sh test
./Scripts/test-install-remote.sh
./Scripts/build-app.sh
git diff --check
```

5. `v0.1.0` 태그를 만들고 GitHub에 푸시한다.
6. README 설치·제거 명령을 빈 환경에서 다시 확인한다.

`v0.1.0` 태그가 공개되기 전 README의 원격 설치 명령은 동작하지 않는다.
