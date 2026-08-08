# 보안

- 기준일: 2026-08-09
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

## 원격 설치

README의 한 줄 설치는 다음을 신뢰한다.

- GitHub HTTPS
- 저장소 소유자
- 고정 릴리스 태그의 bootstrap과 소스 압축본
- 사용자 Mac의 Xcode toolchain

스크립트는 고정 태그 소스를 임시 폴더에 받고 기존 로컬 설치 스크립트에 위임한다. `main`, `sudo`, 시스템 trust 변경은 사용하지 않는다.

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
- 앱 삭제만으로 저장 credential이 제거되지 않는다.
- Developer ID 서명·공증과 별도 checksum은 공개 릴리스 범위 밖이다.
