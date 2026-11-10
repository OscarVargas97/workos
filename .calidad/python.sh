# ia-qa, perfil python: ruff (lint y formato), mypy si está configurado, pytest, import-linter si hay contratos.
python_tiene() { grep -q "$1" pyproject.toml setup.cfg mypy.ini .importlinter 2>/dev/null; }

python_rapidos() {
  echo "== ruff"
  py_tool ruff check --output-format concise .
  py_tool ruff format --check .
}

python_ci() {
  python_rapidos
  if python_tiene '\[tool.mypy\]\|\[mypy\]'; then echo "== mypy"; py_tool mypy .; fi
  if python_tiene '\[importlinter\]\|\[tool.importlinter\]'; then echo "== import-linter"; py_tool --from import-linter lint-imports; fi
  # Solo con tests de Python: un tests/ con .sh o .nix no es de pytest.
  if find tests test -name '*.py' 2>/dev/null | grep -q . || python_tiene '\[tool.pytest'; then
    echo "== pytest"
    if [ -f pyproject.toml ] && command -v uv >/dev/null 2>&1; then uv run --with pytest pytest -q
    else python -m pip install -q -e . pytest 2>/dev/null || python -m pip install -q pytest; python -m pytest -q; fi
  fi
}
