#!/usr/bin/env python3
"""Validates developer-owned connector definitions (connectors/*.json) before they can be merged.

Every connector must
  * be a CFK Connector CR that matches one of the templates in templates/ exactly – only the
    <<PLACEHOLDER>> values may differ and no keys may be added (prevents arbitrary configs,
    credential references or client overrides),
  * be registered in the admin-owned connector registry with the same type,
  * only use a topic the registry grants to it,
  * authenticate with its own Kafka credential (enforced by the template: the JAAS config is
    derived from the connector name),
  * be listed in connectors/kustomization.yaml (and nothing else may be listed there).

Templates, registry and this script are read from --trusted (the base branch in CI), the connector
files from --candidate (the pull request). Needs only the Python standard library and PyYAML.
"""
import argparse
import json
import re
import sys
from pathlib import Path

import yaml

REGISTRY = "platform/kafka-admin/connector-registry.yaml"
COLUMN = r"[a-z_][a-z0-9_]{0,62}"
PARAMS = {
    "CONNECTOR_NAME": r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?",
    "TOPIC": r"[A-Za-z0-9._-]{1,249}",
    "QUEUE": r"[A-Z0-9._]{1,48}",
    "TABLE": COLUMN,
    "MODE": r"incrementing|timestamp|timestamp\+incrementing",
    "INCREMENTING_COLUMN": COLUMN,
    "TIMESTAMP_COLUMN": COLUMN,
    "PK_COLUMNS": rf"{COLUMN}(?:,{COLUMN})*",
}
PLACEHOLDER = re.compile(r"<<([A-Z_]+)>>")
# Keys that may be omitted depending on other parameters (enforced by mode_rules).
OPTIONAL_KEYS = {"jdbc-source": {"incrementing.column.name", "timestamp.column.name"}}


class Invalid(Exception):
    pass


def template_regex(tpl: str) -> re.Pattern:
    out, pos, seen = [], 0, set()
    for m in PLACEHOLDER.finditer(tpl):
        name = m.group(1)
        if name not in PARAMS:
            raise Invalid(f"template uses unknown placeholder {name}")
        out.append(re.escape(tpl[pos:m.start()]))
        out.append(f"(?P={name})" if name in seen else f"(?P<{name}>{PARAMS[name]})")
        seen.add(name)
        pos = m.end()
    out.append(re.escape(tpl[pos:]))
    return re.compile("".join(out))


def match(tpl, cand, path, params, optional):
    """Structurally compares candidate against template, collecting placeholder values."""
    if isinstance(tpl, dict):
        if not isinstance(cand, dict):
            raise Invalid(f"{path}: expected an object")
        extra = set(cand) - set(tpl)
        if extra:
            raise Invalid(f"{path}: keys not allowed by the template: {sorted(extra)}")
        for key, sub in tpl.items():
            if key not in cand:
                if key in optional:
                    continue
                raise Invalid(f"{path}: missing key '{key}'")
            match(sub, cand[key], f"{path}.{key}", params, optional)
    elif isinstance(tpl, str):
        if not isinstance(cand, str):
            raise Invalid(f"{path}: expected a string")
        m = template_regex(tpl).fullmatch(cand)
        if not m:
            raise Invalid(f"{path}: value '{cand}' does not match template '{tpl}'")
        for name, value in m.groupdict().items():
            if params.setdefault(name, value) != value:
                raise Invalid(f"{path}: {name} must be '{params[name]}' everywhere, found '{value}'")
    elif tpl != cand or type(tpl) is not type(cand):
        raise Invalid(f"{path}: must be {json.dumps(tpl)}")


def mode_rules(kind, configs, params):
    if kind != "jdbc-source":
        return
    mode = params["MODE"]
    for key, needed in (("incrementing.column.name", "incrementing" in mode),
                        ("timestamp.column.name", "timestamp" in mode)):
        if needed and key not in configs:
            raise Invalid(f"mode '{mode}' requires '{key}'")
        if not needed and key in configs:
            raise Invalid(f"mode '{mode}' does not use '{key}' – remove it")


def validate_connector(file: Path, templates: dict, registry: dict) -> str:
    try:
        doc = json.loads(file.read_text())
    except json.JSONDecodeError as e:
        raise Invalid(f"invalid JSON: {e}")
    if not isinstance(doc, dict):
        raise Invalid("expected a JSON object")
    cls = (doc.get("spec") or {}).get("class")
    kind = next((k for k, t in templates.items() if t["spec"]["class"] == cls), None)
    if kind is None:
        raise Invalid(f"connector class '{cls}' is not provided by any template")
    params = {}
    match(templates[kind], doc, "$", params, OPTIONAL_KEYS.get(kind, set()))
    mode_rules(kind, doc["spec"]["configs"], params)

    name = params["CONNECTOR_NAME"]
    if file.name != f"{name}.json":
        raise Invalid(f"file must be named {name}.json")
    entry = registry.get(name)
    if entry is None:
        raise Invalid(f"connector '{name}' is not registered in {REGISTRY} – ask an admin to onboard it")
    if entry.get("type") != kind:
        raise Invalid(f"connector '{name}' is registered as type '{entry.get('type')}', not '{kind}'")
    if params["TOPIC"] not in entry.get("topics", []):
        raise Invalid(f"topic '{params['TOPIC']}' is not granted to '{name}' (allowed: {entry.get('topics', [])})")
    return name


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trusted", default=".", help="checkout providing templates/ and the registry")
    ap.add_argument("--candidate", default=".", help="checkout providing connectors/")
    args = ap.parse_args()
    trusted, candidate = Path(args.trusted), Path(args.candidate)

    templates = {p.stem: json.loads(p.read_text()) for p in sorted((trusted / "templates").glob("*.json"))}
    registry = (yaml.safe_load((trusted / REGISTRY).read_text()) or {}).get("connectors") or {}
    cdir = candidate / "connectors"
    errors = []

    for p in sorted(cdir.iterdir()):
        if p.is_dir() or (p.suffix != ".json" and p.name not in {"kustomization.yaml", "README.md"}):
            errors.append(f"connectors/{p.name}: only <name>.json files are allowed in connectors/")

    json_files = sorted(cdir.glob("*.json"))
    for f in json_files:
        try:
            name = validate_connector(f, templates, registry)
            print(f"OK   connectors/{f.name} ({registry[name]['type']})")
        except Invalid as e:
            errors.append(f"connectors/{f.name}: {e}")

    kust = yaml.safe_load((cdir / "kustomization.yaml").read_text()) or {}
    listed = sorted(kust.get("resources") or [])
    expected = sorted(f.name for f in json_files)
    if listed != expected:
        errors.append(f"connectors/kustomization.yaml: resources must list exactly {expected}, found {listed}")
    if set(kust) - {"apiVersion", "kind", "resources"}:
        errors.append("connectors/kustomization.yaml: only apiVersion, kind and resources are allowed")

    for e in errors:
        print(f"FAIL {e}")
    print(f"{len(json_files)} connector(s) checked, {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
