"""Ownership rules (config/ownership_rules.csv): sample owner names -> expected class.

The pipeline applies these rules in SQL with Postgres regexes. Here they're applied with
Python's `re` using the same first-match-by-priority semantics. The rules are written to
mean the same thing in both dialects (no \\b, which Postgres reads as backspace).
"""

import csv
import re

import pytest

from shore import config


def load_rules():
    with open(config.CONFIG / "ownership_rules.csv", newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return sorted(rows, key=lambda r: int(r["priority"]))


RULES = load_rules()


def classify(owner: str) -> tuple[str, str]:
    owner = owner.strip().upper()
    for rule in RULES:
        if re.search(rule["pattern"], owner):
            return rule["class"], rule["label"]
    raise AssertionError("the fallback rule should always match")


@pytest.mark.parametrize(
    ("owner", "expected_class"),
    [
        ("CITY OF MADISON PARKS HENRY VILAS BEACH & ZOO", "municipal"),
        ("CITY OF MADISON ENGINEER STORMWATER UTILITY 533", "municipal"),
        ("MADISON, CITY OF", "municipal"),
        ("VILLAGE OF MAPLE BLUFF", "municipal"),
        ("DANE COUNTY", "county"),
        ("DANE, COUNTY OF", "county"),
        ("COUNTY OF DANE", "county"),
        ("DANE COUNTY GROWERS", "private"),
        ("BECKS ENTERPRISES OF DANE COUNTY LLC", "private"),
        ("UW REGENTS ARBORETUM VAN HISE HALL #1860", "university"),
        ("BOARD OF REGENTS OF UNIV OF WIS SYSTEM", "university"),
        ("WI DNR", "state"),
        ("STATE OF WISCONSIN DEPT OF NATURAL RESOURCES", "state"),
        ("UNITED STATES OF AMERICA", "federal"),
        ("MADISON METROPOLITAN SCHOOL DISTRICT", "school_district"),
        ("MADISON METROPOLITAN SEWERAGE DISTRICT", "utility"),
        ("EDGEWOOD CONDO ASSN INC", "private"),
        ("LAKE VIEW HOME OWNERS ASSOCIATION INC", "private"),
        ("NOT AVAILABLE", "unknown"),
        ("KUBLY QPRT TRUST, RYAN", "private"),
        ("FRIDAY INVESTMENTS LLC", "private"),
    ],
)
def test_class(owner, expected_class):
    assert classify(owner)[0] == expected_class


@pytest.mark.parametrize(
    ("owner", "expected_label"),
    [
        ("EDGEWOOD COLLEGE INC", "Edgewood College"),
        ("EDGEWOOD CONDO ASSN INC", "Condo / HOA"),
        ("ST MARYS CATHOLIC CHURCH", "Church"),
        ("UW REGENTS ARBORETUM RE DEV & ADMIN UW MADISON", "UW–Madison"),
        ("SMITH, JOHN", "Private"),
    ],
)
def test_label(owner, expected_label):
    assert classify(owner)[1] == expected_label


def test_priorities_unique():
    priorities = [r["priority"] for r in RULES]
    assert len(priorities) == len(set(priorities))


def test_patterns_avoid_backslash_b():
    # \b is a word boundary in Python but backspace in Postgres regexes.
    assert not [r["pattern"] for r in RULES if r"\b" in r["pattern"]]
