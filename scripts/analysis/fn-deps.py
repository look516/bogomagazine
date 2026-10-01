"""함수/뷰 수준의 모듈 간 의존을 분석한다 (외래키로는 보이지 않는 의존).

사용 (DB 가 떠 있고 마이그레이션이 적용된 상태에서):
    ./scripts/db.sh up && ./scripts/db.sh migrate
    PYTHONUTF8=1 python3 scripts/analysis/fn-deps.py

방법: db/migrations/R__*.sql 에서 함수/뷰 본문을 뽑아, 본문에 나오는 테이블 이름과 다른 모듈 함수 호출을 찾는다.
      오브젝트의 모듈은 파일명(R__###_<모듈>_...)이고, 테이블의 모듈은 테이블 코멘트(module:...)다.
한계: 이름 매칭(정규식) 기반이라 동적 SQL 은 못 보고, 주석과 문자열 리터럴은 제외한다. 사람이 결과를 읽고 판단해야 한다.
      plpgsql 본문은 PostgreSQL 이 의존성을 추적하지 않으므로 이런 분석이 필요하다 (뷰는 추적함).
"""
import re, glob, os, subprocess, sys, collections

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
os.chdir(ROOT)

# 1) 테이블 -> 모듈 (DB 코멘트에서)
out = subprocess.run(
    ["docker", "compose", "exec", "-T", "db", "psql", "-U", "postgres", "-d", "pub", "-At", "-F", "|", "-c",
     "SELECT c.relname, substring(obj_description(c.oid,'pg_class') FROM '^module:([a-z]+)') FROM pg_class c "
     "WHERE c.relnamespace='public'::regnamespace AND c.relkind='r' AND c.relname<>'flyway_schema_history'"],
    capture_output=True, text=True, encoding="utf-8", env={**os.environ, "MSYS_NO_PATHCONV": "1"}).stdout
table_mod = dict(line.split("|") for line in out.strip().splitlines())

# 2) R 파일 -> 모듈 (파일명 R__NNN_<모듈>_...)
def file_module(path):
    return re.match(r"R__\d+_([a-z]+)_", os.path.basename(path)).group(1)

def strip_noise(sql):
    sql = re.sub(r"--[^\n]*", "", sql)            # 주석
    sql = re.sub(r"'(?:[^']|'')*'", "''", sql)    # 문자열 리터럴 ('page' 같은 값이 테이블로 오인되지 않게)
    return sql

objs = []   # (kind, name, module, body)
for path in sorted(glob.glob("db/migrations/R__*.sql")):
    mod = file_module(path)
    src = open(path, encoding="utf-8").read()
    for m in re.finditer(r"CREATE OR REPLACE FUNCTION (\w+)\s*\(.*?\$\$(.*?)\$\$", src, re.S):
        objs.append(("function", m.group(1), mod, m.group(2)))
    for m in re.finditer(r"CREATE VIEW (\w+) AS(.*?);\s*(?:\n\n|\Z|\n--)", src, re.S):
        objs.append(("view", m.group(1), mod, m.group(2)))
    for m in re.finditer(r"CREATE OR REPLACE VIEW (\w+) AS(.*?);\s*(?:\n\n|\Z|\n--)", src, re.S):
        objs.append(("view", m.group(1), mod, m.group(2)))

fn_names = {o[1]: o for o in objs if o[0] == "function"}
rows = []
edges = collections.defaultdict(set)   # (own_mod, other_mod) -> {오브젝트: R/W}
for kind, name, mod, body in objs:
    b = strip_noise(body)
    for t, tm in table_mod.items():
        if not re.search(rf"\b{t}\b", b):
            continue
        write = bool(re.search(rf"\b(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+{t}\b", b, re.I))
        if tm != mod:
            rows.append((mod, kind, name, tm, t, "쓰기" if write else "읽기"))
            edges[(mod, tm)].add(f"{name}→{t}({'W' if write else 'R'})")
    # 다른 모듈의 함수 호출
    for other, o in fn_names.items():
        if other != name and o[2] != mod and re.search(rf"\b{other}\s*\(", b):
            rows.append((mod, kind, name, o[2], other + "()", "호출"))
            edges[(mod, o[2])].add(f"{name}→{other}()")

# 허용된 모듈 간 의존은 db/tests/architecture.sql 의 allowed_dep 가 단일 기준이다 (여기에 따로 적지 않는다)
_arch = open(os.path.join(ROOT, "db", "tests", "architecture.sql"), encoding="utf-8").read()
_block = re.search(r"INSERT INTO allowed_dep VALUES(.*?);", _arch, re.S).group(1)
ALLOWED = set(re.findall(r"\('([a-z]+)',\s*'([a-z]+)'\)", _block))

print(f"분석한 오브젝트: 함수 {sum(1 for o in objs if o[0]=='function')}개, 뷰 {sum(1 for o in objs if o[0]=='view')}개\n")
print("=== 함수/뷰 수준 모듈 간 의존 (외래키 허용 방향 기준)")
print(f"{'오브젝트의 모듈':<10} {'→':<2} {'의존 대상':<10} {'FK 허용':<7} 상세")
for (a, b), items in sorted(edges.items()):
    ok = "허용" if (a, b) in ALLOWED else "★역방향/미허용"
    print(f"{a:<12} → {b:<10} {ok:<12} {', '.join(sorted(items))[:150]}")

# 3) 함수 수준 의존까지 합친 그래프의 순환
mods = sorted({m for e in edges for m in e})
adj = collections.defaultdict(set)
for (a, b) in edges: adj[a].add(b)
for (a, b) in ALLOWED: adj[a].add(b)
def reach(s):
    seen, st = set(), [s]
    while st:
        x = st.pop()
        for y in adj[x]:
            if y not in seen: seen.add(y); st.append(y)
    return seen
cyc = sorted(m for m in mods if m in reach(m))
print("\n=== 함수 수준까지 합친 의존 그래프에서 순환에 얽힌 모듈:", ", ".join(cyc) or "없음")
mutual = sorted({tuple(sorted((a, b))) for (a, b) in edges if (b, a) in edges or ((b, a) in ALLOWED and (a, b) not in ALLOWED)})
print("상호 의존(양방향) 쌍:", mutual or "없음")
