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
        │ groups  │         │          groups: 가족 그룹, 구성원, 초대 링크, 조부모님 배송지
        └────┬────┘         │
             │              │
        ┌────▼──────────────▼──┐
        │        issues        │  호 생명주기(상태 전이, 월 마감 배치, 진행 조회)
        └───┬────────┬─────────┘
            │        │
       ┌────▼───┐    │
       │  feed  │    │            feed: 앱 안 피드(글/사진)와 호별 사진 선별
       └────┬───┘    │
            │        │
        ┌───▼────────▼──┐
        │    layout     │          layout: 자동 조판 결과 + 워커
        └───┬───────┬───┘
            │       │
       ┌────▼───┐ ┌─▼────────┐
       │ review │ │ printing │     review: 승인/수정, printing: 인쇄 작업/주문(조부모님 댁마다 1건)
       └────────┘ └──────────┘
```

화살표 방향(위 → 아래)이 "아래가 위를 참조해도 된다"는 뜻이다. 반대 방향 외래키는 CI가 거부한다.

## 모듈 지도

| 모듈 | 소유 테이블 | 책임 | 마이그레이션 파일 |
|---|---|---|---|
| **identity** | `app_user`, `auth_identity` | 사용자, 카카오/애플 로그인 연결, 회원 탈퇴 익명화 | `V001`, `R__070_identity_privacy` |
| **groups** | `family_group`, `family_member`, `family_invite`, `delivery_address` | 가족 그룹(방장 = `owner_id`), 구성원(나가면 `left_at`), 카카오톡 초대 링크, 조부모님 배송지(주소만 저장) | `V001`, `R__005_groups_membership` |
| **templates** | `template`, `page_master`, `style`, `font` | 불변 버전의 판형/슬롯/스타일/폰트 | `V001` |
| **issues** | `issue`, `issue_status_history`, `issue_status_transition` | 호의 상태 전이, 월 마감 배치, 진행상태 조회 | `R__020_issues_lifecycle`, `R__050_issues_batch` |
| **feed** | `post`, `media`, `media_rendition`, `issue_media`, `text_block` | 앱 안 피드(글/사진, 호와 독립), 마감 후 게시 가드, 호별 사진 선별(`issue_media`) | `R__010_feed_selection`, `R__030_feed_guards` |
| **layout** | `layout_run`, `page`, `placement`, `preview` | 자동 조판 결과, 워커 임대 계약, 조판 큐 | `R__060_layout_worker` |
| **review** | `approval`, `override`, `page_lock` | 승인(버전 기록), 사람의 수정, 락 | `R__040_review_guards` |
| **printing** | `print_job`, `print_order` | PDF/프리플라이트, 주문(주문 시점의 받는 사람/주소를 복사해 보관) | `V001`, `R__080_printing_guards` |

**소유권의 단일 기준은 각 테이블의 코멘트(`COMMENT ON TABLE ... IS 'module:<모듈> | 설명'`)다.** 이 문서의 표와 다르면 DB가 맞다.
컬럼 수준의 구조와 모듈별 관계도는 자동 생성되는 [erd.md](erd.md)를 본다.

## 강제되는 규칙 (CI 실패)

| 규칙 | 검사 |
|---|---|
| 모든 테이블은 `module:<모듈>` 코멘트로 소유 모듈을 밝혀야 한다 (없거나 알 수 없는 모듈이면 실패) | T90 |
| `docs/erd.md`는 현재 스키마와 같아야 한다 | `db.sh erd --check` (`db.sh test`에 포함) |
| **같은 사실이 두 곳에 있으면 어긋나지 못한다**: 사진/텍스트는 원본 글과 같은 그룹, 호별 선별은 호와 사진이 같은 그룹, 승인/수정/인쇄작업은 호와 조판이 같아야 하고, 글/승인/수정/주문의 작성자는 그 그룹의 활동 중인 구성원, 배치는 그 호에서 선별된 사진, 주문의 배송지는 같은 그룹이어야 한다 | 복합 외래키 + 트리거, `db/tests/integrity.sql` T100~T116, `groups.sql` T20~T27 |
| 모듈 간 외래키는 `allowed_dep`에 적힌 방향으로만 가능하다 | T91 |
| 허용한 의존 방향에 순환이 없다 | T92 |
| `main`에 합쳐진 `V###` 마이그레이션은 수정할 수 없다. 번호 중복/순서 역전/이름 규칙 위반 금지 | `scripts/check-migrations.sh` |
| 적용된 마이그레이션의 체크섬이 파일과 같다 | `flyway validate` (`db.sh test`에 포함) |

## 참조 정합성 (같은 사실이 두 곳에 있을 때)

정규화를 더 하는 대신 **중복된 값이 서로 어긋나지 못하게 제약을 건다.** (컬럼을 지우면 조회와 잠금 경로가 복잡해진다)

| 방법 | 대상 |
|---|---|
| **복합 외래키** (부모에 `UNIQUE(id, group_id)` 등을 두고 자식이 둘을 함께 참조) | `media` ↔ `post`, `text_block` ↔ `post`/`issue`, `issue_media` ↔ `issue`/`media`(모두 같은 그룹), `post`/`family_invite`/`delivery_address` ↔ `family_member`(그 그룹의 구성원), `approval` ↔ `layout_run`/`page`(같은 호, 같은 조판), `override`/`print_job` ↔ `layout_run`(같은 호), `preview` ↔ `page`(존재하는 페이지) |
| **트리거** (활동 중인지, 선별되었는지 등 외래키로 못 쓰는 것) | `post`(작성자가 활동 중인 구성원, 마감된 기간 거부), `media`(마감된 기간 거부), `family_invite`(방장만), `delivery_address`(활동 중인 구성원), `placement`(그 호에서 선별된 사진/그 호의 텍스트), `approval`/`override`(작성자가 활동 중인 구성원), `print_order`(같은 그룹의 배송지, 활동 중인 주문자) |

복합 외래키는 컬럼 중 하나가 NULL 이면 검사를 건너뛴다. 원본 글이 없는 텍스트(제목), 호 전체 승인이 그 경우다.
**일부러 허용한 것**: 호의 선별(`issue_media`)에 기간 밖의 사진이 들어가는 것(기간은 선별 함수가 지킨다), 조판이 쓴 템플릿이 호의 템플릿과 다른 것(그 시점의 기록), 수정로그의 `target_id`가 사라진 대상을 가리키는 것(다형 로그), 배치의 `slot_id`(템플릿 JSON 안의 이름, 조판 알고리즘 출력에서 검증). 모두 `integrity.sql`에 "허용됨"으로 고정되어 있다.
**삭제와 연쇄**: 글을 지우면 사진은 함께 지워지고 텍스트는 `post_id`만 NULL이 된다. 단 **조판에 배치된 사진을 가진 글은 물리 삭제가 거부된다**(T115). 앱은 글을 지울 때 `deleted_at`으로 숨겨야 하고, 이미 마감된 호의 내용은 바뀌지 않는다.

## 권한 (누가 무엇을 하는가)

| 행동 | 누구 | DB가 지키는 방식 |
|---|---|---|
| 로그인 | 카카오/애플만 (`auth_identity.provider` CHECK) | 제약 (T82) |
| 그룹 만들기 | 로그인한 누구나. 만든 사람이 방장 | `create_family_group()` |
| 초대 링크 만들기/취소 | **방장만** | 트리거 (T21). 취소는 `revoked_at` 갱신 (앱이 방장 확인) |
| 초대 수락 | 로그인한 누구나(링크 소지자). 항상 일반 구성원으로 합류 | `accept_family_invite()` (만료/취소/횟수 초과 거부, T22~T23) |
| 구성원 내보내기 | **방장만**. 나가기는 본인 | `remove_family_member(group, actor, target)` (T24) |
| 방장 넘기기 | 현재 방장만 | `transfer_family_owner()` (T25) |
| 글/사진 올리기 | 그 그룹의 활동 중인 구성원 | 트리거 (T53, T103) |
| 조부모님 배송지 등록 | 그 그룹의 활동 중인 구성원 | 트리거 (T26) |
| 승인/수정 | 그 그룹의 활동 중인 구성원 (누가 승인할 수 있는지는 TODO 정책) | 트리거 (T104, T105) |
| 인쇄 주문 | 그 그룹의 활동 중인 구성원 (방장만으로 좁힐지는 TODO 정책) | 트리거 (T109) |

**한계(중요)**: 위 함수들은 `p_actor`(행위자)를 **앱이 넘겨주는 값**으로 믿는다. 앱이 테이블을 직접 UPDATE/DELETE 하면 방장 검사를 우회할 수 있다.
DB 롤 분리(앱 롤에는 함수 실행만 허용)는 TODO이며, 그 전까지 "방장만"은 앱 코드 리뷰로도 지켜야 하는 규칙이다.
조회 권한(자기 그룹의 데이터만 읽기)은 DB가 아니라 API 계층의 책임이다. 모든 테이블이 `group_id`를 갖거나 호/글을 통해 닿으므로 쿼리마다 `group_id` 조건을 거는 방식으로 구현한다(행 수준 보안은 적용하지 않음).

## 알려진 예외 (현재 규칙을 어기지만 의도한 결합)

외래키 방향은 위 규칙을 지키지만, **함수/뷰 수준에서는 아래 결합이 있다.** 자동으로 검사되지 않으니 수정할 때 주의한다.

| 위치 | 결합 | 이유 |
|---|---|---|
| `issues.change_issue_status()` | `layout_run`(무효화), `override`, `print_job`, `v_issue_progress`를 읽거나 씀 | 호 상태 전이의 사전조건이 조판/승인/인쇄의 실체를 확인해야 하고, 한 트랜잭션이어야 한다. **issues가 생명주기를 지휘하는 조정자(process manager)** 다. |
| `issues.v_issue_progress` | post, issue_media, family_member, layout_run, page, approval, override, placement, print_job, print_order를 조인 | 진행 조회 전용 읽기 모델. 읽기만 한다. |
| `issues.close_due_issues()` | `feed.select_media()` 호출, `issue_media`/`post` 조회 | 마감 시 선별을 한 트랜잭션에서 하기 위해. |
| `review`/`layout`의 트리거·워커 함수 | `issues.change_issue_status()` 호출 (승인 후 수정 시 `review` 복귀, 조판 완료 시 `review` 전환) | 상태 전이의 단일 진입점을 지키기 위해. 외래키 방향(아래→위)과는 같다. |
| `identity.anonymize_user()` | groups(구성원 `left_at`), review(`page_lock`)의 행을 수정/삭제하고 `family_group`을 읽음 | 탈퇴는 본질적으로 여러 모듈을 가로지르는 작업. 글/사진은 지우지 않는다. |

이 예외가 늘어나면 모듈 경계가 무너지고 있다는 신호다. 새 결합을 추가하는 PR은 이 표를 함께 고친다.

### 함수 수준까지 보면 "계층"이 아니다 (분석으로 확인)

외래키만 보면 위 그림처럼 순환 없는 계층이다. 그러나 함수/뷰 본문까지 파싱해 보면(`scripts/analysis/fn-deps.py`, 함수 31개·뷰 2개)
**`issues`는 `layout`/`review`/`feed`/`printing`과 양방향 결합**이 있다. 외래키는 그쪽이 `issues`를 가리키고, 함수는 `issues`가 그쪽을 읽는다.
`identity.anonymize_user()`도 groups/review를 건드린다(`groups → identity`는 외래키 방향이라 서로 읽는 쌍이 된다). 위 표가 그 목록이며, 분석 결과와 일치함을 확인했다.

- 의미: **`issues`는 독립적으로 바꾸거나 떼어낼 수 없다.** `layout_run`/`approval`/`override`/`print_job`/`placement`/`issue_media`/`post`의 컬럼을 바꾸면
  `change_issue_status()`와 `v_issue_progress`가 영향을 받는다.
- DB가 지켜 주는 것과 아닌 것: **뷰**(`v_issue_progress`)가 쓰는 컬럼은 PostgreSQL이 추적해서 지우려 하면 막는다.
  **plpgsql 함수 본문**은 추적하지 않아서, 컬럼 이름을 바꿔도 마이그레이션은 성공하고 **테스트에서만** 실패한다(재현 확인). 그래서 모든 함수가 테스트에서 호출되는 것이 중요하다 (`track_functions=all`로 측정: 31개 중 30개가 호출 횟수로 잡혔고, 나머지 `guard_post_period_update`는 예외만 던지는 경로라 횟수는 0이지만 변이 검사 #13이 실행됨을 증명한다. 분기 단위 커버리지는 미측정).

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
│  ├─ identity/   groups/   templates/   issues/   feed/   layout/   review/   printing/
│  │    └─ 각 모듈: api(외부 공개 인터페이스) / domain / repo(DB 접근) 로 나누고,
│  │       다른 모듈은 api 만 import 할 수 있다
│  └─ shared/     (모듈이 공유하는 순수 유틸. 비즈니스 규칙을 넣지 않는다)
└─ apps/
   ├─ api/        (HTTP 서버 진입점)
   └─ worker/     (조판/배치 워커 진입점)
```

import 방향 검사는 언어별 도구로 CI에 추가한다 (이 저장소의 `Dockerfile`이 Java 21이므로 Java로 확정되면 `ArchUnit`. 참고: TypeScript `dependency-cruiser`, Python `import-linter`, .NET `NetArchTest`).
규칙은 DB와 같다: **허용된 방향으로만 import, 순환 금지, 다른 모듈의 `domain`/`repo`는 직접 import 금지.**
