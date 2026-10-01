# 검증과 재현 방법

"그렇다고 들었다"가 아니라 **직접 돌려서 확인할 수 있는 것**만 모았다. 모든 명령은 저장소 루트에서 실행하고 Docker가 켜져 있어야 한다.

## 한 줄 검증

```bash
./scripts/db.sh test
```

빈 DB → Flyway 마이그레이션 → 체크섬 검증 → **ERD가 스키마와 같은지** → 시드 → 모듈별 테스트 + 모듈 경계 테스트. CI도 같은 명령을 쓴다.

## 주장별 확인 방법

| 확인하고 싶은 것 | 명령 | 기대 결과 |
|---|---|---|
| 규칙이 코드대로 동작한다 | `./scripts/db.sh test` | `ALL DB TESTS PASSED` |
| **테스트가 정말 문제를 잡는다** (테스트의 테스트) | `./scripts/verify-guards.sh` | 보호 장치 10개를 하나씩 빼고, 모두 해당 테스트가 실패해야 `모든 변이를 테스트가 잡았다` |
| 업로드/마감, 워커 중복 수령이 **동시에 움직여도** 안전하다 | `./scripts/repro/concurrency.sh` | 업로드는 마감이 끝날 때까지 기다렸다 거부되고, 워커 둘은 서로 막히지 않고 다른 호를 받는다 |
| `CREATE INDEX CONCURRENTLY`가 Flyway 기본 설정에서 **멈춘다** | `./scripts/repro/flyway-concurrent-index.sh` | 기본값은 30초 안에 끝나지 않고(`timeout`), 우리 설정은 정상 적용 |
| 조회/배치 성능 수치 | `./scripts/db.sh bench` | 호 1건 조회 약 0.1ms, 그룹 목록 약 0.25ms, 마감 200건 약 2.4초, 사진 3,000장 선별 약 0.5초 (PC마다 다름) |
| ERD가 스키마와 일치한다 | `./scripts/db.sh erd --check` | `ERD 최신 상태` |
| ERD 그림이 **실제로 렌더링된다** | 아래 "ERD 렌더링 확인" | `RESULT 10/10 OK` |
| 비밀이 커밋되지 않는다 | `./scripts/secret-scan.sh --tree` | `no leaks found` |
| 마이그레이션 규칙(수정 금지/번호/이름) | `./scripts/check-migrations.sh origin/main` (PR 기준) | `마이그레이션 규칙 OK` |

## 지난 설계 점검에서 찾은 문제 → 회귀 테스트

점검 때 재현했던 문제는 모두 고쳤고, 같은 문제가 다시 생기면 아래 테스트가 실패한다.

| 문제 | 테스트 |
|---|---|
| S1 재오픈하면 배치가 다시 닫아 버림 | T50 (`db/tests/issues.sql`) |
| S2 마감 후에도 업로드가 됨 | T51 (`db/tests/media.sql`) |
| S3 `issue.status` 직접 변경으로 전이 규칙 우회 | T53 (`issues.sql`) |
| S4 승인 뒤 수정이 생겨도 승인이 유효 | T54, T62 (`db/tests/review.sql`) |
| S5 조판/승인/인쇄 없이 상태만 진행 | T55, T55b (`issues.sql`) |
| S6 참여자 0명이면 진행률 NULL | T58 (`issues.sql`) |
| 워커가 죽으면 호가 영원히 멈춤 | T70~T74 (`db/tests/layout.sql`) |
| 같은 시각의 행에서 "최신" 판정이 흔들림 | T63 (`layout.sql`) |
| 모듈 경계 위반 | T90~T92 (`db/tests/architecture.sql`) |

`verify-guards.sh`는 이 테스트들이 "통과만 하는 가짜"가 아님을 확인한다.

## ERD 렌더링 확인

GitHub에서 그림이 깨지는 것을 막기 위해 실제 Mermaid 엔진으로 확인한다. (Mermaid 라이브러리를 CDN에서 받으므로 인터넷이 필요하다.)

```bash
python3 -m http.server 8765 --bind 127.0.0.1
# 브라우저에서 http://127.0.0.1:8765/scripts/erd-render-check.html 열기
# 맨 위에 "RESULT 10/10 OK" 가 나와야 한다. 실패하면 다이어그램별 오류가 빨갛게 표시된다.
```

이 검사로 실제 결함을 한 번 잡았다: 테이블 이름 `style`이 Mermaid 예약어라 3개 다이어그램이 깨졌고, 모든 엔티티 이름에 따옴표를 붙여 해결했다.

## 도구 평가 재현 (린트/스캔)

지난 검토에서 판단 근거로 쓴 실행들이다. 숫자는 2026-10-01 기준이며 파일이 바뀌면 달라진다.

```bash
# shellcheck: 지적 0건이어야 함
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable scripts/*.sh scripts/repro/*.sh .githooks/pre-commit

# actionlint: 워크플로 문법 검사, 지적 0건이어야 함
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest

# squawk: baseline 에는 소음 118건. 위험한 변경(NOT NULL 추가, 인덱스 잠금, 컬럼 삭제 등)은 실제로 잡음
docker run --rm -v "$PWD:/w" -w /w ghcr.io/sbdchd/squawk:latest db/migrations/V001__baseline.sql

# sqlfluff: R__020 에서 248건(대부분 스타일). 함수 본문 안은 검사하지 않음 -> 도입하지 않기로 함
python3 -m pip install sqlfluff
python3 -m sqlfluff lint db/migrations/R__020_issues_lifecycle.sql --dialect postgres
```

비밀 스캔이 실제로 잡는지 확인하려면 가짜 토큰을 스테이징해 본다 (값은 임의의 가짜).

```bash
printf 'token = "ghp_%s"\n' "$(head -c 200 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 36)" > zz_fake.txt
git add zz_fake.txt && bash scripts/secret-scan.sh --staged   # leaks found, 종료 코드 1
git reset -q && rm zz_fake.txt
```

## 이 검증의 한계

- **환경**: Windows + Docker Desktop, PostgreSQL 16.15, Flyway 13.8.1에서 확인했다. 다른 버전에서는 같은 동작을 보장하지 않는다 (특히 Flyway 멈춤 재현은 버전에 민감하다).
- **GitHub Actions**: 워크플로 파일의 문법은 `actionlint`로 확인했지만, 원격에서 한 번도 실행되지 않았다.
- **성능 수치**: 한 대의 PC, 컨테이너 기본 설정, 합성 데이터 기준이다. 실제 데이터 분포와 운영 DB 사양에서는 다르다. 비교는 같은 PC에서 전/후로 한다.
- **동시성 재현**은 타이밍 기반이다. 판정 기준을 넉넉하게 잡았지만(잠금 3초 / 시작 1.5초 지연 / 임계값 1.0~1.5초), 매우 느린 환경에서는 오탐할 수 있다. 이 스크립트가 보여 주는 것은 "그 순서로 실행했을 때의 보장"이지, 모든 인터리빙의 증명은 아니다.
- **변이 검사**는 10가지뿐이다. 통과해도 "모든 테스트가 충분하다"는 뜻이 아니다.
- **CI에 들어간 것**은 `db.sh test`(ERD 일치 포함)와 비밀 스캔뿐이다. `verify-guards.sh`, `repro/*`, `bench`, ERD 렌더링 확인은 시간이 오래 걸리거나 인터넷/브라우저가 필요해 수동 실행이다.
- **Mermaid 버전**: 렌더링 확인은 Mermaid 11을 썼다. GitHub에 내장된 버전과 다를 수 있다. 원격에 올린 뒤 `docs/erd.md`가 GitHub에서 실제로 그려지는지 한 번 눈으로 확인해야 한다.
