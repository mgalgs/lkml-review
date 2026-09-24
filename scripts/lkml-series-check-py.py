#!/usr/bin/env python3
"""lkml-series-check-py.py -- helper for lkml-series-check.sh (plumbing).

Usage: lkml-series-check-py.py <old.py> <new.py>

Exit 0 when the two Python sources differ only in comments, docstrings
and layout: their ASTs are equal once every docstring (the first
statement of a module, class or function body, when it is a bare string
expression) is removed. Exit 1 in every other case, including a file
that does not parse -- the caller is conservative and never refuses a
change it cannot prove is comment-only.

The sources are parsed with ast.parse, which does not execute them.
"""
import ast
import sys


def strip_docstrings(tree):
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)):
            continue
        body = node.body
        if (body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)):
            del body[0]
    return tree


def dump(path):
    with open(path, "rb") as fh:
        return ast.dump(strip_docstrings(ast.parse(fh.read())))


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return 0 if dump(argv[1]) == dump(argv[2]) else 1
    except Exception:
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
