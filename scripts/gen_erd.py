#!/usr/bin/env python3
"""DB 카탈로그 JSON(scripts/erd-query.sql 의 출력)을 읽어 docs/erd.md 용 Mermaid 문서를 만든다.

입력: stdin (JSON)   출력: stdout (Markdown)
- 같은 스키마면 항상 같은 출력이다 (시각 등 변하는 값을 넣지 않는다). 그래서 CI 가 diff 로 어긋남을 잡을 수 있다.
- 모듈은 각 테이블 코멘트 'module:<모듈> | 설명' 에서 읽는다.
"""
import json
import re
import sys
from collections import Counter, defaultdict

MODULE_ORDER = ["identity", "templates", "groups", "issues", "feed", "layout", "review", "printing"]
ON_DELETE = {"c": "cascade", "n": "set null", "d": "set default"}  # a/r(기본) 은 표시하지 않음

TYPE_MAP = {
    "timestamp with time zone": "timestamptz",
    "timestamp without time zone": "timestamp",
    "character varying": "varchar",
    "double precision": "float8",
    "integer": "int",
    "boolean": "bool",
    "character": "char",
}


def mtype(t: str) -> str:
    """Mermaid 속성 타입 규칙(영숫자/_/[]만, 쉼표·공백 불가)에 맞게 바꾼다."""
    t = t.lower()
    arr = t.endswith("[]")
    base = t[:-2] if arr else t
    base = re.sub(r"\(.*\)", "", base).strip()
    base = TYPE_MAP.get(base, base)
    base = re.sub(r"[^a-z0-9_]", "_", base)
    return base + ("[]" if arr else "")


def q(name: str) -> str:
    """엔티티 이름은 항상 따옴표로 감싼다. 'style' 처럼 Mermaid 예약어와 겹치는 테이블 이름도 안전하다."""
    return f'"{name}"'


def parse_comment(comment):
    m = re.match(r"module:([a-z]+)\s*\|\s*(.*)$", comment or "")
    return (m.group(1), m.group(2)) if m else (None, comment or "")


def main():
    data = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    tables = {t["name"]: t for t in data["tables"]}
    fks = data["fks"] or []

    module_of, desc_of = {}, {}
    for name, t in tables.items():
        mod, desc = parse_comment(t["comment"])
        if mod is None:
            sys.exit(f"테이블 '{name}' 에 'module:<모듈> | 설명' 코멘트가 없습니다")
        module_of[name], desc_of[name] = mod, desc

    modules = [m for m in MODULE_ORDER if m in set(module_of.values())]
    extra = sorted(set(module_of.values()) - set(MODULE_ORDER))
    modules += extra

    by_module = defaultdict(list)
    for name in sorted(tables):
        by_module[module_of[name]].append(name)

    fk_cols = defaultdict(set)  # 테이블 -> FK 컬럼 집합
    for f in fks:
        fk_cols[f["child"]].update(f["cols"])

    def keys_of(table, col):
        t = tables[table]
        keys = []
        if col in (t["pk"] or []):
            keys.append("PK")
        if col in fk_cols[table]:
            keys.append("FK")
        if any(u == [col] for u in t["uniques"]):
            keys.append("UK")
        return ", ".join(keys)

    def entity(table, only=None):
        lines = [f"    {q(table)} {{"]
        for c in tables[table]["cols"]:
            if only is not None and c["name"] not in only:
                continue
            k = keys_of(table, c["name"])
            lines.append(f"        {mtype(c['type'])} {c['name']}" + (f" {k}" if k else ""))
        lines.append("    }")
        return "\n".join(lines)

    def edge(f):
        child_pk = tables[f["child"]]["pk"] or []
        one_to_one = sorted(f["cols"]) == sorted(child_pk)
        left = "||" if f["required"] else "|o"
        right = "o|" if one_to_one else "o{"
        label = ", ".join(f["cols"])
        extra = ON_DELETE.get(f["on_delete"])
        if extra:
            label += f" ({extra})"
        return f'    {q(f["parent"])} {left}--{right} {q(f["child"])} : "{label}"'

    out = []
    w = out.append
    w("# ERD (자동 생성)")
    w("")
    w("> **이 파일은 DB 스키마에서 자동 생성됩니다. 직접 수정하지 마세요.**")
    w("> 갱신: `./scripts/db.sh erd` · CI(`./scripts/db.sh test`)가 스키마와 일치하는지 검사하고, 어긋나면 실패합니다.")
    w("> 모듈 경계와 규칙은 [architecture.md](architecture.md) 참고. 소유 모듈은 각 테이블의 코멘트(`module:<모듈>`)가 기준입니다.")
    w("")
    w("범례: `PK` 기본키 · `FK` 외래키 · `UK` 유일 · 관계선 `||--o{` 은 \"부모 1 : 자식 0..N\", `|o` 는 부모가 선택(NULL 가능), `o|` 는 자식이 최대 1(1:1). 라벨은 외래키 컬럼이며 괄호는 부모 삭제 시 동작입니다.")
    w("")

    # ---- 0. 모듈 의존 ----
    cross = Counter()
    for f in fks:
        a, b = module_of[f["child"]], module_of[f["parent"]]
        if a != b:
            cross[(a, b)] += 1
    w("## 0. 모듈 구성과 의존 방향")
    w("")
    w("화살표는 \"참조한다(의존한다)\"는 뜻이고 숫자는 모듈 간 외래키 개수입니다.")
    w("")
    w("```mermaid")
    w("flowchart LR")
    for m in modules:
        w(f'    {m}["{m}<br/>{len(by_module[m])} tables"]')
    for (a, b), n in sorted(cross.items(), key=lambda kv: (modules.index(kv[0][0]), modules.index(kv[0][1]))):
        w(f'    {a} -->|"{n} FK"| {b}')
    w("```")
    w("")

    # ---- 1. 전체 관계 (컬럼 생략) ----
    w("## 1. 전체 관계 (컬럼 생략)")
    w("")
    w("```mermaid")
    w("erDiagram")
    seen = set()
    for f in fks:
        w(edge(f))
        seen.update([f["child"], f["parent"]])
    for name in sorted(tables):
        if name not in seen:
            w(f"    {q(name)}")
    w("```")
    w("")

    # ---- 2. 모듈별 상세 ----
    w("## 2. 모듈별 상세")
    w("")
    w("해당 모듈의 테이블은 컬럼까지 보여 주고, 다른 모듈의 테이블은 연결에 필요한 컬럼만 보여 줍니다.")
    for m in modules:
        own = set(by_module[m])
        deps = sorted({b for (a, b) in cross if a == m}, key=modules.index)
        used_by = sorted({a for (a, b) in cross if b == m}, key=modules.index)
        w("")
        w(f"### {m}")
        w("")
        w(f"- 참조하는 모듈: {', '.join(deps) if deps else '없음 (바닥 모듈)'}")
        w(f"- 이 모듈을 참조하는 모듈: {', '.join(used_by) if used_by else '없음'}")
        w("")
        edges = [f for f in fks if f["child"] in own or f["parent"] in own]
        stubs = defaultdict(set)  # 외부 테이블 -> 보여 줄 컬럼
        for f in edges:
            for side, cols in (("child", f["cols"]), ("parent", tables[f["parent"]]["pk"] or [])):
                t = f[side]
                if t not in own:
                    stubs[t].update(cols if side == "child" else (tables[t]["pk"] or []))
            if f["child"] not in own:
                stubs[f["child"]].update(tables[f["child"]]["pk"] or [])
        w("```mermaid")
        w("erDiagram")
        for f in edges:
            w(edge(f))
        for t in sorted(own):
            w(entity(t))
        for t in sorted(stubs):
            w(entity(t, only=stubs[t]))
        w("```")

    # ---- 3. 테이블 목록 ----
    w("")
    w("## 3. 테이블 목록")
    w("")
    w("| 모듈 | 테이블 | 컬럼 수 | 설명 |")
    w("|---|---|---|---|")
    for m in modules:
        for t in by_module[m]:
            w(f"| {m} | `{t}` | {len(tables[t]['cols'])} | {desc_of[t]} |")
    w("")
    sys.stdout.buffer.write("\n".join(out).encode("utf-8"))


if __name__ == "__main__":
    main()
