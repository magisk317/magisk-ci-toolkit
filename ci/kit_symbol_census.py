#!/usr/bin/env python3
"""Class-level dead-API census for the shared Gradle kits.

Package-level checks answer "is this package imported anywhere?". They cannot
see a public class that no consumer references, and they cannot tell a class
used only inside its own file from one used elsewhere in the kit. This script
does both: it collects class/object/interface declarations from the kit repos
and counts identifier references in the kit itself and in the fleet (consumer
repos).

Declaration matching deliberately covers ``class``, ``data class``,
``enum class``, ``sealed class``, ``fun interface`` and ``object``. Missing
``enum class`` / ``data class`` was the failure mode that made an earlier
ad-hoc census declare the whole LogTransport file dead while DeliveryResult
inside it was still consumed by the fleet.

Reference counting is token-based, not semantic: imports, KDoc and string
literals count. Treat the output as a shortlist for review, not proof. Test
source sets are excluded from both sides so a test-only class does not look
like a live public API.

Usage:
  kit_symbol_census.py --kit ../magisk-xposed-kit --kit ../magisk-ui-kit \
      --fleet ../XposedSmsCode --fleet ../xinyi-relay --fleet ../push/MiPushFramework

Exit status is 0 for a report. With ``--fail-on-dead`` it returns 1 when a
symbol has zero kit-internal and zero fleet references.
"""
import argparse
import collections
import json
import os
import re
import sys

EXCLUDED_DIRS = {
    ".git", ".gradle", "build", "out", "node_modules",
    # shared submodules live inside consumer checkouts; scanning them would
    # make every kit symbol look like a fleet consumer of itself
    "smscode", "magisk-ui-kit", "magisk-xposed-kit", "magisk-ci-toolkit", "build-logic",
}
TEST_SOURCE = re.compile(
    r"(^|/)(src/(test|androidTest|commonTest|jvmTest|androidHostTest|desktopTest|iosTest)/|__tests__/)"
)
DECL = re.compile(
    r"^\s*"
    r"(?:(?:public|internal|private|protected|abstract|open|sealed|data|value|fun|annotation|expect|actual|inline|operator|infix|tailrec)\s+)*"
    r"(class|interface|object)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
VISIBILITY = re.compile(r"^\s*(public|internal|private|protected)\b")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def kotlin_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS]
        rel_dir = os.path.relpath(dirpath, root)
        for name in filenames:
            if not name.endswith(".kt"):
                continue
            rel = name if rel_dir == "." else os.path.join(rel_dir, name)
            rel = rel.replace(os.sep, "/")
            if TEST_SOURCE.search(rel):
                continue
            yield rel, os.path.join(dirpath, name)


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def scan_repo(root):
    """Return {relative_path: text} plus a token Counter for the whole repo."""
    texts = {}
    counts = collections.Counter()
    for rel, path in kotlin_files(root):
        text = read_text(path)
        texts[rel] = text
        counts.update(IDENT.findall(text))
    return texts, counts


def collect_declarations(texts):
    """Return [{symbol, kind, file, visibility}] from already-read sources."""
    found = []
    for rel, text in texts.items():
        for line in text.splitlines():
            match = DECL.match(line)
            if not match:
                continue
            kind, symbol = match.group(1), match.group(2)
            if symbol == "Companion":
                continue
            visibility_match = VISIBILITY.match(line)
            found.append(
                {
                    "symbol": symbol,
                    "kind": kind,
                    "file": rel,
                    "visibility": visibility_match.group(1) if visibility_match else "public",
                }
            )
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kit", action="append", required=True, help="shared kit repo root (repeatable)")
    parser.add_argument("--fleet", action="append", required=True, help="consumer repo root (repeatable)")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    parser.add_argument("--fail-on-dead", action="store_true")
    parser.add_argument("--min-name-length", type=int, default=3)
    args = parser.parse_args()

    fleet_counts = collections.Counter()
    for root in args.fleet:
        _, counts = scan_repo(root)
        fleet_counts.update(counts)

    rows = []
    for kit_root in args.kit:
        texts, kit_counts = scan_repo(kit_root)
        file_counts = {rel: collections.Counter(IDENT.findall(text)) for rel, text in texts.items()}
        for decl in collect_declarations(texts):
            symbol = decl["symbol"]
            if len(symbol) < args.min_name_length or decl["visibility"] == "private":
                continue
            own = file_counts[decl["file"]].get(symbol, 0)
            same_file = max(0, own - 1)
            kit_other = kit_counts.get(symbol, 0) - own
            fleet_refs = fleet_counts.get(symbol, 0)
            if fleet_refs > 0:
                verdict = "public"
            elif kit_other > 0:
                verdict = "kit-internal"
            elif same_file > 0:
                verdict = "same-file-only"
            else:
                verdict = "dead"
            rows.append(
                {
                    "kit": os.path.basename(os.path.abspath(kit_root)),
                    "symbol": symbol,
                    "kind": decl["kind"],
                    "file": decl["file"],
                    "fleet_refs": fleet_refs,
                    "kit_other_refs": kit_other,
                    "same_file_refs": same_file,
                    "verdict": verdict,
                }
            )

    rows.sort(
        key=lambda row: (
            row["verdict"] != "dead",
            row["verdict"] != "same-file-only",
            row["kit"],
            row["symbol"],
        )
    )
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    else:
        print(f"{'VERDICT':<16} {'KIND':<9} {'FLEET':>5} {'KIT':>5} {'SELF':>5}  SYMBOL")
        for row in rows:
            if row["verdict"] == "public":
                continue
            print(
                f"{row['verdict']:<16} {row['kind']:<9} {row['fleet_refs']:>5} "
                f"{row['kit_other_refs']:>5} {row['same_file_refs']:>5}  "
                f"{row['symbol']} ({row['kit']}/{row['file']})"
            )
        dead = [row for row in rows if row["verdict"] == "dead"]
        print(
            f"\n{len(rows)} declarations; {len(dead)} dead; "
            f"{sum(row['verdict'] == 'same-file-only' for row in rows)} same-file-only; "
            f"{sum(row['verdict'] == 'kit-internal' for row in rows)} kit-internal"
        )
    if args.fail_on_dead and any(row["verdict"] == "dead" for row in rows):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
