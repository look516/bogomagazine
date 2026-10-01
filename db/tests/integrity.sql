-- 참조 정합성 테스트: "같은 사실이 두 곳에 있을 때 서로 어긋난 값이 들어갈 수 있는가"를 일부러 시도해 본다.
-- 막혀야 하는 것(복합 외래키 / 트리거)은 막히는지, 정상 데이터는 막히지 않는지(과잉 차단 방지),
-- 의도적으로 허용한 것은 허용되는지, 복합 키에서도 SET NULL / CASCADE 가 의도대로 동작하는지 확인한다.
-- 전체 실행: ./scripts/db.sh test. 하나의 트랜잭션 안에서 공통 준비물을 만들고 끝에 ROLLBACK 한다.
\echo == integrity
BEGIN;

CREATE TEMP TABLE fx (name text PRIMARY KEY, id uuid NOT NULL);
CREATE FUNCTION pg_temp.fx(p text) RETURNS uuid LANGUAGE sql STABLE AS $f$ SELECT id FROM fx WHERE name = p $f$;

-- 준비: 호 A(9월, 시드, 검토 단계)와 호 B(10월, 수집 중). 각자의 게시물/사진/텍스트/조판/페이지.
--   u1=그룹 소유자, u2=기여자, u3=그룹 밖 사용자, u4=그룹 구성원이자 호 B 의 viewer
DO $$
DECLARE
  a   constant uuid := '00000000-0000-0000-0000-0000000000c1';
  grp constant uuid := '00000000-0000-0000-0000-0000000000d1';
  tpl constant uuid := '00000000-0000-0000-0000-0000000000a1';
  u2  constant uuid := '00000000-0000-0000-0000-000000000002';
  u3 uuid := gen_random_uuid(); u4 uuid := gen_random_uuid();
  b uuid; ra1 uuid; ra2 uuid; rb uuid; pa uuid; pb uuid;
  postA uuid; postB uuid; mediaA uuid; mediaB uuid; tbA uuid; tbB uuid; acc uuid; tpl2 uuid;
BEGIN
  SELECT o_issue_id INTO b FROM open_monthly_issues('2026-10-02 12:00+09');
  INSERT INTO app_user (id, name) VALUES (u3, '그룹 밖 사용자'), (u4, '관람자');
  INSERT INTO family_member (group_id, user_id, role) VALUES (grp, u4, 'viewer');
  INSERT INTO issue_member (issue_id, user_id, role) VALUES (b, u4, 'viewer');

  INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at) VALUES (a, u2, 'instagram', 'fx-a', now()) RETURNING id INTO postA;
  INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at) VALUES (b, u2, 'instagram', 'fx-b', now()) RETURNING id INTO postB;
  INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok) VALUES (a, u2, 'fx-ma', 'fxma', 1, 1, true) RETURNING id INTO mediaA;
  INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok) VALUES (b, u2, 'fx-mb', 'fxmb', 1, 1, true) RETURNING id INTO mediaB;
  INSERT INTO text_block (issue_id, kind, body) VALUES (a, 'caption', 'A') RETURNING id INTO tbA;
  INSERT INTO text_block (issue_id, kind, body) VALUES (b, 'caption', 'B') RETURNING id INTO tbB;
  INSERT INTO social_account (user_id, platform, external_id) VALUES (u2, 'facebook', 'fx-fb') RETURNING id INTO acc;
  INSERT INTO template (name, version, spec) VALUES ('integrity-test', 1, '{}') RETURNING id INTO tpl2;

  PERFORM change_issue_status(a, 'closing');
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status) VALUES (a, tpl, '0.1', 1, 'h', 'done') RETURNING id INTO ra1;
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status) VALUES (a, tpl, '0.1', 2, 'h', 'done') RETURNING id INTO ra2;
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status) VALUES (b, tpl, '0.1', 3, 'h', 'done') RETURNING id INTO rb;
  INSERT INTO page (run_id, page_no) VALUES (ra1, 1) RETURNING id INTO pa;
  INSERT INTO page (run_id, page_no) VALUES (rb, 1) RETURNING id INTO pb;
  PERFORM change_issue_status(a, 'review');

  INSERT INTO fx VALUES ('a', a), ('b', b), ('u1', '00000000-0000-0000-0000-000000000001'), ('u2', u2), ('u3', u3), ('u4', u4),
    ('postA', postA), ('postB', postB), ('mediaA', mediaA), ('mediaB', mediaB), ('tbA', tbA), ('tbB', tbB),
    ('acc', acc), ('tpl2', tpl2), ('ra1', ra1), ('ra2', ra2), ('rb', rb), ('pa', pa), ('pb', pb);
END $$;

\echo T100 사진: 원본 게시물이 있으면 같은 호의 게시물이어야 한다 (게시물 없는 사진은 허용)
DO $$ BEGIN
  BEGIN
    INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok, source_post_id)
    VALUES (pg_temp.fx('b'), pg_temp.fx('u2'), 'bad', 'bad', 1, 1, true, pg_temp.fx('postA'));
    RAISE EXCEPTION 'T100 failed: 다른 호의 게시물을 가진 사진이 저장됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok, source_post_id)
  VALUES (pg_temp.fx('b'), pg_temp.fx('u2'), 'ok1', 'ok1', 1, 1, true, pg_temp.fx('postB'));
  INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok)
  VALUES (pg_temp.fx('b'), pg_temp.fx('u2'), 'ok2', 'ok2', 1, 1, true);
END $$;

\echo T101 텍스트: 원본 게시물이 있으면 같은 호의 게시물이어야 한다
DO $$ BEGIN
  BEGIN
    INSERT INTO text_block (issue_id, kind, body, source_post_id) VALUES (pg_temp.fx('b'), 'caption', 'x', pg_temp.fx('postA'));
    RAISE EXCEPTION 'T101 failed: 다른 호의 게시물을 가진 텍스트가 저장됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  INSERT INTO text_block (issue_id, kind, body, source_post_id) VALUES (pg_temp.fx('b'), 'caption', 'x', pg_temp.fx('postB'));
END $$;

\echo T102 승인: 호/조판/페이지가 서로 어긋나면 거부, 일관된 승인과 호 전체 승인은 허용
DO $$ BEGIN
  BEGIN
    INSERT INTO approval (issue_id, page_id, run_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('pa'), pg_temp.fx('ra2'), pg_temp.fx('u1'), 'approved');
    RAISE EXCEPTION 'T102 failed: 페이지의 조판과 다른 조판으로 승인됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO approval (issue_id, page_id, user_id, status) VALUES (pg_temp.fx('b'), pg_temp.fx('pa'), pg_temp.fx('u1'), 'approved');
    RAISE EXCEPTION 'T102 failed: 다른 호의 페이지가 승인됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO approval (issue_id, run_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('rb'), pg_temp.fx('u1'), 'approved');
    RAISE EXCEPTION 'T102 failed: 다른 호의 조판으로 호 전체가 승인됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  INSERT INTO approval (issue_id, page_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('pa'), pg_temp.fx('u1'), 'approved');
  INSERT INTO approval (issue_id, user_id, status) VALUES (pg_temp.fx('a'), pg_temp.fx('u1'), 'approved');
  ASSERT (SELECT run_id FROM approval WHERE page_id = pg_temp.fx('pa') LIMIT 1) = pg_temp.fx('ra1'), 'T102 run_id 자동 기록';
END $$;

\echo T103 수정로그: 수정이 가리키는 조판은 그 호의 조판이어야 한다
DO $$ BEGIN
  BEGIN
    INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
    VALUES (pg_temp.fx('a'), pg_temp.fx('rb'), 'page', pg_temp.fx('pa'), '{}', pg_temp.fx('u1'));
    RAISE EXCEPTION 'T103 failed: 다른 호의 조판에 대한 수정이 저장됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
  VALUES (pg_temp.fx('a'), pg_temp.fx('ra1'), 'page', pg_temp.fx('pa'), '{}', pg_temp.fx('u1'));
END $$;

\echo T104 인쇄작업: 인쇄할 조판은 그 호의 조판이어야 한다
DO $$ BEGIN
  BEGIN
    INSERT INTO print_job (issue_id, run_id, override_seq, status) VALUES (pg_temp.fx('a'), pg_temp.fx('rb'), 0, 'ready');
    RAISE EXCEPTION 'T104 failed: 다른 호의 조판으로 인쇄작업이 만들어짐';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  INSERT INTO print_job (issue_id, run_id, override_seq, status) VALUES (pg_temp.fx('a'), pg_temp.fx('ra1'), 0, 'ready');
END $$;

\echo T105 배치: 다른 호의 사진/텍스트는 배치할 수 없다 (같은 호는 허용)
DO $$ BEGIN
  BEGIN
    INSERT INTO placement (page_id, ref_type, media_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'media', pg_temp.fx('mediaB'), 0, 0, 1, 1);
    RAISE EXCEPTION 'T105 failed: 다른 호의 사진이 배치됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO placement (page_id, ref_type, text_block_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'text_block', pg_temp.fx('tbB'), 0, 0, 1, 1);
    RAISE EXCEPTION 'T105 failed: 다른 호의 텍스트가 배치됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO placement (page_id, ref_type, media_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'media', pg_temp.fx('mediaA'), 0, 0, 1, 1);
  INSERT INTO placement (page_id, ref_type, text_block_id, x, y, w, h) VALUES (pg_temp.fx('pa'), 'text_block', pg_temp.fx('tbA'), 0, 0, 1, 1);
END $$;

\echo T106 코멘트: 코멘트가 달린 페이지는 그 호의 페이지여야 한다 (페이지 없는 코멘트는 허용)
DO $$ BEGIN
  BEGIN
    INSERT INTO comment (issue_id, page_id, author_id, body) VALUES (pg_temp.fx('a'), pg_temp.fx('pb'), pg_temp.fx('u1'), 'x');
    RAISE EXCEPTION 'T106 failed: 다른 호의 페이지에 코멘트가 달림';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO comment (issue_id, page_id, author_id, body) VALUES (pg_temp.fx('a'), pg_temp.fx('pa'), pg_temp.fx('u1'), 'ok');
  INSERT INTO comment (issue_id, author_id, body) VALUES (pg_temp.fx('a'), pg_temp.fx('u1'), 'ok');
END $$;

\echo T107 게시물: 연결한 SNS 계정의 플랫폼과 주인이 게시물과 일치해야 한다 (계정 없는 게시물은 허용)
DO $$ BEGIN
  BEGIN
    INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at, account_id)
    VALUES (pg_temp.fx('b'), pg_temp.fx('u2'), 'instagram', 'x1', now(), pg_temp.fx('acc'));
    RAISE EXCEPTION 'T107 failed: 계정(facebook)과 다른 플랫폼(instagram)의 게시물이 저장됨';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at, account_id)
    VALUES (pg_temp.fx('b'), pg_temp.fx('u1'), 'facebook', 'x2', now(), pg_temp.fx('acc'));
    RAISE EXCEPTION 'T107 failed: 계정 주인이 아닌 사람이 그 계정의 게시물로 등록함';
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN NULL;
  END;
  INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at, account_id)
  VALUES (pg_temp.fx('b'), pg_temp.fx('u2'), 'facebook', 'x3', now(), pg_temp.fx('acc'));
  INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at)
  VALUES (pg_temp.fx('b'), pg_temp.fx('u2'), 'manual', 'x4', now());
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

\echo T109 호 참여자: 그 호의 가족 그룹 구성원만 될 수 있다
DO $$ BEGIN
  BEGIN
    INSERT INTO issue_member (issue_id, user_id, role) VALUES (pg_temp.fx('b'), pg_temp.fx('u3'), 'contributor');
    RAISE EXCEPTION 'T109 failed: 그룹 밖 사용자가 호 참여자가 됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT EXISTS (SELECT 1 FROM issue_member WHERE issue_id = pg_temp.fx('b') AND user_id = pg_temp.fx('u4')), 'T109 그룹 구성원(u4)은 참여자가 될 수 있어야 함';
END $$;

\echo T110 사진 업로드: 그 호의 참여자(viewer 제외)만 올릴 수 있다
DO $$ BEGIN
  BEGIN
    INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok) VALUES (pg_temp.fx('b'), pg_temp.fx('u3'), 'n1', 'n1', 1, 1, true);
    RAISE EXCEPTION 'T110 failed: 참여자가 아닌 사용자가 사진을 올림';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok) VALUES (pg_temp.fx('b'), pg_temp.fx('u4'), 'n2', 'n2', 1, 1, true);
    RAISE EXCEPTION 'T110 failed: viewer 가 사진을 올림';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;

\echo T111 게시물 등록: 그 호의 참여자(viewer 제외)만 등록할 수 있다
DO $$ BEGIN
  BEGIN
    INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at) VALUES (pg_temp.fx('b'), pg_temp.fx('u3'), 'manual', 'n3', now());
    RAISE EXCEPTION 'T111 failed: 참여자가 아닌 사용자가 게시물을 등록함';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at) VALUES (pg_temp.fx('b'), pg_temp.fx('u4'), 'manual', 'n4', now());
    RAISE EXCEPTION 'T111 failed: viewer 가 게시물을 등록함';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;

\echo T112 [의도적으로 허용] 조판이 쓴 템플릿은 호의 템플릿과 달라도 된다 (그 시점에 쓴 템플릿을 기록)
DO $$ BEGIN
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (pg_temp.fx('a'), pg_temp.fx('tpl2'), '0.1', 9, 'h', 'done');
END $$;

\echo T113 [의도적으로 허용] 수정로그의 대상(target_id)은 나중에 사라질 수 있어 외래키로 묶지 않는다
DO $$ BEGIN
  INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
  VALUES (pg_temp.fx('a'), pg_temp.fx('ra1'), 'page', gen_random_uuid(), '{}', pg_temp.fx('u1'));
END $$;

\echo T114 [의도적으로 허용] 배치의 slot_id 는 템플릿 JSON 안의 이름이라 DB 가 검증하지 않는다 (조판 알고리즘 출력에서 검증)
DO $$ BEGIN
  INSERT INTO placement (page_id, ref_type, media_id, slot_id, x, y, w, h)
  VALUES (pg_temp.fx('pa'), 'media', pg_temp.fx('mediaA'), '없는-슬롯', 0, 0, 1, 1);
END $$;

\echo T115 복합 외래키의 SET NULL: 게시물이 지워져도 사진은 남고 source_post_id 만 NULL, issue_id 는 유지
DO $$
DECLARE v_post uuid; v_media uuid;
BEGIN
  INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at)
  VALUES (pg_temp.fx('b'), pg_temp.fx('u2'), 'manual', 'del', now()) RETURNING id INTO v_post;
  INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok, source_post_id)
  VALUES (pg_temp.fx('b'), pg_temp.fx('u2'), 'del-m', 'delm', 1, 1, true, v_post) RETURNING id INTO v_media;
  DELETE FROM source_post WHERE id = v_post;
  ASSERT (SELECT source_post_id IS NULL AND issue_id = pg_temp.fx('b') FROM media WHERE id = v_media), 'T115 SET NULL 후 상태';
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
