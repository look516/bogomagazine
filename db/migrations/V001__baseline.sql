-- V001 baseline: 초기 스키마 전체. 아직 어디에도 배포되지 않았으므로 설계가 바뀌면 이 파일에 직접 반영한다.
-- main 에 합쳐지고 어떤 DB 에 적용된 뒤에는 수정하지 않는다 (체크섬이 깨짐). 그때부터는 새 V0xx__설명.sql 을 추가한다.
-- 함수/뷰/트리거는 R__*.sql 에서 관리한다.
--
-- 서비스: 가족 그룹(방장 + 구성원)이 앱 안 피드에 사진/글을 올리면, 매월 그 달의 글을 모아 신문(월간지)으로 자동 조판하고
--         가족이 검토/승인한 뒤 인쇄해서 조부모님께 우편으로 보낸다. 로그인은 카카오/애플만. 조부모님은 앱 사용자가 아니다.
-- 흐름: 피드 게시 -> (월 마감) 선별 -> 자동 조판 -> 가족 검토/수정 -> 승인 -> 미리보기 -> 인쇄 -> 배송
--
-- 무결성 원칙: 같은 사실이 두 곳에 있으면(예: 사진의 그룹 = 게시물의 그룹) 복합 외래키로 서로 어긋나지 못하게 한다.
--   복합 외래키는 컬럼 중 하나가 NULL 이면 검사를 건너뛴다 (호 전체 승인, 게시물이 지워진 텍스트 등이 이에 해당).
--   외래키로 표현할 수 없는 것(배치 <-> 선별된 사진, 작성자 <-> 활동 중인 구성원 등)은 R__*.sql 의 트리거가 지킨다.

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()

-- =========================================================
-- 0. 사용자 / 로그인 (카카오, 애플)
-- =========================================================
CREATE TABLE app_user (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email       text,                  -- 카카오: 동의 안 하면 NULL / 애플: 릴레이 주소일 수 있음
    name        text,                  -- 애플은 최초 로그인 때만 제공 -> 없을 수 있음
    created_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz
);
-- 이메일은 있을 때만 유일 (대소문자 무시)
CREATE UNIQUE INDEX ux_app_user_email ON app_user (lower(email)) WHERE email IS NOT NULL;

-- 로그인 수단 (한 사용자가 카카오와 애플을 모두 연결할 수 있다)
CREATE TABLE auth_identity (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    provider      text NOT NULL CHECK (provider IN ('kakao','apple')),
    provider_uid  text NOT NULL,       -- 카카오 회원번호 / 애플 sub (이메일 말고 이것으로 식별)
    email         text,                -- 해당 제공자가 준 이메일 (참고용)
    email_verified boolean NOT NULL DEFAULT false,
    is_private_relay boolean NOT NULL DEFAULT false,   -- 애플 릴레이 이메일 여부
    refresh_token_ref text,            -- 시크릿 저장소 참조 (원문 저장 금지)
    last_login_at timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, provider_uid)
);
CREATE INDEX ix_auth_identity_user ON auth_identity (user_id);

-- =========================================================
-- 1. 템플릿 (불변 버전)
-- =========================================================
CREATE TABLE template (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    version     int  NOT NULL,
    -- 판형, 단 수, 그리드, 여백, 블리드, 안전영역
    spec        jsonb NOT NULL,
    -- 규모 제약 (호 생성 시 issue 로 복사되어 호별로 조정 가능)
    min_photos           int NOT NULL DEFAULT 15,
    max_photos           int NOT NULL DEFAULT 250,
    min_pages            int NOT NULL DEFAULT 8,
    max_pages            int NOT NULL DEFAULT 80,
    page_multiple        int NOT NULL DEFAULT 4,   -- 중철 4, 무선철 등은 별도
    photos_per_page_min  int NOT NULL DEFAULT 1,
    photos_per_page_max  int NOT NULL DEFAULT 6,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (name, version)
);

CREATE TABLE page_master (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id  uuid NOT NULL REFERENCES template(id) ON DELETE CASCADE,
    name         text NOT NULL,
    grid         jsonb NOT NULL,
    -- 슬롯 목록: [{slot_id, kind: photo|text, x,y,w,h, aspect_min, aspect_max}]
    slots        jsonb NOT NULL,
    UNIQUE (template_id, name)
);

CREATE TABLE style (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id  uuid NOT NULL REFERENCES template(id) ON DELETE CASCADE,
    kind         text NOT NULL CHECK (kind IN ('paragraph','character','caption','frame')),
    name         text NOT NULL,
    based_on     uuid REFERENCES style(id),   -- 상속: 오버라이드 값만 props 에 저장
    props        jsonb NOT NULL DEFAULT '{}',
    UNIQUE (template_id, kind, name)
);

-- =========================================================
-- 2. 가족 그룹 (방장 + 구성원), 초대, 배송지
-- =========================================================
-- 방장은 owner_id 하나로 표현한다 (구성원의 역할 컬럼을 따로 두지 않는다: 같은 사실이 두 곳에 있으면 어긋난다).
-- 방장만 멤버 관리(초대, 내보내기, 방장 넘기기) 권한을 가진다 -> R__005_groups_membership.sql 의 함수와 트리거
CREATE TABLE family_group (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    owner_id    uuid NOT NULL REFERENCES app_user(id),   -- 방장
    close_day   int  NOT NULL DEFAULT 1 CHECK (close_day BETWEEN 1 AND 28),  -- 다음 달 며칠 00:00 에 마감
    timezone    text NOT NULL DEFAULT 'Asia/Seoul',
    -- true: 선별 가능한 사진이 min_photos 미만이면 자동 미발행(skipped)
    -- false: 부족해도 마감하고 조판이 큰 사진/여백으로 채움
    auto_skip_below_min boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- 구성원. 나가거나 내보내도 행은 지우지 않고 left_at 을 채운다 (그 사람이 쓴 글/기록의 작성자 정보를 유지하려고).
CREATE TABLE family_member (
    group_id   uuid NOT NULL REFERENCES family_group(id) ON DELETE CASCADE,
    user_id    uuid NOT NULL REFERENCES app_user(id),
    nickname   text,                    -- 가족 안에서의 호칭 (엄마, 아빠 ...)
    joined_at  timestamptz NOT NULL DEFAULT now(),
    left_at    timestamptz,             -- NULL = 활동 중
    PRIMARY KEY (group_id, user_id),
    CHECK (left_at IS NULL OR left_at >= joined_at)
);

-- 방장은 반드시 그 그룹의 구성원이어야 한다. 그룹과 구성원이 서로를 참조하므로 커밋 시점에 검사한다
-- (그룹을 만들 때는 한 트랜잭션에서 그룹과 방장 구성원을 함께 넣는다: create_family_group()).
ALTER TABLE family_group
    ADD CONSTRAINT family_group_owner_member_fkey
    FOREIGN KEY (id, owner_id) REFERENCES family_member (group_id, user_id) DEFERRABLE INITIALLY DEFERRED;

-- 카카오톡으로 보내는 초대 링크. 링크의 토큰 원문은 저장하지 않고 해시만 저장한다.
-- 애플은 이메일을 숨길 수 있으므로 이메일이 아니라 링크 토큰으로 합류시킨다. 합류하는 사람은 항상 일반 구성원이다.
CREATE TABLE family_invite (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    uuid NOT NULL REFERENCES family_group(id) ON DELETE CASCADE,
    created_by  uuid NOT NULL,              -- 방장 (R__005 트리거가 검사)
    token_hash  text NOT NULL UNIQUE CHECK (length(token_hash) = 64),   -- sha256 hex
    expires_at  timestamptz NOT NULL,
    max_uses    int CHECK (max_uses IS NULL OR max_uses > 0),           -- NULL = 횟수 제한 없음 (만료 전까지)
    use_count   int NOT NULL DEFAULT 0 CHECK (use_count >= 0),
    revoked_at  timestamptz,                -- 방장이 링크를 취소한 시각
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (expires_at > created_at),
    CHECK (max_uses IS NULL OR use_count <= max_uses),
    -- 커밋 시점 검사: 그룹을 지우면 구성원과 초대가 같은 문장에서 함께 지워지기 때문
    FOREIGN KEY (group_id, created_by) REFERENCES family_member (group_id, user_id) DEFERRABLE INITIALLY DEFERRED
);

-- 조부모님 배송지. 조부모님은 앱에 로그인하지 않고 신문으로 받으시므로 주소만 저장한다.
-- 주문(print_order)에는 주문 시점의 주소를 복사해 두므로, 여기서 주소를 고치거나 지워도 이미 보낸 주문의 기록은 바뀌지 않는다.
CREATE TABLE delivery_address (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id        uuid NOT NULL REFERENCES family_group(id) ON DELETE CASCADE,
    label           text NOT NULL,          -- 예: 친할머니·친할아버지 댁
    recipient_name  text NOT NULL,
    recipient_phone text,                   -- 개인정보: 접근을 제한하고 필요하면 암호화한다 (TODO.md)
    postal_code     text NOT NULL,
    address_line1   text NOT NULL,
    address_line2   text,
    memo            text,                   -- 배송 메모 (예: 경비실에 맡겨 주세요)
    created_by      uuid NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (group_id, created_by) REFERENCES family_member (group_id, user_id) DEFERRABLE INITIALLY DEFERRED
);

-- =========================================================
-- 3. 월간 호
-- =========================================================
CREATE TABLE issue (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id        uuid NOT NULL REFERENCES family_group(id),
    title           text NOT NULL,
    period_start    date NOT NULL,          -- 이 호에 실리는 게시물의 기간 (그룹 타임존 기준 날짜)
    period_end      date NOT NULL,
    -- 상태 흐름은 아래 issue_status_transition 과 R__020_issues_lifecycle.sql 참고
    --   collecting(수집) -> closing(마감 처리: 선별+조판) -> review(검토) -> approved(승인)
    --   -> printing(인쇄 제작) -> printed(인쇄 완료/배송) -> archived
    --   수집량 미달 시 collecting -> skipped(이번 달 미발행) -> archived
    status          text NOT NULL DEFAULT 'collecting'
        CHECK (status IN ('collecting','closing','review','approved','printing',
                          'printed','skipped','archived')),
    status_changed_at timestamptz NOT NULL DEFAULT now(),
    close_at        timestamptz NOT NULL,     -- 수집 마감 예정 시각
    closed_at       timestamptz,              -- 실제로 수집을 닫은 시각 (closing 진입 시)
    -- 마감 배치 실패 기록: 5회 이상 실패한 호는 자동 재시도 대상에서 빠지고 사람이 확인한다
    close_attempts  int NOT NULL DEFAULT 0,
    close_error     text,
    template_id     uuid NOT NULL REFERENCES template(id),
    -- 템플릿 값을 복사해 호별로 조정 가능하게 둠
    min_photos      int NOT NULL,
    max_photos      int NOT NULL,
    min_pages       int NOT NULL,
    max_pages       int NOT NULL,
    page_multiple   int NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (period_end >= period_start),
    CHECK (min_photos <= max_photos),
    CHECK (min_pages <= max_pages),
    UNIQUE (group_id, period_start),          -- 그룹당 같은 기간의 호는 하나
    UNIQUE (id, group_id)                     -- 복합 외래키(issue_media/text_block 이 같은 그룹만 참조)의 대상
);

-- 상태 변경 이력 (진행 타임라인 조회용)
CREATE TABLE issue_status_history (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    issue_id     uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    from_status  text,
    to_status    text NOT NULL,
    changed_by   uuid REFERENCES app_user(id),
    note         text,
    changed_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_issue_status_history ON issue_status_history (issue_id, changed_at);

-- 허용된 상태 전이 표 (행 데이터는 R__020_issues_lifecycle.sql 이 관리한다)
CREATE TABLE issue_status_transition (
    from_status  text NOT NULL,
    to_status    text NOT NULL,
    note         text,
    PRIMARY KEY (from_status, to_status)
);

-- =========================================================
-- 4. 피드 (앱 안에서 가족이 올리는 사진/글)와 호별 선별
--    게시물은 호와 독립이다. 호는 "그 달(period_start~period_end)의 게시물을 모아 만든 결과물"이다.
-- =========================================================
CREATE TABLE post (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    uuid NOT NULL REFERENCES family_group(id) ON DELETE CASCADE,
    author_id   uuid NOT NULL,
    body        text,                       -- 글 (사진만 올릴 수도 있다)
    posted_at   timestamptz NOT NULL DEFAULT now(),   -- 어느 호에 실릴지를 정한다 (그룹 타임존 기준 날짜)
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,                -- 삭제한 글. 이미 마감된 호의 내용은 바뀌지 않는다
    UNIQUE (id, group_id),                  -- 복합 외래키(사진/텍스트가 같은 그룹만 참조)의 대상
    -- 작성자는 그 그룹의 구성원이어야 한다 (활동 중인지는 R__030 트리거가 검사)
    FOREIGN KEY (group_id, author_id) REFERENCES family_member (group_id, user_id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE media (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id           uuid NOT NULL,
    group_id          uuid NOT NULL,        -- 게시물의 그룹 (복합 외래키로 일치를 보장. issue_media 가 같은 그룹만 묶게 하려고 둠)
    kind              text NOT NULL DEFAULT 'photo' CHECK (kind IN ('photo','video_thumb')),
    storage_key       text NOT NULL,
    sha256            text NOT NULL,
    width             int  NOT NULL,
    height            int  NOT NULL,
    exif              jsonb,
    taken_at          timestamptz,
    color_profile     text,
    -- 이미지 분석 결과
    focal_point       jsonb,                -- {x,y} 0..1
    saliency          jsonb,                -- 주요 피사체/얼굴 영역
    quality_score     real,
    phash             bigint,               -- 유사 사진 묶기
    rights_ok         boolean NOT NULL DEFAULT true,    -- false 면 선별에서 제외 (신고 등으로 쓸 수 없는 사진)
    -- 사용자의 의도 (호와 무관하게 사진에 붙는 선택). 선별 결과는 issue_media 에 따로 둔다.
    pinned            boolean NOT NULL DEFAULT false,   -- "꼭 넣기"
    excluded          boolean NOT NULL DEFAULT false,   -- "이번 호에서 빼기"
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (post_id, sha256),
    UNIQUE (id, group_id),                  -- 복합 외래키(issue_media)의 대상
    FOREIGN KEY (post_id, group_id) REFERENCES post (id, group_id) ON DELETE CASCADE
);
CREATE INDEX ix_media_phash ON media (phash);

CREATE TABLE media_rendition (
    media_id     uuid NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    purpose      text NOT NULL CHECK (purpose IN ('thumb','preview','print')),
    storage_key  text NOT NULL,
    width        int NOT NULL,
    height       int NOT NULL,
    PRIMARY KEY (media_id, purpose)
);

-- 호별 사진 선별 결과. 사진 자체(media)와 "이 호에서 어떻게 되었나"를 분리한다 (파생 데이터, 마감할 때 만들어진다).
CREATE TABLE issue_media (
    issue_id          uuid NOT NULL,
    media_id          uuid NOT NULL,
    group_id          uuid NOT NULL,        -- 호의 그룹 = 사진의 그룹 (복합 외래키 두 개로 보장)
    selection_status  text NOT NULL DEFAULT 'candidate'
        CHECK (selection_status IN ('candidate','selected','excluded_auto','excluded_manual')),
    selection_score   real,
    created_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (issue_id, media_id),
    FOREIGN KEY (issue_id, group_id) REFERENCES issue (id, group_id) ON DELETE CASCADE,
    FOREIGN KEY (media_id, group_id) REFERENCES media (id, group_id) ON DELETE CASCADE
);
CREATE INDEX ix_issue_media_sel ON issue_media (issue_id, selection_status);

-- 호에 들어가는 글 조각(제목, 캡션, 인용, 본문). 게시물 글에서 만들어지거나 조판 중에 만들어진다.
CREATE TABLE text_block (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issue_id         uuid NOT NULL,
    group_id         uuid NOT NULL,
    post_id          uuid,                  -- 원본 게시물 (제목처럼 만들어진 글은 NULL)
    kind             text NOT NULL CHECK (kind IN ('title','caption','quote','body')),
    body             text NOT NULL,
    runs             jsonb,                 -- 인라인 서식 span 배열
    created_by       uuid REFERENCES app_user(id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (issue_id, group_id) REFERENCES issue (id, group_id) ON DELETE CASCADE,
    FOREIGN KEY (post_id, group_id)  REFERENCES post (id, group_id) ON DELETE SET NULL (post_id)
);

-- =========================================================
-- 5. 자동 조판 결과 (파생물, 재생성 가능)
-- =========================================================
CREATE TABLE layout_run (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- "최신"은 created_at 이 아니라 seq 로 판정한다 (같은 트랜잭션에서 만든 행은 created_at 이 같다)
    seq                  bigint GENERATED ALWAYS AS IDENTITY,
    -- 호별 조판 회차 (1부터). R__060_layout_worker.sql 의 트리거가 자동 부여한다.
    run_no               int NOT NULL,
    issue_id             uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    template_id          uuid NOT NULL REFERENCES template(id),
    algorithm_version    text NOT NULL,
    params               jsonb NOT NULL DEFAULT '{}',
    seed                 bigint NOT NULL,
    input_snapshot_hash  text NOT NULL,   -- 입력이 바뀌었는지 판단
    -- superseded: 재오픈/재조판으로 더 이상 유효하지 않은 실행 (워커는 저장 전에 이 상태인지 확인할 것)
    status               text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued','running','done','failed','superseded')),
    score                real,
    report               jsonb,          -- 조판 결과 보고: {warnings, unplaced, stats}
    log                  text,
    started_at           timestamptz,
    finished_at          timestamptz,
    -- 워커 임대(lease): R__060_layout_worker.sql 의 claim/heartbeat/complete/fail/reap 함수가 관리
    locked_by            text,
    locked_at            timestamptz,
    heartbeat_at         timestamptz,    -- running 인데 오래 갱신이 없으면 워커가 죽은 것으로 보고 failed 처리
    attempts             int NOT NULL DEFAULT 0,   -- 이 호의 몇 번째 시도인지 (실패 횟수 + 1)
    input_ref            text,           -- 조판 입력 JSON 의 저장 위치 (재현용)
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (issue_id, run_no),
    -- 복합 외래키(승인/수정/인쇄작업의 호와 조판의 호가 같음을 보장)의 대상
    UNIQUE (id, issue_id)
);
CREATE INDEX ix_layout_run_issue ON layout_run (issue_id, seq DESC);
CREATE INDEX ix_layout_run_running ON layout_run (heartbeat_at) WHERE status = 'running';

CREATE TABLE page (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id     uuid NOT NULL REFERENCES layout_run(id) ON DELETE CASCADE,
    page_no    int  NOT NULL,
    master_id  uuid REFERENCES page_master(id),
    UNIQUE (run_id, page_no),
    UNIQUE (id, run_id)       -- 복합 외래키(승인의 페이지와 조판이 같음을 보장)의 대상
);

CREATE TABLE placement (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    page_id   uuid NOT NULL REFERENCES page(id) ON DELETE CASCADE,
    slot_id   text,
    ref_type  text NOT NULL CHECK (ref_type IN ('media','text_block')),
    -- 배치에 쓰인 사진/텍스트는 따로 지울 수 없다. 사진은 호와 독립이라 호를 지워도 남으므로 즉시 검사한다.
    -- 텍스트는 호를 지우면 text_block 과 placement 가 같은 문장에서 지워지고 순서가 보장되지 않으므로 커밋 시점에 검사한다.
    -- 이 호에서 선별된 사진/같은 호의 텍스트인지는 R__060_layout_worker.sql 의 트리거가 지킨다.
    media_id       uuid REFERENCES media(id),
    text_block_id  uuid REFERENCES text_block(id) DEFERRABLE INITIALLY DEFERRED,
    -- 단위: mm
    x numeric(8,2) NOT NULL,
    y numeric(8,2) NOT NULL,
    w numeric(8,2) NOT NULL,
    h numeric(8,2) NOT NULL,
    z int NOT NULL DEFAULT 0,
    crop      jsonb,                    -- 원본 기준 크롭 사각형 (0..1)
    style_id  uuid REFERENCES style(id),
    CHECK (
        (ref_type = 'media'      AND media_id      IS NOT NULL AND text_block_id IS NULL) OR
        (ref_type = 'text_block' AND text_block_id IS NOT NULL AND media_id      IS NULL)
    )
);
CREATE INDEX ix_placement_page  ON placement (page_id);
CREATE INDEX ix_placement_media ON placement (media_id);
CREATE INDEX ix_placement_text_block ON placement (text_block_id);

-- =========================================================
-- 6. 협업: 수동 보정 / 락 / 승인
-- =========================================================
CREATE TABLE override (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issue_id     uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    run_id       uuid NOT NULL,
    seq          bigint GENERATED ALWAYS AS IDENTITY,   -- 변경 순서
    target_type  text NOT NULL CHECK (target_type IN ('page','placement','media')),
    target_id    uuid NOT NULL,
    op           jsonb NOT NULL,   -- move/resize/swap/crop/pin/exclude ...
    author_id    uuid NOT NULL REFERENCES app_user(id),
    created_at   timestamptz NOT NULL DEFAULT now(),
    -- 수정이 가리키는 조판이 이 호의 조판이어야 한다
    FOREIGN KEY (run_id, issue_id) REFERENCES layout_run (id, issue_id) ON DELETE CASCADE
);
CREATE INDEX ix_override_run_seq ON override (run_id, seq);

CREATE TABLE page_lock (
    page_id     uuid PRIMARY KEY REFERENCES page(id) ON DELETE CASCADE,
    user_id     uuid NOT NULL REFERENCES app_user(id),
    expires_at  timestamptz NOT NULL
);

CREATE TABLE approval (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq         bigint GENERATED ALWAYS AS IDENTITY,   -- 최신 판정 기준 (created_at 아님)
    issue_id    uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    page_id     uuid,                          -- NULL 이면 호 전체
    -- 어느 버전을 승인했는지. R__040_review_guards.sql 의 트리거가 비워 두면 자동으로 채운다.
    -- 이후에 이 run 에서 seq 가 더 큰 override 가 이 페이지에 생기면 승인은 무효(stale)로 본다.
    run_id        uuid,
    override_seq  bigint,
    user_id     uuid NOT NULL REFERENCES app_user(id),
    status      text NOT NULL CHECK (status IN ('approved','changes_requested')),
    comment     text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- 페이지를 승인하면 그 페이지의 조판(run_id)도 반드시 같이 기록된다 (복합 외래키는 NULL 이 있으면 검사를 건너뛰므로 따로 막는다)
    CHECK (page_id IS NULL OR run_id IS NOT NULL),
    -- 승인의 호 / 조판 / 페이지가 서로 어긋나지 않게 한다
    FOREIGN KEY (run_id, issue_id) REFERENCES layout_run (id, issue_id) ON DELETE CASCADE,
    FOREIGN KEY (page_id, run_id)  REFERENCES page (id, run_id) ON DELETE CASCADE
);

-- =========================================================
-- 7. 미리보기 / 인쇄 / 배송
-- =========================================================
CREATE TABLE preview (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id        uuid NOT NULL,
    override_seq  bigint NOT NULL DEFAULT 0,   -- 이 시점까지의 수정 반영
    page_no       int NOT NULL,
    storage_key   text,
    status        text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued','done','failed')),
    UNIQUE (run_id, override_seq, page_no),
    -- 존재하는 페이지의 미리보기만 둘 수 있다 (page 가 지워지면 함께 지워짐)
    FOREIGN KEY (run_id, page_no) REFERENCES page (run_id, page_no) ON DELETE CASCADE
);

CREATE TABLE print_job (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq               bigint GENERATED ALWAYS AS IDENTITY,   -- 최신 판정 기준 (created_at 아님)
    issue_id          uuid NOT NULL REFERENCES issue(id),
    run_id            uuid NOT NULL,
    override_seq      bigint NOT NULL,        -- 확정본 고정
    pdf_key           text,
    pdf_profile       text NOT NULL DEFAULT 'PDF/X-1a',
    color_mode        text NOT NULL DEFAULT 'CMYK' CHECK (color_mode IN ('CMYK','RGB')),
    bleed_mm          numeric(4,1) NOT NULL DEFAULT 3.0,
    crop_marks        boolean NOT NULL DEFAULT true,
    preflight_report  jsonb,                  -- 해상도 부족, 폰트 누락, 안전영역 침범
    status            text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued','rendering','preflight_failed','ready','failed')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- 인쇄할 조판이 이 호의 조판이어야 한다
    FOREIGN KEY (run_id, issue_id) REFERENCES layout_run (id, issue_id)
);

-- 인쇄 주문 1건 = 배송지 1곳. 같은 인쇄 작업(PDF)으로 조부모님 댁마다 주문을 하나씩 만든다.
-- 받는 사람/주소는 주문 시점의 값을 복사해 둔다 (배송지를 나중에 고치거나 지워도 이미 보낸 주문의 기록이 바뀌지 않게).
-- R__080_printing_guards.sql 의 트리거가 "같은 그룹의 배송지", "활동 중인 구성원의 주문"을 검사한다.
CREATE TABLE print_order (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq                 bigint GENERATED ALWAYS AS IDENTITY,   -- 최신 판정 기준 (created_at 아님)
    print_job_id        uuid NOT NULL REFERENCES print_job(id),
    delivery_address_id uuid REFERENCES delivery_address(id) ON DELETE SET NULL,   -- 어느 배송지에서 복사했는지 (참고용)
    ordered_by          uuid NOT NULL REFERENCES app_user(id),
    recipient_name      text NOT NULL,
    recipient_phone     text,
    postal_code         text NOT NULL,
    address_line1       text NOT NULL,
    address_line2       text,
    vendor              text,
    quantity            int NOT NULL DEFAULT 1 CHECK (quantity > 0),
    price               numeric(12,2),
    status              text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','confirmed','printing','shipped','delivered','cancelled')),
    tracking            text,
    created_at          timestamptz NOT NULL DEFAULT now()
);

-- =========================================================
-- 8. 폰트
-- =========================================================
CREATE TABLE font (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    family       text NOT NULL,
    weight       int  NOT NULL DEFAULT 400,
    italic       boolean NOT NULL DEFAULT false,
    storage_key  text NOT NULL,
    sha256       text NOT NULL,
    license      text,
    fallback     uuid REFERENCES font(id),
    UNIQUE (family, weight, italic)
);

-- =========================================================
-- 9. 추가 인덱스 (조회 경로 + 부모 삭제 시 연쇄 삭제 속도)
-- =========================================================
-- 마감 배치가 찾는 "수집 중이고 마감이 지난 호"
CREATE INDEX ix_issue_collecting_close ON issue (close_at) WHERE status = 'collecting';
-- 사용자 기준 조회 ("내가 속한 그룹"): 기본키가 (group_id, user_id)라서 user_id 만으로는 못 탄다
CREATE INDEX ix_family_member_user   ON family_member (user_id);
CREATE INDEX ix_family_invite_group  ON family_invite (group_id);
CREATE INDEX ix_delivery_address_group ON delivery_address (group_id);
-- 피드: 그룹의 기간별 게시물 (월 마감 때 모으는 경로), 작성자별 (복합 외래키/탈퇴 처리)
CREATE INDEX ix_post_group_time      ON post (group_id, posted_at);
CREATE INDEX ix_post_group_author    ON post (group_id, author_id);
CREATE INDEX ix_media_post           ON media (post_id);
CREATE INDEX ix_issue_media_media    ON issue_media (media_id);
CREATE INDEX ix_text_block_issue     ON text_block (issue_id);
CREATE INDEX ix_text_block_post      ON text_block (post_id);
-- 진행 뷰가 페이지/호/인쇄 단위로 "가장 최근 1건"을 찾는 경로
CREATE INDEX ix_approval_page        ON approval (page_id, seq DESC);
CREATE INDEX ix_approval_issue       ON approval (issue_id);
CREATE INDEX ix_approval_run         ON approval (run_id);
CREATE INDEX ix_override_issue       ON override (issue_id);
CREATE INDEX ix_print_job_issue      ON print_job (issue_id, seq DESC);
CREATE INDEX ix_print_job_run        ON print_job (run_id);
CREATE INDEX ix_print_order_job      ON print_order (print_job_id, seq DESC);
CREATE INDEX ix_print_order_address  ON print_order (delivery_address_id);

-- =========================================================
-- 10. 테이블 소유 모듈 + 설명 (소유권의 단일 기준)
--     형식: 'module:<모듈> | <설명>'. db/tests/architecture.sql 이 형식을 검사하고
--     docs/erd.md 생성기(scripts/gen_erd.py)가 이 코멘트로 모듈별로 묶는다.
-- =========================================================
COMMENT ON TABLE app_user                IS 'module:identity | 사용자. 탈퇴하면 익명화하고 행은 유지한다';
COMMENT ON TABLE auth_identity           IS 'module:identity | 로그인 수단(카카오/애플). (provider, provider_uid)로 식별';
COMMENT ON TABLE family_group            IS 'module:groups | 가족 그룹. 방장(owner_id)과 월 마감 정책(마감일, 타임존, 미달 시 자동 미발행)';
COMMENT ON TABLE family_member           IS 'module:groups | 그룹 구성원. 나가도 행은 남기고 left_at 만 채운다';
COMMENT ON TABLE family_invite           IS 'module:groups | 카카오톡 초대 링크(토큰 해시, 만료, 사용 횟수, 취소). 방장만 만든다';
COMMENT ON TABLE delivery_address        IS 'module:groups | 조부모님 배송지(주소만, 로그인 없음). 주문에는 복사본을 남긴다';
COMMENT ON TABLE template                IS 'module:templates | 불변 버전의 판형 템플릿과 규모 제약(사진/페이지 수)';
COMMENT ON TABLE page_master             IS 'module:templates | 페이지 마스터(슬롯 배치 정의)';
COMMENT ON TABLE style                   IS 'module:templates | 문단/글자 스타일(상속 구조)';
COMMENT ON TABLE font                    IS 'module:templates | 폰트 메타데이터';
COMMENT ON TABLE issue                   IS 'module:issues | 월간 호. 그 달의 게시물을 모아 만든 결과물. 상태는 change_issue_status()로만 바꾼다';
COMMENT ON TABLE issue_status_history    IS 'module:issues | 호 상태 변경 이력';
COMMENT ON TABLE issue_status_transition IS 'module:issues | 허용된 상태 전이 표';
COMMENT ON TABLE post                    IS 'module:feed | 피드 게시물(글). 호와 독립이고 posted_at 으로 어느 호에 실릴지 정해진다';
COMMENT ON TABLE media                   IS 'module:feed | 게시물의 사진. 이미지 분석 결과와 사용자의 의도(꼭 넣기/빼기)';
COMMENT ON TABLE media_rendition         IS 'module:feed | 사진의 파생본(썸네일/미리보기/인쇄용)';
COMMENT ON TABLE issue_media             IS 'module:feed | 호별 사진 선별 결과(후보/선택/제외와 점수). 마감할 때 만들어진다';
COMMENT ON TABLE text_block              IS 'module:feed | 호에 들어가는 글 조각(제목/캡션/인용/본문)';
COMMENT ON TABLE layout_run              IS 'module:layout | 자동 조판 실행 1회(seed, 알고리즘 버전, 워커 임대 정보)';
COMMENT ON TABLE page                    IS 'module:layout | 조판 결과의 페이지';
COMMENT ON TABLE placement               IS 'module:layout | 페이지 위 요소 배치(mm 단위)';
COMMENT ON TABLE preview                 IS 'module:layout | 페이지 미리보기 렌더 결과';
COMMENT ON TABLE approval                IS 'module:review | 페이지 승인/수정 요청(승인한 조판 버전을 기록)';
COMMENT ON TABLE override                IS 'module:review | 사람의 수정 로그(seq 순서)';
COMMENT ON TABLE page_lock               IS 'module:review | 페이지 편집 락';
COMMENT ON TABLE print_job               IS 'module:printing | PDF 생성/프리플라이트 작업';
COMMENT ON TABLE print_order             IS 'module:printing | 인쇄 주문 1건 = 배송지 1곳. 받는 사람/주소는 주문 시점의 복사본';
