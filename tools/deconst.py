#!/usr/bin/env python3
"""Removes `const` from Dart const expressions/declarations that textually contain a
name which is no longer constant (theme colours, tr() calls). Iterates to a fixpoint:
a const declaration that becomes `final` makes its own name non-constant too.

usage: deconst.py NAMES_FILE file.dart...
NAMES_FILE lines: `name` (bare identifier) or `Prefix.member` or `name(` (call).
"""
import re
import sys

IDENT = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")


def tokenize(src):
    """Yields (kind, start, end, text) for identifiers, punctuation; skips strings/comments
    but descends into string interpolations."""
    out = []
    i, n = 0, len(src)

    def string(i, quote, raw, triple):
        # returns end index after closing quote; records interpolation tokens
        q = quote * 3 if triple else quote
        i += len(q)
        while i < n:
            if not raw and src[i] == "\\":
                i += 2
                continue
            if src.startswith(q, i):
                return i + len(q)
            if not raw and src[i] == "$":
                if i + 1 < n and src[i + 1] == "{":
                    depth = 1
                    j = i + 2
                    start = j
                    # tokenize inside interpolation recursively until matching }
                    while j < n and depth:
                        c = src[j]
                        if c in "'\"":
                            r = False
                            t = src.startswith(c * 3, j)
                            j = string(j, c, r, t)
                            continue
                        if c == "{":
                            depth += 1
                        elif c == "}":
                            depth -= 1
                            if depth == 0:
                                break
                        m = IDENT.match(src, j)
                        if m:
                            out.append(("id", m.start(), m.end(), m.group()))
                            j = m.end()
                            continue
                        out.append(("p", j, j + 1, c))
                        j += 1
                    i = j + 1
                    continue
                m = IDENT.match(src, i + 1)
                if m:
                    out.append(("id", m.start(), m.end(), m.group()))
                    i = m.end()
                    continue
            i += 1
        return i

    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c in "'\"" or (c == "r" and i + 1 < n and src[i + 1] in "'\"" and not (i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_"))):
            raw = c == "r"
            if raw:
                i += 1
                c = src[i]
            triple = src.startswith(c * 3, i)
            start = i - (1 if raw else 0)
            i = string(i, c, raw, triple)
            out.append(("s", start, i, src[start:i]))
            continue
        m = IDENT.match(src, i)
        if m:
            out.append(("id", m.start(), m.end(), m.group()))
            i = m.end()
            continue
        if c.isdigit():
            m = re.compile(r"[0-9][0-9a-fA-FxX._eE]*").match(src, i)
            out.append(("num", i, m.end(), m.group()))
            i = m.end()
            continue
        if not c.isspace():
            out.append(("p", i, i + 1, c))
        i += 1
    return out


PAIR = {"(": ")", "[": "]", "{": "}", "<": ">"}


def match(toks, k):
    """Index of the token closing toks[k] (a bracket)."""
    open_, close = toks[k][3], PAIR[toks[k][3]]
    depth = 0
    for j in range(k, len(toks)):
        t = toks[j][3]
        if toks[j][0] != "p":
            continue
        if t == open_:
            depth += 1
        elif t == close:
            depth -= 1
            if depth == 0:
                return j
    return len(toks) - 1


def const_spans(src, toks):
    """(kind, const_token_index, end_token_index, declared_name) for each `const`."""
    spans = []
    for k, t in enumerate(toks):
        if t[0] != "id" or t[3] != "const":
            continue
        j = k + 1
        if j >= len(toks):
            continue
        # declaration: const [Type] name = ... ;
        m = j
        if toks[m][0] == "id":
            m2 = m + 1
            if m2 < len(toks) and toks[m2][3] == "<":
                m2 = match(toks, m2) + 1
            if m2 < len(toks) and toks[m2][3] == "?":
                m2 += 1
            cand = None
            if m2 < len(toks) and toks[m2][3] == "=" and not (m2 + 1 < len(toks) and toks[m2 + 1][3] in "=>"):
                cand = m
            elif m2 < len(toks) and toks[m2][0] == "id" and m2 + 1 < len(toks) and toks[m2 + 1][3] == "=" and not (toks[m2 + 2][3] in "=>"):
                cand = m2
            if cand is not None:
                # until ; or , at depth 0 (one declarator)
                depth = 0
                e = cand
                while e < len(toks):
                    p = toks[e][3] if toks[e][0] == "p" else None
                    if p in ("(", "[", "{"):
                        depth += 1
                    elif p in (")", "]", "}"):
                        if depth == 0:
                            break
                        depth -= 1
                    elif p in (";", ",") and depth == 0:
                        break
                    e += 1
                spans.append(("decl", k, e, toks[cand][3]))
                continue
        # expression: [<T>] ( [ { or Name(.Name)*[<T>](...)
        if toks[j][3] == "<":
            j = match(toks, j) + 1
        if j < len(toks) and toks[j][3] in ("[", "{", "("):
            spans.append(("expr", k, match(toks, j), None))
            continue
        while j < len(toks) and toks[j][0] == "id":
            if j + 1 < len(toks) and toks[j + 1][3] == ".":
                j += 2
                continue
            break
        j += 1
        if j < len(toks) and toks[j][3] == "<":
            j = match(toks, j) + 1
        if j < len(toks) and toks[j][3] == "(":
            spans.append(("expr", k, match(toks, j), None))
    return spans


def uses(toks, a, b, names, qualified, calls):
    for x in range(a, b + 1):
        t = toks[x]
        if t[0] != "id":
            continue
        prev = toks[x - 1][3] if x > 0 else ""
        nxt = toks[x + 1][3] if x + 1 < len(toks) else ""
        if prev == "." and toks[x - 1][0] == "p":
            continue
        if t[3] in calls and nxt == "(":
            return True
        if t[3] in names and nxt != ":" and not (nxt == "(" ):
            return True
        if nxt == "." and x + 2 < len(toks) and f"{t[3]}.{toks[x + 2][3]}" in qualified:
            return True
    return False


def process(src, names, qualified, calls):
    toks = tokenize(src)
    spans = const_spans(src, toks)
    edits = []  # (start, end, replacement)
    newnames = set()
    for kind, k, e, decl in spans:
        if uses(toks, k + 1, e, names, qualified, calls):
            s = toks[k]
            if kind == "decl":
                edits.append((s[1], s[2], "final"))
                newnames.add(decl)
            else:
                end = s[2]
                while end < len(src) and src[end] in " \t":
                    end += 1
                edits.append((s[1], end, ""))
    for a, b, r in sorted(edits, reverse=True):
        src = src[:a] + r + src[b:]
    return src, newnames, len(edits)


def main():
    lines = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
    names = {l for l in lines if "." not in l and not l.endswith("(")}
    qualified = {l for l in lines if "." in l}
    calls = {l[:-1] for l in lines if l.endswith("(")}
    files = sys.argv[2:]
    total = 0
    while True:
        grew = False
        for f in files:
            src = open(f, encoding="utf-8").read()
            out, new, count = process(src, names, qualified, calls)
            if out != src:
                open(f, "w", encoding="utf-8").write(out)
                total += count
            # private names only matter in their own file, public ones everywhere
            for nm in new:
                if nm not in names:
                    names.add(nm)
                    grew = True
        if not grew:
            break
    print(f"removed/changed {total} const")


if __name__ == "__main__":
    main()
