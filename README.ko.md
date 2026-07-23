# NotchOtter

[English](README.md) | **한국어**

맥에 사는 픽셀 해달들이 모든 Claude Code 세션의 상태를 실시간으로
보여줍니다 — 어느 앱에 있든, 한눈에.

![해달 상태](assets/previews/otter_states.png)

API 호출도, 토큰 소모도, 외부 전송도 없습니다. 전부 내 맥 안에서만
동작해요: Claude Code 훅이 작은 JSON 상태 파일을 쓰고, 네이티브 앱이
그걸 해달로 그려줄 뿐입니다.

## 세 가지 화면

| 화면 | 보이는 것 | 언제 |
| --- | --- | --- |
| **노치 패널** | 노치 옆 해달 1마리 + `3 working · 1 waiting` 배지 | 항상 |
| **컴패니언 줄** | 세션마다 해달 1마리, Ghostty 탭 순서 그대로 터미널 위에 | Ghostty가 앞일 때 |
| **데스크톱 펫** | 아무 데나 끌어놓을 수 있는 해달 1마리, 클릭하면 세션 수만큼 확장 | 다른 앱이 앞일 때 |

해달 애니메이션은 항상 가장 급한 상태를 보여줍니다:
`에러 > 허가 대기 > 입력 대기 > 작업 중 > 완료 > 대기`.

## 기능

- **세션으로 점프** — 해달을 클릭하면 그 세션의 Ghostty 탭으로 이동.
- **호버로 상태 확인** — 데스크톱 펫 해달에 마우스를 올리면 커지면서
  말풍선에 상태·프로젝트·경과 시간·마지막 답변 요약이 뜹니다
  (대화 기록에서 로컬로 추출 — 무료).
- **자유 배치** — 컴패니언 줄과 데스크톱 펫 모두 드래그로 옮길 수 있고,
  위치는 기억됩니다.
- **알림** — 허가 필요/완료/에러 시 macOS 알림.
- **Otter Outputs** — 세션이 끝나면 만들었던 파일들이
  `~/Desktop/Otter Outputs/<날짜>-<프로젝트>/`에 모입니다.
- **유령 해달** — 터미널이 죽은 세션은 반투명 유령으로 표시됐다가
  자동 정리됩니다.

## 설치

macOS 13+, Claude Code, Swift 툴체인(Command Line Tools)이 필요합니다.
Ghostty ≥ 1.3은 선택 — 없으면 탭 점프와 탭 순서 라벨만 빠집니다.

```bash
bash engine/install.sh        # 훅 등록 (기존 설정은 먼저 백업됨)
bash scripts/build_app.sh     # dist/NotchOtter.app 빌드
open dist/NotchOtter.app
```

첫 실행 시 macOS가 알림 권한과 Automation 권한(Ghostty 탭 포커스용)을
한 번씩 물어봅니다. 메뉴바 아이템에서 "Launch at Login"을 켜두세요.

제거: `bash engine/uninstall.sh` (NotchOtter 훅만 제거) 후 앱 삭제.

## 내 캐릭터 만들기

아무 사진이나 애니메이션과 상태 배지가 달린 픽셀 캐릭터로 변환할 수
있습니다:

```bash
python3 spritegen/hatch.py 사진경로.jpg --name 우리강아지
```

그다음 메뉴바 → **Preferences…**에서 선택하면 세 화면 모두 즉시
바뀝니다. 팩은 `~/.local/share/notch-otter/sprites/`에 저장되고,
폴더를 지우면 제거됩니다.

같은 Preferences 창에서 세션 아이콘 클릭 시 어떤 터미널 앱을
포커스할지도 선택할 수 있습니다 (Ghostty·iTerm2·Terminal.app 중
설치된 것을 자동 감지). 탭 단위 정확한 포커스는 Ghostty에서만
가능하고, iTerm2·Terminal은 작업 디렉토리 기준의 최선 노력형
창 포커스를 사용합니다.

## 자주 묻는 질문

**돈 드나요?** 아니요. API 호출이 전혀 없습니다 — 훅과 파일 감시뿐이에요.
말풍선의 답변 요약도 이미 디스크에 있는 대화 기록 파일에서 잘라낸
텍스트입니다.

**Ghostty 말고 다른 터미널은?** 상태 표시, 노치 패널, 알림, 데스크톱
펫은 어디서든 동작합니다. 탭 점프와 탭 제목 라벨만 Ghostty 전용이에요.

**프라이버시?** 아무것도 맥 밖으로 나가지 않습니다.

## 더 보기

`SPEC.md`가 공식 계약 문서입니다 (상태 스키마, 전이 규칙, 스프라이트
포맷). 훅 엔진은 순수 `sh` + `jq`이고 항상 exit 0 — Claude Code를
막거나 느리게 만들 수 없습니다. 앱은 SPM으로 빌드한 네이티브
AppKit이에요. Electron도, Xcode 프로젝트도 없습니다.
