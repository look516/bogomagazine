-- V001 baseline: 초기 스키마. 이 파일은 배포된 뒤에는 절대 수정하지 않는다 (체크섬이 깨짐).
-- 스키마를 바꾸려면 새 V0xx__설명.sql 을 추가한다. 함수/뷰/트리거는 R__*.sql 에서 관리한다.

-- 자동 조판 출판 서비스 DB 스키마 (PostgreSQL)
-- 흐름: 수집 -> 선별 -> 자동 조판 -> 사람 수정 -> 미리보기 -> 인쇄

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()

-- =========================================================
-- 0. 사용자
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

-- 로그인 수단 (한 사용자가 여러 개 연결 가능)
CREATE TABLE auth_identity (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    provider      text NOT NULL CHECK (provider IN ('kakao','apple','google','password')),
    provider_uid  text NOT NULL,       -- 카카오 회원번호 / 애플 sub (이메일 말고 이것으로 식별)
    email         text,                -- 해당 제공자가 준 이메일 (참고용)
    email_verified boolean NOT NULL DEFAULT false,
    is_private_relay boolean NOT NULL DEFAULT false,   -- 애플 릴레이 이메일 여부
    refresh_token_ref text,            -- 시크릿 스토어 참조 (원문 저장 금지)
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
-- 2. 출판물 / 호 / 협업
-- =========================================================
-- 가족 그룹: 월 단위 호 마감의 주체
CREATE TABLE family_group (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    owner_id    uuid NOT NULL REFERENCES app_user(id),
    close_day   int  NOT NULL DEFAULT 1 CHECK (close_day BETWEEN 1 AND 28),  -- 다음 달 며칠 00:00 에 마감
    timezone    text NOT NULL DEFAULT 'Asia/Seoul',
    -- true: 선별 가능한 사진이 min_photos 미만이면 자동 미발행(skipped)
    -- false: 부족해도 마감하고 조판이 큰 사진/여백으로 채움
    auto_skip_below_min boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE family_member (
    group_id   uuid NOT NULL REFERENCES family_group(id) ON DELETE CASCADE,
    user_id    uuid NOT NULL REFERENCES app_user(id),
    role       text NOT NULL CHECK (role IN ('admin','member','viewer')),
    joined_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, user_id)
);

CREATE TABLE publication (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    uuid NOT NULL REFERENCES family_group(id),
    name        text NOT NULL,
    owner_id    uuid NOT NULL REFERENCES app_user(id),
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE issue (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    publication_id  uuid NOT NULL REFERENCES publication(id),
    title           text NOT NULL,
    period_start    date NOT NULL,
    period_end      date NOT NULL,
    -- 상태 흐름은 progress.sql 의 issue_status_transition 참고
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
    UNIQUE (publication_id, period_start)     -- 그룹당 같은 기간의 호는 하나
);

CREATE TABLE issue_member (
    issue_id       uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    user_id        uuid NOT NULL REFERENCES app_user(id),
    role           text NOT NULL CHECK (role IN ('owner','editor','contributor','viewer')),
    -- 참여자별 제출 현황 (viewer 는 집계에서 제외)
    submit_status  text NOT NULL DEFAULT 'pending'
        CHECK (submit_status IN ('pending','submitted','skipped')),
    submitted_at   timestamptz,
    PRIMARY KEY (issue_id, user_id)
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

-- =========================================================
-- 3. 입력 수집 (SNS 게시물 / 사진)
-- =========================================================
CREATE TABLE social_account (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid NOT NULL REFERENCES app_user(id),
    platform       text NOT NULL,
    external_id    text NOT NULL,
    token_ref      text,                -- 시크릿 스토어 참조 (토큰 원문 저장 금지)
    consent_at     timestamptz,
    consent_scope  jsonb,               -- 사용/인쇄/공개 동의 범위
    UNIQUE (platform, external_id)
);

CREATE TABLE source_post (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issue_id          uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    contributor_id    uuid NOT NULL REFERENCES app_user(id),
    account_id        uuid REFERENCES social_account(id),
    platform          text NOT NULL,
    external_post_id  text,
    posted_at         timestamptz NOT NULL,
    caption           text,
    hashtags          text[] NOT NULL DEFAULT '{}',
    location          text,
    engagement        jsonb,            -- 좋아요/댓글 수 등 (중요도 점수 입력)
    raw               jsonb,            -- 원본 payload 스냅샷
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (issue_id, platform, external_post_id)
);
CREATE INDEX ix_source_post_issue_time ON source_post (issue_id, posted_at);

CREATE TABLE media (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issue_id          uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    source_post_id    uuid REFERENCES source_post(id) ON DELETE SET NULL,
    uploader_id       uuid NOT NULL REFERENCES app_user(id),
    kind              text NOT NULL DEFAULT 'photo' CHECK (kind IN ('photo','video_thumb')),
    storage_key       text NOT NULL,
    sha256            text NOT NULL,
    width             int  NOT NULL,
    height            int  NOT NULL,
    exif              jsonb,
    taken_at          timestamptz,
    color_profile     text,
    -- 이미지 분석 결과
    focal_point       jsonb,            -- {x,y} 0..1
    saliency          jsonb,            -- 주요 피사체/얼굴 영역
    quality_score     real,
    phash             bigint,           -- 유사 사진 묶기
    -- 선별 상태
    selection_status  text NOT NULL DEFAULT 'candidate'
        CHECK (selection_status IN ('candidate','selected','excluded_auto','excluded_manual')),
    pinned            boolean NOT NULL DEFAULT false,   -- 사용자가 "꼭 넣기" 지정
    selection_score   real,
    -- 권리/동의
    rights_ok         boolean NOT NULL DEFAULT false,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (issue_id, sha256)
);
CREATE INDEX ix_media_issue_sel ON media (issue_id, selection_status);
CREATE INDEX ix_media_phash     ON media (phash);

CREATE TABLE media_rendition (
    media_id     uuid NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    purpose      text NOT NULL CHECK (purpose IN ('thumb','preview','print')),
    storage_key  text NOT NULL,
    width        int NOT NULL,
    height       int NOT NULL,
    PRIMARY KEY (media_id, purpose)
);

-- 본문 텍스트 블록 (캡션, 인용, 기사 등)
CREATE TABLE text_block (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issue_id         uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    source_post_id   uuid REFERENCES source_post(id) ON DELETE SET NULL,
    kind             text NOT NULL CHECK (kind IN ('title','caption','quote','body')),
    body             text NOT NULL,
    runs             jsonb,             -- 인라인 서식 span 배열
    created_by       uuid REFERENCES app_user(id),
    created_at       timestamptz NOT NULL DEFAULT now()
);

-- =========================================================
-- 4. 자동 조판 결과 (파생물, 재생성 가능)
-- =========================================================
CREATE TABLE layout_run (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- "최신"은 created_at 이 아니라 seq 로 판정한다 (같은 트랜잭션에서 만든 행은 created_at 이 같다)
    seq                  bigint GENERATED ALWAYS AS IDENTITY,
    -- 호별 조판 회차 (1부터). guards.sql 의 트리거가 자동 부여한다.
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
    -- 워커 임대(lease): worker.sql 의 claim/heartbeat/complete/fail/reap 함수가 관리
    locked_by            text,
    locked_at            timestamptz,
    heartbeat_at         timestamptz,    -- running 인데 오래 갱신이 없으면 워커가 죽은 것으로 보고 failed 처리
    attempts             int NOT NULL DEFAULT 0,   -- 이 호의 몇 번째 시도인지 (실패 횟수 + 1)
    input_ref            text,           -- 조판 입력 JSON 의 저장 위치 (재현용)
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (issue_id, run_no)
);
CREATE INDEX ix_layout_run_issue ON layout_run (issue_id, seq DESC);
CREATE INDEX ix_layout_run_running ON layout_run (heartbeat_at) WHERE status = 'running';

CREATE TABLE page (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id     uuid NOT NULL REFERENCES layout_run(id) ON DELETE CASCADE,
    page_no    int  NOT NULL,
    master_id  uuid REFERENCES page_master(id),
    UNIQUE (run_id, page_no)
);

CREATE TABLE placement (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    page_id   uuid NOT NULL REFERENCES page(id) ON DELETE CASCADE,
    slot_id   text,
    ref_type  text NOT NULL CHECK (ref_type IN ('media','text_block')),
    media_id       uuid REFERENCES media(id),
    text_block_id  uuid REFERENCES text_block(id),
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

-- =========================================================
-- 5. 협업: 수동 보정 / 락 / 승인 / 코멘트
-- =========================================================
CREATE TABLE override (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issue_id     uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    run_id       uuid NOT NULL REFERENCES layout_run(id) ON DELETE CASCADE,
    seq          bigint GENERATED ALWAYS AS IDENTITY,   -- 변경 순서
    target_type  text NOT NULL CHECK (target_type IN ('page','placement','media')),
    target_id    uuid NOT NULL,
    op           jsonb NOT NULL,   -- move/resize/swap/crop/pin/exclude ...
    author_id    uuid NOT NULL REFERENCES app_user(id),
    created_at   timestamptz NOT NULL DEFAULT now()
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
    page_id     uuid REFERENCES page(id) ON DELETE CASCADE,   -- NULL 이면 호 전체
    -- 어느 버전을 승인했는지. guards.sql 의 트리거가 비워 두면 자동으로 채운다.
    -- 이후에 이 run 에서 seq 가 더 큰 override 가 이 페이지에 생기면 승인은 무효(stale)로 본다.
    run_id        uuid REFERENCES layout_run(id) ON DELETE CASCADE,
    override_seq  bigint,
    user_id     uuid NOT NULL REFERENCES app_user(id),
    status      text NOT NULL CHECK (status IN ('approved','changes_requested')),
    comment     text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE comment (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issue_id    uuid NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    page_id     uuid REFERENCES page(id) ON DELETE CASCADE,
    anchor      jsonb,              -- 페이지 위 좌표 또는 placement 참조
    author_id   uuid NOT NULL REFERENCES app_user(id),
    body        text NOT NULL,
    resolved    boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- =========================================================
-- 6. 미리보기 / 인쇄
-- =========================================================
CREATE TABLE preview (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id        uuid NOT NULL REFERENCES layout_run(id) ON DELETE CASCADE,
    override_seq  bigint NOT NULL DEFAULT 0,   -- 이 시점까지의 수정 반영
    page_no       int NOT NULL,
    storage_key   text,
    status        text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued','done','failed')),
    UNIQUE (run_id, override_seq, page_no)
);

CREATE TABLE print_job (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq               bigint GENERATED ALWAYS AS IDENTITY,   -- 최신 판정 기준 (created_at 아님)
    issue_id          uuid NOT NULL REFERENCES issue(id),
    run_id            uuid NOT NULL REFERENCES layout_run(id),
    override_seq      bigint NOT NULL,        -- 확정본 고정
    pdf_key           text,
    pdf_profile       text NOT NULL DEFAULT 'PDF/X-1a',
    color_mode        text NOT NULL DEFAULT 'CMYK' CHECK (color_mode IN ('CMYK','RGB')),
    bleed_mm          numeric(4,1) NOT NULL DEFAULT 3.0,
    crop_marks        boolean NOT NULL DEFAULT true,
    preflight_report  jsonb,                  -- 해상도 부족, 폰트 누락, 안전영역 침범
    status            text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued','rendering','preflight_failed','ready','failed')),
    created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE print_order (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq           bigint GENERATED ALWAYS AS IDENTITY,   -- 최신 판정 기준 (created_at 아님)
    print_job_id  uuid NOT NULL REFERENCES print_job(id),
    ordered_by    uuid NOT NULL REFERENCES app_user(id),
    vendor        text,
    quantity      int NOT NULL CHECK (quantity > 0),
    shipping      jsonb,
    price         numeric(12,2),
    status        text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','confirmed','printing','shipped','delivered','cancelled')),
    tracking      text,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- =========================================================
-- 7. 폰트
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
-- 8. 추가 인덱스 (조회 경로 + 부모 삭제 시 연쇄 삭제 속도)
-- =========================================================
-- 마감 배치가 찾는 "수집 중이고 마감이 지난 호"
CREATE INDEX ix_issue_collecting_close ON issue (close_at) WHERE status = 'collecting';
-- 진행 뷰가 페이지/호/인쇄 단위로 "가장 최근 1건"을 찾는 경로
CREATE INDEX ix_approval_page        ON approval (page_id, seq DESC);
CREATE INDEX ix_approval_issue       ON approval (issue_id);
CREATE INDEX ix_approval_run         ON approval (run_id);
CREATE INDEX ix_print_job_issue      ON print_job (issue_id, seq DESC);
CREATE INDEX ix_print_job_run        ON print_job (run_id);
CREATE INDEX ix_print_order_job      ON print_order (print_job_id, seq DESC);
-- 부모 삭제(호/게시물/그룹) 시 하위 행을 찾는 경로
CREATE INDEX ix_media_source_post    ON media (source_post_id);
CREATE INDEX ix_text_block_issue     ON text_block (issue_id);
CREATE INDEX ix_text_block_post      ON text_block (source_post_id);
CREATE INDEX ix_override_issue       ON override (issue_id);
CREATE INDEX ix_comment_issue        ON comment (issue_id);
CREATE INDEX ix_comment_page         ON comment (page_id);
CREATE INDEX ix_source_post_account  ON source_post (account_id);
CREATE INDEX ix_publication_group    ON publication (group_id);
-- 사용자 기준 조회 ("내가 속한 그룹/호"): 기본키가 (group_id, user_id)/(issue_id, user_id)라서 user_id 만으로는 못 탄다
CREATE INDEX ix_family_member_user   ON family_member (user_id);
CREATE INDEX ix_issue_member_user    ON issue_member (user_id);
-- 회원 탈퇴(anonymize_user) 시 사용자의 콘텐츠/연동을 찾는 경로
CREATE INDEX ix_media_uploader       ON media (uploader_id);
CREATE INDEX ix_source_post_contrib  ON source_post (contributor_id);
CREATE INDEX ix_social_account_user  ON social_account (user_id);

-- =========================================================
-- 9. 상태 전이 허용표 (테이블만 여기서 만든다. 행 데이터는 R__020_progress.sql 이 관리)
-- =========================================================
CREATE TABLE issue_status_transition (
    from_status  text NOT NULL,
    to_status    text NOT NULL,
    note         text,
    PRIMARY KEY (from_status, to_status)
);

-- =========================================================
-- 10. 테이블 소유 모듈 + 설명 (소유권의 단일 기준)
--     형식: 'module:<모듈> | <설명>'. db/tests/architecture.sql 이 형식을 검사하고
--     docs/erd.md 생성기(scripts/gen_erd.py)가 이 코멘트로 모듈별로 묶는다.
-- =========================================================
COMMENT ON TABLE app_user                IS 'module:identity | 사용자. 탈퇴하면 익명화하고 행은 유지한다';
COMMENT ON TABLE auth_identity           IS 'module:identity | 로그인 수단(카카오/애플 등). (provider, provider_uid)로 식별';
COMMENT ON TABLE family_group            IS 'module:groups | 가족 그룹. 월 마감 정책(마감일, 타임존, 미달 시 자동 미발행)';
COMMENT ON TABLE family_member           IS 'module:groups | 그룹 구성원과 역할';
COMMENT ON TABLE publication             IS 'module:groups | 그룹의 월간지';
COMMENT ON TABLE template                IS 'module:templates | 불변 버전의 판형 템플릿과 규모 제약(사진/페이지 수)';
COMMENT ON TABLE page_master             IS 'module:templates | 페이지 마스터(슬롯 배치 정의)';
COMMENT ON TABLE style                   IS 'module:templates | 문단/글자 스타일(상속 구조)';
COMMENT ON TABLE font                    IS 'module:templates | 폰트 메타데이터';
COMMENT ON TABLE issue                   IS 'module:issues | 월간 호. 상태는 change_issue_status()로만 바꾼다';
COMMENT ON TABLE issue_member            IS 'module:issues | 호별 참여자의 역할과 제출 현황';
COMMENT ON TABLE issue_status_history    IS 'module:issues | 호 상태 변경 이력';
COMMENT ON TABLE issue_status_transition IS 'module:issues | 허용된 상태 전이 표';
COMMENT ON TABLE social_account          IS 'module:intake | SNS 연동 계정(토큰은 참조만 저장)';
COMMENT ON TABLE source_post             IS 'module:intake | 수집한 SNS 게시물 스냅샷';
COMMENT ON TABLE media                   IS 'module:intake | 사진. 이미지 분석 결과와 선별 상태';
COMMENT ON TABLE media_rendition         IS 'module:intake | 사진의 파생본(썸네일/미리보기/인쇄용)';
COMMENT ON TABLE text_block              IS 'module:intake | 캡션/인용 등 본문 텍스트';
COMMENT ON TABLE layout_run              IS 'module:layout | 자동 조판 실행 1회(seed, 알고리즘 버전, 워커 임대 정보)';
COMMENT ON TABLE page                    IS 'module:layout | 조판 결과의 페이지';
COMMENT ON TABLE placement               IS 'module:layout | 페이지 위 요소 배치(mm 단위)';
COMMENT ON TABLE preview                 IS 'module:layout | 페이지 미리보기 렌더 결과';
COMMENT ON TABLE approval                IS 'module:review | 페이지 승인/수정 요청(승인한 조판 버전을 기록)';
COMMENT ON TABLE override                IS 'module:review | 사람의 수정 로그(seq 순서)';
COMMENT ON TABLE comment                 IS 'module:review | 페이지 코멘트';
COMMENT ON TABLE page_lock               IS 'module:review | 페이지 편집 락';
COMMENT ON TABLE print_job               IS 'module:printing | PDF 생성/프리플라이트 작업';
COMMENT ON TABLE print_order             IS 'module:printing | 인쇄 주문과 배송';
