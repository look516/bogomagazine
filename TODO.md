# TODO

## 1순위: ERD 초안 — 마감 12시 (오늘 자정으로 가정함, 시각 확인 필요)

- [x] 스키마에서 자동 생성되는 ERD 초안 → [docs/erd.md](docs/erd.md) (모듈 의존도, 전체 관계, 모듈별 상세, 테이블 목록)
  - 검증: Mermaid 엔진으로 10개 다이어그램 모두 렌더링 확인(10/10), 스키마와 어긋나면 CI 실패(`db.sh erd --check`)
  - 한계: 전체 관계도는 테이블 28개라 가로로 넓다. 읽기 좋은 것은 모듈별 상세
- [ ] 초안 검토: 모듈 경계, 테이블/컬럼 이름, 관계선 확인. 특히 `issues`가 조정자 역할을 하는 결합 ([architecture.md](docs/architecture.md)의 "알려진 예외")
- [ ] 아래 보류 항목이 확정되면 ERD가 바뀐다 (확정 → 새 `V###` 마이그레이션 → `./scripts/db.sh erd`):

| 보류 항목 | ERD 변경 예정 |
|---|---|
| 마감 시각 강제 + 유예 | `media.initiated_at`, `media.upload_status`, `family_group.upload_grace` |
| DB 권한 분리 | 테이블 변경 없음 (권한/함수) |
| 다중 승인 정책 | `family_group.approval_policy`, `issue.approvals_required` |
| 마감 임박 알림 | `notification`, `device` 테이블 추가 (소유 모듈을 새로 정할지 기존 모듈에 둘지 결정 필요) |
| 탈퇴 시 콘텐츠 처리 | 정책에 따라 `media`/`source_post`의 삭제 표시 컬럼 가능성 |

## 보류 중 (설계안까지 있고 구현만 남음)

### 1. 마감 시각 강제 + 업로드 유예
- 지금: DB는 `close_at` 시각 자체를 강제하지 않는다. 배치가 호를 닫기 전까지 업로드를 받는다 (앱이 먼저 확인해야 함).
- 안: `media`에 `initiated_at`(업로드 시작)과 `upload_status`(pending/complete)를 추가한다. 시작은 `close_at`까지, 완료는 `close_at + 유예`까지 허용한다.
  대용량 업로드가 마감 직전에 시작해 직후에 끝나도 버려지지 않게 하려는 것이다. 마감 배치도 `close_at + 유예` 이후에 처리한다.
- 같이: `family_group.upload_grace`(기본 10분), 현재 시각을 `app_now()`로 감싸 테스트에서 고정 가능하게.
- 정할 것: 유예 시간, 업로드를 "시작/완료"로 나눌지.

### 2. DB 권한 분리
- 지금: `issue.status` 직접 변경 차단은 세션 플래그라 우회 가능한 가드레일이다.
- 안: 앱 접속 역할에서 `issue.status` 컬럼 `UPDATE` 권한을 회수하고 `change_issue_status()`를 `SECURITY DEFINER`(+`search_path` 고정)로 만든다.
  역할: 앱(읽기/쓰기), 마감 배치, 조판 워커, 조회 API(뷰만 읽기). 필요하면 조회 역할에 행 수준 보안(RLS)으로 가족 그룹 간 격리.
- 정할 것: 배포 환경과 역할 구성. (환경이 정해진 뒤에 한다)

### 3. 다중 승인 정책
- 지금: "페이지별 가장 최근 승인 1건"만 본다. 몇 명이 승인해야 하는지 규칙이 없다.
- 안: `family_group.approval_policy`(한 명 / 편집자 전원 / 과반)를 두고 호 생성 때 `issue.approvals_required`로 복사한다 (진행 중인 호의 규칙이 바뀌지 않게).
  뷰는 페이지마다 **사용자별 최신 판정**을 보고, 유효한 승인 수가 기준 이상이며 수정 요청이 없을 때 승인으로 센다.
- 정할 것: 정책 종류, 승인권을 가진 역할.

### 4. 마감 임박 알림
- 안: `notification` 발송 대기열 테이블(`UNIQUE (user_id, issue_id, kind)`로 중복 방지). 마감 배치가 `enqueue_deadline_reminders()`로 "3일 전/1일 전" 알림을 넣고, 발송 워커가 `SKIP LOCKED`로 처리한다.
  푸시 토큰(`device`)과 수신 설정도 필요하다. 대상은 `issue_member.submit_status = 'pending'`.
- 정할 것: 채널(푸시/이메일 등), 시점.

## 결정 대기 (정책)

- **삭제 정책**: 지금은 인쇄 작업이 있는 호(`print_job` → `issue`), 호가 있는 가족 그룹(`publication`), 데이터가 있는 사용자는 **삭제할 수 없다.** 의도한 보호지만
  "인쇄된 호의 삭제 요청", "그룹 해체", "보관 기간 후 삭제"를 어떻게 할지는 정하지 않았다. 탈퇴 시 콘텐츠 처리와 함께 결정한다.
- **탈퇴 시 콘텐츠 처리**: 지금 `anonymize_user()`는 신원/인증 정보만 지우고 사진·게시물(SNS 원본 데이터 `raw` 포함)·본문은 남긴다.
  삭제할지, 이미 인쇄된 호는 어떻게 할지 정해야 한다. 법적 검토가 필요하다 (가족 사진에는 미성년자와 타인의 얼굴이 있다).

## 구현 예정

- [ ] 앱 언어/프레임워크 확정 확인 (`Dockerfile` 기준 Java 21 + Gradle) → `src/` 구조와 모듈 경계 검사(ArchUnit) 도입 ([architecture.md](docs/architecture.md))
- [ ] 조판 알고리즘 v0.1 + 조판 워커 ([algorithm-io.md](docs/algorithm-io.md)의 계약대로)
- [ ] 운영 DB 마이그레이션 절차 (백업, 승인, 적용 시점)
- [ ] 원격 저장소 생성, `main` 브랜치 보호, `CODEOWNERS` ([workflow.md](docs/workflow.md) 끝부분)
- [ ] 이미지 분석/PDF 렌더 워커
- [ ] `verify-guards.sh`(변이 검사)를 CI에 정기(주 1회/수동) 실행으로 추가 — 약 2~3분, 테스트가 통과만 하는 가짜가 되는 것을 막는다 ([verification.md](docs/verification.md))
- [ ] CI에 `shellcheck` + `actionlint` 추가 (지금 저장소에서 둘 다 통과 확인됨. 비용 작고 사고를 일찍 잡는다)
- [ ] 첫 운영 데이터가 생기면 CI에 `squawk`(PostgreSQL 마이그레이션 안전성 린터)를 **새로 추가된 V 파일에만** 적용. baseline에는 소음 118건, 규칙 조정 필요
- [ ] 앱 코드가 생기면 모듈 경계 검사(ArchUnit 등가물)를 CI 필수 검사로 추가 ([architecture.md](docs/architecture.md))
- [ ] **plpgsql 정적 검사(`plpgsql_check` 등) 도입 검토**: 함수 본문은 PostgreSQL이 검사·추적하지 않아, 컬럼 이름을 바꿔도 마이그레이션은 성공하고 테스트에서만 걸린다(재현 확인). 기본 postgres 이미지에는 없어 별도 이미지가 필요하다 (미검증)
- [ ] 함수 수준 모듈 의존 분석(`scripts/analysis/fn-deps.py`)을 CI 검사로: 새 역방향 의존이 생기면 실패하게 (지금은 사람이 실행)
- [ ] 함수 분기 커버리지 측정 (지금은 "호출됐는가"만 확인: 24개 모두 호출됨)
- [ ] CD 설계 — **앱 언어와 호스팅이 정해진 뒤.** 착수 전에 이미 정해진 원칙: forward-only 마이그레이션, 앱 배포와 별개 단계로 마이그레이션 실행(+백업, 운영은 수동 승인),
      운영에도 `FLYWAY_POSTGRESQL_TRANSACTIONAL_LOCK=false` 적용([ADR-0002](docs/adr/0002-db-migrations.md)), 배포 중 구버전/신버전 앱이 같은 DB를 함께 쓸 수 있게 변경(컬럼 추가 → 앱 전환 → 옛 컬럼 제거)

## 정합성 점검에서 남은 것 (일부러 미룬 것)

- [ ] **승인/수정/코멘트 작성자가 호 참여자인지(또는 승인권이 있는 역할인지) 검사** — 업로더/등록자에는 적용했지만 이쪽은 아직이다. 누가 승인할 수 있는지는 "다중 승인 정책"과 함께 정한다.
- [ ] `family_group.owner_id`/`publication.owner_id`가 그 그룹의 구성원인지(관리자 역할) 검사
- [ ] 배치 `slot_id`가 템플릿 마스터에 있는지는 DB가 못 보므로 조판 알고리즘 출력 검증으로 (알고리즘 구현 시)

## 결정 기록 (일부러 하지 않기로 한 것)

| 항목 | 이유 |
|---|---|
| `sqlfluff` 도입 | 위반 248건이 거의 전부 들여쓰기/줄 길이/대소문자 스타일이고, 함수 본문(`$$ ... $$`)은 아예 검사하지 않는다 (본문에 쓰레기 코드를 넣어도 통과함을 확인). 소음은 큰데 우리 로직은 못 본다 |
| 앱/CD 파이프라인을 지금 만들기 | 앱 코드, 언어, 호스팅이 없다. 대신 CD에 영향을 주는 원칙만 위 "구현 예정"에 먼저 기록했다 |
| 내용 없는 자리표시용 CI 작업 | "검사하고 있다"는 거짓 안심을 준다. 앱 코드가 생기면 실제 검사를 붙인다 |
| 정규화를 더 진행해 중복 컬럼 제거 | `override.issue_id`, `approval.issue_id` 같은 중복 컬럼은 조회·잠금·연쇄 삭제 경로에 쓰인다. 지우는 대신 **복합 외래키로 어긋나지 못하게** 했다 |
| 조판의 `template_id` ↔ 호의 `template_id` 일치 강제 | 조판이 "그 시점에 쓴 템플릿"을 기록하는 것이라 달라도 된다고 판단 (T112) |
| 수정로그 `target_id` 외래키(다형 참조) | 조판이 재생성되면 대상이 사라지는 것이 정상이다. 로그는 추가만 한다 (T113) |
| 서비스(마이크로서비스) 분리 | [ADR-0001](docs/adr/0001-modular-monolith.md) 참고 |

## 알려진 한계

- 비밀 스캔(gitleaks)은 패턴 기반이라 완벽한 보증이 아니다. 로컬 pre-commit은 Docker가 꺼져 있으면 경고만 하고 통과하며(CI가 다시 검사), `--no-verify`로 우회할 수 있다.
- **Flyway `CREATE INDEX CONCURRENTLY` 함정**: `FLYWAY_POSTGRESQL_TRANSACTIONAL_LOCK=false`가 없으면 배포가 무한 정지한다. `docker-compose.dbtest.yml`에는 적용했지만 **운영 배포 설정에는 따로 넣어야 한다** ([ADR-0002](docs/adr/0002-db-migrations.md)).

- GitHub Actions 워크플로(`.github/workflows/ci.yml`)는 아직 한 번도 원격에서 실행해 보지 못했다. 같은 명령(`scripts/db.sh test`, `scripts/check-migrations.sh`)은 로컬에서 검증했다.
- 모듈 간 **함수/뷰 수준 결합**은 자동 검사가 없다 ([architecture.md](docs/architecture.md)의 "알려진 예외").
- 사용자/템플릿/스타일을 참조하는 외래키 21개에는 인덱스가 없다. 사용자를 실제로 삭제하지 않고 익명화하므로 일부러 뺐다.
- 같은 트랜잭션에서 만든 행의 `created_at`은 같다. "최신" 판정은 `seq`로 하므로 영향이 없지만, 시각 정렬에 의존하는 새 코드를 쓰면 안 된다.
