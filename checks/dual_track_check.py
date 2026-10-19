#!/usr/bin/env python3
"""Configuration-driven M3/Miuix convergence gate."""

import argparse
import json
import os
import re
import sys

DEFAULT_CONFIG = {
    "track_m_suffixes": ["Material.kt", "Expressive.kt"],
    "track_x_suffix": "Miuix.kt",
    "skip_dirs": ["build", ".git", ".gradle", ".idea", "magisk-ui-kit", "magisk-xposed-kit", "build-logic", "node_modules"],
    "submodule_prefixes": ["smscode/core", "smscode/rules", "smscode-core"],
    "exempt_prefixes": [],
    "leaves": [
        "Text", "IconButton", "Button", "TextButton", "OutlinedButton", "FilledTonalButton", "ElevatedButton",
        "AlertDialog", "BasicAlertDialog", "Switch", "Checkbox", "RadioButton", "Slider", "RangeSlider",
        "CircularProgressIndicator", "LinearProgressIndicator", "Surface", "HorizontalDivider", "VerticalDivider",
        "Divider", "Card", "OutlinedCard", "ElevatedCard", "ListItem", "SnackbarHost", "NavigationBar",
        "FloatingActionButton", "ExtendedFloatingActionButton", "Icon", "FilterChip", "AssistChip", "InputChip",
        "SuggestionChip", "DropdownMenu", "DropdownMenuItem", "SegmentedButton", "Badge", "TextField",
        "OutlinedTextField", "BasicTextField", "SecureTextField", "ExposedDropdownMenuBox", "ExposedDropdownMenu",
        "Tab", "TabRow", "TopAppBar", "Scaffold", "ModalBottomSheet", "BottomSheetScaffold", "NavigationRail",
    ],
}

IMPORT_RE = re.compile(
    r"^import\s+([A-Za-z_][A-Za-z0-9_.]*?)(?:\.(\*))?\s*(?:as\s+([A-Za-z0-9_]+))?\s*$",
    re.M,
)


def load_config(path):
    config = dict(DEFAULT_CONFIG)
    if path:
        with open(path, encoding="utf-8") as handle:
            loaded = json.load(handle)
        config.update({key: value for key, value in loaded.items() if key in config})
    return config


def strip_strings_comments(src):
    out = list(src)
    i, n, state, depth = 0, len(src), None, 0
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state is None:
            if ch == "/" and nxt == "/":
                state = "line"
                out[i] = " "
                i += 1
                continue
            if ch == "/" and nxt == "*":
                state, depth = "block", 1
                out[i] = " "
                i += 1
                continue
            if src.startswith('"""', i):
                state = "raw"
                out[i] = " "
                i += 3
                continue
            if ch == '"':
                state = "str"
                out[i] = " "
                i += 1
                continue
            if ch == "'":
                state = "char"
                out[i] = " "
                i += 1
                continue
            i += 1
            continue
        if state == "line":
            if ch == "\n":
                state = None
            else:
                out[i] = " "
            i += 1
            continue
        if state == "block":
            if ch == "*" and nxt == "/":
                depth -= 1
                out[i] = " "
                if depth == 0:
                    state = None
                i += 1
                continue
            if ch == "/" and nxt == "*":
                depth += 1
            out[i] = " " if ch != "\n" else "\n"
            i += 1
            continue
        if state == "raw":
            if src.startswith('"""', i):
                state = None
                out[i] = " "
                i += 3
                continue
            out[i] = " " if ch != "\n" else "\n"
            i += 1
            continue
        if state == "str":
            if ch == "\\":
                out[i] = " "
                if i + 1 < n:
                    out[i + 1] = " "
                i += 2
                continue
            if ch == '"':
                state = None
                out[i] = " "
                i += 1
                continue
            out[i] = " " if ch != "\n" else "\n"
            i += 1
            continue
        if state == "char":
            if ch == "\\":
                i += 2
                continue
            if ch == "'":
                state = None
            out[i] = " " if ch != "\n" else "\n"
            i += 1
    return "".join(out)


def parse_imports(src):
    exact, wild = {}, []
    for match in IMPORT_RE.finditer(src):
        fqn, star, alias = match.group(1), match.group(2), match.group(3)
        if star:
            wild.append(fqn)
        else:
            exact[alias or fqn.rsplit(".", 1)[1]] = fqn
    return exact, wild


def resolve(name, exact, wild):
    if name in exact:
        fqn = exact[name]
        if fqn.startswith("androidx.compose.material3."):
            return "M3"
        if fqn.startswith("androidx.compose.material."):
            return "M2"
        if fqn.startswith("top.yukonga."):
            return "MIUIX"
        if fqn.startswith("io.github.magisk317."):
            return "KIT"
        return None
    families = set()
    for package in wild:
        if package == "androidx.compose.material3" or package.startswith("androidx.compose.material3."):
            families.add("M3")
        elif package == "androidx.compose.material" or package.startswith("androidx.compose.material."):
            families.add("M2")
        elif package.startswith("top.yukonga."):
            families.add("MIUIX")
        elif package.startswith("io.github.magisk317."):
            families.add("KIT")
    debt = families & {"M3", "M2"}
    if len(families) == 1 and debt:
        return "M3" if "M3" in families else "M2"
    if len(families) > 1 and debt:
        return "AMBIG"
    return None


def is_prefix(path, prefixes):
    return any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in prefixes)


def track_of(path, config):
    base = os.path.basename(path)
    if base.endswith(config["track_x_suffix"]):
        return "X"
    if base.endswith(tuple(config["track_m_suffixes"])):
        return "M"
    return "shared"


def walk(root, config):
    skip_dirs = set(config["skip_dirs"])
    submodule_prefixes = tuple(config["submodule_prefixes"])
    exempt_prefixes = tuple(config["exempt_prefixes"])
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root).replace(os.sep, "/")
        dirnames[:] = [name for name in dirnames if name not in skip_dirs]
        if is_prefix(rel_dir, exempt_prefixes) or is_prefix(rel_dir, submodule_prefixes):
            dirnames[:] = []
            continue
        if re.search(r"/src/(test|androidTest)(/|$)", "/" + rel_dir):
            dirnames[:] = []
            continue
        for filename in filenames:
            if not filename.endswith(".kt"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, filename), root).replace(os.sep, "/")
            if is_prefix(rel, exempt_prefixes) or is_prefix(rel, submodule_prefixes):
                continue
            yield os.path.join(dirpath, filename), rel


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--config")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    config = load_config(args.config)
    leaf_re = {
        name: re.compile(r"(?<![A-Za-z0-9_.])" + re.escape(name) + r"\s*\(")
        for name in sorted(set(config["leaves"]))
    }
    findings = []
    for path, rel in sorted(walk(root, config), key=lambda item: item[1]):
        track = track_of(path, config)
        try:
            with open(path, encoding="utf-8") as handle:
                source = strip_strings_comments(handle.read())
        except (OSError, UnicodeDecodeError):
            continue
        exact, wild = parse_imports(source)
        for name, pattern in leaf_re.items():
            kind = resolve(name, exact, wild)
            if kind not in ("M3", "M2", "MIUIX", "AMBIG"):
                continue
            for match in pattern.finditer(source):
                line = source[:match.start()].count("\n") + 1
                if track == "M" and kind == "MIUIX":
                    findings.append(("M-track uses miuix native", rel, line, name))
                elif track == "X" and kind in ("M3", "M2", "AMBIG"):
                    findings.append(("Miuix-track uses M3", rel, line, name))
                elif track == "shared" and kind in ("M3", "M2", "AMBIG"):
                    findings.append(("shared uses M3 component", rel, line, name))
                elif track == "shared" and kind == "MIUIX":
                    findings.append(("shared uses miuix native", rel, line, name))
        if track == "shared":
            for match in re.finditer(r"MaterialTheme\.(colorScheme|typography|shapes)\.", source):
                line = source[:match.start()].count("\n") + 1
                findings.append(("shared uses M3 theme API (%s)" % match.group(1), rel, line, match.group(0)))
    if not args.quiet:
        print("== dual-track check: %s ==" % root)
        for kind, rel, line, name in findings:
            print("FAIL  %-34s %s:%d  %s" % (kind, rel, line, name))
    print("SUMMARY fail=%d" % len(findings))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
