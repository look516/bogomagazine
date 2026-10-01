# 호 진행상태 조회 API

가족 그룹별로 매월 호를 마감한다. 이 API는 `v_issue_progress` 뷰([R__020_issues_lifecycle.sql](../db/migrations/R__020_issues_lifecycle.sql))를 읽기만 한다.
(상태 변경은 별도 쓰기 API가 `change_issue_status()`를 호출해 처리한다.)

DB는 Flyway 마이그레이션(`db/migrations`)으로 관리한다: 테이블은 `V###`(한 번만 적용), 함수/뷰/트리거는 `R__###`(바뀌면 재적용). 전체 테스트는 `./scripts/db.sh test`. 모듈 구성은 [architecture.md](architecture.md) 참고.

## 1. 엔드포인트

| 메서드 | 경로 | 설명 |
|---|---|---|
| GET | `/groups/{groupId}/issues?month=2026-09` | 그룹의 호 목록 (월 필터, 없으면 최신순) |
| GET | `/issues/{issueId}/progress` | 호 1건의 진행 상세 |
| GET | `/issues/{issueId}/timeline` | 상태 변경 이력 (`issue_status_history`) |

권한: 해당 그룹의 활동 중인 구성원(방장 포함, `family_member.left_at IS NULL`)이면 누구나 조회 가능. 그 외는 404(존재 여부 노출 금지).
DB는 조회 권한을 강제하지 않는다. API가 쿼리마다 `group_id`(또는 호의 그룹)와 구성원 여부를 확인해야 한다 ([architecture.md](architecture.md)의 "권한").

## 2. 응답: `GET /issues/{issueId}/progress`

```json
{
  "issueId": "uuid",
  "groupId": "uuid",
  "title": "2026년 9월호",
  "period": {"start": "2026-09-01", "end": "2026-09-30"},

  "status": "collecting",
  "currentStep": "collecting",
  "progressPct": 10,
  "statusChangedAt": "2026-09-01T00:00:00+09:00",

  "deadline": {"closeAt": "2026-10-01T00:00:00+09:00", "isOverdue": false},
  "closeFailure": {"attempts": 0, "error": null},

  "submissions": {"total": 4, "submitted": 1},
  "media": {"total": 0, "selected": 0, "excluded": 0, "min": 15, "max": 60},
  "layout": {"latestRunId": null, "latestRunStatus": null},
  "review": {"totalPages": 0, "approvedPages": 0, "changesRequestedPages": 0, "staleApprovalPages": 0},
  "print": {"jobStatus": null, "orderStatus": null}
}
```

**`media`(호별 선별 결과)는 마감 때 `select_media()`가 만들기 때문에 수집 중에는 모두 0이다.** 수집 중에 "이번 달 올라온 사진 수"를 보여 주려면 API가 `post`/`media`를 기간으로 직접 센다.

필드는 뷰 컬럼과 1:1: `status`, `current_step`, `progress_pct`, `close_at`, `is_overdue`,
`close_attempts/close_error`, `total_members/submitted_members`,
`total/selected/excluded_media`, `latest_run_*`,
`total/approved/changes_requested/stale_approval_pages`, `print_job_status`, `print_order_status`.

## 3. 상태값

### `status` (DB 저장값, `issue.status`)

| 값 | 의미 | 다음으로 갈 수 있는 값 |
|---|---|---|
| `collecting` | 사진/게시물 수집 중 | `closing`, `skipped` |
| `closing` | 마감 처리 중 (선별 + 자동 조판) | `review`, `collecting`(재오픈) |
| `review` | 가족 검토 중 | `approved`, `closing`(재조판) |
| `approved` | 전 페이지 승인 완료 | `printing`, `review` |
| `printing` | PDF 생성/인쇄 제작 중 | `printed`, `approved` |
| `printed` | 인쇄 완료 (배송 포함) | `archived` |
| `skipped` | 이번 달 미발행 | `closing`(강제 발행), `collecting`(재오픈), `archived` |
| `archived` | 보관 | - |

전이 규칙의 원본은 `issue_status_transition` 테이블이다.
**`issue.status`는 `change_issue_status()`로만 바꿀 수 있다.** 직접 `UPDATE`하면 트리거가 거부한다.
(실수 방지용이며 보안 장치는 아니다. 권한 통제는 앱/DB 권한에서 해야 한다.)

### 전이 사전조건 (`change_issue_status`가 검사, 위반 시 `check_violation`)

| 전이 | 조건 |
|---|---|
| `→ collecting` (재오픈) | **미래의 `close_at`을 인자로 줘야 함.** 안 그러면 배치가 곧바로 다시 닫는다. |
| `→ review` | 완료(`done`)된 조판이 있어야 함 |
| `→ approved`, `→ printing` | 최신 조판의 **모든 페이지가 현재 버전 기준으로 승인**되어 있어야 함 (낡은 승인은 불인정) |
| `→ printed` | 최신 조판과 일치하고 최신 수정 번호 이상인 `ready` 인쇄 작업이 있어야 함 |
| `→ closing`, `closing → collecting` | 이전 조판 실행(queued/running/done)을 `superseded`로 무효화 |

### `currentStep` (뷰가 계산하는 세부 단계, UI 표시용)

| 값 | 조건 | 진행률 |
|---|---|---|
| `collecting` | status=collecting | 0~20 (이번 달 글을 올린 구성원 비율, 구성원 0명이면 0) |
| `close_failed` | collecting, 마감 처리가 5회 실패 | 20 |
| `selecting` | closing, 조판 실행 기록 없음, 선별된 사진 0 | 30 |
| `composing` | closing, 조판 진행 중이거나 결과 대기 | 40 |
| `compose_failed` | closing, 최근 조판이 `failed` | 40 |
| `reviewing` | status=review | 50~80 (유효 승인 페이지 비율) |
| `approved` | status=approved | 85 |
| `preflight_failed` | printing, 최근 인쇄 작업이 `preflight_failed`/`failed` | 88 |
| `printing` | printing | 90 |
| `shipping` | printed, 주문이 아직 `delivered` 아님 | 95 |
| `order_cancelled` | printed, 최근 주문이 `cancelled` | 90 |
| `delivered` | printed, 주문 `delivered` | 100 |
| `skipped` / `archived` | 해당 status | 100 |

`*_failed`와 `order_cancelled`는 사용자/운영자 조치가 필요하다는 신호다. UI는 이 값일 때 경고를 띄운다.

### 판정 기준 (알아둘 것)

- **제출 인원**: 총원은 그 그룹의 **활동 중인 구성원**(나간 사람 제외), 제출은 그중 **이 호의 기간(그룹 타임존 날짜)에 글을 올린 사람**(삭제한 글 제외)이다. 호 참여자 행은 따로 없다.
- **페이지 승인**: 페이지별로 **가장 최근 승인 기록 1건**만 본다. 최근 기록이 `approved`여도, 그 승인 뒤에
  **같은 조판 실행에서 이 페이지(또는 이 페이지의 배치/사진)를 대상으로 한 수정(`override`)이 생기면
  무효(`staleApprovalPages`)** 로 센다. 승인 기록의 `run_id`/`override_seq`는 트리거가 자동으로 채운다.
  (여러 명이 승인해야 하는 규칙은 아직 없다.)
- **승인 후 수정**: 호가 `approved`일 때 수정이 들어오면 호를 자동으로 `review`로 되돌린다.
  `review`가 아닌 단계(`printing` 등)에서는 수정을 거부한다. 무효(`superseded`)가 된 조판에는 승인/수정 모두 거부.
- **진행률**: UI 진행바용 근사치다. 단계별 고정 구간이고 실제 소요 시간과 무관하다.
- **마감 초과**: `collecting`인데 `close_at`이 지났으면 `isOverdue=true`.

## 4. 목록 응답: `GET /groups/{groupId}/issues`

```json
{
  "items": [
    {
      "issueId": "uuid",
      "title": "2026년 9월호",
      "period": {"start": "2026-09-01", "end": "2026-09-30"},
      "status": "review",
      "currentStep": "reviewing",
      "progressPct": 65,
      "isOverdue": false
    }
  ]
}
```

목록은 요약 필드만 내려주고 상세는 `/progress`로 조회한다. `month` 파라미터는 `period_start`가 해당 월에 속하는 호를 찾는다.

## 5. 게시 규칙 ([R__030_feed_guards.sql](../db/migrations/R__030_feed_guards.sql))

글(`post`)은 앱 피드에 올라가며 **호와 독립**이다. 어느 호에 실리는지는 `posted_at`(그룹 타임존 날짜)이 어느 호의 기간에 속하는지로 정해진다.

- 글과 사진은 그 기간의 호가 **`collecting`이거나 아직 만들어지지 않았을 때만** 들어간다. 호가 마감되었으면 DB가 거부한다.
  마감 배치와는 행 잠금으로 직렬화되어, 선별이 끝난 뒤에 들어온 글/사진이 조용히 누락되지 않는다.
- 글의 날짜(`posted_at`)를 마감된 기간으로 옮기는 것도 거부한다.
- 작성자는 그 그룹의 **활동 중인 구성원**이어야 한다 (나간 사람, 다른 그룹 사람 거부).
- DB는 `close_at` 시각 자체를 강제하지 않는다. 배치가 호를 닫기 전까지는 받는다. 마감 시각을 엄격히
  적용하려면 앱이 `close_at`을 먼저 확인할 것. 마감 후 늦은 글을 받아야 하면 방장이
  `change_issue_status(호, 'collecting', 사용자, 사유, 새_close_at)`으로 재오픈한다.
- 글을 지울 때는 `deleted_at`을 채운다(숨김). 마감된 호의 내용은 바뀌지 않으며, 조판에 배치된 사진을 가진 글은 **물리 삭제가 거부된다**.
- 사진 파일은 서버를 거치지 않고 올리고(직접 업로드), 업로드가 끝난 뒤 `media` 행을 만든다. `rights_ok=false`는 선별에서 제외된다.

## 6. 월 마감 배치 ([R__050_issues_batch.sql](../db/migrations/R__050_issues_batch.sql))

스케줄러가 30분마다 `SELECT * FROM run_monthly_batch();` 를 호출한다. 여러 번 불려도 안전하다.
**한 번 호출 = 한 트랜잭션 = 마감 대상 최대 200건**이다. 월초에 모든 그룹이 동시에 마감되어도 트랜잭션이
길어지지 않도록, 호출자는 마감 처리 결과(`closing`/`skipped`)가 0건이 될 때까지 반복 호출한다.

1. **마감**: `close_at`이 지난 `collecting` 호를 처리한다 (`FOR UPDATE SKIP LOCKED`라 동시 실행 가능).
   - 그 기간의 글(삭제한 글 제외)에서 사진 선별(`select_media`) 실행 → 결과는 `issue_media`에 기록 (사용자가 "꼭 넣기"/"빼기"한 사진은 존중)
   - 선별 사진이 `min_photos` 미만이면 `skipped`(미발행), 아니면 `closing`
   - 그룹이 `auto_skip_below_min = false`이면 부족해도 `closing`으로 진행
2. **호 생성**: 마감 대상이 한 번에 처리할 수 있는 건수보다 적게 남았을 때, 그룹 타임존 기준 이번 달 호가 없으면 만든다.
   마감은 다음 달 `close_day`일 00:00.
3. **조판 큐**: `v_compose_queue`에 마감된 호가 나타난다. 워커는 아래 계약([R__060_layout_worker.sql](../db/migrations/R__060_layout_worker.sql))으로 가져간다.
   실패가 3번 쌓이면 큐에서 빠지고 `compose_failed`로 표시되며, 운영자가 `reset_compose_failures(호)`로 다시 시도시킨다.

### 조판 워커 계약

| 함수 | 역할 |
|---|---|
| `claim_compose_job(worker, 알고리즘버전)` | 마감된 호 1건을 가져가 `running` 실행을 만든다 (`run_id, issue_id, seed, attempt` 반환). 없으면 0행. `SKIP LOCKED`라 워커가 여럿이어도 같은 호를 받지 않는다. |
| `heartbeat_compose_job(run, worker)` | 계산 중 주기적으로 호출. **`false`면 내 작업이 무효가 된 것이니 즉시 중단.** |
| `complete_compose_job(run, worker, 입력해시, 점수, 보고서, 입력위치)` | 같은 트랜잭션에서 `page`/`placement`를 저장한 뒤 호출. 아직 유효할 때만 `done`으로 바꾸고 호를 `review`로 넘긴다. 무효면 **예외 → 저장하던 페이지까지 롤백**. 페이지가 0개여도 거부. |
| `fail_compose_job(run, worker, 사유)` | 실패 보고 (내 작업이 아직 유효할 때만 기록) |
| `reap_stale_compose_jobs()` | `running`인데 5분 넘게 하트비트가 없는 실행을 `failed`로 (claim이 자동 호출) |

- **워커가 죽으면**: 하트비트가 끊긴 실행을 다음 claim이 `failed`로 정리하고 다른 워커가 이어받는다. 죽었던 워커가
  뒤늦게 살아나 `complete`를 호출해도 거부된다 (재오픈/재조판으로 `superseded`된 작업도 마찬가지).
- **회차**: 호별로 `run_no`(1, 2, 3 ...)가 자동 부여된다. "최신" 판정은 시각이 아니라 `seq`(삽입 순서)다.
  `layout_run`, `approval`, `print_job`, `print_order` 모두 같다.

호 하나의 처리가 실패해도 다른 호는 계속 처리한다. 실패는 `close_attempts`/`close_error`에 기록되고,
5회 실패하면 자동 재시도에서 빠져 `close_failed`로 표시된다 (운영자가 원인을 고친 뒤 재오픈/재시도).

## 7. 가족 그룹 / 초대 / 배송지 ([R__005_groups_membership.sql](../db/migrations/R__005_groups_membership.sql))

로그인은 카카오/애플만 가능하다(`auth_identity.provider`). 애플은 이메일을 숨길 수 있어 **이메일이 아니라 초대 링크 토큰**으로 가족을 합류시킨다.
**아래 함수들은 `p_actor`를 앱이 넘긴 값으로 믿는다.** 로그인한 사용자 id를 그대로 넘길 것 (DB 권한 분리는 TODO).

| 하는 일 | 호출 | 규칙 |
|---|---|---|
| 그룹 만들기 | `create_family_group(이름, 만든사람, 호칭)` | 만든 사람이 방장이자 첫 구성원. 반드시 이 함수로 (그룹과 방장 구성원은 한 트랜잭션) |
| 초대 링크 만들기 | `INSERT INTO family_invite (group_id, created_by, token_hash, expires_at, max_uses)` | **방장만**. 앱이 무작위 토큰을 만들어 **sha256 hex(64자)만 저장**하고 원문은 카카오톡 링크에만 싣는다. 만료/최대 사용 횟수 필수 설정 권장 |
| 초대 취소 | `UPDATE family_invite SET revoked_at = now()` | 방장 확인은 앱이 한다 (DB는 검사하지 않음) |
| 초대 수락 | `accept_family_invite(토큰해시, 사용자)` → 그룹 id | 없는 링크/취소/만료/횟수 초과는 예외. 이미 구성원이면 횟수를 쓰지 않고 성공(링크를 두 번 눌러도 안전). 나갔던 사람은 복귀. 항상 일반 구성원 |
| 나가기 / 내보내기 | `remove_family_member(그룹, 행위자, 대상)` | 본인은 누구나, 타인은 방장만. **방장은 나갈 수 없다(먼저 넘길 것)**. 행은 남고 `left_at`만 채워진다 |
| 방장 넘기기 | `transfer_family_owner(그룹, 행위자, 새방장)` | 현재 방장만, 새 방장은 활동 중인 구성원 |
| 조부모님 배송지 | `INSERT INTO delivery_address (...)` | 활동 중인 구성원이 등록. **로그인하지 않는 수신자라 주소/전화/메모만 저장** |
| 주문 | `INSERT INTO print_order (...)` | 배송지마다 1건. **주문 시점의 받는 사람/주소를 복사해 넣는다** (배송지를 나중에 고치거나 지워도 주문 기록은 그대로, `delivery_address_id`는 NULL이 될 수 있음) |

- 초대 수락은 방장이 내보낸 사람이 **옛 링크로 다시 들어올 수 있다.** 내보낸 뒤에는 링크를 취소할 것.
- 전화번호/주소는 개인정보다. 현재는 평문 컬럼이며 암호화/접근 제한은 TODO.

## 8. 회원 탈퇴 ([R__070_identity_privacy.sql](../db/migrations/R__070_identity_privacy.sql))

`anonymize_user(userId)`는 사용자를 **지우지 않고 익명화**한다 (기록이 깨지지 않게).
- 제거: 이메일/이름, 로그인 수단(`auth_identity`), 페이지 편집 락
- 변경: 그룹 구성원 행은 남기고 `left_at`을 채운다 (이후 글/승인/주문 불가)
- 유지: 사진/글 등 **콘텐츠**, 승인/수정 기록 — 삭제 범위는 정책 결정 대기 중
- 반환: 외부 시크릿 저장소에서 **폐기해야 할 토큰 참조 목록** (DB 밖이라 DB가 지울 수 없다. 앱이 반드시 폐기할 것)
- **방장은 방장을 넘기기 전에는 거부된다.** 여러 번 호출해도 안전하다.
- 탈퇴한 사용자의 카카오/애플 계정은 연결이 완전히 풀려 같은 계정으로 다시 가입할 수 있다.

## 9. 아직 정해지지 않은 것

- **다중 승인 정책**: 가족 중 몇 명이 승인해야 `approved`로 넘길지. 지금은 쓰기 API가 판단해 `change_issue_status()`를 호출한다.
- **탈퇴 시 콘텐츠 처리**: 사용자가 올린 사진/게시물(`raw` 포함)과 본문을 지울지, 남길지, 가족이 승인한 호는 어떻게 할지.
- **마감 시각 강제 / 업로드 유예**, **DB 권한 분리**: 설계안만 있고 미적용.
- **마감 임박 알림**: 이번 달 글을 아직 안 올린 구성원에게 알림을 보내는 기능은 없다 (대상은 `v_issue_progress`의 제출 기준으로 조회 가능).
- **주문 권한**: 지금은 활동 중인 구성원 누구나 주문할 수 있다. 방장만으로 좁힐지 정하지 않았다.
- **재인쇄/정정 인쇄**: `printed` 이후의 정정은 `archived`로만 갈 수 있다. 주문 취소는 `order_cancelled`로 표시만 한다.
- **실시간 갱신**: 폴링으로 시작하고, 필요해지면 SSE/WebSocket으로 확장한다.
