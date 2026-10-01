# 아키텍처: 모듈러 모놀리스

결정 배경은 [ADR-0001](adr/0001-modular-monolith.md), DB 변경 방식은 [ADR-0002](adr/0002-db-migrations.md).

## 한 줄 요약

**배포 단위는 하나(+ 같은 코드베이스의 워커 프로세스), 코드와 DB는 8개 모듈로 나누고, 모듈 경계는 CI가 강제한다.**

```
        ┌─────────┐   ┌───────────┐
        │identity │   │ templates │        (아무것도 참조하지 않는 바닥 모듈)
        └────┬────┘   └─────┬─────┘
             │              │
        ┌────▼────┐         │
        │ groups  │         │
        └────┬────┘         │
             │              │
        ┌────▼──────────────▼──┐
        │        issues        │  호 생명주기(상태 전이, 월 마감 배치, 진행 조회)
        └───┬────────┬─────────┘
            │        │
       ┌────▼───┐    │
       │ intake │    │            intake: 사진/게시물 수집·선별
       └────┬───┘    │
            │        │
        ┌───▼────────▼──┐
        │    layout     │          layout: 자동 조판 결과 + 워커
        └───┬───────┬───┘
            │       │
       ┌────▼───┐ ┌─▼────────┐
       │ review │ │ printing │     review: 승인/수정/코멘트, printing: 인쇄 작업/주문
       └────────┘ └──────────┘
```

화살표 방향(위 → 아래)이 "아래가 위를 참조해도 된다"는 뜻이다. 반대 방향 외래키는 CI가 거부한다.

## 모듈 지도

| 모듈 | 소유 테이블 | 책임 | 마이그레이션 파일 |
|---|---|---|---|
| **identity** | `app_user`, `auth_identity` | 사용자, 카카오/애플 로그인 연결, 회원 탈퇴 익명화 | `V001`, `R__070_identity_privacy` |
| **groups** | `family_group`, `family_member`, `publication` | 가족 그룹, 구성원, 월간지 | `V001` |
| **templates** | `template`, `page_master`, `style`, `font` | 불변 버전의 판형/슬롯/스타일/폰트 | `V001` |
| **issues** | `issue`, `issue_member`, `issue_status_history`, `issue_status_transition` | 호의 상태 전이, 월 마감 배치, 진행상태 조회, 업로드할 호 고르기(`upload_target_issue`) | `R__020_issues_lifecycle`, `R__050_issues_batch` |
| **intake** | `social_account`, `source_post`, `media`, `media_rendition`, `text_block` | 사진/게시물 수집, 업로드 가드, 선별 | `R__010_intake_selection`, `R__030_intake_guards` |
| **layout** | `layout_run`, `page`, `placement`, `preview` | 자동 조판 결과, 워커 임대 계약, 조판 큐 | `R__060_layout_worker` |
| **review** | `approval`, `override`, `comment`, `page_lock` | 승인(버전 기록), 사람의 수정, 코멘트, 락 | `R__040_review_guards` |
| **printing** | `print_job`, `print_order` | PDF/프리플라이트, 주문 | `V001` |

**소유권의 단일 기준은 각 테이블의 코멘트(`COMMENT ON TABLE ... IS 'module:<모듈> | 설명'`)다.** 이 문서의 표와 다르면 DB가 맞다.
컬럼 수준의 구조와 모듈별 관계도는 자동 생성되는 [erd.md](erd.md)를 본다.

## 강제되는 규칙 (CI 실패)

| 규칙 | 검사 |
|---|---|
| 모든 테이블은 `module:<모듈>` 코멘트로 소유 모듈을 밝혀야 한다 (없거나 알 수 없는 모듈이면 실패) | T90 |
| `docs/erd.md`는 현재 스키마와 같아야 한다 | `db.sh erd --check` (`db.sh test`에 포함) |
| **같은 사실이 두 곳에 있으면 어긋나지 못한다**: 사진/텍스트는 원본 게시물과, 승인/수정/인쇄작업은 조판과, 게시물은 SNS 계정과, 배치/코멘트는 호와 같은 호여야 하고, 호 참여자는 그룹 구성원, 업로더는 호 참여자여야 한다 | 복합 외래키 9개 + 트리거 5개, `db/tests/integrity.sql` T100~T116 |
| 모듈 간 외래키는 `allowed_dep`에 적힌 방향으로만 가능하다 | T91 |
| 허용한 의존 방향에 순환이 없다 | T92 |
| `main`에 합쳐진 `V###` 마이그레이션은 수정할 수 없다. 번호 중복/순서 역전/이름 규칙 위반 금지 | `scripts/check-migrations.sh` |
| 적용된 마이그레이션의 체크섬이 파일과 같다 | `flyway validate` (`db.sh test`에 포함) |

## 참조 정합성 (같은 사실이 두 곳에 있을 때)

정규화를 더 하는 대신 **중복된 값이 서로 어긋나지 못하게 제약을 건다.** (컬럼을 지우면 조회와 잠금 경로가 복잡해진다)

| 방법 | 대상 |
|---|---|
| **복합 외래키** (부모에 `UNIQUE(id, issue_id)` 등을 두고 자식이 둘을 함께 참조) | `media`/`text_block` ↔ `source_post`(같은 호), `approval` ↔ `layout_run`/`page`(같은 호, 같은 조판), `override`/`print_job` ↔ `layout_run`(같은 호), `source_post` ↔ `social_account`(같은 플랫폼, 같은 주인), `preview` ↔ `page`(존재하는 페이지) |
| **트리거** (호를 직접 갖지 않거나 그룹 구성원 관계처럼 외래키로 못 쓰는 것) | `placement`(같은 호의 사진/텍스트), `comment`(같은 호의 페이지), `issue_member`(그룹 구성원), `media`/`source_post`(업로더/등록자는 viewer 아닌 호 참여자) |

복합 외래키는 컬럼 중 하나가 NULL 이면 검사를 건너뛴다. 게시물 없이 올린 사진, 호 전체 승인이 그 경우다.
**일부러 허용한 것**: 조판이 쓴 템플릿이 호의 템플릿과 다른 것(그 시점의 기록), 수정로그의 `target_id`가 사라진 대상을 가리키는 것(다형 로그), 배치의 `slot_id`(템플릿 JSON 안의 이름, 조판 알고리즘 출력에서 검증). 모두 `integrity.sql`에 "허용됨"으로 고정되어 있다.

## 알려진 예외 (현재 규칙을 어기지만 의도한 결합)

외래키 방향은 위 규칙을 지키지만, **함수/뷰 수준에서는 아래 결합이 있다.** 자동으로 검사되지 않으니 수정할 때 주의한다.

| 위치 | 결합 | 이유 |
|---|---|---|
| `issues.change_issue_status()` | `layout_run`(무효화), `override`, `print_job`, `v_issue_progress`를 읽거나 씀 | 호 상태 전이의 사전조건이 조판/승인/인쇄의 실체를 확인해야 하고, 한 트랜잭션이어야 한다. **issues가 생명주기를 지휘하는 조정자(process manager)** 다. |
| `issues.v_issue_progress` | media, layout_run, page, approval, override, placement, print_job, print_order를 조인 | 진행 조회 전용 읽기 모델. 읽기만 한다. |
| `issues.close_due_issues()` | `intake.select_media()` 호출, `media` 조회 | 마감 시 선별을 한 트랜잭션에서 하기 위해. |
| `review`/`layout`의 트리거·워커 함수 | `issues.change_issue_status()` 호출 (승인 후 수정 시 `review` 복귀, 조판 완료 시 `review` 전환) | 상태 전이의 단일 진입점을 지키기 위해. 외래키 방향(아래→위)과는 같다. |
| `identity.anonymize_user()` | groups, issues, intake, review의 행을 삭제/수정 | 탈퇴는 본질적으로 여러 모듈을 가로지르는 작업. |

이 예외가 늘어나면 모듈 경계가 무너지고 있다는 신호다. 새 결합을 추가하는 PR은 이 표를 함께 고친다.

### 함수 수준까지 보면 "계층"이 아니다 (분석으로 확인)

외래키만 보면 위 그림처럼 순환 없는 계층이다. 그러나 함수/뷰 본문까지 파싱해 보면(`scripts/analysis/fn-deps.py`, 함수 24개·뷰 2개)
**`issues`는 `layout`/`review`/`intake`/`printing`과 양방향 결합**이 있다. 외래키는 그쪽이 `issues`를 가리키고, 함수는 `issues`가 그쪽을 읽는다.
`identity.anonymize_user()`도 groups/issues/intake/review를 건드린다. 위 표가 그 목록이며, 분석 결과와 일치함을 확인했다.

- 의미: **`issues`는 독립적으로 바꾸거나 떼어낼 수 없다.** `layout_run`/`approval`/`override`/`print_job`/`placement`/`media`의 컬럼을 바꾸면
  `change_issue_status()`와 `v_issue_progress`가 영향을 받는다.
- DB가 지켜 주는 것과 아닌 것: **뷰**(`v_issue_progress`)가 쓰는 컬럼은 PostgreSQL이 추적해서 지우려 하면 막는다.
  **plpgsql 함수 본문**은 추적하지 않아서, 컬럼 이름을 바꿔도 마이그레이션은 성공하고 **테스트에서만** 실패한다(재현 확인). 그래서 모든 함수가 테스트에서 호출되는 것이 중요하다 (현재 24개 모두 호출됨, 분기 단위 커버리지는 미측정).

## 프로세스 구성

| 프로세스 | 하는 일 | 같은 저장소? |
|---|---|---|
| API 서버 | 조회/쓰기 API (`Dockerfile` 기준 Java 21 + Spring Boot로 보임, 팀 확인) | 예 |
| 마감 배치 | `SELECT * FROM run_monthly_batch()` 를 30분마다 호출 | 예 (스케줄러 또는 pg_cron) |
| 조판 워커 | `claim_compose_job` → 조판 → `complete_compose_job` | 예, 별도 프로세스 |
| (예정) 이미지 분석/PDF 렌더 워커 | 무거운 계산 | 예, 별도 프로세스 |

워커를 별도 프로세스로 두는 것은 서비스 분리가 아니다. 같은 코드베이스, 같은 DB, 배포 단위만 다르다.

## 앱 코드 구조 (언어 확정 후)

언어가 정해지면 DB 모듈과 같은 이름으로 맞춘다.

```
src/
├─ modules/
│  ├─ identity/   groups/   templates/   issues/   intake/   layout/   review/   printing/
│  │    └─ 각 모듈: api(외부 공개 인터페이스) / domain / repo(DB 접근) 로 나누고,
│  │       다른 모듈은 api 만 import 할 수 있다
│  └─ shared/     (모듈이 공유하는 순수 유틸. 비즈니스 규칙을 넣지 않는다)
└─ apps/
   ├─ api/        (HTTP 서버 진입점)
   └─ worker/     (조판/배치 워커 진입점)
```

import 방향 검사는 언어별 도구로 CI에 추가한다 (이 저장소의 `Dockerfile`이 Java 21이므로 Java로 확정되면 `ArchUnit`. 참고: TypeScript `dependency-cruiser`, Python `import-linter`, .NET `NetArchTest`).
규칙은 DB와 같다: **허용된 방향으로만 import, 순환 금지, 다른 모듈의 `domain`/`repo`는 직접 import 금지.**
