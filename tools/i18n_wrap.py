#!/usr/bin/env python3
"""Wraps user-facing Dart string literals in tr(): 'Dodano: ${n} utworów' becomes
tr('Dodano: {0} utworów', [n]). Prints the templates (source form) to stdout as JSON.

Skips: directives, raw strings, map keys, switch patterns, strings without letters,
technical strings (no space, no capital, no Polish letter) and already wrapped ones.
usage: i18n_wrap.py out.json file.dart...
"""
import json
import re
import sys

PL = set("ąćęłńóśźżĄĆĘŁŃÓŚŹŻ")
SKIP_CALLS = {
    "tr", "Key", "ValueKey", "PageStorageKey", "ObjectKey", "GlobalKey", "get", "set", "number", "list",
    "invokeMethod", "api", "_api", "_call", "_job", "MethodChannel", "EventChannel", "AssetImage",
    "Image.asset", "RegExp", "Uri.parse", "Uri", "debugPrint", "print", "jsonDecode", "fontFamily",
    "replaceFirst", "replaceAll", "contains", "startsWith", "endsWith", "split", "indexOf", "lastIndexOf",
    "_audioApi", "Path", "parseSvgPath",
}
TECH = re.compile(r"^(https?:|mytify:|file:|content:|/api|application/|image/|audio/|[a-z0-9_.:/-]*$)")
templates = {}


def is_ui(text):
    letters = re.sub(r"\{\d+\}", "", text)
    if len(letters.strip()) <= 2 or len(letters) > 600 or re.fullmatch(r"[MLQCZ0-9 .,-]+", letters):
        return False
    if re.fullmatch(r"[A-Za-z0-9]+(-[A-Za-z0-9]+)+", letters):
        return False
    if not re.search(r"[A-Za-ząćęłńóśźżĄĆĘŁŃÓŚŹŻ]", letters):
        return False
    if any(c in PL for c in letters):
        return True
    if TECH.match(letters):
        return False
    if letters in {"Arial", "Bearer", "GET", "POST", "HEAD", "PUT", "DELETE", "OK", "Mytify", "FLAC", "MP3", "WAV", "DLNA", "AirPlay", "Android", "Windows", "USB", "HDMI", "Content-Type", "Authorization", "Range", "Accept"}:
        return False
    return " " in letters or letters[:1].isupper()


def scan_string(src, i):
    """Parses one (non-raw) literal at i. Returns (end, quote, triple, parts) where parts
    are ('t', source_text) and ('e', expr_source, is_simple_identifier)."""
    q = src[i]
    triple = src.startswith(q * 3, i)
    qq = q * 3 if triple else q
    i += len(qq)
    parts = []
    buf = []
    n = len(src)
    while i < n:
        c = src[i]
        if c == "\\":
            buf.append(src[i:i + 2])
            i += 2
            continue
        if src.startswith(qq, i):
            if buf:
                parts.append(("t", "".join(buf)))
            return i + len(qq), q, triple, parts
        if c == "$":
            if src.startswith("${", i):
                depth = 1
                j = i + 2
                while j < n and depth:
                    d = src[j]
                    if d in "'\"":
                        if j > 0 and src[j - 1] == "r":
                            pass
                        j = scan_string(src, j)[0]
                        continue
                    if d == "{":
                        depth += 1
                    elif d == "}":
                        depth -= 1
                    j += 1
                if buf:
                    parts.append(("t", "".join(buf)))
                    buf = []
                parts.append(("e", src[i + 2:j - 1], False))
                i = j
                continue
            m = re.compile(r"[A-Za-z_][A-Za-z0-9_]*").match(src, i + 1)
            if m:
                if buf:
                    parts.append(("t", "".join(buf)))
                    buf = []
                parts.append(("e", m.group(), True))
                i = m.end()
                continue
        buf.append(c)
        i += 1
    raise ValueError("unterminated string")


def prev_token(src, i):
    j = i - 1
    while j >= 0 and src[j].isspace():
        j -= 1
    # skip line comments is not needed for our purposes
    if j < 0:
        return "", j
    if src[j].isalnum() or src[j] == "_":
        k = j
        while k >= 0 and (src[k].isalnum() or src[k] in "_."):
            k -= 1
        return src[k + 1:j + 1], k + 1
    if src[j] in "=|&>":
        return src[max(0, j - 1):j + 1], j - 1
    return src[j], j


def next_token(src, i):
    j = i
    while j < len(src) and src[j].isspace():
        j += 1
    return src[j:j + 4], j


def call_name(src, i):
    """Name of the call whose '(' directly encloses position i (first argument only)."""
    t, j = prev_token(src, i)
    if t == "(":
        name, _ = prev_token(src, j)
        return name
    return None


def transform(src, top=True):
    out = []
    i, n = 0, len(src)
    line_start = True
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(src[i:j])
            i = j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(src[i:j])
            i = j
            continue
        if c == "r" and i + 1 < n and src[i + 1] in "'\"" and not (i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_")):
            j = i + 1
            q = src[j]
            triple = src.startswith(q * 3, j)
            qq = q * 3 if triple else q
            k = src.find(qq, j + len(qq))
            out.append(src[i:k + len(qq)])
            i = k + len(qq)
            continue
        if c in "'\"":
            start = i
            end, q, triple, parts = scan_string(src, i)
            # adjacent literals ('a' 'b') with the same quote form one string
            while True:
                m = re.compile(r"\s*").match(src, end)
                k = m.end()
                if k < n and src[k] == q and not src.startswith(q * 3, k) and not triple and not (k + 1 < n and src[k + 1] == q and k + 2 < n and src[k + 2] != q and False):
                    e2, q2, t2, p2 = scan_string(src, k)
                    if t2:
                        break
                    parts = parts + p2
                    end = e2
                    continue
                break
            raw_src = src[start:end]
            text_parts = [p[1] for p in parts if p[0] == "t"]
            # build template
            tmpl, args = [], []
            for p in parts:
                if p[0] == "t":
                    tmpl.append(p[1])
                else:
                    tmpl.append("{%d}" % len(args))
                    args.append(p[1])
            template = "".join(tmpl)
            line = src.rfind("\n", 0, start) + 1
            head = src[line:start].lstrip()
            pt, pj = prev_token(src, start)
            nt, nj = next_token(src, end)
            skip = (
                head.startswith(("import", "export", "part", "library", "@"))
                or nt.startswith("=>")
                or nt.startswith("||")
                or nt.startswith("when")
                or pt == "case"
                or (nt.startswith(":") and pt in ("{", ","))
                or call_name(src, start) in SKIP_CALLS
                or "{0}" in "".join(text_parts)
                or not is_ui(template)
            )
            if skip:
                # still translate strings inside interpolations
                rebuilt = raw_src
                if args:
                    rebuilt = rebuild(q, triple, parts, inner=True)
                out.append(rebuilt)
                i = end
                continue
            body = q * (3 if triple else 1) + template + q * (3 if triple else 1)
            templates[body] = templates.get(body, 0) + 1
            if args:
                arg_src = ", ".join(transform(a, False) for a in args)
                out.append(f"tr({body}, [{arg_src}])")
            else:
                out.append(f"tr({body})")
            i = end
            continue
        out.append(c)
        i += 1
    return "".join(out)


def rebuild(q, triple, parts, inner):
    qq = q * (3 if triple else 1)
    s = [qq]
    for p in parts:
        if p[0] == "t":
            s.append(p[1])
        elif p[2]:
            s.append("$" + p[1])
        else:
            s.append("${" + transform(p[1], False) + "}")
    s.append(qq)
    return "".join(s)


def main():
    out_json = sys.argv[1]
    for f in sys.argv[2:]:
        src = open(f, encoding="utf-8").read()
        new = transform(src)
        if new != src:
            if "import 'l10n.dart';" not in new and not f.endswith(("l10n.dart", "l10n_en.dart")):
                # after the last import
                idx = [m.end() for m in re.finditer(r"^import [^\n]*;\n", new, re.M)]
                at = idx[-1] if idx else 0
                new = new[:at] + "import 'l10n.dart';\n" + new[at:]
            open(f, "w", encoding="utf-8").write(new)
    json.dump(sorted(templates), open(out_json, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
    print(len(templates), "templates")


if __name__ == "__main__":
    main()
