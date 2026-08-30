# 보안

- 기준일: 2026-08-30
- 적용 대상: Codex Account Switcher 메뉴바 앱과 진단 CLI

## 보호 범위

이 앱은 여러 ChatGPT 계정의 인증을 로컬에 저장하고 `~/.codex/auth.json` 하나를 안전하게 교체한다.

보호 목표:

- 인증 토큰을 로그, 저장소, UI 오류에 노출하지 않는다.
- 관련 프로세스가 안전하게 정리된 경우에만 인증을 바꾼다.
- 중단·오류 뒤 이전 계정을 검증 가능한 상태로 복구한다.

비목표:

- 같은 macOS 사용자 권한의 악성 프로세스로부터 토큰 보호
- 계정별 task·history·설정·skills 격리
- OpenAI 공식 지원 또는 API 계약 보장

## 저장 위치

| 데이터 | 위치 | 권한 |
|---|---|---|
| 프로필 목록·active ID | `~/Library/Application Support/CodexAccountSwitcher/profiles.json` | `0600` |
| 계정별 credential | `~/Library/Application Support/CodexAccountSwitcher/credentials/<UUID>.json` | `0600` |
| 토큰 사용용 격리 workspace | `~/Library/Application Support/CodexAccountSwitcher/token-use-home/` | 디렉터리 `0700`, auth 파일 `0600` |
| 배터리 자동 해제 기준 | `~/Library/Application Support/CodexAccountSwitcher/sleep-guard-threshold` | `0600` |
| 현재 활성 인증 | `~/.codex/auth.json` | `0600` |
| 상위 private 디렉터리 | `~/Library/Application Support/CodexAccountSwitcher/` | `0700` |

저장 credential은 Keychain 암호화가 아니다. 파일 권한, 소유권, regular-file 여부, symlink 부재를 검사하고 실패하면 다른 저장소로 fallback하지 않는다.

비활성 계정 삭제는 해당 프로필과 credential만 제거한다. 앱 제거는 저장 계정과 로그를 삭제하지 않는다.

## 인증 교체

- 모든 mutation은 단일 lock과 내구 journal 아래 실행한다.
- 임시 파일을 같은 디렉터리에 `0600`으로 쓰고 `fsync`한 뒤 rename과 상위 디렉터리 `fsync`를 확인한다.
- 현재·대상 계정 이메일이 등록 프로필과 완전히 일치할 때만 저장·커밋한다.
- 사용량 수치는 계정 식별이나 전환 성공 판정에 사용하지 않는다.
- 상태가 모순되거나 파일 내구성을 확인할 수 없으면 추측하지 않고 중단한다.

## 수동·자동 토큰 사용

- `⚡` 실행은 대상 계정 credential의 probe 사본만 `token-use-home/auth.json`에 기록하고, refresh token은 사본에서 비활성화한다.
- 실행 프로세스의 `CODEX_HOME`은 `token-use-home`으로 지정한다. 공유 `~/.codex/auth.json`과 활성 계정은 변경하지 않는다.
- `codex exec`에는 `OK`만 요청하고, 출력이 정확히 `OK`일 때만 성공으로 처리한다. 읽은 마지막 메시지 파일은 제거한다.
- 자동 실행은 계정별 사용량 조회의 `resetsAt` 변경과 변경된 창의 잔여율 `100%`를 함께 확인한 뒤 순차 실행한다. 조회 실패나 토큰 실행 실패를 성공으로 기록하지 않는다.
- `token-use-home`은 계정 관리 경로 아래 유지된다. 앱 제거 시 저장 계정·로그와 함께 자동 삭제하지 않으므로, 필요하면 사용자가 별도로 정리해야 한다.

## 프로세스 검사

- 공식 Codex에는 정상 종료만 먼저 요청한다.
- 독립 Codex CLI, IDE, app-server, 분류 불명 관련 프로세스가 남으면 인증을 바꾸지 않는다.
- 정상 종료 전에 확인한 exact 앱 소유 PID·시작 시각·실행 경로가 그대로 남은 경우만 사용자 승인 후 `SIGTERM` 한 번을 보낼 수 있다.
- 새 프로세스, PID 재사용, identity 변경, 독립 프로세스는 종료 후보에 추가하지 않는다.
- `SIGKILL`과 자동 force quit은 제공하지 않는다.

업데이트 중 실행 파일이 삭제된 공식 Crashpad는 PPID 1, 커널의 valid·signed·hardened runtime·Developer ID, exact process identity와 OpenAI Team ID를 모두 확인한 경우에만 비차단 resident로 인정한다. 하나라도 확인할 수 없으면 차단한다.

## 롤백과 복구

- 인증 교체 전 실패: 기존 활성 인증을 바꾸지 않는다.
- 대상 검증 실패: 저장된 이전 credential을 복원하고 이메일을 다시 검증한다.
- 롤백 검증 실패: `rollbackFailed`로 남기고 공식 앱을 실행하지 않는다.
- 앱 시작 시 미완료 journal을 먼저 검사한다. 안전한 단일 결론이 없으면 자동 변경하지 않는다.
- 수동 복구는 journal의 exact 이전 profile만 대상으로 하며 현재 상태를 추측하지 않는다.

복구 중 `auth.json`을 직접 편집하거나 다른 계정으로 로그인하면 증거가 바뀔 수 있다. 앱의 수동 복구 UI 또는 개발 문서의 복구 CLI를 사용한다.

## 배터리 자동 해제

- root LaunchDaemon은 `/Library/PrivilegedHelperTools/local.codex.account-switcher.sleep-guard`에서 실행한다.
- 자동 해제 서비스 설치·갱신·제거에는 관리자 인증이 필요하다. 서비스의 평상시 자동 해제에는 암호를 요청하지 않는다.
- macOS IOKit 전원 소스 변경 알림과 서비스 시작 시점에만 상태를 확인하며 주기 polling은 하지 않는다.
- 내부 배터리 사용 중이고 충전 중이 아니며 설정 임계값 이하일 때만 고정 명령 `/usr/bin/pmset -a disablesleep 0`을 실행한다.
- 잠자기 방지를 자동으로 켜거나 임의 명령·인자를 실행하는 경로는 없다.
- 설정 파일은 regular file, 설치 사용자 소유, group/world 쓰기 불가, 최대 3바이트 조건을 확인한다. 없거나 잘못되면 안전 기본값 `30%`를 쓴다.
- 다른 프로세스가 재평가 알림을 보내도 같은 고정 조건만 다시 검사한다.

## 원격 설치

README의 한 줄 설치는 다음을 신뢰한다.

- GitHub HTTPS
- 저장소 소유자
- 고정 릴리스 태그의 bootstrap과 소스 압축본
- 사용자 Mac의 Xcode toolchain

스크립트는 고정 태그 소스를 임시 폴더에 받고 기존 로컬 설치 스크립트에 위임한다. `main`과 시스템 trust 변경은 사용하지 않는다. macOS 표준 관리자 인증은 root 소유 LaunchDaemon 설치·갱신·제거에만 사용한다.

고정 태그는 checksum, Developer ID 서명, Apple 공증을 대체하지 않는다. 실행 전에 README에 연결된 스크립트를 확인해야 한다.

## 로그와 공유 자료

허용:

- profile UUID, transaction ID, phase
- 안전하게 마스킹된 계정 표시
- 인증 SHA-256, 파일 크기, 수정 시각
- 안전한 프로세스 이름·PID와 종료 전후 개수
- stable 오류 코드

금지:

- access·refresh·ID token
- credential JSON 또는 `auth.json` 원문
- authorization header, 쿠키, App Server 원문 stderr
- 전체 process command line
- task 본문, 사용자 prompt, 회사 코드
- 실제 이메일이 보이는 공유 screenshot

## 알려진 제한

- 공식 Codex 업데이트로 bundle, App Server, 프로세스 계약이 바뀌면 전환이 차단될 수 있다.
- 잠자기 방지는 시스템 전체 설정이며 앱 종료·제거 후에도 유지될 수 있다.
- 배터리 자동 해제 서비스는 설치한 macOS 사용자 한 명의 설정만 읽는다.
- 앱 삭제만으로 저장 credential이 제거되지 않는다.
- Developer ID 서명·공증과 별도 checksum은 공개 릴리스 범위 밖이다.
