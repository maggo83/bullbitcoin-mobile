#!/usr/bin/env python3
"""Collect, resolve, and apply conflicting translations in a review JSON file.

This script uses only the Python standard library. It expects each reviewed
message to have adjacent <key>_en, <key>_de, and <key>_uniqueId values.

Usage:
  python3 tools/reconcile_translation_review.py collect REVIEW_JSON CONFLICTS_JSON
  python3 tools/reconcile_translation_review.py resolve CONFLICTS_JSON
  python3 tools/reconcile_translation_review.py apply CONFLICTS_JSON REVIEW_JSON
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any


CONFLICTS_FORMAT = "bull-translation-review-conflicts-v1"


class ReviewError(Exception):
    """Raised when a review or conflict document is unsafe to process."""


def _read_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ReviewError(f"Cannot read {label} {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ReviewError(f"{label.capitalize()} {path} is not valid JSON: {error}") from error

    if not isinstance(value, dict):
        raise ReviewError(f"{label.capitalize()} {path} must contain a JSON object.")
    return value


def _require_string(value: Any, context: str) -> str:
    if not isinstance(value, str):
        raise ReviewError(f"{context} must be a string.")
    return value


def _require_positive_int(value: Any, context: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ReviewError(f"{context} must be a positive integer.")
    return value


def _require_locale(locale: str, flag: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*", locale):
        raise ReviewError(f"{flag} must be a locale tag such as en, de, or pt_BR.")
    return locale


def _validate_review_header(
    review: Mapping[str, Any],
    base_locale: str,
    target_locale: str,
) -> None:
    header = review.get("@@review")
    if not isinstance(header, dict):
        raise ReviewError('Review must contain an object-valued "@@review" header.')

    actual_base = header.get("baseLocale")
    actual_target = header.get("secondaryLocale")
    if actual_base != base_locale or actual_target != target_locale:
        raise ReviewError(
            'Review locales do not match the requested locales: expected '
            f"{base_locale}/{target_locale}, found {actual_base}/{actual_target}."
        )


def _review_groups(
    review: Mapping[str, Any],
    base_locale: str,
    target_locale: str,
) -> dict[int, list[dict[str, str]]]:
    unique_id_suffix = "_uniqueId"
    groups: dict[int, list[dict[str, str]]] = {}

    for review_key, raw_unique_id in review.items():
        if not review_key.endswith(unique_id_suffix):
            continue

        source_key = review_key[: -len(unique_id_suffix)]
        if not source_key:
            raise ReviewError(f'Invalid unique ID key "{review_key}".')
        unique_id = _require_positive_int(raw_unique_id, f'Unique ID "{review_key}"')
        base_key = f"{source_key}_{base_locale}"
        target_key = f"{source_key}_{target_locale}"
        base_value = _require_string(review.get(base_key), f'Base value "{base_key}"')
        target_value = _require_string(
            review.get(target_key),
            f'Target value "{target_key}"',
        )
        groups.setdefault(unique_id, []).append(
            {
                "sourceKey": source_key,
                "baseValue": base_value,
                "targetValue": target_value,
            }
        )

    if not groups:
        raise ReviewError("Review has no <key>_uniqueId entries.")

    for unique_id, entries in groups.items():
        base_values = {entry["baseValue"] for entry in entries}
        if len(base_values) != 1:
            raise ReviewError(
                f"Unique ID {unique_id} is assigned to different base-language values."
            )

    return groups


def _conflict_document(
    review_path: Path,
    review: Mapping[str, Any],
    base_locale: str,
    target_locale: str,
) -> dict[str, Any]:
    groups = _review_groups(review, base_locale, target_locale)
    conflicts: list[dict[str, Any]] = []

    for unique_id in sorted(groups):
        entries = groups[unique_id]
        translations: dict[str, list[str]] = {}
        for entry in entries:
            translations.setdefault(entry["targetValue"], []).append(entry["sourceKey"])

        if len(entries) < 2 or len(translations) < 2:
            continue

        conflicts.append(
            {
                "uniqueId": unique_id,
                "english": entries[0]["baseValue"],
                "keys": [entry["sourceKey"] for entry in entries],
                "candidates": [
                    {"german": german, "keys": keys}
                    for german, keys in translations.items()
                ],
                "canonicalGerman": None,
            }
        )

    return {
        "format": CONFLICTS_FORMAT,
        "review": {
            "path": str(review_path),
            "baseLocale": base_locale,
            "targetLocale": target_locale,
        },
        "conflicts": conflicts,
    }


def _atomic_write(path: Path, contents: str, preserve_mode_from: Path | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        text=True,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8", newline="") as output:
            output.write(contents)
        if preserve_mode_from is not None:
            temporary_path.chmod(stat.S_IMODE(preserve_mode_from.stat().st_mode))
        os.replace(temporary_path, path)
    except OSError as error:
        temporary_path.unlink(missing_ok=True)
        raise ReviewError(f"Cannot write {path}: {error}") from error


def _write_json(path: Path, document: Mapping[str, Any]) -> None:
    contents = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    _atomic_write(path, contents)


def _validate_conflicts_document(document: Mapping[str, Any]) -> tuple[str, str, list[dict[str, Any]]]:
    if document.get("format") != CONFLICTS_FORMAT:
        raise ReviewError(
            f"Conflict document format must be {CONFLICTS_FORMAT!r}."
        )

    review = document.get("review")
    if not isinstance(review, dict):
        raise ReviewError('Conflict document must contain an object-valued "review" field.')
    base_locale = _require_locale(
        _require_string(review.get("baseLocale"), 'Conflict review field "baseLocale"'),
        'Conflict review field "baseLocale"',
    )
    target_locale = _require_locale(
        _require_string(review.get("targetLocale"), 'Conflict review field "targetLocale"'),
        'Conflict review field "targetLocale"',
    )

    conflicts = document.get("conflicts")
    if not isinstance(conflicts, list):
        raise ReviewError('Conflict document field "conflicts" must be a list.')

    seen_ids: set[int] = set()
    for conflict in conflicts:
        if not isinstance(conflict, dict):
            raise ReviewError("Each conflict must be an object.")
        unique_id = _require_positive_int(conflict.get("uniqueId"), "Conflict uniqueId")
        if unique_id in seen_ids:
            raise ReviewError(f"Conflict document contains duplicate unique ID {unique_id}.")
        seen_ids.add(unique_id)
        _require_string(conflict.get("english"), f"Conflict {unique_id} English value")

        keys = conflict.get("keys")
        if not isinstance(keys, list) or not keys:
            raise ReviewError(f"Conflict {unique_id} must contain at least one source key.")
        if len(keys) != len(set(keys)):
            raise ReviewError(f"Conflict {unique_id} contains duplicate source keys.")
        for source_key in keys:
            _require_string(source_key, f"Conflict {unique_id} source key")

        candidates = conflict.get("candidates")
        if not isinstance(candidates, list) or len(candidates) < 2:
            raise ReviewError(f"Conflict {unique_id} must contain at least two candidates.")
        candidate_values: set[str] = set()
        candidate_source_keys: list[str] = []
        for candidate in candidates:
            if not isinstance(candidate, dict):
                raise ReviewError(f"Conflict {unique_id} candidate must be an object.")
            german = _require_string(candidate.get("german"), f"Conflict {unique_id} German candidate")
            if german in candidate_values:
                raise ReviewError(f"Conflict {unique_id} contains duplicate German candidates.")
            candidate_values.add(german)
            candidate_keys = candidate.get("keys")
            if not isinstance(candidate_keys, list) or not candidate_keys:
                raise ReviewError(f"Conflict {unique_id} candidate must contain source keys.")
            for source_key in candidate_keys:
                _require_string(source_key, f"Conflict {unique_id} candidate source key")
                candidate_source_keys.append(source_key)
        if len(candidate_source_keys) != len(set(candidate_source_keys)):
            raise ReviewError(f"Conflict {unique_id} candidates contain duplicate source keys.")
        if set(candidate_source_keys) != set(keys):
            raise ReviewError(
                f"Conflict {unique_id} candidate source keys do not match the conflict source keys."
            )

        canonical_german = conflict.get("canonicalGerman")
        if canonical_german is not None:
            _require_string(canonical_german, f"Conflict {unique_id} canonical German value")

    return base_locale, target_locale, conflicts


def _print_conflict(conflict: Mapping[str, Any], position: int, total: int) -> None:
    unique_id = conflict["uniqueId"]
    print(f"\n[{position}/{total}] Unique ID {unique_id}")
    print(f"English: {json.dumps(conflict['english'], ensure_ascii=False)}")
    for index, candidate in enumerate(conflict["candidates"], start=1):
        print(f"{index}. {json.dumps(candidate['german'], ensure_ascii=False)}")
        print(f"   Keys: {', '.join(candidate['keys'])}")
    canonical_german = conflict.get("canonicalGerman")
    if canonical_german is not None:
        print(f"Current canonical value: {json.dumps(canonical_german, ensure_ascii=False)}")


def _resolve_conflicts(conflicts_path: Path) -> None:
    document = _read_json_object(conflicts_path, "conflict document")
    _, _, conflicts = _validate_conflicts_document(document)

    if not conflicts:
        print("No competing translations were collected.")
        return

    print("Choose a candidate number, n for a new German translation, s to skip, or q to stop.")
    for position, conflict in enumerate(conflicts, start=1):
        _print_conflict(conflict, position, len(conflicts))
        while True:
            choice = input("Choice: ").strip().lower()
            if choice == "q":
                print("Stopped. Choices saved before this prompt remain in the conflict document.")
                return
            if choice == "s":
                break
            if choice == "n":
                conflict["canonicalGerman"] = input("Canonical German translation: ")
                _write_json(conflicts_path, document)
                break
            if choice.isdigit():
                candidate_index = int(choice) - 1
                candidates = conflict["candidates"]
                if 0 <= candidate_index < len(candidates):
                    conflict["canonicalGerman"] = candidates[candidate_index]["german"]
                    _write_json(conflicts_path, document)
                    break
            print("Enter a displayed candidate number, n, s, or q.")

    print(f"Saved resolutions to {conflicts_path}.")


def _validate_conflict_against_review(
    conflict: Mapping[str, Any],
    review_groups: Mapping[int, list[dict[str, str]]],
) -> list[dict[str, str]]:
    unique_id = conflict["uniqueId"]
    entries = review_groups.get(unique_id)
    if entries is None:
        raise ReviewError(f"Review no longer contains unique ID {unique_id}.")

    expected_keys = set(conflict["keys"])
    actual_keys = {entry["sourceKey"] for entry in entries}
    if actual_keys != expected_keys:
        raise ReviewError(
            f"Unique ID {unique_id} no longer has the source keys recorded in the conflict document."
        )

    actual_english = {entry["baseValue"] for entry in entries}
    if actual_english != {conflict["english"]}:
        raise ReviewError(
            f"Unique ID {unique_id} no longer has the recorded English value."
        )

    expected_candidates = {candidate["german"] for candidate in conflict["candidates"]}
    actual_candidates = {entry["targetValue"] for entry in entries}
    if actual_candidates != expected_candidates:
        raise ReviewError(
            f"Unique ID {unique_id} has changed since collection. Collect conflicts again before applying."
        )

    return entries


def _replace_review_values(
    review_path: Path,
    replacements: Mapping[str, str],
) -> None:
    contents = review_path.read_text(encoding="utf-8")
    updated_contents = contents

    for review_key, replacement in replacements.items():
        encoded_key = json.dumps(review_key, ensure_ascii=False)
        pattern = re.compile(
            rf"^(?P<prefix>\s*{re.escape(encoded_key)}\s*:\s*)"
            r'(?P<value>"(?:\\.|[^"\\\r\n])*")(?P<suffix>\s*,?\s*)$',
            re.MULTILINE,
        )
        matches = list(pattern.finditer(updated_contents))
        if len(matches) != 1:
            raise ReviewError(
                f"Expected exactly one single-line JSON value for {review_key}; found {len(matches)}."
            )

        match = matches[0]
        try:
            previous_value = json.loads(match.group("value"))
        except json.JSONDecodeError as error:
            raise ReviewError(f"Cannot decode JSON value for {review_key}: {error}") from error
        if not isinstance(previous_value, str):
            raise ReviewError(f"Review value {review_key} is not a string.")

        encoded_replacement = json.dumps(replacement, ensure_ascii=False)
        updated_contents = (
            updated_contents[: match.start()]
            + match.group("prefix")
            + encoded_replacement
            + match.group("suffix")
            + updated_contents[match.end() :]
        )

    try:
        updated_review = json.loads(updated_contents)
    except json.JSONDecodeError as error:
        raise ReviewError(f"Refusing to write invalid JSON to {review_path}: {error}") from error
    if not isinstance(updated_review, dict):
        raise ReviewError(f"Refusing to write non-object JSON to {review_path}.")
    for review_key, replacement in replacements.items():
        if updated_review.get(review_key) != replacement:
            raise ReviewError(f"Replacement verification failed for {review_key}.")

    _atomic_write(review_path, updated_contents, preserve_mode_from=review_path)


def _apply_resolutions(conflicts_path: Path, review_path: Path, dry_run: bool) -> None:
    document = _read_json_object(conflicts_path, "conflict document")
    base_locale, target_locale, conflicts = _validate_conflicts_document(document)
    review = _read_json_object(review_path, "review")
    _validate_review_header(review, base_locale, target_locale)
    review_groups = _review_groups(review, base_locale, target_locale)

    replacements: dict[str, str] = {}
    resolved_ids: list[int] = []
    for conflict in conflicts:
        canonical_german = conflict.get("canonicalGerman")
        if canonical_german is None:
            continue
        entries = _validate_conflict_against_review(conflict, review_groups)
        unique_id = conflict["uniqueId"]
        resolved_ids.append(unique_id)
        for entry in entries:
            if entry["targetValue"] != canonical_german:
                replacements[f"{entry['sourceKey']}_{target_locale}"] = canonical_german

    if not resolved_ids:
        print("No canonical translations selected; review was not changed.")
        return
    if dry_run:
        print(
            f"[dry-run] would update {len(replacements)} German values across "
            f"{len(resolved_ids)} resolved unique IDs in {review_path}"
        )
        return
    if not replacements:
        print("All selected canonical translations are already applied.")
        return

    _replace_review_values(review_path, replacements)
    print(
        f"Applied {len(replacements)} German values across "
        f"{len(resolved_ids)} resolved unique IDs in {review_path}"
    )


def _collect_conflicts(
    review_path: Path,
    conflicts_path: Path,
    base_locale: str,
    target_locale: str,
    overwrite: bool,
) -> None:
    if conflicts_path.exists() and not overwrite:
        raise ReviewError(
            f"Conflict document {conflicts_path} already exists. Use --overwrite to replace it."
        )

    review = _read_json_object(review_path, "review")
    _validate_review_header(review, base_locale, target_locale)
    document = _conflict_document(review_path, review, base_locale, target_locale)
    _write_json(conflicts_path, document)
    print(
        f"Collected {len(document['conflicts'])} conflicting unique IDs in {conflicts_path}"
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Reconcile competing translations for shared review unique IDs."
    )
    commands = parser.add_subparsers(dest="command", required=True)

    collect = commands.add_parser(
        "collect",
        help="write a conflict document for shared IDs with competing translations",
    )
    collect.add_argument("review_json", type=Path)
    collect.add_argument("conflicts_json", type=Path)
    collect.add_argument("--base-locale", default="en")
    collect.add_argument("--target-locale", default="de")
    collect.add_argument("--overwrite", action="store_true")

    resolve = commands.add_parser(
        "resolve",
        help="interactively select canonical translations in a conflict document",
    )
    resolve.add_argument("conflicts_json", type=Path)

    apply = commands.add_parser(
        "apply",
        help="apply selected canonical translations to the review JSON",
    )
    apply.add_argument("conflicts_json", type=Path)
    apply.add_argument("review_json", type=Path)
    apply.add_argument("--dry-run", action="store_true")

    return parser


def _run(arguments: argparse.Namespace) -> None:
    if arguments.command == "collect":
        _collect_conflicts(
            arguments.review_json,
            arguments.conflicts_json,
            _require_locale(arguments.base_locale, "--base-locale"),
            _require_locale(arguments.target_locale, "--target-locale"),
            arguments.overwrite,
        )
    elif arguments.command == "resolve":
        _resolve_conflicts(arguments.conflicts_json)
    elif arguments.command == "apply":
        _apply_resolutions(
            arguments.conflicts_json,
            arguments.review_json,
            arguments.dry_run,
        )
    else:
        raise ReviewError(f"Unknown command {arguments.command!r}.")


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    arguments = parser.parse_args(argv)
    try:
        _run(arguments)
    except ReviewError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())