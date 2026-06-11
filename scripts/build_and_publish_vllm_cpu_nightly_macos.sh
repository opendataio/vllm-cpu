#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Build & publish a CPU-only vLLM wheel as `vllm-cpu-nightly` to PyPI,
# this time for **macOS arm64 (Apple silicon)**.
#
# Why a separate script (instead of cross-compiling from devcloud):
#   * macOS wheels MUST be linked against Apple's libSystem and the macOS
#     SDK, which only exists on a real Mac (no manylinux trick possible).
#   * vLLM's CPU build relies on torch.utils.cpp_extension, which in turn
#     calls clang++ on the host — there is no usable cross-compiler from
#     Linux to mac arm64.
# So this script is meant to be executed on the maintainer's M1/M2 macbook
# directly (no containerization).
#
# Strategy:
#   1. Use a fresh python 3.12 venv (isolates from any conda base / system
#      site-packages) under WORK_DIR. We deliberately do NOT install into
#      the host python.
#   2. Clone vLLM `main` (the latest tip) and rename the distribution to
#      `vllm-cpu-nightly` by patching pyproject.toml BEFORE the build
#      runs. The python import name (`import vllm`) is preserved.
#   3. Build the wheel with a minute-stamped PEP-440 dev version:
#        `<base>.devN<YYYYMMDDHHMM>`
#      That number is monotonically increasing, so `pip install --upgrade
#      vllm-cpu-nightly` always picks the newest one regardless of which
#      platform produced it (PyPI hosts linux + mac wheels under the same
#      version stream, pip resolves the right one per-runner).
#   4. Force `MACOSX_DEPLOYMENT_TARGET=11.0` so the resulting wheel is
#      tagged `macosx_11_0_arm64` and is installable on every macOS
#      version that GitHub-hosted `macos-latest` runners use (currently
#      macOS 14, but the same wheel works on 11+).
#   5. Twine-upload to PyPI using the API token from
#      /Users/msy/pypi_apikey (override via PYPI_TOKEN_FILE).
#
# Usage (on the local Mac):
#   bash .github/workflows/build_and_publish_vllm_cpu_nightly_macos.sh
#
# Optional env overrides:
#   PYPI_TOKEN_FILE   default: /Users/msy/pypi_apikey
#   PKG_NAME          default: vllm-cpu-nightly
#   VLLM_GIT_REF      default: main      (set to a tag/sha to pin)
#   SKIP_UPLOAD       default: 0         (set to 1 for a dry-run build)
#   WORK_DIR          default: $HOME/.cache/vllm-cpu-nightly-build-macos
#   PYTHON_BIN        default: auto-detect python3.12 in PATH
#   MACOSX_DEPLOYMENT_TARGET  default: 11.0
# ----------------------------------------------------------------------------
set -euo pipefail

PYPI_TOKEN_FILE="${PYPI_TOKEN_FILE:-/Users/msy/pypi_apikey}"
PKG_NAME="${PKG_NAME:-vllm-cpu-nightly}"
VLLM_GIT_REF="${VLLM_GIT_REF:-main}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
WORK_DIR="${WORK_DIR:-$HOME/.cache/vllm-cpu-nightly-build-macos}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3.12 || true)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Sanity checks ----------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "This script must run on macOS."
[[ "$(uname -m)" == "arm64" ]] \
    || die "This script targets Apple silicon (arm64); host is $(uname -m)."
[[ -n "${PYTHON_BIN}" && -x "${PYTHON_BIN}" ]] \
    || die "python3.12 not found in PATH (override with PYTHON_BIN=...)"
"${PYTHON_BIN}" -c 'import sys; assert sys.version_info[:2] == (3, 12), sys.version' \
    || die "PYTHON_BIN must be python 3.12"
command -v git    >/dev/null || die "git is required"
command -v cargo  >/dev/null \
    || die "cargo (rustup) is required for vLLM's setuptools-rust frontend"
xcode-select -p >/dev/null 2>&1 \
    || die "Xcode command line tools required (run: xcode-select --install)"

[[ -f "${PYPI_TOKEN_FILE}" ]] || die "PyPI token file not found: ${PYPI_TOKEN_FILE}"
PYPI_TOKEN="$(tr -d '[:space:]' < "${PYPI_TOKEN_FILE}")"
[[ -n "${PYPI_TOKEN}" ]] || die "PyPI token file is empty"

mkdir -p "${WORK_DIR}"
SRC_DIR="${WORK_DIR}/vllm"
VENV_DIR="${WORK_DIR}/venv"
OUT_DIR="${WORK_DIR}/dist"
mkdir -p "${OUT_DIR}"

STAMP_FULL="$(date -u +%Y%m%d%H%M)"

# --- 1. Bootstrap an isolated venv -----------------------------------------
log "Creating venv at ${VENV_DIR} (python: ${PYTHON_BIN})..."
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
python -m pip install --upgrade pip wheel setuptools build twine >/dev/null

# --- 2. Clone vLLM ----------------------------------------------------------
log "Cloning vLLM @ ${VLLM_GIT_REF} -> ${SRC_DIR}..."
rm -rf "${SRC_DIR}"
git clone --depth 1 --branch "${VLLM_GIT_REF}" \
    https://github.com/vllm-project/vllm.git "${SRC_DIR}" 2>/dev/null \
    || git clone https://github.com/vllm-project/vllm.git "${SRC_DIR}"
cd "${SRC_DIR}"
if [[ "${VLLM_GIT_REF}" != "main" ]]; then
    git checkout "${VLLM_GIT_REF}"
fi
VLLM_COMMIT="$(git rev-parse HEAD)"
log "vLLM commit: ${VLLM_COMMIT}"

# --- 3. Patch distribution name + nightly version --------------------------
log "Patching distribution name -> ${PKG_NAME} and computing nightly version..."

# Determine the upstream version that setuptools-scm would have produced
# for this commit. We deliberately do NOT trust setuptools-scm: a shallow
# clone has no reachable tag and scm falls back to "0.1.dev1", which PyPI
# would treat as older than every real release. Instead we fetch all tags
# and bump the latest stable tag's patch by 1 (vLLM `main` is always
# post-release).
git fetch --tags --depth=1 origin >/dev/null 2>&1 || true
LAST_STABLE="$(git tag --sort=-v:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
LAST_STABLE="${LAST_STABLE:-v0.0.0}"
BASE_RAW="${LAST_STABLE#v}"
BASE_VER="$(awk -v v="${BASE_RAW}" 'BEGIN {
    n = split(v, a, ".");
    printf "%d.%d.%d", a[1], a[2], a[3] + 1;
}')"
NIGHTLY_VER="${BASE_VER}.dev${STAMP_FULL}"
log "  last stable tag : ${LAST_STABLE}"
log "  nightly version : ${NIGHTLY_VER}  (minute-stamped, monotonic)"

# Rename only [project].name in pyproject.toml; the import package
# (`vllm/`) is untouched so `import vllm` still works for consumers.
PKG_NAME="${PKG_NAME}" python - <<'PY'
import os, pathlib, re
pkg = os.environ["PKG_NAME"]
p = pathlib.Path("pyproject.toml")
txt = p.read_text()
new = re.sub(r"^(\s*name\s*=\s*[\"'])vllm([\"'])",
             lambda m: m.group(1) + pkg + m.group(2),
             txt, count=1, flags=re.MULTILINE)
assert new != txt, "failed to patch pyproject.toml name"
p.write_text(new)
print(f"Patched name -> {pkg} in pyproject.toml")
PY

# Patch requirements/cpu.txt: PyPI rejects wheels whose deps carry a
# PEP 440 local label like `torch==2.11.0+cpu`. Strip the +cpu suffix;
# downstream installers can still pull the cpu wheel with
# `--extra-index-url https://download.pytorch.org/whl/cpu`. macOS arm64
# wheels of torch live on plain PyPI without the +cpu label anyway, so
# this is correct on both platforms.
if [[ -f requirements/cpu.txt ]]; then
    sed -i.bak -E 's/torch==([0-9.]+)\+cpu/torch==\1/g' requirements/cpu.txt
    rm -f requirements/cpu.txt.bak
    echo "--- patched requirements/cpu.txt ---"
    grep -E '^torch' requirements/cpu.txt || true
fi

# --- 4. Install build deps + torch(cpu) -------------------------------------
log "Installing build deps + torch(cpu) into venv..."
# Without build isolation we must install everything that pyproject.toml
# [build-system].requires asks for ourselves.
pip install \
    "cmake>=3.26.1" ninja "packaging>=24.2" \
    "setuptools>=77.0.3,<81.0.0" "setuptools-scm>=8.0" \
    "setuptools-rust>=1.9.0" wheel jinja2 >/dev/null
# Plain torch so vLLM's setup.py can `import torch`. On macOS arm64 the
# default PyPI wheel is already CPU-only (no CUDA variant exists for mac).
pip install "numpy<2" >/dev/null
pip install torch==2.11.0 >/dev/null

# --- 5. Build the wheel -----------------------------------------------------
log "Building wheel with version=${NIGHTLY_VER} (~30-40 min)..."
# shellcheck disable=SC1091
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

export VLLM_TARGET_DEVICE=cpu
export SETUPTOOLS_SCM_PRETEND_VERSION="${NIGHTLY_VER}"
export VLLM_VERSION_OVERRIDE="${NIGHTLY_VER}"
# sysctl -n hw.ncpu is the mac equivalent of nproc.
export MAX_JOBS="$(sysctl -n hw.ncpu)"
# Force-pin the macOS ABI floor so the produced wheel tag is stable
# (macosx_11_0_arm64) and consumable on any macOS >= 11.
export MACOSX_DEPLOYMENT_TARGET

rm -rf "${SRC_DIR}/build" "${SRC_DIR}/dist"
# Note: on macOS we let setup.py / wheel auto-pick the platform tag; we
# do NOT pass `--plat-name`, because macOS plat tags depend on
# MACOSX_DEPLOYMENT_TARGET and the host arch and are easy to get wrong
# manually. The env above pins them deterministically.
python setup.py bdist_wheel

cp "${SRC_DIR}/dist/"*.whl "${OUT_DIR}/"
ls -lh "${OUT_DIR}/"
twine check "${OUT_DIR}/"*.whl

log "Wheels staged at: ${OUT_DIR}"

if [[ "${SKIP_UPLOAD}" == "1" ]]; then
    log "SKIP_UPLOAD=1 -> stopping before twine upload."
    exit 0
fi

# --- 6. Upload to PyPI ------------------------------------------------------
log "Uploading to PyPI via twine..."
TWINE_USERNAME="__token__" \
TWINE_PASSWORD="${PYPI_TOKEN}" \
    twine upload --non-interactive --disable-progress-bar "${OUT_DIR}/"*.whl

log "Done. Index page: https://pypi.org/project/${PKG_NAME}/"
log "Install with:    pip install ${PKG_NAME}"
