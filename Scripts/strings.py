#!/usr/bin/env python3
"""Keep Localizable.xcstrings in step with the code.

  strings.py --check   fail on a missing key, an unused key, a literal
                       that bypasses the catalog, or a key with no
                       complete text in a language of LANGUAGES
  strings.py --write   write the catalog from the code (keeps translations)

A key is the English text. The script finds keys in these places:
  * the first string literal of the SwiftUI calls in App/ that take a
    LocalizedStringKey: Text("..."), Button("..."), Label("..."), ...
  * every UIText("...") in App/ and PaddockKit/Sources/
  * every literal on a line that ends with "// localized"

The lint rules: no Text(verbatim: "...") with a literal, and no
interpolation inside a localized literal (use UIText with %@ instead).

One language per interface: every key has a text in every language of
LANGUAGES, with the same values as the key. A translation takes the values
in order with %@, or by place with %1$@, %2$@ when its language needs
another order (UIText.fill). A count is %lld (or %1$lld): its key has a
plural variation in each language with the forms of PLURAL_FORMS.
AppTests/LocalizationTests.swift runs the same check on the Mac.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "App", "Resources", "Localizable.xcstrings")
LITERAL = r'"((?:[^"\\]|\\.)*)"'
CALLS = ["Text", "Button", "Label", "Toggle", "Picker", "Section", "LabeledContent", "TextField",
         "Menu", "TableColumn", "ContentUnavailableView", "Window", "CommandMenu", "Link",
         "String(localized:"]
CALL_RE = re.compile(r'(?<![\w.])(?:' + "|".join(re.escape(c) if c.endswith(":") else re.escape(c) + r'\(' for c in CALLS)
                     + r')\s*' + LITERAL)
UITEXT_RE = re.compile(r'UIText\(\s*(?:key:\s*)?' + LITERAL)
ANY_RE = re.compile(LITERAL)
VERBATIM_RE = re.compile(r'Text\(verbatim:\s*"')


# The languages of the interface besides English, the source.
LANGUAGES = ["zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR", "ru", "it"]

# The plural forms that a counted text needs in each language (CLDR).
# A key with %lld is counted: in a language with more than one form, its
# text is a plural variation with each of these forms.
PLURAL_FORMS = {
    "zh-Hans": ["other"], "zh-Hant": ["other"], "ja": ["other"], "ko": ["other"],
    "es": ["one", "other"], "fr": ["one", "other"], "de": ["one", "other"],
    "pt-BR": ["one", "other"], "it": ["one", "other"],
    "ru": ["one", "few", "many", "other"],
}
PLACE_RE = re.compile(r'%(?:(\d+)\$)?(@|lld)')


def places(text):
    """The values a text takes: a sorted list of (place from 1, type)."""
    found = []
    following = 0
    for m in PLACE_RE.finditer(text):
        if m.group(1):
            found.append((int(m.group(1)), m.group(2)))
        else:
            following += 1
            found.append((following, m.group(2)))
    return sorted(found)


def texts(entry, language):
    """The texts of a language: {form: value}. A plain text is "other"."""
    loc = entry.get("localizations", {}).get(language, {})
    if "variations" in loc:
        plural = loc["variations"].get("plural", {})
        return {form: v.get("stringUnit", {}).get("value", "") for form, v in plural.items()}
    if "stringUnit" in loc:
        return {"other": loc["stringUnit"].get("value", "")}
    return {}


def translation_problems(strings):
    problems = []
    for key in sorted(strings):
        want = places(key)
        counted = sum(1 for _, kind in want if kind == "lld")
        if counted > 1:
            problems.append(f"more than one count in a key; build it from counted parts: {key!r}")
        for language in LANGUAGES:
            found = texts(strings[key], language)
            if not any(v.strip() for v in found.values()):
                problems.append(f"no {language} text: {key!r}")
                continue
            if counted:
                forms = PLURAL_FORMS[language]
                if len(forms) > 1 and "variations" not in strings[key]["localizations"][language]:
                    problems.append(f"the {language} text of a count is not a plural variation: {key!r}")
                for form in forms:
                    if not found.get(form, "").strip():
                        problems.append(f"no {language} plural form {form!r}: {key!r}")
            elif set(found) != {"other"} or "variations" in strings[key]["localizations"][language]:
                problems.append(f"a {language} plural variation for a key without a count: {key!r}")
            for form, value in sorted(found.items()):
                # Foundation formats a count: a lone % there is undefined.
                if "%" in PLACE_RE.sub("", value):
                    problems.append(f"the {language} text ({form}) has a % that is no value; write the word: {key!r} -> {value!r}")
                if places(value) != want:
                    problems.append(f"the {language} text ({form}) takes other values than its key: {key!r} -> {value!r}")
    return problems


def bundle_problems():
    """project.yml lists every language in CFBundleLocalizations."""
    with open(os.path.join(ROOT, "project.yml"), encoding="utf-8") as f:
        m = re.search(r"CFBundleLocalizations:\s*\[([^\]]*)\]", f.read())
    listed = [x.strip() for x in m.group(1).split(",")] if m else []
    want = ["en"] + LANGUAGES
    if sorted(listed) != sorted(want):
        return [f"project.yml CFBundleLocalizations is {listed}, not {want}"]
    return []


def counts():
    """Texts per language, for the report."""
    strings = load().get("strings", {})
    out = {}
    for language in ["en"] + LANGUAGES:
        done = sum(1 for e in strings.values() if any(v.strip() for v in texts(e, language).values()))
        plural = sum(1 for e in strings.values()
                     if "variations" in e.get("localizations", {}).get(language, {}))
        out[language] = (done, plural)
    return out


def unescape(text):
    return text.replace('\\"', '"').replace("\\\\", "\\").replace("\\n", "\n")


def swift_files(*dirs):
    for d in dirs:
        for base, _, files in os.walk(os.path.join(ROOT, d)):
            for name in sorted(files):
                if name.endswith(".swift"):
                    yield os.path.join(base, name)


def extract():
    keys = {}
    problems = []
    for path in swift_files("App", os.path.join("PaddockKit", "Sources")):
        in_app = os.sep + "App" + os.sep in path
        rel = os.path.relpath(path, ROOT)
        with open(path, encoding="utf-8") as f:
            for number, line in enumerate(f, 1):
                code = line.split("//")[0] if not line.rstrip().endswith("// localized") else line
                found = []
                for m in UITEXT_RE.finditer(code):
                    found.append(m.group(1))
                if in_app:
                    for m in CALL_RE.finditer(code):
                        found.append(m.group(1))
                    if line.rstrip().endswith("// localized"):
                        found += [m.group(1) for m in ANY_RE.finditer(line.split("// localized")[0])]
                    if VERBATIM_RE.search(code):
                        problems.append(f"{rel}:{number}: Text(verbatim:) with a literal; put the text in the catalog")
                for raw in found:
                    if "\\(" in raw:
                        problems.append(f"{rel}:{number}: interpolation in a localized literal; use UIText with %@")
                        continue
                    keys.setdefault(unescape(raw), f"{rel}:{number}")
    return keys, problems


def load():
    if not os.path.exists(CATALOG):
        return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    with open(CATALOG, encoding="utf-8") as f:
        return json.load(f)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    keys, problems = extract()
    catalog = load()
    if mode == "--write":
        old = catalog.get("strings", {})
        strings = {}
        for key in sorted(keys):
            entry = old.get(key) or {}
            entry["extractionState"] = "manual"
            loc = entry.setdefault("localizations", {})
            loc["en"] = {"stringUnit": {"state": "translated", "value": key}}
            strings[key] = entry
        catalog["strings"] = strings
        os.makedirs(os.path.dirname(CATALOG), exist_ok=True)
        with open(CATALOG, "w", encoding="utf-8") as f:
            json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
        print(f"strings: wrote {len(strings)} keys")
    have = set(catalog.get("strings", {}))
    missing = sorted(set(keys) - have)
    unused = sorted(have - set(keys))
    for key in missing:
        problems.append(f"{keys[key]}: missing in the catalog: {key!r}")
    for key in unused:
        problems.append(f"unused key in the catalog: {key!r}")
    problems += translation_problems(catalog.get("strings", {}))
    problems += bundle_problems()
    for p in problems:
        print("strings: " + p)
    if problems:
        sys.exit(1)
    report = ", ".join(f"{lang} {done}" + (f" ({plural} plural)" if plural else "")
                       for lang, (done, plural) in counts().items())
    print(f"strings: ok, {len(have)} keys; texts per language: {report}")


if __name__ == "__main__":
    main()
