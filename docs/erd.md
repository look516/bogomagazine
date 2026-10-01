# ERD (자동 생성)

> **이 파일은 DB 스키마에서 자동 생성됩니다. 직접 수정하지 마세요.**
> 갱신: `./scripts/db.sh erd` · CI(`./scripts/db.sh test`)가 스키마와 일치하는지 검사하고, 어긋나면 실패합니다.
> 모듈 경계와 규칙은 [architecture.md](architecture.md) 참고. 소유 모듈은 각 테이블의 코멘트(`module:<모듈>`)가 기준입니다.

범례: `PK` 기본키 · `FK` 외래키 · `UK` 유일 · 관계선 `||--o{` 은 "부모 1 : 자식 0..N", `|o` 는 부모가 선택(NULL 가능), `o|` 는 자식이 최대 1(1:1). 라벨은 외래키 컬럼이며 괄호는 부모 삭제 시 동작입니다.

## 0. 모듈 구성과 의존 방향

화살표는 "참조한다(의존한다)"는 뜻이고 숫자는 모듈 간 외래키 개수입니다.

```mermaid
flowchart LR
    identity["identity<br/>2 tables"]
    templates["templates<br/>4 tables"]
    groups["groups<br/>3 tables"]
    issues["issues<br/>4 tables"]
    intake["intake<br/>5 tables"]
    layout["layout<br/>4 tables"]
    review["review<br/>4 tables"]
    printing["printing<br/>2 tables"]
    groups -->|"3 FK"| identity
    issues -->|"2 FK"| identity
    issues -->|"1 FK"| templates
    issues -->|"1 FK"| groups
    intake -->|"4 FK"| identity
    intake -->|"3 FK"| issues
    layout -->|"3 FK"| templates
    layout -->|"1 FK"| issues
    layout -->|"2 FK"| intake
    review -->|"4 FK"| identity
    review -->|"3 FK"| issues
    review -->|"5 FK"| layout
    printing -->|"1 FK"| identity
    printing -->|"1 FK"| issues
    printing -->|"1 FK"| layout
```

## 1. 전체 관계 (컬럼 생략)

```mermaid
erDiagram
    "issue" ||--o{ "approval" : "issue_id (cascade)"
    "page" |o--o{ "approval" : "page_id, run_id (cascade)"
    "layout_run" |o--o{ "approval" : "run_id, issue_id (cascade)"
    "app_user" ||--o{ "approval" : "user_id"
    "app_user" ||--o{ "auth_identity" : "user_id (cascade)"
    "app_user" ||--o{ "comment" : "author_id"
    "issue" ||--o{ "comment" : "issue_id (cascade)"
    "page" |o--o{ "comment" : "page_id (cascade)"
    "app_user" ||--o{ "family_group" : "owner_id"
    "family_group" ||--o{ "family_member" : "group_id (cascade)"
    "app_user" ||--o{ "family_member" : "user_id"
    "font" |o--o{ "font" : "fallback"
    "publication" ||--o{ "issue" : "publication_id"
    "template" ||--o{ "issue" : "template_id"
    "issue" ||--o{ "issue_member" : "issue_id (cascade)"
    "app_user" ||--o{ "issue_member" : "user_id"
    "app_user" |o--o{ "issue_status_history" : "changed_by"
    "issue" ||--o{ "issue_status_history" : "issue_id (cascade)"
    "issue" ||--o{ "layout_run" : "issue_id (cascade)"
    "template" ||--o{ "layout_run" : "template_id"
    "issue" ||--o{ "media" : "issue_id (cascade)"
    "source_post" |o--o{ "media" : "source_post_id, issue_id (set null)"
    "app_user" ||--o{ "media" : "uploader_id"
    "media" ||--o{ "media_rendition" : "media_id (cascade)"
    "app_user" ||--o{ "override" : "author_id"
    "issue" ||--o{ "override" : "issue_id (cascade)"
    "layout_run" ||--o{ "override" : "run_id, issue_id (cascade)"
    "page_master" |o--o{ "page" : "master_id"
    "layout_run" ||--o{ "page" : "run_id (cascade)"
    "page" ||--o| "page_lock" : "page_id (cascade)"
    "app_user" ||--o{ "page_lock" : "user_id"
    "template" ||--o{ "page_master" : "template_id (cascade)"
    "media" |o--o{ "placement" : "media_id"
    "page" ||--o{ "placement" : "page_id (cascade)"
    "style" |o--o{ "placement" : "style_id"
    "text_block" |o--o{ "placement" : "text_block_id"
    "page" ||--o{ "preview" : "run_id, page_no (cascade)"
    "issue" ||--o{ "print_job" : "issue_id"
    "layout_run" ||--o{ "print_job" : "run_id, issue_id"
    "app_user" ||--o{ "print_order" : "ordered_by"
    "print_job" ||--o{ "print_order" : "print_job_id"
    "family_group" ||--o{ "publication" : "group_id"
    "app_user" ||--o{ "publication" : "owner_id"
    "app_user" ||--o{ "social_account" : "user_id"
    "social_account" |o--o{ "source_post" : "account_id, contributor_id"
    "social_account" |o--o{ "source_post" : "account_id, platform"
    "app_user" ||--o{ "source_post" : "contributor_id"
    "issue" ||--o{ "source_post" : "issue_id (cascade)"
    "style" |o--o{ "style" : "based_on"
    "template" ||--o{ "style" : "template_id (cascade)"
    "app_user" |o--o{ "text_block" : "created_by"
    "issue" ||--o{ "text_block" : "issue_id (cascade)"
    "source_post" |o--o{ "text_block" : "source_post_id, issue_id (set null)"
    "issue_status_transition"
```

## 2. 모듈별 상세

해당 모듈의 테이블은 컬럼까지 보여 주고, 다른 모듈의 테이블은 연결에 필요한 컬럼만 보여 줍니다.

### identity

- 참조하는 모듈: 없음 (바닥 모듈)
- 이 모듈을 참조하는 모듈: groups, issues, intake, review, printing

```mermaid
erDiagram
    "app_user" ||--o{ "approval" : "user_id"
    "app_user" ||--o{ "auth_identity" : "user_id (cascade)"
    "app_user" ||--o{ "comment" : "author_id"
    "app_user" ||--o{ "family_group" : "owner_id"
    "app_user" ||--o{ "family_member" : "user_id"
    "app_user" ||--o{ "issue_member" : "user_id"
    "app_user" |o--o{ "issue_status_history" : "changed_by"
    "app_user" ||--o{ "media" : "uploader_id"
    "app_user" ||--o{ "override" : "author_id"
    "app_user" ||--o{ "page_lock" : "user_id"
    "app_user" ||--o{ "print_order" : "ordered_by"
    "app_user" ||--o{ "publication" : "owner_id"
    "app_user" ||--o{ "social_account" : "user_id"
    "app_user" ||--o{ "source_post" : "contributor_id"
    "app_user" |o--o{ "text_block" : "created_by"
    "app_user" {
        uuid id PK
        text email
        text name
        timestamptz created_at
        timestamptz deleted_at
    }
    "auth_identity" {
        uuid id PK
        uuid user_id FK
        text provider
        text provider_uid
        text email
        bool email_verified
        bool is_private_relay
        text refresh_token_ref
        timestamptz last_login_at
        timestamptz created_at
    }
    "approval" {
        uuid id PK
        uuid user_id FK
    }
    "comment" {
        uuid id PK
        uuid author_id FK
    }
    "family_group" {
        uuid id PK
        uuid owner_id FK
    }
    "family_member" {
        uuid group_id PK, FK
        uuid user_id PK, FK
    }
    "issue_member" {
        uuid issue_id PK, FK
        uuid user_id PK, FK
    }
    "issue_status_history" {
        bigint id PK
        uuid changed_by FK
    }
    "media" {
        uuid id PK
        uuid uploader_id FK
    }
    "override" {
        uuid id PK
        uuid author_id FK
    }
    "page_lock" {
        uuid page_id PK, FK
        uuid user_id FK
    }
    "print_order" {
        uuid id PK
        uuid ordered_by FK
    }
    "publication" {
        uuid id PK
        uuid owner_id FK
    }
    "social_account" {
        uuid id PK
        uuid user_id FK
    }
    "source_post" {
        uuid id PK
        uuid contributor_id FK
    }
    "text_block" {
        uuid id PK
        uuid created_by FK
    }
```

### templates

- 참조하는 모듈: 없음 (바닥 모듈)
- 이 모듈을 참조하는 모듈: issues, layout

```mermaid
erDiagram
    "font" |o--o{ "font" : "fallback"
    "template" ||--o{ "issue" : "template_id"
    "template" ||--o{ "layout_run" : "template_id"
    "page_master" |o--o{ "page" : "master_id"
    "template" ||--o{ "page_master" : "template_id (cascade)"
    "style" |o--o{ "placement" : "style_id"
    "style" |o--o{ "style" : "based_on"
    "template" ||--o{ "style" : "template_id (cascade)"
    "font" {
        uuid id PK
        text family
        int weight
        bool italic
        text storage_key
        text sha256
        text license
        uuid fallback FK
    }
    "page_master" {
        uuid id PK
        uuid template_id FK
        text name
        jsonb grid
        jsonb slots
    }
    "style" {
        uuid id PK
        uuid template_id FK
        text kind
        text name
        uuid based_on FK
        jsonb props
    }
    "template" {
        uuid id PK
        text name
        int version
        jsonb spec
        int min_photos
        int max_photos
        int min_pages
        int max_pages
        int page_multiple
        int photos_per_page_min
        int photos_per_page_max
        timestamptz created_at
    }
    "issue" {
        uuid id PK
        uuid template_id FK
    }
    "layout_run" {
        uuid id PK
        uuid template_id FK
    }
    "page" {
        uuid id PK
        uuid master_id FK
    }
    "placement" {
        uuid id PK
        uuid style_id FK
    }
```

### groups

- 참조하는 모듈: identity
- 이 모듈을 참조하는 모듈: issues

```mermaid
erDiagram
    "app_user" ||--o{ "family_group" : "owner_id"
    "family_group" ||--o{ "family_member" : "group_id (cascade)"
    "app_user" ||--o{ "family_member" : "user_id"
    "publication" ||--o{ "issue" : "publication_id"
    "family_group" ||--o{ "publication" : "group_id"
    "app_user" ||--o{ "publication" : "owner_id"
    "family_group" {
        uuid id PK
        text name
        uuid owner_id FK
        int close_day
        text timezone
        bool auto_skip_below_min
        timestamptz created_at
    }
    "family_member" {
        uuid group_id PK, FK
        uuid user_id PK, FK
        text role
        timestamptz joined_at
    }
    "publication" {
        uuid id PK
        uuid group_id FK
        text name
        uuid owner_id FK
        timestamptz created_at
    }
    "app_user" {
        uuid id PK
    }
    "issue" {
        uuid id PK
        uuid publication_id FK
    }
```

### issues

- 참조하는 모듈: identity, templates, groups
- 이 모듈을 참조하는 모듈: intake, layout, review, printing

```mermaid
erDiagram
    "issue" ||--o{ "approval" : "issue_id (cascade)"
    "issue" ||--o{ "comment" : "issue_id (cascade)"
    "publication" ||--o{ "issue" : "publication_id"
    "template" ||--o{ "issue" : "template_id"
    "issue" ||--o{ "issue_member" : "issue_id (cascade)"
    "app_user" ||--o{ "issue_member" : "user_id"
    "app_user" |o--o{ "issue_status_history" : "changed_by"
    "issue" ||--o{ "issue_status_history" : "issue_id (cascade)"
    "issue" ||--o{ "layout_run" : "issue_id (cascade)"
    "issue" ||--o{ "media" : "issue_id (cascade)"
    "issue" ||--o{ "override" : "issue_id (cascade)"
    "issue" ||--o{ "print_job" : "issue_id"
    "issue" ||--o{ "source_post" : "issue_id (cascade)"
    "issue" ||--o{ "text_block" : "issue_id (cascade)"
    "issue" {
        uuid id PK
        uuid publication_id FK
        text title
        date period_start
        date period_end
        text status
        timestamptz status_changed_at
        timestamptz close_at
        timestamptz closed_at
        int close_attempts
        text close_error
        uuid template_id FK
        int min_photos
        int max_photos
        int min_pages
        int max_pages
        int page_multiple
        timestamptz created_at
    }
    "issue_member" {
        uuid issue_id PK, FK
        uuid user_id PK, FK
        text role
        text submit_status
        timestamptz submitted_at
    }
    "issue_status_history" {
        bigint id PK
        uuid issue_id FK
        text from_status
        text to_status
        uuid changed_by FK
        text note
        timestamptz changed_at
    }
    "issue_status_transition" {
        text from_status PK
        text to_status PK
        text note
    }
    "app_user" {
        uuid id PK
    }
    "approval" {
        uuid id PK
        uuid issue_id FK
    }
    "comment" {
        uuid id PK
        uuid issue_id FK
    }
    "layout_run" {
        uuid id PK
        uuid issue_id FK
    }
    "media" {
        uuid id PK
        uuid issue_id FK
    }
    "override" {
        uuid id PK
        uuid issue_id FK
    }
    "print_job" {
        uuid id PK
        uuid issue_id FK
    }
    "publication" {
        uuid id PK
    }
    "source_post" {
        uuid id PK
        uuid issue_id FK
    }
    "template" {
        uuid id PK
    }
    "text_block" {
        uuid id PK
        uuid issue_id FK
    }
```

### intake

- 참조하는 모듈: identity, issues
- 이 모듈을 참조하는 모듈: layout

```mermaid
erDiagram
    "issue" ||--o{ "media" : "issue_id (cascade)"
    "source_post" |o--o{ "media" : "source_post_id, issue_id (set null)"
    "app_user" ||--o{ "media" : "uploader_id"
    "media" ||--o{ "media_rendition" : "media_id (cascade)"
    "media" |o--o{ "placement" : "media_id"
    "text_block" |o--o{ "placement" : "text_block_id"
    "app_user" ||--o{ "social_account" : "user_id"
    "social_account" |o--o{ "source_post" : "account_id, contributor_id"
    "social_account" |o--o{ "source_post" : "account_id, platform"
    "app_user" ||--o{ "source_post" : "contributor_id"
    "issue" ||--o{ "source_post" : "issue_id (cascade)"
    "app_user" |o--o{ "text_block" : "created_by"
    "issue" ||--o{ "text_block" : "issue_id (cascade)"
    "source_post" |o--o{ "text_block" : "source_post_id, issue_id (set null)"
    "media" {
        uuid id PK
        uuid issue_id FK
        uuid source_post_id FK
        uuid uploader_id FK
        text kind
        text storage_key
        text sha256
        int width
        int height
        jsonb exif
        timestamptz taken_at
        text color_profile
        jsonb focal_point
        jsonb saliency
        real quality_score
        bigint phash
        text selection_status
        bool pinned
        real selection_score
        bool rights_ok
        timestamptz created_at
    }
    "media_rendition" {
        uuid media_id PK, FK
        text purpose PK
        text storage_key
        int width
        int height
    }
    "social_account" {
        uuid id PK
        uuid user_id FK
        text platform
        text external_id
        text token_ref
        timestamptz consent_at
        jsonb consent_scope
    }
    "source_post" {
        uuid id PK
        uuid issue_id FK
        uuid contributor_id FK
        uuid account_id FK
        text platform FK
        text external_post_id
        timestamptz posted_at
        text caption
        text[] hashtags
        text location
        jsonb engagement
        jsonb raw
        timestamptz created_at
    }
    "text_block" {
        uuid id PK
        uuid issue_id FK
        uuid source_post_id FK
        text kind
        text body
        jsonb runs
        uuid created_by FK
        timestamptz created_at
    }
    "app_user" {
        uuid id PK
    }
    "issue" {
        uuid id PK
    }
    "placement" {
        uuid id PK
        uuid media_id FK
        uuid text_block_id FK
    }
```

### layout

- 참조하는 모듈: templates, issues, intake
- 이 모듈을 참조하는 모듈: review, printing

```mermaid
erDiagram
    "page" |o--o{ "approval" : "page_id, run_id (cascade)"
    "layout_run" |o--o{ "approval" : "run_id, issue_id (cascade)"
    "page" |o--o{ "comment" : "page_id (cascade)"
    "issue" ||--o{ "layout_run" : "issue_id (cascade)"
    "template" ||--o{ "layout_run" : "template_id"
    "layout_run" ||--o{ "override" : "run_id, issue_id (cascade)"
    "page_master" |o--o{ "page" : "master_id"
    "layout_run" ||--o{ "page" : "run_id (cascade)"
    "page" ||--o| "page_lock" : "page_id (cascade)"
    "media" |o--o{ "placement" : "media_id"
    "page" ||--o{ "placement" : "page_id (cascade)"
    "style" |o--o{ "placement" : "style_id"
    "text_block" |o--o{ "placement" : "text_block_id"
    "page" ||--o{ "preview" : "run_id, page_no (cascade)"
    "layout_run" ||--o{ "print_job" : "run_id, issue_id"
    "layout_run" {
        uuid id PK
        bigint seq
        int run_no
        uuid issue_id FK
        uuid template_id FK
        text algorithm_version
        jsonb params
        bigint seed
        text input_snapshot_hash
        text status
        real score
        jsonb report
        text log
        timestamptz started_at
        timestamptz finished_at
        text locked_by
        timestamptz locked_at
        timestamptz heartbeat_at
        int attempts
        text input_ref
        timestamptz created_at
    }
    "page" {
        uuid id PK
        uuid run_id FK
        int page_no
        uuid master_id FK
    }
    "placement" {
        uuid id PK
        uuid page_id FK
        text slot_id
        text ref_type
        uuid media_id FK
        uuid text_block_id FK
        numeric x
        numeric y
        numeric w
        numeric h
        int z
        jsonb crop
        uuid style_id FK
    }
    "preview" {
        uuid id PK
        uuid run_id FK
        bigint override_seq
        int page_no FK
        text storage_key
        text status
    }
    "approval" {
        uuid id PK
        uuid issue_id FK
        uuid page_id FK
        uuid run_id FK
    }
    "comment" {
        uuid id PK
        uuid page_id FK
    }
    "issue" {
        uuid id PK
    }
    "media" {
        uuid id PK
    }
    "override" {
        uuid id PK
        uuid issue_id FK
        uuid run_id FK
    }
    "page_lock" {
        uuid page_id PK, FK
    }
    "page_master" {
        uuid id PK
    }
    "print_job" {
        uuid id PK
        uuid issue_id FK
        uuid run_id FK
    }
    "style" {
        uuid id PK
    }
    "template" {
        uuid id PK
    }
    "text_block" {
        uuid id PK
    }
```

### review

- 참조하는 모듈: identity, issues, layout
- 이 모듈을 참조하는 모듈: 없음

```mermaid
erDiagram
    "issue" ||--o{ "approval" : "issue_id (cascade)"
    "page" |o--o{ "approval" : "page_id, run_id (cascade)"
    "layout_run" |o--o{ "approval" : "run_id, issue_id (cascade)"
    "app_user" ||--o{ "approval" : "user_id"
    "app_user" ||--o{ "comment" : "author_id"
    "issue" ||--o{ "comment" : "issue_id (cascade)"
    "page" |o--o{ "comment" : "page_id (cascade)"
    "app_user" ||--o{ "override" : "author_id"
    "issue" ||--o{ "override" : "issue_id (cascade)"
    "layout_run" ||--o{ "override" : "run_id, issue_id (cascade)"
    "page" ||--o| "page_lock" : "page_id (cascade)"
    "app_user" ||--o{ "page_lock" : "user_id"
    "approval" {
        uuid id PK
        bigint seq
        uuid issue_id FK
        uuid page_id FK
        uuid run_id FK
        bigint override_seq
        uuid user_id FK
        text status
        text comment
        timestamptz created_at
    }
    "comment" {
        uuid id PK
        uuid issue_id FK
        uuid page_id FK
        jsonb anchor
        uuid author_id FK
        text body
        bool resolved
        timestamptz created_at
    }
    "override" {
        uuid id PK
        uuid issue_id FK
        uuid run_id FK
        bigint seq
        text target_type
        uuid target_id
        jsonb op
        uuid author_id FK
        timestamptz created_at
    }
    "page_lock" {
        uuid page_id PK, FK
        uuid user_id FK
        timestamptz expires_at
    }
    "app_user" {
        uuid id PK
    }
    "issue" {
        uuid id PK
    }
    "layout_run" {
        uuid id PK
    }
    "page" {
        uuid id PK
    }
```

### printing

- 참조하는 모듈: identity, issues, layout
- 이 모듈을 참조하는 모듈: 없음

```mermaid
erDiagram
    "issue" ||--o{ "print_job" : "issue_id"
    "layout_run" ||--o{ "print_job" : "run_id, issue_id"
    "app_user" ||--o{ "print_order" : "ordered_by"
    "print_job" ||--o{ "print_order" : "print_job_id"
    "print_job" {
        uuid id PK
        bigint seq
        uuid issue_id FK
        uuid run_id FK
        bigint override_seq
        text pdf_key
        text pdf_profile
        text color_mode
        numeric bleed_mm
        bool crop_marks
        jsonb preflight_report
        text status
        timestamptz created_at
    }
    "print_order" {
        uuid id PK
        bigint seq
        uuid print_job_id FK
        uuid ordered_by FK
        text vendor
        int quantity
        jsonb shipping
        numeric price
        text status
        text tracking
        timestamptz created_at
    }
    "app_user" {
        uuid id PK
    }
    "issue" {
        uuid id PK
    }
    "layout_run" {
        uuid id PK
    }
```

## 3. 테이블 목록

| 모듈 | 테이블 | 컬럼 수 | 설명 |
|---|---|---|---|
| identity | `app_user` | 5 | 사용자. 탈퇴하면 익명화하고 행은 유지한다 |
| identity | `auth_identity` | 10 | 로그인 수단(카카오/애플 등). (provider, provider_uid)로 식별 |
| templates | `font` | 8 | 폰트 메타데이터 |
| templates | `page_master` | 5 | 페이지 마스터(슬롯 배치 정의) |
| templates | `style` | 6 | 문단/글자 스타일(상속 구조) |
| templates | `template` | 12 | 불변 버전의 판형 템플릿과 규모 제약(사진/페이지 수) |
| groups | `family_group` | 7 | 가족 그룹. 월 마감 정책(마감일, 타임존, 미달 시 자동 미발행) |
| groups | `family_member` | 4 | 그룹 구성원과 역할 |
| groups | `publication` | 5 | 그룹의 월간지 |
| issues | `issue` | 18 | 월간 호. 상태는 change_issue_status()로만 바꾼다 |
| issues | `issue_member` | 5 | 호별 참여자의 역할과 제출 현황 |
| issues | `issue_status_history` | 7 | 호 상태 변경 이력 |
| issues | `issue_status_transition` | 3 | 허용된 상태 전이 표 |
| intake | `media` | 21 | 사진. 이미지 분석 결과와 선별 상태 |
| intake | `media_rendition` | 5 | 사진의 파생본(썸네일/미리보기/인쇄용) |
| intake | `social_account` | 7 | SNS 연동 계정(토큰은 참조만 저장) |
| intake | `source_post` | 13 | 수집한 SNS 게시물 스냅샷 |
| intake | `text_block` | 8 | 캡션/인용 등 본문 텍스트 |
| layout | `layout_run` | 21 | 자동 조판 실행 1회(seed, 알고리즘 버전, 워커 임대 정보) |
| layout | `page` | 4 | 조판 결과의 페이지 |
| layout | `placement` | 13 | 페이지 위 요소 배치(mm 단위) |
| layout | `preview` | 6 | 페이지 미리보기 렌더 결과 |
| review | `approval` | 10 | 페이지 승인/수정 요청(승인한 조판 버전을 기록) |
| review | `comment` | 8 | 페이지 코멘트 |
| review | `override` | 9 | 사람의 수정 로그(seq 순서) |
| review | `page_lock` | 3 | 페이지 편집 락 |
| printing | `print_job` | 13 | PDF 생성/프리플라이트 작업 |
| printing | `print_order` | 11 | 인쇄 주문과 배송 |
