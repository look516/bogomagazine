# 26puppy

가족 그룹이 사진을 올리면 매월 한 호씩 **자동으로 조판**해 미리보기를 보여 주고 **인쇄**까지 연결하는 서비스.
지금은 DB 설계와 규칙이 먼저 만들어진 상태이고, 앱 코드(언어 미정)와 조판 알고리즘은 아직 없다.

## 빠른 시작

```bash
./scripts/setup.sh        # git 훅 활성화 (한 번만)
./scripts/db.sh test      # 빈 DB → 마이그레이션 → 시드 → 전체 테스트. Docker 필요
```

## 폴더 구조

```
├─ db/
│  ├─ migrations/        Flyway: V001__baseline.sql (구조, 수정 금지) + R__###_모듈_*.sql (함수/뷰/트리거)
│  ├─ seed/dev.sql       개발용 샘플 데이터 (마이그레이션 아님)
│  ├─ bench/perf.sql     성능 측정 (./scripts/db.sh bench)
│  └─ tests/             모듈별 테스트 + architecture.sql(모듈 경계 검증)
├─ docs/
│  ├─ status.md          진행 현황 체크리스트 (한 것 / 앞으로 / 팀 결정 사항)
│  ├─ erd.md             ERD (스키마에서 자동 생성, 모듈별 관계도 포함)
│  ├─ architecture.md    모듈 지도, 의존 규칙, 알려진 예외
│  ├─ workflow.md        작업 흐름, 브랜치/커밋 규칙
│  ├─ verification.md    검증/재현 방법 (직접 돌려 볼 수 있는 것만)
│  ├─ api-progress.md    호 진행상태 조회 API + 상태값 + 배치/워커 계약
│  ├─ algorithm-io.md    자동 조판 알고리즘 입출력 계약
│  └─ adr/               결정 기록 (모듈러 모놀리스, DB 마이그레이션)
├─ scripts/              db.sh(개발/테스트/ERD/성능), check-migrations.sh, secret-scan.sh, check.sh, setup.sh,
│                        verify-guards.sh(변이 검사), repro/(재현 스크립트), analysis/(함수 수준 의존 분석),
│                        erd-render-check.html
├─ .githooks/            pre-commit
├─ .github/              CI 워크플로, PR 템플릿
├─ docker-compose.yml    로컬/CI 공용 PostgreSQL + Flyway
└─ TODO.md               보류/결정 대기/구현 예정
```

## 읽는 순서

0. [docs/status.md](docs/status.md): **진행 현황 체크리스트** — 한 것, 해야 할 것, 팀이 결정할 것
1. [docs/architecture.md](docs/architecture.md): 어떤 모듈이 무엇을 소유하나
2. [docs/workflow.md](docs/workflow.md): 무엇을 바꿀 때 어떤 파일을 고치나
3. [docs/api-progress.md](docs/api-progress.md): 호의 생애와 상태값
4. [TODO.md](TODO.md): 아직 안 한 것
