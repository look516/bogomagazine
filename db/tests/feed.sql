-- feed 모듈 테스트 (게시물/사진, 호별 선별, 게시 가드). 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == feed

\echo T10 선별: max_photos 초과 시 상한으로 자르고 "꼭 넣기"는 유지
BEGIN;
DO $$
DECLARE r record;
BEGIN
  UPDATE issue SET min_photos = 1, max_photos = 10 WHERE id = '00000000-0000-0000-0000-0000000000c1';
  SELECT * INTO r FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT r.selected = 10, format('T10 selected=%s (기대 10)', r.selected);
  ASSERT (SELECT count(*) FROM issue_media im JOIN media m ON m.id = im.media_id
           WHERE m.pinned AND im.selection_status = 'selected') = 2, 'T10 꼭 넣기 누락';
END $$;
ROLLBACK;

\echo T11 선별: min_photos 미달 시 채우되 중복/저화질/권리 문제는 채우지 않고 short_by 보고
BEGIN;
DO $$
DECLARE r record;
BEGIN
  UPDATE issue SET min_photos = 95, max_photos = 100 WHERE id = '00000000-0000-0000-0000-0000000000c1';
  SELECT * INTO r FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT r.short_by > 0,                         'T11 short_by 가 0';
  ASSERT r.short_by = 95 - r.selected,           'T11 short_by 계산 불일치';
  ASSERT (SELECT count(*) FROM issue_media im JOIN media m ON m.id = im.media_id
           WHERE im.selection_status = 'selected' AND NOT m.rights_ok) = 0, 'T11 권리 문제 사진이 선택됨';
  ASSERT (SELECT count(*) FROM issue_media im JOIN media m ON m.id = im.media_id
           WHERE im.selection_status = 'selected' AND NOT m.pinned AND m.quality_score < 0.3) = 0, 'T11 저화질이 선택됨';
  ASSERT (SELECT count(*) FROM issue_media a JOIN media ma ON ma.id = a.media_id
            JOIN issue_media b ON b.issue_id = a.issue_id AND b.media_id > a.media_id
            JOIN media mb ON mb.id = b.media_id
           WHERE a.selection_status = 'selected' AND b.selection_status = 'selected'
             AND hamming64(ma.phash, mb.phash) <= 8) = 0, 'T11 유사쌍이 선택됨';
END $$;
ROLLBACK;

\echo T12 선별: 글이 없는 달의 호
BEGIN;
DO $$
DECLARE r record; v_id uuid;
BEGIN
  INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id,
                     min_photos, max_photos, min_pages, max_pages, page_multiple)
  VALUES ('00000000-0000-0000-0000-0000000000d1','empty','2026-10-01','2026-10-31', now(),
          '00000000-0000-0000-0000-0000000000a1', 15, 60, 8, 40, 4) RETURNING id INTO v_id;
  SELECT * INTO r FROM select_media(v_id);
  ASSERT r.selected = 0 AND r.excluded_auto = 0 AND r.short_by = 15, 'T12 빈 호 결과 이상';
END $$;
ROLLBACK;

\echo T13 선별: 존재하지 않는 호는 예외
BEGIN;
DO $$ BEGIN
  BEGIN
    PERFORM * FROM select_media(gen_random_uuid());
    RAISE EXCEPTION 'T13 failed: 예외 없음';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%not found%', 'T13 메시지 이상: ' || SQLERRM;
  END;
END $$;
ROLLBACK;

\echo T14 선별: 전부 같은 사진이면 1장만 선택
BEGIN;
DO $$
DECLARE r record; v_id uuid; v_post uuid;
        g  constant uuid := '00000000-0000-0000-0000-0000000000d1';
BEGIN
  INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id,
                     min_photos, max_photos, min_pages, max_pages, page_multiple)
  VALUES (g,'dups','2026-10-01','2026-10-31', now(),
          '00000000-0000-0000-0000-0000000000a1', 1, 10, 8, 40, 4) RETURNING id INTO v_id;
  INSERT INTO post (group_id, author_id, body, posted_at)
  VALUES (g, '00000000-0000-0000-0000-000000000002', '같은 사진 5장', '2026-10-05 12:00+09') RETURNING id INTO v_post;
  INSERT INTO media (post_id, group_id, storage_key, sha256, width, height, quality_score, phash)
  SELECT v_post, g, 'd' || n, 'sha' || n, 4000, 3000, 0.9, 12345 FROM generate_series(1, 5) n;
  SELECT * INTO r FROM select_media(v_id);
  ASSERT r.selected = 1 AND r.excluded_auto = 4, format('T14 selected=%s excluded=%s', r.selected, r.excluded_auto);
END $$;
ROLLBACK;

\echo T15 선별: 사용자가 뺀 사진(excluded)은 excluded_manual 로 남고 다시 선별해도 바뀌지 않는다
BEGIN;
DO $$
DECLARE r record;
BEGIN
  UPDATE media SET excluded = true WHERE storage_key = 'media/1.jpg';
  SELECT * INTO r FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT (SELECT im.selection_status FROM issue_media im JOIN media m ON m.id = im.media_id
           WHERE m.storage_key = 'media/1.jpg') = 'excluded_manual', 'T15 뺀 사진이 excluded_manual 이 아님';
  SELECT * INTO r FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT (SELECT im.selection_status FROM issue_media im JOIN media m ON m.id = im.media_id
           WHERE m.storage_key = 'media/1.jpg') = 'excluded_manual', 'T15 재선별 후 바뀜';
END $$;
ROLLBACK;

\echo T16 선별: 같은 트랜잭션에서 두 번 호출해도 같은 결과
BEGIN;
DO $$
DECLARE a record; b record;
BEGIN
  SELECT * INTO a FROM select_media('00000000-0000-0000-0000-0000000000c1');
  SELECT * INTO b FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT a = b, 'T16 재호출 결과 상이';
END $$;
ROLLBACK;

\echo T17 선별: 삭제한 글의 사진은 후보에 남되 선택되지 않는다 (excluded_manual)
BEGIN;
DO $$
DECLARE v_post uuid; r record;
BEGIN
  SELECT post_id INTO v_post FROM media WHERE storage_key = 'media/2.jpg';
  UPDATE post SET deleted_at = now() WHERE id = v_post;
  SELECT * INTO r FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT (SELECT count(*) FROM issue_media im JOIN media m ON m.id = im.media_id
           WHERE m.post_id = v_post AND im.selection_status = 'excluded_manual') >= 1, 'T17 삭제한 글의 사진 상태';
  ASSERT (SELECT count(*) FROM issue_media im JOIN media m ON m.id = im.media_id
           WHERE m.post_id = v_post AND im.selection_status = 'selected') = 0, 'T17 삭제한 글의 사진이 선택됨';
END $$;
ROLLBACK;

\echo T18 그룹 격리: 다른 가족 그룹의 사진은 이 호의 후보가 되지 않는다
BEGIN;
DO $$
DECLARE g2 uuid; u3 uuid := gen_random_uuid(); p2 uuid; m2 uuid; r record;
BEGIN
  INSERT INTO app_user (id, name) VALUES (u3, '다른 가족');
  g2 := create_family_group('다른 가족', u3);
  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g2, u3, '다른 그룹의 글', '2026-09-10 12:00+09') RETURNING id INTO p2;
  INSERT INTO media (post_id, group_id, storage_key, sha256, width, height, quality_score, phash)
  VALUES (p2, g2, 'other-group', 'other', 4000, 3000, 0.99, 42) RETURNING id INTO m2;
  SELECT * INTO r FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT NOT EXISTS (SELECT 1 FROM issue_media WHERE media_id = m2), 'T18 다른 그룹의 사진이 이 호의 후보가 됨';
  ASSERT (SELECT count(*) FROM issue_media WHERE issue_id = '00000000-0000-0000-0000-0000000000c1') = 100, 'T18 후보 수';
END $$;
ROLLBACK;

\echo T19 글의 날짜가 어느 호에 실릴지 정한다 (그룹 타임존 경계: 한국 시간 9/30 23:30 은 9월호, 10/1 00:30 은 10월호)
BEGIN;
DO $$
DECLARE g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        v_sep constant uuid := '00000000-0000-0000-0000-0000000000c1'; v_oct uuid;
        p_sep uuid; p_oct uuid; m_sep uuid; m_oct uuid;
BEGIN
  SELECT o_issue_id INTO v_oct FROM open_monthly_issues('2026-10-02 12:00+09');
  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g, '00000000-0000-0000-0000-000000000002', 'sep', '2026-09-30 23:30+09') RETURNING id INTO p_sep;
  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g, '00000000-0000-0000-0000-000000000002', 'oct', '2026-10-01 00:30+09') RETURNING id INTO p_oct;
  INSERT INTO media (post_id, group_id, storage_key, sha256, width, height, quality_score, phash) VALUES (p_sep, g, 'edge-sep', 'edgesep', 1, 1, 0.9, 7) RETURNING id INTO m_sep;
  INSERT INTO media (post_id, group_id, storage_key, sha256, width, height, quality_score, phash) VALUES (p_oct, g, 'edge-oct', 'edgeoct', 1, 1, 0.9, 99) RETURNING id INTO m_oct;
  PERFORM * FROM select_media(v_sep);
  PERFORM * FROM select_media(v_oct);
  ASSERT EXISTS (SELECT 1 FROM issue_media WHERE issue_id = v_sep AND media_id = m_sep), 'T19 9/30 23:30 이 9월호에 없음';
  ASSERT NOT EXISTS (SELECT 1 FROM issue_media WHERE issue_id = v_oct AND media_id = m_sep), 'T19 9/30 23:30 이 10월호에 들어감';
  ASSERT EXISTS (SELECT 1 FROM issue_media WHERE issue_id = v_oct AND media_id = m_oct), 'T19 10/1 00:30 이 10월호에 없음';
  ASSERT NOT EXISTS (SELECT 1 FROM issue_media WHERE issue_id = v_sep AND media_id = m_oct), 'T19 10/1 00:30 이 9월호에 들어감';
END $$;
ROLLBACK;

\echo T51 게시 가드: 마감된 호의 기간에는 글/사진을 올릴 수 없고, 다음 기간의 글은 올릴 수 있다
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
        g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        u2 constant uuid := '00000000-0000-0000-0000-000000000002';
        v_post uuid;
BEGIN
  SELECT id INTO v_post FROM post LIMIT 1;
  PERFORM * FROM close_due_issues('2026-10-01 00:00:01+09');
  ASSERT (SELECT status FROM issue WHERE id = v) = 'closing', 'T51 precondition';
  BEGIN
    INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g, u2, '늦은 글', '2026-09-20 12:00+09');
    RAISE EXCEPTION 'T51 failed: 마감된 9월에 글이 올라감';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO media (post_id, group_id, storage_key, sha256, width, height) VALUES (v_post, g, 'late.jpg', 'late', 4000, 3000);
    RAISE EXCEPTION 'T51 failed: 마감된 9월의 글에 사진이 붙음';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE post SET posted_at = '2026-09-25 12:00+09' WHERE id = (SELECT id FROM post WHERE posted_at > '2026-10-01' LIMIT 1);
  EXCEPTION WHEN OTHERS THEN NULL;   -- 10월 글이 아직 없으면 대상 행이 없어 아무 일도 안 일어난다
  END;
  -- 다음 기간(10월)의 글은 올릴 수 있다
  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g, u2, '10월 글', '2026-10-05 12:00+09');

  -- 재오픈하면 다시 9월에 올릴 수 있다
  PERFORM change_issue_status(v, 'collecting', NULL, NULL, now() + interval '1 day');
  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g, u2, '재오픈 후 글', '2026-09-20 12:00+09');
END $$;
ROLLBACK;

\echo T52 게시 가드: 글의 날짜를 마감된 기간으로 옮길 수 없다
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
        g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        p uuid;
BEGIN
  SELECT o_issue_id INTO p FROM open_monthly_issues('2026-10-02 12:00+09');   -- 10월호(수집 중) 생성
  INSERT INTO post (group_id, author_id, body, posted_at)
  VALUES (g, '00000000-0000-0000-0000-000000000002', '10월 글', '2026-10-05 12:00+09') RETURNING id INTO p;
  PERFORM change_issue_status(v, 'closing');
  BEGIN
    UPDATE post SET posted_at = '2026-09-25 12:00+09' WHERE id = p;
    RAISE EXCEPTION 'T52 failed: 글이 마감된 9월로 옮겨짐';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T53 게시 가드: 작성자는 그 그룹에서 활동 중인 구성원이어야 한다 (그룹 밖 사람, 나간 구성원은 거부)
BEGIN;
DO $$
DECLARE g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        u2 constant uuid := '00000000-0000-0000-0000-000000000002';
        u3 uuid := gen_random_uuid();
BEGIN
  INSERT INTO app_user (id, name) VALUES (u3, '외부인');
  BEGIN
    INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g, u3, 'x', '2026-10-05 12:00+09');
    RAISE EXCEPTION 'T53 failed: 그룹 밖 사람의 글이 저장됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE family_member SET left_at = now() WHERE group_id = g AND user_id = u2;
  BEGIN
    INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g, u2, 'x', '2026-10-05 12:00+09');
    RAISE EXCEPTION 'T53 failed: 나간 구성원의 글이 저장됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T60 hamming64: bit_count 구현이 문자열 방식과 항상 같음
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM (
            SELECT ((random() * 8e18) - 4e18)::bigint AS a, ((random() * 8e18) - 4e18)::bigint AS b
              FROM generate_series(1, 3000)) x
           WHERE hamming64(a, b) <> length(replace(((a # b)::bit(64))::text, '0', ''))) = 0, 'T60 구현 불일치';
  ASSERT hamming64(0, 0) = 0 AND hamming64(0, -1) = 64 AND hamming64(5, 3) = 2, 'T60 기준값';
END $$;
