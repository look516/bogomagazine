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
| **테스트가 정말 문제를 잡는다** (테스트의 테스트) | `./scripts/verify-guards.sh` | 보호 장치 24개를 하나씩 빼고, 모두 해당 테스트가 실패해야 `모든 변이를 테스트가 잡았다` |
| **함수/뷰 수준 모듈 의존**(외래키로 안 보이는 결합) | `./scripts/db.sh up && ./scripts/db.sh migrate` 후 `PYTHONUTF8=1 python3 scripts/analysis/fn-deps.py` | 모듈 간 의존 목록. `architecture.md`의 "알려진 예외" 표와 일치해야 하고, 표에 없는 줄이 나오면 문서화하거나 함수를 옮긴다 |
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

## DB 의존성 점검 (2026-10-01 실행)

| 점검 | 방법 | 결과 |
|---|---|---|
| 테이블 외래키 순환 | `pg_constraint`에서 재귀 쿼리 | 없음 (자기참조 `style.based_on`, `font.fallback`뿐) |
| 호 상태 정의 일관성 | CHECK 제약 / 전이표 / `collecting`에서의 도달 가능성 비교 | 모두 일치, 끝점은 `archived`뿐 |
| 중복·불필요 인덱스 | 완전 중복 + 다른 인덱스의 앞부분인 것. 쿼리 자체도 일부러 만든 중복으로 검증 | 없음 |
| 반복 마이그레이션 순서 의존 | 7개 파일을 **역순/무작위 순서**로 적용한 뒤 전체 테스트, 이미 적용된 DB에 2번 재적용 | 전부 통과 (순서에 의존하지 않음) |
| 테스트가 호출하지 않는 함수 | `track_functions=all`로 전체 테스트 실행 후 `pg_stat_user_functions` | 함수 24개 모두 호출됨 (분기 커버리지는 미측정) |
| 함수/뷰 수준 모듈 의존 | `scripts/analysis/fn-deps.py` | 문서의 예외 표와 일치. 단, 문서에 없던 `intake → groups` 1건 발견 → 함수를 옮겨 해소 |
| 삭제 동작 | 실제로 지워 보기 | **결함 발견**: 조판 결과가 있는 호는 삭제 실패 → 배치 외래키를 커밋 시점 검사로 수정, T04b/T04c로 고정 |
| 의존성이 깨지는 방식 | 컬럼 삭제/이름 변경을 직접 시도 | 뷰가 쓰는 컬럼은 DB가 삭제를 막음. **함수 본문이 쓰는 컬럼은 이름을 바꿔도 마이그레이션이 성공**하고 테스트에서만 실패 |

## 정규화·참조 정합성 점검 (2026-10-01 실행)

| 점검 | 방법 | 결과 |
|---|---|---|
| 같은 사실이 두 곳에 있는 구조 찾기 | 한 테이블이 부모 A와 B를 동시에 참조하고 B도 A로 이어지는 "마름모" 탐색 (`pg_constraint`) | 호/조판/게시물/계정 사이에 9곳 (사용자 참조는 "누가"를 뜻해 제외) |
| 실제로 어긋난 값이 들어가는가 | 호 A/B를 만들어 엇갈리게 연결해 보기 17건 | 보강 전: **16건 허용**(막힌 것은 승인의 호 불일치 1건뿐). 보강 후: 14건 거부 + 의도적으로 허용한 3건(`T112`~`T114`) |
| 정상 데이터까지 막지 않는가 | 같은 시나리오의 일관된 입력 | 모두 허용 (T100~T111의 양성 대조) |
| 복합 키에서 연쇄 동작이 유지되는가 | 게시물 삭제 시 `SET NULL (source_post_id)`, 조판 삭제 시 `CASCADE` | 정상 (T115, T116) |
| 새 보호 장치가 정말 막는가 | `verify-guards.sh` 13항목 추가 | 24/24 전부 잡힘 |
| 기존 기능이 깨지지 않았나 | 기존 테스트 전체 | 2곳이 실패했고 둘 다 **테스트가 일관되지 않은 데이터**를 쓰던 것(그룹 밖 사용자를 호 참여자로, 참여자가 아닌 사용자가 사진 업로드)이라 코드가 아닌 테스트를 고침 |

## 이 검증의 한계

- **환경**: Windows + Docker Desktop, PostgreSQL 16.15, Flyway 13.8.1에서 확인했다. 다른 버전에서는 같은 동작을 보장하지 않는다 (특히 Flyway 멈춤 재현은 버전에 민감하다).
- **GitHub Actions**: 워크플로 파일의 문법은 `actionlint`로 확인했지만, 원격에서 한 번도 실행되지 않았다.
- **성능 수치**: 한 대의 PC, 컨테이너 기본 설정, 합성 데이터 기준이다. 실제 데이터 분포와 운영 DB 사양에서는 다르다. 비교는 같은 PC에서 전/후로 한다.
- **동시성 재현**은 타이밍 기반이다. 판정 기준을 넉넉하게 잡았지만(잠금 3초 / 시작 1.5초 지연 / 임계값 1.0~1.5초), 매우 느린 환경에서는 오탐할 수 있다. 이 스크립트가 보여 주는 것은 "그 순서로 실행했을 때의 보장"이지, 모든 인터리빙의 증명은 아니다.
- **함수 수준 의존 분석**은 이름 매칭(정규식) 기반이라 동적 SQL은 못 보고 오탐/누락이 있을 수 있다. 결과를 사람이 읽고 판단해야 하며, 아직 CI 검사가 아니다.
- **함수 커버리지**는 "호출됐는가"까지만 본다. 함수 안의 분기(오류 경로 등)가 실행됐는지는 모른다.
- **변이 검사**는 24가지뿐이다. 통과해도 "모든 테스트가 충분하다"는 뜻이 아니다.
- **CI에 들어간 것**은 `db.sh test`(ERD 일치 포함)와 비밀 스캔뿐이다. `verify-guards.sh`, `repro/*`, `bench`, ERD 렌더링 확인은 시간이 오래 걸리거나 인터넷/브라우저가 필요해 수동 실행이다.
- **Mermaid 버전**: 렌더링 확인은 Mermaid 11을 썼다. GitHub에 내장된 버전과 다를 수 있다. 원격에 올린 뒤 `docs/erd.md`가 GitHub에서 실제로 그려지는지 한 번 눈으로 확인해야 한다.
