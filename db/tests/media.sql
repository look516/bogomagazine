-- media 모듈 테스트. 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == media

\echo T10 선별: max_photos 초과 시 상한으로 자르고 핀은 유지
BEGIN;
DO $$
DECLARE r record;
BEGIN
  UPDATE issue SET min_photos = 1, max_photos = 10 WHERE id = '00000000-0000-0000-0000-0000000000c1';
  SELECT * INTO r FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT r.selected = 10, format('T10 selected=%s (기대 10)', r.selected);
  ASSERT (SELECT count(*) FROM media WHERE pinned AND selection_status = 'selected') = 2, 'T10 핀 누락';
END $$;
ROLLBACK;

\echo T11 선별: min_photos 미달 시 채우되 중복/저화질/권리없음은 채우지 않고 short_by 보고
BEGIN;
DO $$
DECLARE r record;
BEGIN
  UPDATE issue SET min_photos = 95, max_photos = 100 WHERE id = '00000000-0000-0000-0000-0000000000c1';
  SELECT * INTO r FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT r.short_by > 0,                         'T11 short_by 가 0';
  ASSERT r.short_by = 95 - r.selected,           'T11 short_by 계산 불일치';
  ASSERT (SELECT count(*) FROM media WHERE selection_status = 'selected' AND NOT rights_ok) = 0, 'T11 권리없음 선택됨';
  ASSERT (SELECT count(*) FROM media WHERE selection_status = 'selected' AND NOT pinned AND quality_score < 0.3) = 0, 'T11 저화질 선택됨';
  ASSERT (SELECT count(*) FROM media a JOIN media b ON a.id < b.id
           WHERE a.selection_status = 'selected' AND b.selection_status = 'selected'
             AND hamming64(a.phash, b.phash) <= 8) = 0, 'T11 유사쌍 선택됨';
END $$;
ROLLBACK;

\echo T12 선별: 사진 0장인 호
BEGIN;
DO $$
DECLARE r record; v_id uuid;
BEGIN
  INSERT INTO issue (publication_id, title, period_start, period_end, close_at, template_id,
                     min_photos, max_photos, min_pages, max_pages, page_multiple)
  VALUES ('00000000-0000-0000-0000-0000000000b1','empty','2026-10-01','2026-10-31', now(),
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

\echo T14 선별: 전부 동일 사진이면 1장만 선택
BEGIN;
DO $$
DECLARE r record; v_id uuid;
BEGIN
  INSERT INTO issue (publication_id, title, period_start, period_end, close_at, template_id,
                     min_photos, max_photos, min_pages, max_pages, page_multiple)
  VALUES ('00000000-0000-0000-0000-0000000000b1','dups','2026-10-01','2026-10-31', now(),
          '00000000-0000-0000-0000-0000000000a1', 1, 10, 8, 40, 4) RETURNING id INTO v_id;
  INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, quality_score, phash, rights_ok)
  SELECT v_id, '00000000-0000-0000-0000-000000000002', 'd' || g, 'sha' || g, 4000, 3000, 0.9, 12345, true
    FROM generate_series(1, 5) g;
  SELECT * INTO r FROM select_media(v_id);
  ASSERT r.selected = 1 AND r.excluded_auto = 4, format('T14 selected=%s excluded=%s', r.selected, r.excluded_auto);
END $$;
ROLLBACK;

\echo T15 선별: excluded_manual 은 건드리지 않음
BEGIN;
DO $$
DECLARE r record;
BEGIN
  UPDATE media SET selection_status = 'excluded_manual' WHERE storage_key = 'media/1.jpg';
  SELECT * INTO r FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT (SELECT selection_status FROM media WHERE storage_key = 'media/1.jpg') = 'excluded_manual', 'T15 manual 이 바뀜';
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

\echo T51 업로드 가드(S2): collecting 에서만 사진/게시물 허용
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
BEGIN
  PERFORM * FROM close_due_issues('2026-10-01 00:00:01+09');
  BEGIN
    INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok)
    VALUES (v, '00000000-0000-0000-0000-000000000002', 'late.jpg', 'late', 4000, 3000, true);
    RAISE EXCEPTION 'T51 failed: closing 에서 사진이 업로드됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at)
    VALUES (v, '00000000-0000-0000-0000-000000000002', 'instagram', 'late', now());
    RAISE EXCEPTION 'T51 failed: closing 에서 게시물이 등록됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  PERFORM change_issue_status(v, 'collecting', NULL, NULL, now() + interval '1 day');
  INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok)
  VALUES (v, '00000000-0000-0000-0000-000000000002', 'late2.jpg', 'late2', 4000, 3000, true);
  ASSERT (SELECT count(*) FROM media WHERE storage_key = 'late2.jpg') = 1, 'T51 재오픈 후 업로드 실패';
END $$;
ROLLBACK;

\echo T52 업로드 라우팅: 기간 포함 호 우선, 없으면 가장 이른 수집 호, 없으면 NULL
BEGIN;
DO $$
DECLARE v_sep constant uuid := '00000000-0000-0000-0000-0000000000c1'; v_oct uuid;
        g constant uuid := '00000000-0000-0000-0000-0000000000d1';
BEGIN
  SELECT o_issue_id INTO v_oct FROM open_monthly_issues('2026-10-02 12:00+09');
  ASSERT upload_target_issue(g, '2026-09-30 23:00+09') = v_sep, 'T52 9월 사진';
  ASSERT upload_target_issue(g, '2026-10-01 00:30+09') = v_oct, 'T52 10월 사진';
  ASSERT upload_target_issue(g, '2026-08-30 12:00+09') = v_sep, 'T52 기간 밖 사진은 가장 이른 수집 호';
  PERFORM change_issue_status(v_sep, 'closing');
  ASSERT upload_target_issue(g, '2026-09-30 23:00+09') = v_oct, 'T52 전달이 닫히면 이번 달로';
  PERFORM change_issue_status(v_oct, 'closing');
  ASSERT upload_target_issue(g, now()) IS NULL, 'T52 수집 중인 호가 없으면 NULL';
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
