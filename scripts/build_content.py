"""抓取每个国家与省级区的内容，生成 Shanhai/Resources/Content/<国家a3>.json。

来源：
  Wikidata  基本资料（首府、人口、面积、语言、货币）、名人（出生地或工作地落在该区）、历史事件（有坐标和日期）
  中文维基  简介首段、「历史」「文化」等章节开头（zh-cn 变体）

全部请求缓存在 data/work/，重跑只补缺的。名人和事件按坐标落进 ids.bin，与 App 点选用同一套边界。
"""
import json, re, struct, sys, time, zlib, threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import requests
from opencc import OpenCC

T2S = OpenCC("t2s").convert   # Wikidata 的 zh 标签繁简混杂，统一成简体

ROOT = Path(__file__).resolve().parent.parent
GEO = ROOT / "Shanhai/Resources/Geo"
OUT = ROOT / "Shanhai/Resources/Content"
WORK = ROOT / "data/work"
OUT.mkdir(parents=True, exist_ok=True)
WORK.mkdir(parents=True, exist_ok=True)
UA = {"User-Agent": "Shanhai/0.1 (personal offline globe; https://github.com/chengffei)"}
S = requests.Session(); S.headers.update(UA)
lock = threading.Lock()


def get(url, params, tries=4):
    for i in range(tries):
        try:
            r = S.get(url, params=params, timeout=60)
            if r.status_code == 429:
                time.sleep(5 * (i + 1)); continue
            r.raise_for_status()
            return r.json()
        except Exception as e:
            if i == tries - 1:
                print("fail", url, params.get("titles") or params.get("ids") or "", e, file=sys.stderr)
                return None
            time.sleep(2 * (i + 1))


def cached(name, fn):
    p = WORK / name
    if p.exists():
        return json.loads(p.read_text())
    v = fn()
    p.write_text(json.dumps(v, ensure_ascii=False))
    return v


# ---------- Wikidata 实体 ----------
def entities(qids):
    store = WORK / "entities.json"
    have = json.loads(store.read_text()) if store.exists() else {}
    need = [q for q in dict.fromkeys(qids) if q and q not in have]
    for i in range(0, len(need), 50):
        d = get("https://www.wikidata.org/w/api.php", {"action": "wbgetentities", "ids": "|".join(need[i:i + 50]),
                "props": "labels|descriptions|claims|sitelinks", "languages": "zh-cn|zh-hans|zh|en", "sitefilter": "zhwiki|enwiki", "format": "json"})
        for q, e in (d or {}).get("entities", {}).items():
            have[q] = slim(e)
        if i % 1000 == 0:
            store.write_text(json.dumps(have, ensure_ascii=False))
            print(f"entities {i}/{len(need)}", file=sys.stderr)
    store.write_text(json.dumps(have, ensure_ascii=False))
    return have


def label(e, lang=("zh-cn", "zh-hans", "zh", "en")):
    for l in lang:
        v = e.get("labels", {}).get(l)
        if v:
            return v
    return ""


def slim(e):
    def lv(k):
        return {l: v["value"] for l, v in e.get(k, {}).items()}
    claims = {}
    for p in ("P36", "P1082", "P2046", "P37", "P38", "P571", "P1376"):
        vals = []
        for c in e.get("claims", {}).get(p, []):
            dv = c.get("mainsnak", {}).get("datavalue", {}).get("value")
            if dv is None:
                continue
            rank = c.get("rank")
            if isinstance(dv, dict) and "id" in dv:
                vals.append((rank, dv["id"]))
            elif isinstance(dv, dict) and "amount" in dv:
                t = (c.get("qualifiers", {}).get("P585") or [{}])[0].get("datavalue", {}).get("value", {}).get("time", "")
                vals.append((rank, [float(dv["amount"]), t[1:5]]))
            elif isinstance(dv, dict) and "time" in dv:
                vals.append((rank, dv["time"][1:5]))
        if vals:
            pref = [v for r, v in vals if r == "preferred"] or [v for r, v in vals]
            claims[p] = pref
    return {"labels": lv("labels"), "desc": lv("descriptions"), "claims": claims,
            "zhwiki": e.get("sitelinks", {}).get("zhwiki", {}).get("title"),
            "enwiki": e.get("sitelinks", {}).get("enwiki", {}).get("title")}


# ---------- 中文维基 ----------
SECTION_KEYS = {"history": ("历史", "歷史", "沿革", "建制沿革"), "culture": ("文化", "风俗", "民俗", "饮食", "社会", "宗教", "旅游", "观光")}


def wiki_text(title):
    safe = re.sub(r"[^\w]", "_", title)[:80]
    p = WORK / "wiki" / f"{safe}.json"
    p.parent.mkdir(exist_ok=True)
    if p.exists():
        return json.loads(p.read_text())
    d = get("https://zh.wikipedia.org/w/api.php", {"action": "query", "prop": "extracts", "titles": title, "explaintext": 1,
            "exsectionformat": "wiki", "redirects": 1, "variant": "zh-cn", "format": "json", "formatversion": 2})
    text = ""
    if d:
        pages = d.get("query", {}).get("pages", [])
        if pages and "extract" in pages[0]:
            text = pages[0]["extract"]
    v = {"title": title, "text": text}
    p.write_text(json.dumps(v, ensure_ascii=False))
    return v


def first_paragraphs(text, limit):
    out, n = [], 0
    for para in [x.strip() for x in text.split("\n") if x.strip()]:
        if para.startswith("=="):
            if out:
                break
            continue
        out.append(para); n += len(para)
        if n >= limit:
            break
    s = "\n".join(out)
    return trim(s, limit)


def trim(s, limit):
    if len(s) <= limit:
        return s
    cut = s[:limit]
    k = max(cut.rfind("。"), cut.rfind("！"), cut.rfind("；"))
    return cut[:k + 1] if k > limit * 0.4 else cut + "……"


def sections(text):
    """拆成 [(标题, 正文)]，只看二级标题"""
    parts, cur, buf = [], None, []
    for line in text.split("\n"):
        m = re.match(r"^==\s*([^=].*?)\s*==$", line.strip())
        if m:
            if cur is not None:
                parts.append((cur, "\n".join(buf)))
            cur, buf = m.group(1), []
        elif cur is not None:
            buf.append(line)
    if cur is not None:
        parts.append((cur, "\n".join(buf)))
    return parts


def section_snippet(text, keys, limit):
    for title, body in sections(text):
        if any(k in title for k in keys):
            # 去掉三级标题行，取前几段
            body = "\n".join(l for l in body.split("\n") if not l.strip().startswith("==="))
            s = first_paragraphs(body, limit)
            if len(s) > 30:
                return {"title": title, "text": s}
    return None


# ---------- 名人与事件（按坐标归区） ----------
# 官方 WDQS 对「全库按语言版本数筛人」这类查询必超时（60 秒上限），改用 QLever 的 Wikidata 镜像
SPARQL = "https://qlever.dev/api/wikidata"
PREFIXES = """PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wikibase: <http://wikiba.se/ontology#>
PREFIX schema: <http://schema.org/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
"""


def sparql(q):
    for i in range(4):
        try:
            r = S.post(SPARQL, data={"query": PREFIXES + q}, headers={"Accept": "application/sparql-results+json"}, timeout=600)
            if r.status_code == 429:
                time.sleep(30); continue
            r.raise_for_status()
            return r.json()["results"]["bindings"]
        except Exception as e:
            print("sparql retry", i, e, file=sys.stderr)
            time.sleep(10 * (i + 1))
    return []


def people_query(prop, lo, hi):
    return f"""SELECT ?p ?sl ?coord ?born ?died ?pLabel ?pDesc WHERE {{
  ?p wdt:P31 wd:Q5; wikibase:sitelinks ?sl. FILTER(?sl >= {lo} && ?sl < {hi})
  ?p wdt:{prop} ?place. ?place wdt:P625 ?coord.
  OPTIONAL {{ ?p wdt:P569 ?born. }} OPTIONAL {{ ?p wdt:P570 ?died. }}
  OPTIONAL {{ ?p rdfs:label ?pLabel. FILTER(LANG(?pLabel) = "zh") }}
  OPTIONAL {{ ?p schema:description ?pDesc. FILTER(LANG(?pDesc) = "zh") }}
}}"""


def event_query(lo, hi):
    return f"""SELECT ?e ?sl ?coord ?t ?start ?eLabel ?eDesc WHERE {{
  ?e wikibase:sitelinks ?sl. FILTER(?sl >= {lo} && ?sl < {hi})
  ?e wdt:P31/wdt:P279* wd:Q1190554.
  ?e wdt:P625 ?coord.
  OPTIONAL {{ ?e wdt:P585 ?t. }} OPTIONAL {{ ?e wdt:P580 ?start. }}
  OPTIONAL {{ ?e rdfs:label ?eLabel. FILTER(LANG(?eLabel) = "zh") }}
  OPTIONAL {{ ?e schema:description ?eDesc. FILTER(LANG(?eDesc) = "zh") }}
}}"""


BANDS = [(20, 100000)]


def fetch_people():
    def run():
        rows = {}
        for prop in ("P19", "P937"):
            for lo, hi in BANDS:
                for b in sparql(people_query(prop, lo, hi)):
                    q = b["p"]["value"].rsplit("/", 1)[1]
                    m = re.match(r"Point\(([-\d.eE]+) ([-\d.eE]+)\)", b["coord"]["value"], re.I)
                    if not m:
                        continue
                    r = rows.setdefault(q, {"q": q, "sl": int(b["sl"]["value"]), "name": b.get("pLabel", {}).get("value", ""),
                                            "desc": b.get("pDesc", {}).get("value", ""), "born": b.get("born", {}).get("value", "")[:5],
                                            "died": b.get("died", {}).get("value", "")[:5], "birth": [], "work": []})
                    r["birth" if prop == "P19" else "work"].append([float(m.group(1)), float(m.group(2))])
                print(f"people {prop} {lo}-{hi}: {len(rows)}", file=sys.stderr)
        return list(rows.values())
    return cached("people.json", run)


def fetch_events():
    def run():
        rows = {}
        for lo, hi in [(15, 100000)]:
            for b in sparql(event_query(lo, hi)):
                q = b["e"]["value"].rsplit("/", 1)[1]
                m = re.match(r"Point\(([-\d.eE]+) ([-\d.eE]+)\)", b["coord"]["value"], re.I)
                if not m or q in rows:
                    continue
                t = (b.get("t") or b.get("start") or {}).get("value", "")
                rows[q] = {"q": q, "sl": int(b["sl"]["value"]), "name": b.get("eLabel", {}).get("value", ""),
                           "desc": b.get("eDesc", {}).get("value", ""), "time": t[:5] if t else "",
                           "at": [float(m.group(1)), float(m.group(2))]}
            print(f"events {lo}-{hi}: {len(rows)}", file=sys.stderr)
        return list(rows.values())
    return cached("events.json", run)


def load_ids():
    b = (GEO / "ids.bin").read_bytes()
    w, h = struct.unpack("<II", b[:8])
    raw = zlib.decompress(b[8:], -15)
    reg = np.frombuffer(raw[:w * h * 2], dtype="<u2").reshape(h, w)
    cty = np.frombuffer(raw[w * h * 2:], dtype=np.uint8).reshape(h, w)
    def look(lon, lat):
        x = int((lon + 180) / 360 * w) % w
        y = min(h - 1, max(0, int((90 - lat) / 180 * h)))
        return int(reg[y, x]), int(cty[y, x])
    return look


def year_num(y):
    m = re.match(r"^(-?\d{1,4})", y or "")
    return int(m.group(1)) if m else None


def year_text(y):
    n = year_num(y)
    if n is None:
        return ""
    return f"公元前{-n}年" if n < 0 else f"{n}年"


def zh(s):
    return T2S(s) if s else s


def fmt_people(rows, place_key):
    out = []
    for r in sorted(rows, key=lambda r: -r["sl"]):
        if not r["name"] or re.fullmatch(r"Q\d+", r["name"]):
            continue
        out.append({"q": r["q"], "name": r["name"], "desc": r["desc"], "born": year_text(r["born"]), "died": year_text(r["died"]), "how": place_key(r)})
    return out


def main():
    countries = json.loads((GEO / "countries.json").read_text())
    regions = json.loads((GEO / "regions.json").read_text())
    qids = [c["wikidata"] for c in countries] + [r["wikidata"] for r in regions]
    ents = entities(qids)
    # 解析首府、语言、货币的名字
    ref = set()
    for q in qids:
        for p in ("P36", "P37", "P38"):
            for v in ents.get(q, {}).get("claims", {}).get(p, []):
                if isinstance(v, str):
                    ref.add(v)
    ents = entities(list(ref))

    # 维基正文（并发 6）
    titles = {q: ents[q]["zhwiki"] for q in qids if q in ents and ents[q].get("zhwiki")}
    todo = [t for t in set(titles.values()) if not (WORK / "wiki" / f"{re.sub(r'[^\w]', '_', t)[:80]}.json").exists()]
    print(f"wiki to fetch: {len(todo)}", file=sys.stderr)
    with ThreadPoolExecutor(6) as ex:
        for i, _ in enumerate(ex.map(wiki_text, todo)):
            if i % 200 == 0:
                print(f"wiki {i}/{len(todo)}", file=sys.stderr)

    look = load_ids()
    people = fetch_people()
    events = fetch_events()
    by_region, by_country = {}, {}
    for p in people:
        seen = set()
        for kind in ("birth", "work"):
            for lon, lat in p[kind]:
                rid, cid = look(lon, lat)
                key = (rid, cid)
                if key in seen or cid == 0:
                    continue
                seen.add(key)
                item = dict(p, how=kind)
                by_region.setdefault(rid, {}).setdefault(p["q"], item)
                by_country.setdefault(cid, {}).setdefault(p["q"], item)
    ev_region, ev_country = {}, {}
    for e in events:
        rid, cid = look(*e["at"])
        if cid:
            ev_region.setdefault(rid, []).append(e)
            ev_country.setdefault(cid, []).append(e)

    def facts(q):
        e = ents.get(q, {})
        c = e.get("claims", {})
        f = {}
        cap = [label(ents[v]) for v in c.get("P36", []) if isinstance(v, str) and v in ents]
        if cap: f["capital"] = "、".join(dict.fromkeys(x for x in cap[:2] if x))
        pops = [v for v in c.get("P1082", []) if isinstance(v, list)]
        if pops:
            v = max(pops, key=lambda x: x[1] or "0")
            f["population"] = int(v[0]); f["populationYear"] = v[1]
        area = [v for v in c.get("P2046", []) if isinstance(v, list)]
        if area: f["area"] = round(area[0][0])
        lang = [label(ents[v]) for v in c.get("P37", []) if isinstance(v, str) and v in ents]
        if lang: f["languages"] = [x for x in dict.fromkeys(lang[:4]) if x]
        cur = [label(ents[v]) for v in c.get("P38", []) if isinstance(v, str) and v in ents]
        if cur: f["currency"] = "、".join(dict.fromkeys(x for x in cur[:2] if x))
        return f

    def article(q, title_override=None):
        e = ents.get(q, {})
        title = title_override or e.get("zhwiki")
        if not title:
            return {}
        text = wiki_text(title)["text"]
        a = {"wiki": title, "summary": first_paragraphs(text, 420)}
        for k, keys in SECTION_KEYS.items():
            s = section_snippet(text, keys, 360)
            if s: a[k] = s
        return a

    def people_list(d, n):
        rows = sorted(d.values(), key=lambda r: -r["sl"])[:n]
        return [{"q": r["q"], "name": zh(r["name"]), "desc": zh(r["desc"]), "born": year_text(r["born"]), "died": year_text(r["died"]),
                 "how": r["how"]} for r in rows if r["name"]]

    def event_list(rows, n):
        # 只要有明确发生时间（P585 时间点或 P580 开始时间）的，排除地铁、陵墓这类「建成物」
        rows = [r for r in rows if r["name"] and year_num(r["time"]) is not None]
        rows = sorted(rows, key=lambda r: -r["sl"])[:n]
        rows.sort(key=lambda r: year_num(r["time"]))
        return [{"q": r["q"], "name": zh(r["name"]), "desc": zh(r["desc"]), "year": year_text(r["time"])} for r in rows]

    overrides = {"Q57251": "台湾"}
    for c in countries:
        doc = {"country": {"id": c["id"], "desc": label({"labels": ents.get(c["wikidata"], {}).get("desc", {})}) if c["wikidata"] in ents else "",
                           "facts": facts(c["wikidata"]), **article(c["wikidata"]),
                           "people": people_list(by_country.get(c["id"], {}), 16), "events": event_list(ev_country.get(c["id"], []), 14)},
               "regions": {}}
        for r in regions:
            if r["country"] != c["id"] or r["pixels"] == 0:
                continue
            q = r["wikidata"]
            doc["regions"][str(r["id"])] = {"desc": label({"labels": ents.get(q, {}).get("desc", {})}) if q in ents else "",
                                           "facts": facts(q) if q else {}, **(article(q, overrides.get(q)) if q else {}),
                                           "people": people_list(by_region.get(r["id"], {}), 12), "events": event_list(ev_region.get(r["id"], []), 10)}
        (OUT / f"{c['a3']}.json").write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")))
    print("done", file=sys.stderr)


if __name__ == "__main__":
    main()
