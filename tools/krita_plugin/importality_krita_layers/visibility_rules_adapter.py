from __future__ import annotations

import json
from typing import Any, Dict, Iterable, List, Mapping

ANNOTATION_TYPE = "org.evelynlimab.krita.sprite_visibility_rules"
SUPPORTED_SCHEMA_VERSION = 1


def _as_bytes(value: Any) -> bytes:
    try:
        return bytes(value)
    except TypeError:
        data = value.data() if hasattr(value, "data") else value
        return bytes(data)


def _node_id(node: Any) -> str:
    value = node.uniqueId()
    if hasattr(value, "toString"):
        value = value.toString()
    return str(value)


def load_rules(document: Any) -> Dict[str, Any]:
    try:
        annotation_types = list(document.annotationTypes())
    except Exception:
        return {"schema_version": SUPPORTED_SCHEMA_VERSION, "plugin": ANNOTATION_TYPE, "rules": [], "warnings": ["Krita annotations are unavailable."]}
    if ANNOTATION_TYPE not in annotation_types:
        return {"schema_version": SUPPORTED_SCHEMA_VERSION, "plugin": ANNOTATION_TYPE, "rules": [], "warnings": []}
    try:
        raw = _as_bytes(document.annotation(ANNOTATION_TYPE))
        payload = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        return {"schema_version": SUPPORTED_SCHEMA_VERSION, "plugin": ANNOTATION_TYPE, "rules": [], "warnings": [f"Could not read visibility rules: {exc}"]}
    if not isinstance(payload, dict):
        return {"schema_version": SUPPORTED_SCHEMA_VERSION, "plugin": ANNOTATION_TYPE, "rules": [], "warnings": ["Visibility-rules annotation is not a JSON object."]}
    version = payload.get("schema_version")
    if version != SUPPORTED_SCHEMA_VERSION:
        return {"schema_version": SUPPORTED_SCHEMA_VERSION, "plugin": ANNOTATION_TYPE, "rules": [], "warnings": [f"Unsupported visibility-rules schema version: {version!r}"]}
    rules = payload.get("rules", [])
    if not isinstance(rules, list):
        return {"schema_version": version, "plugin": ANNOTATION_TYPE, "rules": [], "warnings": ["Visibility-rules 'rules' field is not a list."]}
    return {
        "schema_version": version,
        "plugin": ANNOTATION_TYPE,
        "plugin_version": payload.get("plugin_version"),
        "rules": rules,
        "warnings": [],
    }


def walk_nodes(root: Any) -> Iterable[Any]:
    stack = list(reversed(list(root.childNodes())))
    while stack:
        node = stack.pop()
        yield node
        stack.extend(reversed(list(node.childNodes())))


def _collect_export_root(document: Any) -> Any:
    matches = [n for n in list(document.rootNode().childNodes()) if n.name().strip() == "@export"]
    if len(matches) != 1 or matches[0].type() != "grouplayer":
        return None
    return matches[0]


def collect_export_bindings(document: Any) -> Dict[str, List[str]]:
    export_root = _collect_export_root(document)
    if export_root is None:
        return {}
    bindings: Dict[str, List[str]] = {}
    for slot_node in list(export_root.childNodes()):
        if slot_node.type() != "grouplayer":
            continue
        raw_slot = slot_node.name().strip()
        additive = raw_slot.startswith("+")
        slot_name = raw_slot[1:] if additive else raw_slot
        for variant_node in list(slot_node.childNodes()):
            raw_variant = variant_node.name().strip()
            is_default = raw_variant.startswith("*")
            variant_name = raw_variant[1:] if is_default else raw_variant
            animation_name = "%s%s/%s%s" % (
                "+" if additive else "", slot_name,
                "*" if is_default else "", variant_name,
            )
            bindings.setdefault(_node_id(variant_node), []).append(animation_name)
    return bindings


def descendant_ids(node: Any) -> List[str]:
    return [_node_id(child) for child in walk_nodes(node)]


def build_node_index(document: Any) -> Dict[str, Any]:
    return {_node_id(node): node for node in walk_nodes(document.rootNode())}


def bind_rules_to_exports(document: Any, exported_nodes: Mapping[str, List[str]]) -> Dict[str, Any]:
    payload = load_rules(document)
    index = build_node_index(document)
    node_bindings: Dict[str, List[str]] = {str(key): list(value) for key, value in exported_nodes.items()}

    for node_id, node in index.items():
        if node_id in node_bindings:
            continue
        descendants: List[str] = []
        for descendant_id in descendant_ids(node):
            descendants.extend(node_bindings.get(descendant_id, []))
        if descendants:
            node_bindings[node_id] = list(dict.fromkeys(descendants))

    warnings = list(payload.get("warnings", []))
    bound_rules: List[Dict[str, Any]] = []
    for rule in payload.get("rules", []):
        if not isinstance(rule, dict):
            warnings.append("Skipped a non-object visibility rule.")
            continue
        bound_rule = dict(rule)
        members: List[Dict[str, Any]] = []
        for member in rule.get("members", []):
            if not isinstance(member, dict):
                warnings.append(f"Rule {rule.get('name', 'Unnamed rule')} has an invalid member entry.")
                continue
            member_id = str(member.get("id", ""))
            binding = list(node_bindings.get(member_id, []))
            if not binding:
                warnings.append(
                    f"Rule {rule.get('name', 'Unnamed rule')} member {member.get('name', member_id)!r} is not exported."
                )
            members.append({"id": member_id, "name": str(member.get("name", "Unnamed layer")), "animations": binding})
        bound_rule["members"] = members
        bound_rules.append(bound_rule)

    payload["warnings"] = warnings
    payload["rules"] = bound_rules
    payload["node_bindings"] = node_bindings
    return payload
