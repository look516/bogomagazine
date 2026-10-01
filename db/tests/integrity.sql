-- 참조 정합성 테스트: "같은 사실이 두 곳에 있을 때 서로 어긋난 값이 들어갈 수 있는가"를 일부러 시도해 본다.
-- 막혀야 하는 것(복합 외래키 / 트리거)은 막히는지, 정상 데이터는 막히지 않는지(과잉 차단 방지),
-- 의도적으로 허용한 것은 허용되는지, 복합 키에서도 SET NULL / CASCADE 가 의도대로 동작하는지 확인한다.
-- 전체 실행: ./scripts/db.sh test. 하나의 트랜잭션 안에서 공통 준비물을 만들고 끝에 ROLLBACK 한다.
\echo == integrity
BEGIN;

CREATE TEMP TABLE fx (name text PRIMARY KEY, id uuid NOT NULL);
CREATE FUNCTION pg_temp.fx(p text) RETURNS uuid LANGUAGE sql STABLE AS $f$ SELECT id FROM fx WHERE name = p $f$;

-- 준비
--   그룹 1(시드 김씨네): u1=방장, u2=구성원. 호 A(9월, 마감 후 검토 단계), 호 B(10월, 수집 중). 배송지 e1.
--   그룹 2(다른 집): u3=방장. 호 X(9월). 그룹 1 과 섞이면 안 되는 글/사진을 가진다.
--   u4 = 그룹 1 을 나간 사람 (과거 구성원)
DO $$
DECLARE
  a   constant uuid := '00000000-0000-0000-0000-0000000000c1';
  g1  constant uuid := '00000000-0000-0000-0000-0000000000d1';
  tpl constant uuid := '00000000-0000-0000-0000-0000000000a1';
  u1  constant uuid := '00000000-0000-0000-0000-000000000001';
  u2  constant uuid := '00000000-0000-0000-0000-000000000002';
  u3 uuid := gen_random_uuid(); u4 uuid := gen_random_uuid();
  b uuid; g2 uuid; x uuid; ra1 uuid; ra2 uuid; rb uuid; pa uuid; pb uuid;
  postB uuid; postX uuid; mediaB uuid; mediaX uuid; mediaA uuid; mediaN uuid; tbA uuid; tbB uuid; tpl2 uuid;
BEGIN
  SELECT o_issue_id INTO b FROM open_monthly_issues('2026-10-02 12:00+09');
  INSERT INTO app_user (id, name) VALUES (u3, '다른 집 방장'), (u4, '나간 사람');
  INSERT INTO family_member (group_id, user_id, joined_at, left_at) VALUES (g1, u4, now() - interval '2 days', now() - interval '1 day');
  g2 := create_family_group('다른집', u3, '아빠');
  INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id, min_photos, max_photos, min_pages, max_pages, page_multiple)
  VALUES (g2, 'X호', '2026-09-01', '2026-09-30', '2026-10-01 00:00+09', tpl, 1, 10, 8, 40, 4) RETURNING id INTO x;

  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g1, u2, 'B월 글', '2026-10-03 12:00+09') RETURNING id INTO postB;
  INSERT INTO media (post_id, group_id, storage_key, sha256, width, height) VALUES (postB, g1, 'fx-mb', 'fxmb', 1, 1) RETURNING id INTO mediaB;
  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g2, u3, '다른 집 글', '2026-09-10 12:00+09') RETURNING id INTO postX;
  INSERT INTO media (post_id, group_id, storage_key, sha256, width, height) VALUES (postX, g2, 'fx-mx', 'fxmx', 1, 1) RETURNING id INTO mediaX;
  INSERT INTO text_block (issue_id, group_id, kind, body) VALUES (b, g1, 'caption', 'B') RETURNING id INTO tbB;
  INSERT INTO template (name, version, spec) VALUES ('integrity-test', 1, '{}') RETURNING id INTO tpl2;

  PERFORM change_issue_status(a, 'closing');
  PERFORM * FROM select_media(a);
  SELECT media_id INTO mediaA FROM issue_media WHERE issue_id = a AND selection_status = 'selected' LIMIT 1;
  SELECT media_id INTO mediaN FROM issue_media WHERE issue_id = a AND selection_status <> 'selected' LIMIT 1;
  INSERT INTO text_block (issue_id, group_id, kind, body) VALUES (a, g1, 'caption', 'A') RETURNING id INTO tbA;

  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status) VALUES (a, tpl, '0.1', 1, 'h', 'done') RETURNING id INTO ra1;
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status) VALUES (a, tpl, '0.1', 2, 'h', 'done') RETURNING id INTO ra2;
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status) VALUES (b, tpl, '0.1', 3, 'h', 'done') RETURNING id INTO rb;
  INSERT INTO page (run_id, page_no) VALUES (ra1, 1) RETURNING id INTO pa;
  INSERT INTO page (run_id, page_no) VALUES (rb, 1) RETURNING id INTO pb;
  PERFORM change_issue_status(a, 'review');

  INSERT INTO fx VALUES ('a', a), ('b', b), ('x', x), ('g1', g1), ('g2', g2), ('u1', u1), ('u2', u2), ('u3', u3), ('u4', u4),
    ('postB', postB), ('postX', postX), ('mediaA', mediaA), ('mediaN', mediaN), ('mediaB', mediaB), ('mediaX', mediaX),
    ('tbA', tbA), ('tbB', tbB), ('tpl2', tpl2), ('ra1', ra1), ('ra2', ra2), ('rb', rb), ('pa', pa), ('pb', pb);
  ASSERT mediaA IS NOT NULL AND mediaN IS NOT NULL, '준비: 선별된 사진/선별되지 않은 사진이 있어야 함';
END $$;

\echo T100 사진: 사진의 그룹은 글의 그룹과 같아야 한다
DO $$ BEGIN
  BEGIN
    INSERT INTO media (post_id, group_id, storage_key, sha256, width, height)
    VALUES (pg_temp.fx('postX'), pg_temp.fx('g1'), 'bad', 'bad', 1, 1);
    RAISE EXCEPTION 'T100 failed: 다른 그룹 글에 붙은 사진이 저장됨';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  INSERT INTO media (post_id, group_id, storage_key, sha256, width, height)
  VALUES (pg_temp.fx('postB'), pg_temp.fx('g1'), 'ok1', 'ok1', 1, 1);
END $$;

\echo T101 텍스트: 호/원본 글/그룹이 서로 어긋나면 거부 (원본 글이 없는 텍스트는 허용)
DO $$ BEGIN
  BEGIN
    INSERT INTO text_block (issue_id, group_id, post_id, kind, body) VALUES (pg_temp.fx('b'), pg_temp.fx('g1'), pg_temp.fx('postX'), 'caption', 'x');
    RAISE EXCEPTION 'T101 failed: 다른 그룹 글을 원본으로 가진 텍스트가 저장됨';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO text_block (issue_id, group_id, kind, body) VALUES (pg_temp.fx('b'), pg_temp.fx('g2'), 'caption', 'x');
    RAISE EXCEPTION 'T101 failed: 호의 그룹과 다른 그룹의 텍스트가 저장됨';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  INSERT INTO text_block (issue_id, group_id, post_id, kind, body) VALUES (pg_temp.fx('b'), pg_temp.fx('g1'), pg_temp.fx('postB'), 'caption', 'x');
  INSERT INTO text_block (issue_id, group_id, kind, body) VALUES (pg_temp.fx('b'), pg_temp.fx('g1'), 'title', '제목');
END $$;

\echo T102 호별 선별: 호와 사진은 같은 그룹이어야 한다
DO $$ BEGIN
  BEGIN
    INSERT INTO issue_media (issue_id, media_id, group_id) VALUES (pg_temp.fx('a'), pg_temp.fx('mediaX'), pg_temp.fx('g1'));
    RAISE EXCEPTION 'T102 failed: 다른 그룹의 사진이 호에 들어감 (사진 쪽 검사)';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO issue_media (issue_id, media_id, group_id) VALUES (pg_temp.fx('a'), pg_temp.fx('mediaX'), pg_temp.fx('g2'));
    RAISE EXCEPTION 'T102 failed: 다른 그룹의 사진이 호에 들어감 (호 쪽 검사)';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END $$;

\echo T103 글 작성자: 그 그룹의 활동 중인 구성원만 (다른 그룹 구성원/나간 사람/외부인 거부)
DO $$
DECLARE uid uuid;
BEGIN
  FOREACH uid IN ARRAY ARRAY[pg_temp.fx('u3'), pg_temp.fx('u4'), gen_random_uuid()] LOOP
    BEGIN
      INSERT INTO post (group_id, author_id, body, posted_at) VALUES (pg_temp.fx('g1'), uid, 'x', '2026-10-05 12:00+09');
      RAISE EXCEPTION 'T103 failed: 구성원이 아닌 사용자 % 가 글을 올림', uid;
    EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
    END;
  END LOOP;
  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (pg_temp.fx('g1'), pg_temp.fx('u2'), 'ok', '2026-10-05 12:00+09');
END $$;

\echo T104 승인: 호/조판/페이지가 서로 어긋나면 거부, 일관된 승인과 호 전체 승인은 허용, 구성원이 아니면 거부
DO $$ BEGIN
  BEGIN
    INSERT INTO approval (issue_id, page_id, run_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('pa'), pg_temp.fx('ra2'), pg_temp.fx('u1'), 'approved');
    RAISE EXCEPTION 'T104 failed: 페이지의 조판과 다른 조판으로 승인됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO approval (issue_id, page_id, user_id, status) VALUES (pg_temp.fx('b'), pg_temp.fx('pa'), pg_temp.fx('u1'), 'approved');
    RAISE EXCEPTION 'T104 failed: 다른 호의 페이지가 승인됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO approval (issue_id, run_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('rb'), pg_temp.fx('u1'), 'approved');
    RAISE EXCEPTION 'T104 failed: 다른 호의 조판으로 호 전체가 승인됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO approval (issue_id, page_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('pa'), pg_temp.fx('u3'), 'approved');
    RAISE EXCEPTION 'T104 failed: 다른 그룹 사람이 승인함';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO approval (issue_id, page_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('pa'), pg_temp.fx('u4'), 'approved');
    RAISE EXCEPTION 'T104 failed: 나간 사람이 승인함';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO approval (issue_id, page_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('pa'), pg_temp.fx('u1'), 'approved');
  INSERT INTO approval (issue_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('u2'), 'approved');
  ASSERT (SELECT run_id FROM approval WHERE page_id = pg_temp.fx('pa') LIMIT 1) = pg_temp.fx('ra1'), 'T104 run_id 자동 기록';
END $$;

\echo T105 수정로그: 가리키는 조판은 그 호의 조판, 작성자는 그 그룹의 활동 중인 구성원
DO $$ BEGIN
  BEGIN
    INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
    VALUES (pg_temp.fx('a'), pg_temp.fx('rb'), 'page', pg_temp.fx('pa'), '{}', pg_temp.fx('u1'));
    RAISE EXCEPTION 'T105 failed: 다른 호의 조판에 대한 수정이 저장됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
    VALUES (pg_temp.fx('a'), pg_temp.fx('ra1'), 'page', pg_temp.fx('pa'), '{}', pg_temp.fx('u3'));
    RAISE EXCEPTION 'T105 failed: 다른 그룹 사람의 수정이 저장됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
  VALUES (pg_temp.fx('a'), pg_temp.fx('ra1'), 'page', pg_temp.fx('pa'), '{}', pg_temp.fx('u1'));
END $$;

\echo T106 인쇄작업: 인쇄할 조판은 그 호의 조판이어야 한다
DO $$ BEGIN
  BEGIN
    INSERT INTO print_job (issue_id, run_id, override_seq, status) VALUES (pg_temp.fx('a'), pg_temp.fx('rb'), 0, 'ready');
    RAISE EXCEPTION 'T106 failed: 다른 호의 조판으로 인쇄작업이 만들어짐';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  INSERT INTO print_job (issue_id, run_id, override_seq, status) VALUES (pg_temp.fx('a'), pg_temp.fx('ra1'), 0, 'ready');
END $$;

\echo T107 배치: 이 호에서 선별된 사진과 이 호의 텍스트만 올 수 있다 (선별 안 된 사진/다른 호/다른 그룹은 거부)
DO $$ BEGIN
  BEGIN
    INSERT INTO placement (page_id, ref_type, media_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'media', pg_temp.fx('mediaN'), 0, 0, 1, 1);
    RAISE EXCEPTION 'T107 failed: 선별되지 않은 사진이 배치됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO placement (page_id, ref_type, media_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'media', pg_temp.fx('mediaB'), 0, 0, 1, 1);
    RAISE EXCEPTION 'T107 failed: 다른 호의 사진이 배치됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO placement (page_id, ref_type, media_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'media', pg_temp.fx('mediaX'), 0, 0, 1, 1);
    RAISE EXCEPTION 'T107 failed: 다른 그룹의 사진이 배치됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO placement (page_id, ref_type, text_block_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'text_block', pg_temp.fx('tbB'), 0, 0, 1, 1);
    RAISE EXCEPTION 'T107 failed: 다른 호의 텍스트가 배치됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO placement (page_id, ref_type, media_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'media', pg_temp.fx('mediaA'), 0, 0, 1, 1);
  INSERT INTO placement (page_id, ref_type, text_block_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'text_block', pg_temp.fx('tbA'), 0, 0, 1, 1);
END $$;

\echo T108 미리보기: 존재하는 페이지의 미리보기만 둘 수 있다
DO $$ BEGIN
  BEGIN
    INSERT INTO preview (run_id, override_seq, page_no) VALUES (pg_temp.fx('ra1'), 0, 99);
    RAISE EXCEPTION 'T108 failed: 없는 페이지(99)의 미리보기가 저장됨';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  INSERT INTO preview (run_id, override_seq, page_no) VALUES (pg_temp.fx('ra1'), 0, 1);
END $$;

\echo T109 주문: 배송지는 그 호와 같은 그룹, 주문자는 그 그룹의 활동 중인 구성원. 배송지를 지워도 주문의 받는 사람/주소는 남는다
DO $$
DECLARE
  e1 constant uuid := '00000000-0000-0000-0000-0000000000e1';
  v_job uuid; v_addr2 uuid; v_order uuid;
BEGIN
  INSERT INTO print_job (issue_id, run_id, override_seq, status) VALUES (pg_temp.fx('a'), pg_temp.fx('ra1'), 0, 'ready') RETURNING id INTO v_job;
  INSERT INTO delivery_address (group_id, label, recipient_name, postal_code, address_line1, created_by)
  VALUES (pg_temp.fx('g2'), '다른 집 조부모', '박가상', '00009', '어딘가', pg_temp.fx('u3')) RETURNING id INTO v_addr2;

  BEGIN
    INSERT INTO print_order (print_job_id, delivery_address_id, ordered_by, recipient_name, postal_code, address_line1)
    VALUES (v_job, v_addr2, pg_temp.fx('u1'), '박가상', '00009', '어딘가');
    RAISE EXCEPTION 'T109 failed: 다른 그룹의 배송지로 주문됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO print_order (print_job_id, delivery_address_id, ordered_by, recipient_name, postal_code, address_line1)
    VALUES (v_job, e1, pg_temp.fx('u3'), '김가상', '00000', '주소');
    RAISE EXCEPTION 'T109 failed: 다른 그룹 사람이 주문함';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO print_order (print_job_id, delivery_address_id, ordered_by, recipient_name, postal_code, address_line1)
    VALUES (v_job, e1, pg_temp.fx('u4'), '김가상', '00000', '주소');
    RAISE EXCEPTION 'T109 failed: 나간 사람이 주문함';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  INSERT INTO print_order (print_job_id, delivery_address_id, ordered_by, recipient_name, recipient_phone, postal_code, address_line1)
  SELECT v_job, id, pg_temp.fx('u1'), recipient_name, recipient_phone, postal_code, address_line1 FROM delivery_address WHERE id = e1
  RETURNING id INTO v_order;
  DELETE FROM delivery_address WHERE id = e1;
  ASSERT (SELECT delivery_address_id IS NULL AND recipient_name = '김가상' AND address_line1 LIKE '서울%' FROM print_order WHERE id = v_order),
         'T109 배송지 삭제 후 주문 기록';
END $$;

\echo T110 [의도적으로 허용] 호의 선별에는 기간 밖의 사진도 넣을 수 있다 (기간은 선별 함수가 지키고 DB 제약으로는 두지 않는다)
DO $$ BEGIN
  INSERT INTO issue_media (issue_id, media_id, group_id) VALUES (pg_temp.fx('a'), pg_temp.fx('mediaB'), pg_temp.fx('g1'));
END $$;

\echo T111 [의도적으로 허용] 조판이 쓴 템플릿은 호의 템플릿과 달라도 된다 (그 시점에 쓴 템플릿을 기록)
DO $$ BEGIN
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (pg_temp.fx('a'), pg_temp.fx('tpl2'), '0.1', 9, 'h', 'done');
END $$;

\echo T112 [의도적으로 허용] 수정로그의 대상(target_id)은 나중에 사라질 수 있어 외래키로 묶지 않는다
DO $$ BEGIN
  INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
  VALUES (pg_temp.fx('a'), pg_temp.fx('ra1'), 'page', gen_random_uuid(), '{}', pg_temp.fx('u1'));
END $$;

\echo T113 [의도적으로 허용] 배치의 slot_id 는 템플릿 JSON 안의 이름이라 DB 가 검증하지 않는다 (조판 알고리즘 출력에서 검증)
DO $$ BEGIN
  INSERT INTO placement (page_id, ref_type, media_id, slot_id, x, y, w, h)
  VALUES (pg_temp.fx('pa'), 'media', pg_temp.fx('mediaA'), '없는-슬롯', 0, 0, 1, 1);
END $$;

\echo T114 복합 외래키의 SET NULL / CASCADE: 글을 지우면 사진은 함께 지워지고 텍스트는 남되 post_id 만 NULL (호/그룹은 유지)
DO $$
DECLARE v_post uuid; v_media uuid; v_tb uuid;
BEGIN
  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (pg_temp.fx('g1'), pg_temp.fx('u2'), 'del', '2026-10-06 12:00+09') RETURNING id INTO v_post;
  INSERT INTO media (post_id, group_id, storage_key, sha256, width, height) VALUES (v_post, pg_temp.fx('g1'), 'del-m', 'delm', 1, 1) RETURNING id INTO v_media;
  INSERT INTO text_block (issue_id, group_id, post_id, kind, body) VALUES (pg_temp.fx('b'), pg_temp.fx('g1'), v_post, 'caption', 'c') RETURNING id INTO v_tb;
  DELETE FROM post WHERE id = v_post;
  ASSERT (SELECT count(*) FROM media WHERE id = v_media) = 0, 'T114 사진은 글과 함께 지워짐';
  ASSERT (SELECT post_id IS NULL AND issue_id = pg_temp.fx('b') AND group_id = pg_temp.fx('g1') FROM text_block WHERE id = v_tb), 'T114 SET NULL 후 상태';
END $$;

\echo T115 조판에 배치된 사진을 가진 글은 지울 수 없다 (마감된 호의 사진 보호: 앱은 물리 삭제 대신 deleted_at 으로 숨겨야 한다)
DO $$
DECLARE v_post uuid;
BEGIN
  SELECT post_id INTO v_post FROM media WHERE id = pg_temp.fx('mediaA');
  BEGIN
    DELETE FROM post WHERE id = v_post;
    RAISE EXCEPTION 'T115 failed: 배치된 사진이 지워짐';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END $$;

\echo T116 복합 외래키의 CASCADE: 조판을 지우면 그 조판의 페이지/승인/수정/미리보기가 함께 지워진다
DO $$
DECLARE v_run uuid; v_pg uuid;
BEGIN
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (pg_temp.fx('a'), '00000000-0000-0000-0000-0000000000a1', '0.1', 77, 'h', 'done') RETURNING id INTO v_run;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 1) RETURNING id INTO v_pg;
  INSERT INTO approval (issue_id, page_id, user_id, status) VALUES (pg_temp.fx('a'), v_pg, pg_temp.fx('u1'), 'approved');
  INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id) VALUES (pg_temp.fx('a'), v_run, 'page', v_pg, '{}', pg_temp.fx('u1'));
  INSERT INTO preview (run_id, override_seq, page_no) VALUES (v_run, 0, 1);
  DELETE FROM layout_run WHERE id = v_run;
  ASSERT (SELECT count(*) FROM page WHERE run_id = v_run) = 0, 'T116 page';
  ASSERT (SELECT count(*) FROM approval WHERE run_id = v_run) = 0, 'T116 approval';
  ASSERT (SELECT count(*) FROM override WHERE run_id = v_run) = 0, 'T116 override';
  ASSERT (SELECT count(*) FROM preview WHERE run_id = v_run) = 0, 'T116 preview';
END $$;

ROLLBACK;
