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
| **issues** | `issue`, `issue_member`, `issue_status_history`, `issue_status_transition` | 호의 상태 전이, 월 마감 배치, 진행상태 조회 | `R__020_issues_lifecycle`, `R__050_issues_batch` |
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
| 모듈 간 외래키는 `allowed_dep`에 적힌 방향으로만 가능하다 | T91 |
| 허용한 의존 방향에 순환이 없다 | T92 |
| 합쳐진 `V###` 마이그레이션은 수정할 수 없다. 번호 중복/순서 역전/이름 규칙 위반 금지 | `scripts/check-migrations.sh` |
| 적용된 마이그레이션의 체크섬이 파일과 같다 | `flyway validate` (`db.sh test`에 포함) |

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

## 프로세스 구성

| 프로세스 | 하는 일 | 같은 저장소? |
|---|---|---|
| API 서버 | 조회/쓰기 API (언어 미정) | 예 |
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

import 방향 검사는 언어별 도구로 CI에 추가한다 (예: TypeScript `dependency-cruiser`, Python `import-linter`, Java `ArchUnit`, .NET `NetArchTest`).
규칙은 DB와 같다: **허용된 방향으로만 import, 순환 금지, 다른 모듈의 `domain`/`repo`는 직접 import 금지.**
