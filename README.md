# 한꼬집 · 스마트 양념 스튜디오

지능형 IoT 설계 8조의 스마트 양념 자동 계량 시스템을 위한 반응형 웹 앱입니다.

## 현재 구현

- 대시보드: 재료 슬롯, 저장한 레시피 수, 계량 횟수와 최근 이력
- 재료 관리: 분말 P1~P4·액체 L1~L2의 재료명과 사용 가능 여부 설정, 실계량 모드의 액체 수위 표시
- CUSTOM 배합: 재료별 g 입력, 인분·이름 설정, 배합 미리보기
- AI 화면: 자유 대화, 음식 추천, 후속 배합 수정과 **실제 AI 배합** 생성·서버 검증
- 내 레시피: 저장·검색·수정·삭제·즐겨찾기
- 계량: 최종 승인, 재료별 진행 표시, 중복 실행 방지, 중단과 결과 저장
- 제조 이력: 목표 중량과 모의 계량값 또는 Arduino 실측값 비교

**기본값은 모의 계량입니다.** 실계량은 Uno R3 또는 R4 펌웨어에 배선·보정값을 설정하고 Raspberry Pi에서 `DEVICE_MODE=uart`을 켜야 합니다. UART 모드에서는 Arduino가 보고한 중량을 저장합니다. AI를 설정한 경우에도 배합은 사용자가 검토하고 승인합니다. [보드별 설치·보정·동작 시험 안내](HARDWARE_INTEGRATION.md)

실계량 펌웨어는 74HC595 두 개를 통해 선택한 분말통의 5 V 스텝 모터·ULN2003을 구동합니다. 액체는 수위를 확인한 뒤 해당 펌프를 켭니다. 두 종류 모두 배출구의 공용 용기에 재료를 하나씩 담고 HX711 저울로 실측량을 계산합니다.

초기 예시 재료는 슬롯마다 바꿀 수 있습니다. 분말·액체 유형은 슬롯에 고정하며, 액체도 g을 사용합니다. 데이터는 `data/demo.sqlite3`에 보관되고 서버를 재시작해도 유지됩니다. SQLite는 로컬 개발용이며 계획서의 MariaDB 연동은 후속 작업입니다.

## 실행

Python 3.10 이상을 사용합니다.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python app.py
```

브라우저에서 **http://127.0.0.1:8000**을 엽니다. 별도의 Node 설치·프런트엔드 빌드가 필요하지 않습니다. 기본 주소는 로컬 컴퓨터에서만 접근할 수 있습니다.

포트 변경 예:

```sh
PORT=5050 .venv/bin/python app.py
```

`DATABASE_PATH` 환경변수로 다른 SQLite 파일 경로를 지정할 수 있습니다. 비밀정보를 담은 환경 파일과 로컬 DB는 Git 추적에서 제외합니다.

이 작업 환경에서는 네트워크 제한으로 새 가상환경의 Flask 설치가 실패했습니다. 기존 IoT 환경의 Flask로 테스트를 수행했으며, 해당 환경이 있는 이 컴퓨터에서는 다음 명령도 사용할 수 있습니다.

```sh
/Users/jaewook/iot/VIOT/bin/python app.py
```

## 사용 순서

1. 재료 관리에서 슬롯 이름과 재료 상태를 확인합니다.
2. CUSTOM에서 중량을 입력하거나 AI와 대화해 음식과 양념 배합을 제안받습니다.
3. 배합을 레시피로 저장하거나 계량을 선택합니다.
4. 실제 장치에서는 빈 컵을 놓고 제어 키를 입력합니다. 확인창에서 목표 중량과 모드를 검토한 뒤 승인합니다.
5. 진행 상태와 제조 이력을 확인합니다. 계량 도중 중단할 수도 있습니다.

기준 인분을 변경해도 CUSTOM 중량은 자동으로 배수 조정하지 않습니다. 슬롯의 재료가 바뀌면 이전 레시피는 검증에서 거부됩니다. CUSTOM에서 현재 재료와 중량을 확인하고 다시 저장해야 합니다.

## 구조

```text
app.py                Flask API, 서버 검증, 제조 작업과 SQLite 저장
uart_device.py        UART 상태 메시지 검증과 Arduino 통신
firmware/             Arduino Uno R3/R4 계량 스케치와 장치 설정
static/index.html     앱 레이아웃
static/style.css      데스크톱·태블릿·모바일 스타일
static/app.js         화면 전환, 입력, API 연동과 상태 조회
requirements.txt      서버 의존성
AGENTS.md             프로젝트 개발 지침
tests/                데모 API와 가상 Arduino 제조 테스트
```

## API 계약

요청·응답은 JSON입니다. 실패 응답은 `{"error": "설명"}` 형태입니다. 잘못된 입력은 400, 없는 자원은 404, 진행 중 작업 충돌은 409입니다.

| 메서드 | 주소 | 기능 |
| --- | --- | --- |
| GET | `/api/state` | 슬롯, 레시피, 제조 작업과 장치 상태 조회 |
| PUT | `/api/slots/{id}` | 재료 이름·유무 상태 변경 |
| POST | `/api/suggestions` | 등록 재료 기반 AI 배합 요청 |
| POST | `/api/ai/chat` | 음식 추천과 양념 배합을 위한 AI 대화 |
| POST | `/api/recipes` | 레시피 저장 |
| PUT | `/api/recipes/{id}` | 레시피 수정·즐겨찾기 변경 |
| PATCH | `/api/recipes/{id}/favorite` | `{"favorite": true/false}`로 즐겨찾기만 변경 |
| DELETE | `/api/recipes/{id}` | 레시피 삭제 |
| POST | `/api/jobs` | 승인한 모의 또는 실제 계량 요청 |
| POST | `/api/jobs/{id}/stop` | 진행 중 작업 중단 |
| DELETE | `/api/jobs/{id}` | 종료된 제조 이력 삭제 |
| POST | `/api/jobs/{id}/recipe` | 종료된 이력의 목표 배합을 새 레시피로 저장 |

레시피 요청 예:

```json
{
  "name": "나만의 양념",
  "servings": 2,
  "mode": "CUSTOM",
  "favorite": false,
  "items": [
    {"slot": "P1", "name": "소금", "kind": "powder", "revision": 1, "grams": 1.5}
  ]
}
```

`name`, `kind`, `revision`은 `/api/state`의 현재 슬롯 정보와 일치해야 합니다. 재료명을 변경하면 revision이 증가해 같은 이름으로 되돌려도 과거 레시피를 자동 재실행하지 않습니다. 레시피 모드는 `CUSTOM`, 실제 생성 결과인 `AI`, 기존 고정 예시인 `DEMO`입니다.

제조 요청은 `{"approved": true, "request_key": "고유 요청 키", "recipe": {...}}` 형식입니다. 같은 요청 키를 재전송하면 기존 작업을 반환하며 다시 실행하지 않습니다. 다른 키로 동시에 요청하면 진행 중인 작업이 끝나기 전에는 거부합니다. UI는 승인창마다 키를 생성하고 전송 재시도 시 유지합니다.

실계량 요청에는 `"device_mode": "uart"`를 추가합니다. UART 모드의 시작·중단·슬롯 수정 요청은 `X-UART-Control-Token` 헤더가 필요합니다. 제어 키 오류는 403, 장치가 준비되지 않으면 503을 반환합니다. 시작 응답의 `starting`은 요청이 기록되었다는 뜻이며, 진행 상태는 `/api/state`에서 확인합니다. 실제 계량의 `items[].actual`은 Arduino에서 확정값을 받기 전까지 `null`입니다.

UART 모드의 `/api/state`에는 슬롯별 `material_present`, `has_level_sensor`, `remaining_pct`가 포함됩니다. 분말은 `has_level_sensor=false`로 보고하고 로드셀의 무게 증가로 실제 배출을 확인합니다. 액체의 아날로그 수위는 `remaining_pct`로 제공하며 디지털 수위는 감지 여부를 제공합니다.

배합 입력 범위는 인분 1~20, 재료별 0.1~100g, 총 300g 이하입니다. UART 모드에서는 Arduino가 보고한 시험 기반 중량 한계와 액체 수위를 추가로 확인합니다. 데모만 재료별 2.5초 동안 시간 기반으로 갱신합니다. 서버는 **단일 프로세스**에서 실행합니다.

## 검증

```sh
.venv/bin/python -m unittest discover -s tests -v
node --check static/app.js
```

테스트는 임시 DB, 가상 Arduino 포트와 모의 AI 응답을 사용합니다. 기존 레시피와 데모 흐름, UART 승인과 제어 권한, 중복 실행 차단, 실측 저장, 정지 응답 지연, 통신 단절과 재시작 복구를 확인합니다. 펌웨어 빌드와 실기기 시험 순서는 [하드웨어 연동 안내](HARDWARE_INTEGRATION.md)에 있습니다.

## 남은 연동

- AI 배합·음식 추천 품질 평가
- MariaDB 스키마·접속 설정과 저장 계층 전환
- 실제 장치 배선과 보정, 중량 한계·오차·시간 제한 검증
- 외부 배포가 필요할 경우 사용자 인증·접근 범위와 운영 서버 구성

## Flutter 모바일 앱

`mobile/`의 iPhone·Android 공용 Flutter 앱은 웹과 같은 Flask API와 SQLite 데이터를 사용합니다. 재료 관리, CUSTOM·AI 배합, 레시피 저장, 제조 승인과 중단, 모의·실계량 이력을 제공합니다.

[iPhone 시연 및 Android 실행 방법](mobile/README.md)을 참고하세요. UART 시험에서는 앱의 서버 연결 화면에 Pi 서버 주소와 제어 키를 입력합니다.

웹 제조 이력과 앱 계량·이력에서 완료·중단된 이력을 삭제하거나 내 레시피로 저장할 수 있습니다. 저장 시 이름·인분·모드·목표 중량을 복사하고 현재 슬롯 정보를 재검증합니다. 슬롯이 바뀌면 저장이 거부됩니다. 진행 중 작업은 두 동작 모두 409, 없는/삭제된 이력은 404를 반환합니다. 삭제는 목록에서 숨기는 방식이며 중복 제조 방지를 위한 원본 작업·요청 키는 DB에 유지합니다. 저장된 레시피는 이력 삭제와 무관하게 유지됩니다.

즐겨찾기 전용 API는 슬롯이 바뀐 과거 레시피에도 사용할 수 있으며 저장된 배합은 변경하지 않습니다. 배합 수정·제조 시에는 현재 슬롯과의 일치를 계속 검증합니다. 웹 내 레시피의 별 버튼으로 등록·해제하고, `즐겨찾기만 보기` 버튼으로 목록을 필터링합니다.


## AI API 설정

추가 의존성은 공식 Python `openai` SDK와 `.env` 로딩용 `python-dotenv`입니다. 서버와 같은 Python 환경에서 설치하세요.

```sh
/Users/jaewook/iot/VIOT/bin/python -m pip install -r requirements.txt
# 프로젝트 루트 .env를 편집해 OPENAI_API_KEY에 실제 키를 입력하세요.
# .env가 없는 새 설치에서는: cp .env.example .env
/Users/jaewook/iot/VIOT/bin/python app.py
```

`OPENAI_MODEL`은 Responses API와 Structured Outputs를 지원하고 해당 계정에서 접근 가능한 모델 ID로 바꿉니다. 계획서의 후보 이름을 검증된 API ID로 사용하지 않습니다. 설정 변경 후 기존 서버를 재시작하세요. 서버는 실행 위치와 관계없이 프로젝트 루트의 `.env`에서 키·모델을 자동으로 읽습니다. 같은 이름의 터미널 환경변수가 있으면 환경변수가 우선합니다. 기존 값을 없애고 파일 설정을 사용하려면 `unset OPENAI_API_KEY OPENAI_MODEL`을 실행한 뒤 서버를 시작하세요. `.env`는 Git에서 제외되며 예제 파일에는 실제 키를 넣지 않습니다. 웹·앱에 키를 넣지 않습니다. 앱은 동일 서버 주소에 연결합니다.

- `POST /api/suggestions`: `{dish, servings, taste}`. 인분은 정수 1~20, 취향은 `balanced` / `less-salt` / `spicy`.
- `/api/suggestions` 성공: `{recipe, notice, missing}`. 생성이 어려우면 HTTP 200과 `recipe: null`, 이유/추가 질문을 반환합니다. 이 API는 앱의 직접 배합 화면에서 계속 사용합니다.
- `POST /api/ai/chat`: `{message, history, current_recipe}`. 메시지는 1~500자, 대화 내역은 최근 12개·총 6000자까지의 `{role: "user" | "assistant", content: "..."}`이며 `current_recipe`는 이전에 제안된 배합 또는 `null`입니다. 성공 응답은 `{message, foods, recipe, missing}`입니다. `foods`는 선택 가능한 음식 이름 목록이며, 질문·음식 추천 등 배합이 없는 응답은 `recipe: null`입니다.
- 대화 내역과 현재 배합은 웹·앱 각각의 메모리에서 관리하고 요청 시 전송합니다. 탭을 오가도 유지되지만 웹 새로고침·앱 종료 또는 새 대화 시 초기화되며, 기기 간 동기화되지 않습니다. 대화 내용은 답변 생성에 필요한 범위에서 OpenAI API에 전달됩니다.
- 대화 중 재료가 바뀌거나 부족해 이전 배합을 사용할 수 없으면 409를 반환합니다. 현재 재료를 확인하고 새 대화를 시작하세요. 서버는 AI의 숫자와 슬롯, 사용자 대화 및 이전 배합을 신뢰하지 않고 다시 검증합니다. 음식 추천에는 등록 양념이 없어도 되며 고기·채소 등 일반 식재료 보유 여부는 사용자가 대화에서 알려줍니다.
- 설정/패키지 누락 503, 동시 요청/호출 제한 429, 슬롯 변경 409, 잘못된 AI 응답/연결 실패 502, AI 시간 초과 504. 오류 형식은 `{error: "사용자 안내"}`이며 외부 오류 원문이나 키는 노출하지 않습니다.
- `/api/state`의 `ai.configured`는 키·모델 설정 여부이며 실제 접속 성공을 뜻하지 않습니다.
- AI는 슬롯·중량을 제안하고 서버는 당시 DB의 재료명·종류·revision을 결합합니다. 응답 후 슬롯 변경, 중복, 미등록/보충 필요 재료, 중량 범위를 검증합니다. 기존 승인·중복 제조 방지 규칙은 유지합니다.
- 한 서버 프로세스당 동시 AI 요청 1개, SDK 자동 재시도 없음, 네트워크 타임아웃 30초, 최대 출력 1800토큰, `store=False`. API 호출에는 사용 요금이 발생할 수 있습니다. 현재 동시 요청 제한은 다중 프로세스 전체에 대한 사용량 제한이 아닙니다.
- 공식 문서: [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs), [인증](https://developers.openai.com/api/reference/overview).

검증: `python -m unittest discover -s tests -v`는 외부 API를 모의 응답으로 대체합니다. 실제 키로 응답 품질·계정 접근·요금 설정을 확인하는 통합 시험은 별도입니다.
