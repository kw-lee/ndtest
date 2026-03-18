# DirtyTest for macOS (Core + CLI + GUI)

이 디렉터리는 Windows Delphi/VCL 기반 Naraeon Dirty Test를 macOS 네이티브(Swift)로 이식한 비공식 포크입니다.

- 앱 표시 이름: `DirtyTest`
- 이 저장소와 빌드는 원저작자의 승인을 받은 공식 배포본이 아닙니다.

## 빠른 다운로드

- 최신 릴리스: https://github.com/kw-lee/ndtest/releases/latest
- 위 페이지의 **Assets**에서 macOS용 ZIP 파일을 다운로드하세요.

## 구현된 기능

### 공통 엔진 (`DirtyTestCore`)

- 자유 공간/전체 용량 기준 쓰기량 계산
  - 남길 용량: `gib`, `mib`, `percent`
  - 쓸 용량: `writeGib`, `writeMib`
- `RandomfileN` 순차 대용량 쓰기 + 4GiB 파일 롤오버
- 쓰기마다 랜덤 버퍼 앞부분 재생성 (`arc4random_buf`)
- 취소 토큰 기반 안전 중단 처리 + 일시정지/재개 지원 (`NSCondition`)
- 구간 속도 측정(MiB/s), 최대/최소/평균 집계
- 평균 속도 50% 이하 구간 비율 계산
- 로그 및 상세 CSV 저장
- 테스트 종료 후 생성 파일 삭제 옵션
- 1회/무한 반복 모드

### GUI (`dirtytest-gui`)

- 2단 레이아웃
  - 좌측: 드라이브/설정/로그경로/시작·일시정지·중지
  - 우측: 진행 상태/차트/로그
- 볼륨 자동 열거 + 여유/전체 용량 표시
- 디스크 모델명 감지: diskutil + IOKit 이중 폴백, APFS 컨테이너/물리 디스크 자동 탐색
- 내장 루트 볼륨(`/`) 선택 시 사용자 홈 경로로 자동 보정
- 남길 용량/쓸 용량 모드 전환 UI
- 테스트 실행 중 설정 패널 자동 비활성화
- 일시정지 / 재개 버튼 (일시정지 구간은 로그에 타임스탬프로 기록)
- 속도 차트
  - 파란 Area + Line
  - 빨간 50% 평균 기준선
  - 다크 플롯 스타일, X축 100→0
  - 무한 반복 모드에서 사이클 재시작 시 자동 초기화
- 현재 속도 + 실시간 누적 평균 속도 동시 표시
- 로그 탭
  - 전체 로그
  - 현재 사이클 로그 (사이클 재시작 시 자동 초기화)
- About 메뉴
  - 포크 프로젝트 안내
  - GPLv3 안내 문구

### 패키징

- `package-gui-app.sh`로 `DirtyTest.app` 생성
- `AppIcon.png`가 있으면 자동으로 `.icns` 생성 후 번들 포함
- `generate-icon.swift`로 차트 스타일 아이콘 생성 가능

## 아직 미포함 (Windows 대비)

- SMART/ATA/SCSI 저수준 상세 정보 표시
- Windows VCL UI 100% 동일 레이아웃/동작

## 빌드

```bash
cd macos
swift build -c release
```

## GUI 실행

```bash
cd macos
swift run -c release dirtytest-gui
```

또는:

```bash
./.build/release/dirtytest-gui
```

## .app 번들 패키징

```bash
cd macos
./package-gui-app.sh
```

생성 결과:

- `macos/dist/DirtyTest.app`

실행:

```bash
open macos/dist/DirtyTest.app
```

## 아이콘 생성 (옵션)

```bash
cd macos
swift generate-icon.swift
./package-gui-app.sh
```

## CLI 실행 예시

```bash
./.build/release/dirtytest \
  --path /Volumes/TestTarget \
  --leave-value 10 \
  --leave-unit gib \
  --unit-speed 1 \
  --cache off \
  --delete on \
  --repeat once \
  --log ./dirtytest.log \
  --detailed-log ./dirtytest-detail.csv
```

## 주요 인자

- `--path <dir>`: 테스트 파일 생성 경로 (필수)
- `--leave-value <number>` + `--leave-unit <gib|mib|percent>`: 남길 여유 공간
- `--unit-speed <0.1|1|10>`: 속도 로그 단위 (기본 `1`)
- `--cache <on|off>`: 캐시 사용 (기본 `on`)
- `--delete <on|off>`: 종료 후 파일 삭제 (기본 `on`)
- `--repeat <once|infinite>`: 반복 모드 (기본 `once`)
- `--buffer-mib <int>`: 버퍼 MiB (기본 `8`)
- `--randomness <0..100>`: 랜덤 데이터 비율 (기본 `100`)

## GitHub에서 다운로드한 경우 (Gatekeeper 우회)

이 앱은 Apple Developer ID로 서명·공증되지 않은 오픈소스 빌드입니다.  
인터넷에서 다운로드하면 macOS Gatekeeper가 실행을 차단할 수 있습니다.

**방법 1 — Finder에서 열기 (GUI)**

1. Finder에서 `DirtyTest.app`을 **Control + 클릭** (또는 우클릭)
2. 메뉴에서 **"열기"** 선택
3. 경고 대화상자에서 **"열기"** 버튼 클릭

한 번만 하면 이후 정상 더블클릭으로 실행됩니다.

**방법 2 — 터미널에서 quarantine 속성 제거**

```bash
xattr -dr com.apple.quarantine /path/to/DirtyTest.app
```

이후 `open /path/to/DirtyTest.app` 또는 더블클릭으로 실행 가능합니다.

## 면책

- 나래온 더티 테스트는 프리웨어입니다. 개발자는 이 프로그램의 부작용에 대해서 어떠한 책임도 지지 않습니다.
- 자세한 내용은 GPL 3.0을 참고하세요.
- 이 macOS 포트 역시 동일하게 사용자 책임하에 사용해야 합니다.

## 주의

- 실제 저장장치에 대용량 쓰기 부하를 발생시킵니다.
- 파일시스템/OS 정책 차이로 Windows와 성능 수치가 완전히 동일하지 않을 수 있습니다.
