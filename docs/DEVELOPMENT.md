# 개발

- 기준일: 2026-09-29
- 상태: Claude 사용량 표시와 계정 등록·재로그인 개선을 포함한 `v0.4.0`

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
| `Sources/CodexAccountMenuBarModel` | 메뉴 상태, 사용량·카운트다운, 자동 토큰 실행 |
| `Sources/CodexAccountMenuBar` | SwiftUI `MenuBarExtra` UI |
| `Sources/CodexSleepGuardCore` | 배터리 임계값·`pmset` 상태 판정 |
| `Sources/CodexSleepGuard` | IOKit 이벤트 기반 root 자동 해제 서비스 |
| `Sources/CodexAccountSpike` | 진단·복구 CLI |
| `Tests/CodexAccountCoreTests` | fake credential 기반 자동 테스트 |
| `Scripts` | 빌드, 설치, 제거, 원격 bootstrap |
| `CHANGELOG.md` | 배포 버전별 사용자 영향 변경 |

UI는 전환 로직을 구현하지 않고 `CodexAccountCore`의 typed API를 호출한다.

## 계정 추가·재로그인 흐름

첫 계정 등록은 공식 앱을 종료하고 현재 인증을 저장한 뒤 재실행한다. 추가 등록과 비활성 계정 재로그인은 아래 격리 로그인 경로를 사용한다.

1. 진행 중인 자동 사용량 조회를 취소하고 완료를 기다린다. UI의 이전 오류를 지우고 새 로그인 작업 ID를 만든다.
2. 저장소 잠금 아래 이전 검증 작업을 검사한다. 미시작 또는 자식 종료가 확인되고 미완료 인증 작업이 없을 때만 임시 폴더를 정리한다. 살아 있는 자식, `launching` 마커, 잘못된 권한은 작업을 차단한다.
3. 공식 앱과 현재 활성 계정을 검증한다. 검증 도중 공용 인증 파일이 바뀌면 등록을 중단한다.
4. `isolated-login-workspace`를 `CODEX_HOME`으로 지정해 번들 CLI의 `codex --config 'cli_auth_credentials_store="file"' login`을 실행한다.
5. CLI 출력에서 검증된 로그인 주소를 받으면 브라우저 대기 상태를 알린다. 메뉴의 `브라우저 다시 열기`는 이 작업의 현재 주소로 기본 브라우저를 연다.
6. 로그인 완료 후 새 계정의 신원을 확인하고 인증을 갱신·재검증한다. 추가 등록은 기존에 등록된 이메일을 거부하며, 재로그인은 대상 이메일과 정확히 일치해야 한다.
7. 현재 활성 계정과 저장소 상태가 유지되는지 확인한 뒤 새 프로필을 비활성으로 저장하거나 대상 프로필의 인증을 갱신한다.

`ProfileLoginProgress`는 `preparing → validatingCurrentAccount → startingLogin → awaitingBrowser → validatingNewAccount → savingAccount`를 전달한다. 브라우저 대기 상태는 로그인 주소를 받았음을 뜻하며, 브라우저 화면이 실제로 열렸다는 확인은 아니다. 로그인 프로세스의 제한 시간은 10분, 종료 요청 뒤 유예 시간은 2초다.

`MenuBarViewModel`은 작업 ID가 다른 콜백과 이미 지난 단계로 돌아가는 콜백을 무시한다. 주소는 브라우저 대기 단계에서만 노출하고 검증 단계 진입·취소·실패·완료 시 제거한다. 자식 종료를 확인하지 못하면 임시 작업을 보존하고 복구 상태로 전환한다. URL 검증과 출력 보관 범위는 [보안 문서](SECURITY.md#브라우저-로그인과-임시-작업-정리)를 따른다.

### 로그인 진단 로그

메뉴바 앱의 로그인 단계·실패 코드는 macOS 통합 로그의 subsystem `local.codex.account-switcher`, category `profile-login`에 기록한다.

```sh
# 최근 15분의 로그인 단계와 실패
/usr/bin/log show --last 15m --style compact \
  --predicate 'subsystem == "local.codex.account-switcher" AND category == "profile-login"'

# 재현 중 실시간 확인
/usr/bin/log stream --style compact \
  --predicate 'subsystem == "local.codex.account-switcher" AND category == "profile-login"'
```

`event=progress`의 `stage`로 마지막 진행 단계를 확인한다. 실패는 `event=registration_failed` 또는 `event=relogin_failed`와 안전한 `code`로 기록한다. 계정 검증 오류에는 검증 단계, 로그인 프로세스 오류에는 확인된 종료 코드를 함께 남긴다. 예를 들어 `provider_activeAuthChanged`는 현재 인증 변경, `account_probe_timeout`은 계정 검증 시간 초과다.

이 로그에는 이메일·인증 토큰·로그인 URL·CLI 원시 출력이 포함되지 않는다. 지원 요청에는 발생 시각과 화면의 오류 문구, 해당 category의 단계·코드를 첨부한다.

## 사용량·자동 토큰 흐름

1. 자동 조회는 활성 계정을 2분마다, 전체 계정을 30분마다 조회한다.
2. 계정별 사용량 캐시의 각 창에서 `resetsAt`을 분 단위로 내림해 다음 조회의 서버값과 비교한다. 첫 조회는 기준값만 만든다.
3. 어느 계정에서든 현재 분 단위 값이 이전 값보다 커진 창을 발견하면 리셋으로 감지한다. 부분 조회에서 감지하면 전체 계정 사용량을 다시 조회하며, 이미 전체를 조회했다면 그 결과를 재사용한다.
4. 5시간 창의 남은 사용량이 `100%`인 계정을 대상으로 한 번에 하나씩 `useToken(profileID:)`를 실행한다. 각 계정은 한 번만 처리하고, 실행 뒤 해당 계정 사용량을 다시 조회해 새 `resetsAt`을 반영한다. 상태에는 감지된 계정·창과 이전·새 `resetsAt`을 표시한다.
5. 실행 실패 계정은 다음 조회에서 재시도한다. 자동 토큰 사용은 메뉴에서 기본 OFF이며, 켜져 있으면 자동 조회와 수동 전체 새로고침 모두 같은 리셋·재시도 판정을 수행한다.

토큰 사용은 계정 credential의 probe 사본을 관리 경로 아래 `token-use-home`에 놓고 그 경로를 `CODEX_HOME`으로 지정한다. 공유 `~/.codex`의 대화·task·history·설정은 변경하지 않는다.

현재 요청은 도구 사용 없는 짧은 자기소개다. 비어 있지 않은 응답을 읽고 JSON 이벤트의 토큰 수를 함께 표시한다. 실행 후 한도 조회가 성공해도 이번 요청의 사용량 반영이나 리셋 시각 고정까지 확인한 것으로 처리하지 않는다.

### Claude 사용량

`ClaudeUsageProbe`는 로컬 Claude Code CLI의 `auth status`와 `-p /usage --output-format json --no-session-persistence`로 현재 로그인된 계정의 구독 한도를 조회한다. CLI는 `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.local/bin/claude` 순서로 찾는다. 자동 조회는 2분마다 수행하며, 카드의 새로고침 버튼으로 다시 조회할 수 있다.

`ClaudeUsageParser`는 5시간·주간 사용률과 초기화 시각을 읽는다. 날짜의 시간대와 `6:59pm`, `7pm` 두 형식을 처리한다. 날짜를 읽을 수 없으면 메뉴바에는 잔여율만 표시하고 카드에는 초기화 원문을 표시한다. 조회 실패 시 마지막 값을 유지하면서 오류를 표시하며, 로그아웃 상태가 확인되면 마지막 값을 지운다. Claude 계정 전환은 제공하지 않는다.

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

진단 CLI의 프로필 저장소는 `~/Library/Application Support/CodexAccountSwitcherSpike`이고, 메뉴바 앱은 `~/Library/Application Support/CodexAccountSwitcher`를 사용한다. CLI의 `profiles list`와 `recovery status`는 메뉴바 앱의 저장소 상태를 보여주지 않는다. 두 프로그램의 공용 활성 인증 경로는 모두 `~/.codex/auth.json`이다.

root LaunchDaemon을 설치·갱신·제거할 때만 관리자 인증을 요청한다. helper와 plist가 동일한 앱-only 갱신, 임계값 변경, 자동 해제에는 요청하지 않는다.

## 버전 관리

- 앱 표시 버전과 빌드 번호는 `Scripts/CodexAccountSwitcher-Info.plist`의 `CFBundleShortVersionString`, `CFBundleVersion`이 기준이다.
- 배포 소스는 같은 버전의 `vX.Y.Z` Git 태그로 고정한다.
- 사용자 영향 변경은 `CHANGELOG.md`의 `배포 예정`에 먼저 기록한다.
- 릴리스할 때 `배포 예정`을 버전·날짜로 바꾸고 plist, README 설치 URL, Git 태그를 같은 버전으로 맞춘다.

## 검증 상태

로그인 개선 검증 기록(2026-09-29):

- `./Scripts/dev.sh test`: 로그인 개선 회귀를 포함해 당시 로컬 작업트리의 전체 테스트 통과.
- 종료된 임시 작업 정리 후 첫 로그인 성공, 살아 있거나 종료 미확인인 자식·잘못된 권한 보존 확인
- 분할된 로그인 URL·출력 폭주·잘못된 주소, 취소·종료 뒤 늦은 출력 처리 확인
- 재시도 오류 제거, 진행 단계·주소 수명, 이전 작업 콜백 무시, 진단 정보의 인증값 비노출 확인
- `./Scripts/build-app.sh`: 배포 앱·서비스 빌드, plist 검사, 서명 검증 통과
- `./Scripts/install-app.sh`: 로컬 설치·재실행 완료, 설치 실행 파일과 빌드 결과 일치 확인
- 실제 새 계정 브라우저 로그인과 만료 계정 재로그인 완료는 이번 수정에서 재검증하지 않았다.

기존 자동 검증 기록:

- 단일 계정 `resetsAt` 변경 뒤 전체 재조회·100% 계정별 순차 자동 토큰 사용 테스트
- 원격 install·uninstall 분기와 잘못된 인자 거부
- 배터리 임계값·전원 상태·`pmset` 출력 정책 테스트
- release 앱과 자동 해제 서비스 빌드, plist lint, strict ad-hoc codesign

기존 실계정 검증 기록:

- A↔B 왕복 3회
- B 삭제·재등록 후 A→B→C→A
- 수동 이전 계정 복구 2회
- 실패 주입 자동 롤백
- 잠자기 방지 OFF/ON 재시작 유지

남은 릴리스 검증:

- 실제 추가 등록·만료 계정 재로그인에서 브라우저 자동 열기와 `브라우저 다시 열기`, 취소·시간 초과 확인
- 최신 공식 앱 대상 auth-changing 왕복
- 만료 계정 exact 재로그인
- 재부팅 후 미완료 journal 복구
- 잔존 프로세스 승인·결과창 실제 조작
- 실제 배터리 감소 알림에서 임계값 자동 해제와 재부팅 후 서비스 기동
- release 앱의 동일 task A↔B 왕복 증거 보존

## 공개 릴리스

1. `CHANGELOG.md`의 `배포 예정`을 릴리스 버전과 날짜로 확정한다.
2. plist 버전·빌드 번호, README 설치 URL, Git 태그를 같은 버전으로 맞춘다.
3. LICENSE, 저장소 이름, 공개 URL, `Scripts/install-remote.sh` 경로를 확인한다.
4. 다음 검증을 통과한다.

```sh
./Scripts/dev.sh test
./Scripts/test-install-remote.sh
./Scripts/build-app.sh
git diff --check
```

5. 버전 태그를 만들고 GitHub에 푸시한다.
6. README 설치·제거 명령을 빈 환경에서 다시 확인한다.

README 설치 URL에 적힌 버전 태그가 공개되기 전에는 원격 설치 명령이 동작하지 않는다.
