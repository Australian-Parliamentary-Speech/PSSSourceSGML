"""Insert the end tags that Hansard SGML omits, and change nothing else (PSSSourceSGML#9).

close_tags(text, model) -> (text with end tags inserted, counts by tag). An open element is closed when a
tag arrives that it never contains (in files where it is always explicitly closed: sgml_model.json),
or when an ancestor's end tag arrives; an INTERJECT with no end tag closes after its TALK.START, as 93% of
explicitly closed ones do. Every other byte of the input is kept, so the BeautifulSoup conversion that
follows gives the same output wherever nothing is inserted or it would have closed the element anyway.
"""
import collections
import json
import re

EMPTY = {"TAB", "BREAK", "COLSPEC", "SPANSPEC"}
ENTITIES = {"mdash": "—", "hyphen": "-", "half": "½", "frac14": "¼", "frac34": "¾",
            "frac13": "⅓", "frac23": "⅔", "bull": "•", "pound": "£", "lt": "<",
            "gt": ">", "amp": "&", "rsquo": "’", "lsquo": "‘", "yen": "¥", "sup2": "²",
            "cent": "¢", "dagger": "†", "nbsp": " "}
TOKEN = re.compile(r"<!--.*?-->|<!DOCTYPE[^\[>]*(?:\[.*?\])?\s*>|</?[A-Za-z][^>]*>|[^<]+|<", re.S)
TAGNAME = re.compile(r"</?\s*([A-Za-z][\w.\-]*)")
ATTR = re.compile(r'([\w.\-]+)\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)')


def tokens(text):
    for m in TOKEN.finditer(text):
        t = m.group(0)
        if t.startswith("<!"):
            continue
        if t.startswith("</"):
            yield "end", TAGNAME.match(t).group(1).upper(), None
        elif t.startswith("<") and len(t) > 1:
            name = TAGNAME.match(t).group(1).upper()
            attrs = [(k.lower(), v.strip("\"'")) for k, v in ATTR.findall(t[len(name) + 1:])]
            yield "start", name, attrs
        else:
            yield "text", t, None


def unclosed_interjects(toks):
    """Indexes of INTERJECT start tags whose end tag is omitted (another speech begins first)."""
    out = set()
    stops = {"INTERJECT", "SPEECH", "QUESTION", "ANSWER", "DEBATE", "DEBATE.SUB1", "DEBATE.SUB2", "PETITION"}
    for i, (kind, name, _) in enumerate(toks):
        if kind == "start" and name == "INTERJECT":
            for kind2, name2, _ in toks[i + 1:]:
                if kind2 == "end" and name2 == "INTERJECT":
                    break
                if kind2 == "start" and name2 in stops or kind2 == "end" and name2 in stops - {"INTERJECT"}:
                    out.add(i)
                    break
            else:
                out.add(i)
    return out


def close_tags(text, model):
    allowed = {k: set(v) for k, v in model.items()}
    spans = list(TOKEN.finditer(text))
    toks = []
    for m in spans:
        t = m.group(0)
        if t.startswith("<!"):
            toks.append(("skip", None, None))
        elif t.startswith("</"):
            toks.append(("end", TAGNAME.match(t).group(1).upper(), None))
        elif t.startswith("<") and len(t) > 1:
            toks.append(("start", TAGNAME.match(t).group(1).upper(), None))
        else:
            toks.append(("text", None, None))
    open_ended = unclosed_interjects([x for x in toks if x[0] != "skip"])
    # unclosed_interjects indexes the token list without skips; map back
    real = [i for i, x in enumerate(toks) if x[0] != "skip"]
    open_ended = {real[i] for i in open_ended}
    out, stack, close_after_talk = [], [], []
    inserted = collections.Counter()

    def close_top():
        name = stack.pop()
        out.append(f"</{name}>")
        inserted[name] += 1
        while close_after_talk and close_after_talk[-1] >= len(stack):
            close_after_talk.pop()

    for i, (m, (kind, name, _)) in enumerate(zip(spans, toks)):
        raw = m.group(0)
        if kind == "start":
            while stack and stack[-1] in allowed and name not in allowed[stack[-1]] \
                    and any(name in allowed.get(a, ()) for a in stack[:-1]):
                close_top()
            out.append(raw)
            if name not in EMPTY:
                if name == "INTERJECT" and i in open_ended:
                    close_after_talk.append(len(stack))
                stack.append(name)
        elif kind == "end":
            if name in stack:
                while stack[-1] != name:
                    close_top()
                out.append(raw)
                stack.pop()
                while close_after_talk and close_after_talk[-1] >= len(stack):
                    close_after_talk.pop()
                if name == "TALK.START" and close_after_talk and len(stack) == close_after_talk[-1] + 1 \
                        and stack[-1] == "INTERJECT":
                    close_top()
            else:
                out.append(raw)
        else:
            out.append(raw)
    return "".join(out), inserted




def load_model(path):
    return json.load(open(path))
