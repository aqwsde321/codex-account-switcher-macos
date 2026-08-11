# Codex Account Switcher for macOS

Codex Account Switcher는 macOS용 Codex 데스크톱 앱 계정을 메뉴바에서 전환하고 계정별 사용 한도를 보여준다. 전환 결과는 같은 `~/.codex` 인증을 사용하는 Codex CLI에도 적용된다.

**계정 전환을 한 번 승인하면 Codex 앱 정상 종료 → 인증 교체 → 대상 검증 → 앱 재실행을 자동 처리한다.** 실행 중인 CLI·IDE 작업은 인증 보호를 위해 전환 전에 종료해야 한다.

<p align="center">
  <img src="docs/assets/menu-bar-status.png" width="206" alt="김이 나는 채운 커피잔, 활성 계정 한도 50%, 초기화까지 7일을 표시하는 메뉴바 상태">
</p>

<p align="center"><sub>가상 상태 예시. 잠자기 방지가 켜지면 채운 커피잔 위로 김 세 줄이 오르고, 꺼지면 빈 커피잔을 표시한다.</sub></p>

<p align="center">
  <img src="docs/assets/account-switch-confirmation.png" width="760" alt="개인정보를 제거한 메뉴바 상태, 계정 전환 확인창, 계정별 사용 한도 메뉴 예시">
</p>

<p align="center"><sub>가상 데이터 예시: 메뉴바 상태 확인 → 대상 계정 선택 → 전환 승인.</sub></p>

## 기능

- 최대 3개 ChatGPT 계정 등록·전환
- Codex 데스크톱 앱 정상 종료 → 인증 교체 → 대상 검증 → 재실행 자동 처리
- 같은 `~/.codex` 인증을 사용하는 Codex CLI에도 전환 결과 적용
- 계정별 plan, 남은 한도, 초기화 시각·카운트다운 표시
- 비활성 계정 삭제·재등록과 만료 계정 재로그인
- 전환 실패 시 이전 계정 자동 롤백, 복구 실패 시 수동 복구
- Mac 덮개를 닫아도 작업을 유지하는 잠자기 방지와 배터리 임계값 자동 해제

계정별 task·history·설정은 분리하지 않고 하나의 `~/.codex`를 공유한다.

## 설치

필요 환경:

- macOS 13 Ventura 이상
- 공식 Codex 앱
- Xcode Command Line Tools 또는 Xcode

설치는 고정 릴리스 태그의 [bootstrap 스크립트](https://github.com/aqwsde321/codex-account-switcher-macos/blob/v0.2.0/Scripts/install-remote.sh)를 사용한다.

```sh
(set -o pipefail && curl -fsSL https://raw.githubusercontent.com/aqwsde321/codex-account-switcher-macos/v0.2.0/Scripts/install-remote.sh | /bin/zsh)
```

고정된 `v0.2.0` 소스를 임시 폴더에 받아 로컬에서 빌드하고 `~/Applications`에 설치한다. 배터리 자동 해제용 시스템 서비스 설치 때문에 관리자 암호를 한 번 요청한다. 설치 후 앱과 시스템 서비스가 자동 시작한다.

## 사용

### 첫 계정 등록

<p align="center">
  <img src="docs/assets/account-register-demo.gif" width="380" alt="계정 등록 버튼, 계정 이름 입력, 현재 로그인 등록 승인, 등록 완료 과정을 보여주는 GIF">
</p>

<p align="center"><sub>가상 데이터 GIF: 등록 시작 → 이름 입력 → 자동 종료·등록 승인 → 활성 계정 등록.</sub></p>

1. 공식 Codex에 사용할 첫 계정으로 로그인한다.
2. 메뉴바 앱에서 `계정 등록`을 누른다.
3. 라벨을 입력하고 `현재 로그인 등록`을 선택한다.
4. 등록을 승인하면 앱이 Codex 종료·저장·재실행을 자동 처리한다.

### 계정 추가

<p align="center">
  <img src="docs/assets/account-add-demo.gif" width="380" alt="새 계정 이름 입력, 브라우저 로그인 승인, 로그인 대기, 비활성 계정 추가 과정을 보여주는 GIF">
</p>

<p align="center"><sub>가상 데이터 GIF: 추가 시작 → 이름 입력 → 브라우저 로그인 → 비활성 계정 저장.</sub></p>

1. `계정 등록`에서 라벨을 입력하고 `새 계정 등록`을 선택한다.
2. 열린 브라우저에서 추가할 계정으로 로그인한다.
3. 새 계정은 비활성으로 저장되고 현재 활성 계정은 유지된다.

추가 등록은 공식 Codex의 현재 로그인과 활성 프로필을 변경하지 않는다.

### 계정 전환

<p align="center">
  <img src="docs/assets/account-switch-demo.gif" width="380" alt="계정 선택, 전환 승인, Codex 앱 정상 종료, 인증 교체와 검증, 앱 자동 재실행, 활성 계정 변경 과정을 보여주는 GIF">
</p>

<p align="center"><sub>가상 데이터 GIF: 대상 선택 → 한 번 승인 → Codex 정상 종료 → 인증 교체·대상 검증 → 앱 자동 재실행 → 활성 계정 변경.</sub></p>

1. 전환할 계정 카드를 선택한다.
2. 확인창에서 `전환`을 한 번 승인한다.
3. 이후 Codex 종료·인증 교체·검증·재실행은 자동이다.

독립 Codex CLI나 IDE 작업이 실행 중이면 인증 보호를 위해 전환을 차단한다. 해당 작업을 직접 종료한 뒤 다시 시도한다.

정상 종료 요청 후 약 1초가 지나도 종료 전에 확인한 동일 공식 앱 프로세스가 남은 경우에만 `SIGTERM 전송` 승인을 요청한다. 독립 CLI·IDE 프로세스는 종료하지 않고 전환을 차단한다.

### 한도와 잠자기 방지

- 카드와 메뉴바에서 활성 계정의 최소 잔여율과 초기화까지 남은 시간을 확인한다.
- 남은 시간은 올림한다. 예: `2일 19시간` → `3d`.
- 자동 조회는 활성 계정 2분, 전체 계정 30분 주기다.
- `잠자기 방지`는 관리자 인증 후 macOS 시스템 설정을 바꾸며 앱을 종료해도 유지될 수 있다.
- 메뉴바와 설정 행의 커피잔은 잠자기 방지 OFF일 때 윤곽선, ON일 때 채움과 아래에서 위로 선명해지는 김 세 줄로 표시한다. macOS `동작 줄이기`가 켜져 있으면 정지한다.
- `배터리 자동 해제` Slider는 `0...99%`를 1% 단위로 선택한다. `0`은 끔이며 기본값은 `30%`다.
- 전원 어댑터가 분리된 상태에서 배터리가 임계값 이하가 되면 잠자기 방지를 끈다. 다시 켜지는 동작은 자동화하지 않는다.
- 60초 주기 조회는 사용하지 않는다. macOS 전원 소스 변경 알림과 서비스 시작 시점에만 상태를 확인한다.
- 자동 해제는 설치된 시스템 서비스가 실행하므로 매번 관리자 암호를 묻지 않는다.

### 계정 삭제

비활성 계정 카드의 휴지통을 누르면 해당 프로필과 저장 인증만 삭제한다. 활성 계정은 삭제할 수 없다.

## 제거

```sh
(set -o pipefail && curl -fsSL https://raw.githubusercontent.com/aqwsde321/codex-account-switcher-macos/v0.2.0/Scripts/install-remote.sh | /bin/zsh -s -- --uninstall)
```

앱, 자동 시작 항목, 배터리 자동 해제 시스템 서비스를 제거한다. 시스템 서비스 제거 때문에 관리자 암호를 요청할 수 있다. 저장 계정, 로그, 현재 잠자기 방지 설정은 보존한다.

## 데이터와 제한

- 계정 목록: `~/Library/Application Support/CodexAccountSwitcher/profiles.json`
- 계정별 인증: `~/Library/Application Support/CodexAccountSwitcher/credentials/`
- 배터리 자동 해제 기준: `~/Library/Application Support/CodexAccountSwitcher/sleep-guard-threshold`
- 현재 활성 인증: `~/.codex/auth.json`
- 저장 인증은 Keychain 암호화가 아니며 같은 macOS 사용자 권한의 다른 프로세스가 읽을 수 있다.
- 실제 인증값은 저장소, 로그, screenshot에 포함하지 않는다.

자세한 변경 내용은 [변경 이력](CHANGELOG.md), 보안 제약은 [보안 문서](docs/SECURITY.md)를 따른다.

<details>
<summary>개발자용 문서</summary>

소스 수정·테스트·로컬 설치는 [개발 문서](docs/DEVELOPMENT.md)를 따른다.

</details>
