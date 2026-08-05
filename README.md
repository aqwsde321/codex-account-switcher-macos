# Codex Account Switcher

개인·회사 Codex 계정을 macOS 메뉴바에서 안전하게 전환하고, 계정별 사용 한도까지 한눈에 보는 앱이다.

> OpenAI 공식 제품이 아닌 개인 프로젝트다. 현재는 소스 빌드로 사용하는 검증 단계다.

<p align="center">
  <img src="docs/assets/account-switcher-overview.png" width="380" alt="가상 계정 세 개와 사용 한도, 잠자기 방지 토글을 보여주는 Codex Account Switcher 화면">
</p>

<p align="center"><sub>실제 UI 기반 데모이며 계정 정보는 모두 가상 데이터다.</sub></p>

## 주요 기능

- 최대 3개 ChatGPT 계정 등록·전환
- 공식 Codex 앱을 정상 종료한 뒤 인증 전환·재실행·계정 검증
- 활성·비활성 계정의 plan, 남은 한도, 초기화 시각 표시
- 메뉴바 아이콘에 활성 계정의 최소 잔여율 표시
- 비활성 계정 삭제·재등록과 만료 계정 재로그인
- 전환 실패 시 이전 계정 자동 복구
- Mac 덮개를 닫아도 작업을 유지하는 잠자기 방지 토글

공식 Codex에서 직접 로그아웃할 필요 없다. 계정별 task·history·설정은 분리하지 않고 하나의 `~/.codex`를 공유한다.

## 설치

필요 환경:

- macOS
- 공식 Codex 앱
- Xcode Command Line Tools 또는 Xcode

```sh
git clone https://github.com/aqwsde321/codex-account-switcher-spike.git
cd codex-account-switcher-spike
./Scripts/install-app.sh
```

설치 후 메뉴바에 앱이 실행되며 로그인할 때 자동 시작한다.

## 사용법

### 1. 첫 계정 등록

1. 공식 Codex 앱에 사용할 첫 계정으로 로그인한다.
2. 메뉴바에서 Codex Account Switcher를 열고 `계정 등록`을 누른다.
3. 라벨을 입력하고 `현재 로그인 등록`을 누른다.
4. 안내를 승인하면 Codex가 정상 종료·재실행되고 첫 계정이 활성 상태로 저장된다.

### 2. B/C 계정 추가

1. `계정 등록`을 누르고 라벨 입력 후 `새 계정 등록`을 누른다.
2. 열린 브라우저에서 추가할 계정으로 로그인한다.
3. 새 계정은 비활성으로 저장되고 기존 활성 계정은 그대로 유지된다.

공식 Codex 앱에서 로그아웃하거나 계정을 바꾸지 않는다.

### 3. 계정 전환

<p align="center">
  <img src="docs/assets/account-switch-demo.gif" width="380" alt="개인 계정에서 회사 계정으로 확인, 검증, 완료되는 전환 과정">
</p>

1. 전환할 계정 카드를 누른다.
2. Codex 종료·전환을 승인한다.
3. 앱이 인증을 교체하고 대상 계정을 검증한 뒤 Codex를 다시 연다.

독립 Codex CLI나 IDE 작업이 실행 중이면 안전을 위해 전환이 차단된다. 해당 작업을 직접 종료한 뒤 다시 시도한다.

### 한도 표시

- 각 카드에서 서버가 제공한 기간별 남은 한도와 초기화 시각을 확인한다.
- 자동 조회는 활성 계정 2분, 전체 계정 30분 주기다.
- 메뉴바의 숫자와 링은 활성 계정에서 가장 적게 남은 한도다.
- 새로고침 버튼은 모든 계정을 즉시 조회한다.

### 잠자기 방지

메뉴 하단의 `잠자기 방지`를 켜면 macOS 관리자 인증 후 시스템 설정을 변경한다. 켜진 동안 메뉴바에 커피 배지가 표시된다.

이 설정은 앱을 종료하거나 제거해도 유지될 수 있다. 발열·배터리 소모에 주의하고 필요 없을 때 끈다.

## 제거

```sh
./Scripts/uninstall-app.sh
```

앱과 자동 시작 항목만 제거한다. 저장 계정, 로그, 잠자기 방지 시스템 설정은 자동 삭제·해제하지 않는다.

## 보안과 제한

- 계정 인증은 `~/Library/Application Support/CodexAccountSwitcher/credentials/`에 저장한다.
- 디렉터리는 `0700`, JSON 파일은 `0600`이지만 Keychain 암호화는 아니다.
- 같은 macOS 사용자 권한의 다른 프로세스는 인증 파일을 읽을 수 있다.
- 이 앱은 계정별 데이터 격리 도구가 아니다. task, history, 설정, skills 등은 공유된다.
- 실제 인증값을 repo, 로그, screenshot에 넣지 않는다.

## 개발과 상세 문서

```sh
./Scripts/dev.sh test
```

현재 174개 테스트와 B 삭제·재등록, A→B→C→A 실계정 전환을 통과했다. 배포 전 Black-box 검증은 아직 남아 있다.

- [전체 문서 인덱스](docs/00_README.md)
- [제품 요구사항](docs/01_product_requirements.md)
- [아키텍처 결정](docs/02_decision_record.md)
- [테스트·인수 기준](docs/07_test_acceptance.md)
- [CLI·복구 Runbook](docs/04_spike_runbook.md)
