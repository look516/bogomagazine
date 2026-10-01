# 자동 조판 알고리즘 입출력 계약

조판 알고리즘을 **DB와 분리된 순수 함수**로 둔다: `compose(input) -> output`.
같은 `input` + 같은 `algorithm_version` + 같은 `seed` 이면 항상 같은 `output`이어야 한다.

```
DB (selected media, template, pins)
        │  build_input()
        ▼
   input.json ──► compose() ──► output.json
                                   │  save_run()
                                   ▼
                       layout_run / page / placement
```

## 1. 입력 (input.json)

```json
{
  "schema_version": 1,
  "issue_id": "uuid",
  "seed": 12345,
  "algorithm_version": "0.1.0",

  "template": {
    "id": "uuid", "version": 1,
    "trim_mm": [210, 297],
    "margin_mm": 15, "bleed_mm": 3, "columns": 3,
    "page_multiple": 4, "min_pages": 8, "max_pages": 40,
    "photos_per_page": [1, 6],
    "masters": [
      {
        "id": "uuid", "name": "3-photo-grid",
        "slots": [
          {"slot_id": "a", "kind": "photo", "x": 15, "y": 15, "w": 180, "h": 120,
           "aspect_min": 1.2, "aspect_max": 2.0},
          {"slot_id": "t1", "kind": "text",  "x": 15, "y": 140, "w": 180, "h": 20}
        ]
      }
    ]
  },

  "media": [
    {
      "id": "uuid",
      "width": 4000, "height": 3000,
      "taken_at": "2026-09-03T10:20:00Z",
      "post_id": "uuid",
      "focal_point": {"x": 0.5, "y": 0.4},
      "saliency": [{"x": 0.3, "y": 0.2, "w": 0.4, "h": 0.5}],
      "score": 0.82,
      "pinned": false
    }
  ],

  "text_blocks": [
    {"id": "uuid", "kind": "caption", "post_id": "uuid", "body": "…", "char_count": 42}
  ],

  "pins": [
    {"media_id": "uuid", "page_no": 3, "slot_id": "a"}
  ]
}
```

규칙
- `media`는 **선별 단계(`select_media`)를 통과한(`issue_media.selection_status = 'selected'`) 사진만** 넣는다. 알고리즘은 선별을 다시 하지 않는다.
- 단위는 전부 **mm**, 좌표 원점은 페이지 왼쪽 위. 사진 `focal_point`/`saliency`는 원본 기준 **0~1 비율**.
- `pins`는 사용자가 지정한 위치 고정. 알고리즘은 반드시 존중하고, 못 지키면 `warnings`에 사유를 남긴다.
- `media` 배열은 `taken_at` 순으로 정렬해 넘긴다 (시간순 서사의 기본 순서). 정렬 기준이 바뀌면 결과가 바뀌므로 입력에 고정한다.

## 2. 출력 (output.json)

```json
{
  "schema_version": 1,
  "input_hash": "sha256 of canonical input",
  "algorithm_version": "0.1.0",
  "seed": 12345,
  "score": 0.78,

  "pages": [
    {
      "page_no": 1,
      "master_id": "uuid",
      "placements": [
        {
          "slot_id": "a",
          "ref_type": "media", "ref_id": "uuid",
          "x": 15, "y": 15, "w": 180, "h": 120, "z": 0,
          "crop": {"x": 0.0, "y": 0.1, "w": 1.0, "h": 0.8}
        },
        {
          "slot_id": "t1",
          "ref_type": "text_block", "ref_id": "uuid",
          "x": 15, "y": 140, "w": 180, "h": 20, "z": 0
        }
      ]
    }
  ],

  "unplaced": [
    {"ref_type": "media", "ref_id": "uuid", "reason": "no_slot_fit"}
  ],

  "warnings": [
    {"code": "low_res", "ref_id": "uuid", "page_no": 5,
     "detail": {"effective_dpi": 212, "required": 300}},
    {"code": "pin_violated", "ref_id": "uuid", "detail": "slot not available"}
  ],

  "stats": {"page_count": 24, "photos_placed": 58, "elapsed_ms": 830}
}
```

규칙
- `page_count`는 반드시 `page_multiple`의 배수. 모자란 페이지는 알고리즘이 **대형 사진 / 여백 / 인용 페이지**로 채운다.
- `crop`은 원본 기준 0~1 비율. 슬롯 비율에 맞추되 `saliency` 영역은 자르지 않는다.
- 사진을 못 넣었으면 조용히 버리지 말고 `unplaced`에 이유와 함께 남긴다.
- `warnings.code` 목록(초안): `low_res`, `pin_violated`, `text_overflow`, `crop_cuts_saliency`, `page_padded`.
  `low_res`는 이후 프리플라이트(`print_job.preflight_report`)의 입력이 된다.

## 3. DB 매핑 (save_run)

| output | 저장 위치 |
|---|---|
| `algorithm_version`, `seed`, `score` | `layout_run` 컬럼 |
| `input_hash` | `layout_run.input_snapshot_hash` |
| `warnings`, `unplaced`, `stats` | `layout_run.report` (jsonb) |
| `pages[]` | `page` (`page_no`, `master_id`) |
| `pages[].placements[]` | `placement` (`slot_id`, `ref_type`, `media_id`/`text_block_id`, `x,y,w,h,z`, `crop`) |

> `layout_run.report`는 프리플라이트(`print_job.preflight_report`)와 UI 경고의 입력으로 쓴다.

## 4. 재실행과 사람 수정 병합

1. `build_input()`이 `input_snapshot_hash`를 계산한다. 직전 `layout_run`과 같으면 **재조판하지 않는다**.
2. 입력이 바뀌었으면 새 `layout_run`을 만든다 (이전 run은 보존).
3. `override` 중 `pin`/`exclude`/`swap`처럼 **의도가 담긴 것**만 `input.pins`/선별 제외로 변환해 다시 넣는다.
   `move`/`resize` 같은 좌표 수정은 새 레이아웃과 충돌하므로 자동 이월하지 않고, 사용자에게 "이전 수정 N건이 적용되지 않았다"고 알린다.
4. 미리보기는 `(run_id, override_seq)`가 키이므로, 수정이 생기면 해당 페이지만 다시 렌더한다.

## 5. 첫 구현(v0.1) 범위 제안

복잡한 최적화 전에, 아래 단순 버전으로 파이프라인 전체를 먼저 끝까지 연결한다.

1. 사진을 `taken_at` 순으로 나열
2. 페이지당 `photos_per_page` 범위 안에서 **연속된 N장씩 묶기** (N은 seed 기반 난수로 2~4)
3. 사진 수와 가로/세로 비율 조합에 맞는 `master` 선택 (예: 가로 1 + 세로 2 → 해당 마스터)
4. 슬롯 비율에 맞게 `focal_point` 중심으로 `crop`
5. `page_multiple`에 맞춰 빈 페이지 채우기
6. 유효 dpi 계산해 `low_res` 경고

점수 최적화(여러 후보 안 생성 후 `score` 최고안 선택)는 v0.2에서 `seed`를 바꿔 여러 번 돌리는 방식으로 확장한다.
