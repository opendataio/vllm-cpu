#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Build & publish a CPU-only vLLM wheel as `vllm-cpu-nightly` to PyPI.
#
# Strategy:
#   1. Spin up an `ubuntu:22.04` container that mirrors the GitHub Actions
#      runner used by .github/workflows/cpu_device.yml (python 3.12, gcc-12,
#      libnuma-dev). This gives a wheel that is binary-compatible with the
#      CI environment.
#   2. Clone vLLM `main` (the latest tip) and rename the distribution to
#      `vllm-cpu-nightly` by patching pyproject.toml + setup.py BEFORE the
#      build runs. The Python import name (`import vllm`) is preserved.
#   3. We build the wheel with a minute-stamped PEP-440 dev version:
#        `<base>.devN<YYYYMMDDHHMM>`
#      That number is monotonically increasing, so `pip install --upgrade
#      vllm-cpu-nightly` always pulls the newest one. PyPI keeps every
#      historical version reachable forever (so older builds stay
#      installable for rollback by pinning the exact version).
#   4. We pass `--plat-name manylinux_2_28_x86_64` directly to
#      `setup.py bdist_wheel` so the resulting wheel carries a PyPI-
#      acceptable platform tag from the start (PyPI rejects the bare
#      `linux_*` tag). This is safe because the ubuntu-22.04 build env
#      has glibc 2.35 and the GitHub runner used by cpu_device.yml is
#      also ubuntu-22.04 (same glibc).
#   5. Twine-upload to PyPI using the API token from
#      /data/home/baoloongmao/pypi_apikey.
#
# Usage (on the devcloud host):
#   bash build_and_publish_vllm_cpu_nightly.sh
#
# Optional env overrides:
#   PYPI_TOKEN_FILE   default: /data/home/baoloongmao/pypi_apikey
#   PKG_NAME          default: vllm-cpu-nightly
#   VLLM_GIT_REF      default: main      (set to a tag/sha to pin)
#   SKIP_UPLOAD       default: 0         (set to 1 for a dry-run build)
#   WORK_DIR          default: /data/vllm-cpu-nightly-build
# ----------------------------------------------------------------------------
set -euo pipefail

PYPI_TOKEN_FILE="${PYPI_TOKEN_FILE:-/data/home/baoloongmao/pypi_apikey}"
PKG_NAME="${PKG_NAME:-vllm-cpu-nightly}"
VLLM_GIT_REF="${VLLM_GIT_REF:-main}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
WORK_DIR="${WORK_DIR:-/data/vllm-cpu-nightly-build}"
IMAGE="ubuntu:22.04"

log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${PYPI_TOKEN_FILE}" ]] || die "PyPI token file not found: ${PYPI_TOKEN_FILE}"
PYPI_TOKEN="$(tr -d '[:space:]' < "${PYPI_TOKEN_FILE}")"
[[ -n "${PYPI_TOKEN}" ]] || die "PyPI token file is empty"

mkdir -p "${WORK_DIR}"
HOST_OUT_DIR="${WORK_DIR}/dist"
mkdir -p "${HOST_OUT_DIR}"

STAMP_FULL="$(date -u +%Y%m%d%H%M)"

log "Pulling ${IMAGE} (no-op if already present)..."
docker pull "${IMAGE}" >/dev/null

CONTAINER_NAME="vllm-cpu-nightly-build-$$"
trap 'docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true' EXIT

log "Starting build container ${CONTAINER_NAME}..."
docker run -d --name "${CONTAINER_NAME}" \
    -e DEBIAN_FRONTEND=noninteractive \
    -e VLLM_TARGET_DEVICE=cpu \
    -e VLLM_GIT_REF="${VLLM_GIT_REF}" \
    -e PKG_NAME="${PKG_NAME}" \
    -e STAMP_FULL="${STAMP_FULL}" \
    -e CC=gcc-12 \
    -e CXX=g++-12 \
    -v "${HOST_OUT_DIR}:/out" \
    "${IMAGE}" \
    sleep infinity >/dev/null

run() { docker exec "${CONTAINER_NAME}" bash -ec "$*"; }

log "Installing system + python toolchain inside container..."
# We avoid `add-apt-repository` because the bare ubuntu:22.04 image
# ships a half-broken `software-properties-common` (gpg-agent missing,
# python3-launchpadlib pulls in 80MB of deps). Instead we register the
# deadsnakes PPA by hand: import its signing key into a trusted keyring
# and drop a sources.list snippet.
run '
set -euo pipefail
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git \
    gcc-12 g++-12 libnuma-dev patchelf >/dev/null
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776" \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/deadsnakes.gpg
echo "deb http://ppa.launchpad.net/deadsnakes/ppa/ubuntu jammy main" \
    > /etc/apt/sources.list.d/deadsnakes.list
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev python3-pip >/dev/null
python3.12 -m venv /opt/venv
. /opt/venv/bin/activate
python -m pip install --upgrade pip wheel setuptools build twine auditwheel >/dev/null
'

log "Cloning vLLM @ ${VLLM_GIT_REF}..."
run '
set -euo pipefail
rm -rf /src/vllm
mkdir -p /src
git clone --depth 1 --branch "${VLLM_GIT_REF}" \
    https://github.com/vllm-project/vllm.git /src/vllm \
    2>/dev/null \
    || git clone https://github.com/vllm-project/vllm.git /src/vllm
cd /src/vllm
if [ "${VLLM_GIT_REF}" != "main" ]; then
    git checkout "${VLLM_GIT_REF}"
fi
git rev-parse HEAD > /src/vllm_commit.txt
echo "vLLM commit: $(cat /src/vllm_commit.txt)"
'

log "Patching distribution name -> ${PKG_NAME} and setting nightly version..."
run '
set -euo pipefail
cd /src/vllm
. /opt/venv/bin/activate

# Determine the upstream version that setuptools-scm would have produced
# for this commit. We deliberately do NOT trust setuptools-scm here:
# a shallow clone has no reachable tag and scm falls back to "0.1.dev1",
# which is too low (PyPI would consider it older than the real 0.x.y
# release line). Instead, fetch all tags and use the latest stable
# release tag (vX.Y.Z, no rc/a/b suffix), then bump the patch by 1
# because vLLM `main` is always post-release.
git fetch --tags --depth=1 origin >/dev/null 2>&1 || true
LAST_STABLE="$(git tag --sort=-v:refname | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | head -1)"
LAST_STABLE="${LAST_STABLE:-v0.0.0}"
BASE_RAW="${LAST_STABLE#v}"
BASE_VER="$(echo "${BASE_RAW}" | awk -F. "{ printf \"%d.%d.%d\", \$1, \$2, \$3+1 }")"
echo "Last stable tag : ${LAST_STABLE}"
echo "Bumped base ver : ${BASE_VER}"
echo "${BASE_VER}" > /src/base_version.txt

NIGHTLY_VER="${BASE_VER}.dev${STAMP_FULL}"
echo "${NIGHTLY_VER}" > /src/nightly_version.txt

# Rename the project distribution to PKG_NAME. Only [project].name in
# pyproject.toml needs to change; the import package (`vllm/`) is
# untouched so `import vllm` still works.
python - <<PY
import pathlib, re
pkg = "${PKG_NAME}"
p = pathlib.Path("pyproject.toml")
txt = p.read_text()
new = re.sub(r"^(\s*name\s*=\s*[\"\x27])vllm([\"\x27])",
             lambda m: m.group(1) + pkg + m.group(2),
             txt, count=1, flags=re.MULTILINE)
assert new != txt, "failed to patch pyproject.toml name"
p.write_text(new)
print(f"Patched name -> {pkg} in pyproject.toml")
PY

# Patch requirements/cpu.txt: PyPI rejects wheels whose dependencies
# carry a PEP 440 local label like `torch==2.11.0+cpu`. Strip the +cpu
# suffix; downstream installers can still pull the cpu wheel with
# `--extra-index-url https://download.pytorch.org/whl/cpu`.
sed -i -E "s/torch==([0-9.]+)\+cpu/torch==\1/g" requirements/cpu.txt
echo "--- patched requirements/cpu.txt ---"
grep -E "^torch" requirements/cpu.txt || true
'

log "Installing build deps + torch(cpu) inside container..."
run '
set -euo pipefail
. /opt/venv/bin/activate
# Without build isolation we must install everything that
# pyproject.toml [build-system].requires asks for ourselves.
pip install "cmake>=3.26.1" ninja "packaging>=24.2" \
    "setuptools>=77.0.3,<81.0.0" "setuptools-scm>=8.0" \
    "setuptools-rust>=1.9.0" wheel jinja2 >/dev/null
# vLLM ships a Rust frontend -> need cargo + system C toolchain so
# rustc can find a default linker and so torch.utils.cpp_extension can
# build the C++ extensions.
apt-get install -y --no-install-recommends build-essential >/dev/null
if ! command -v cargo >/dev/null 2>&1; then
    curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable -q
fi
# Plain torch (cpu) so setup.py can `import torch`.
pip install "numpy<2" >/dev/null
pip install torch==2.11.0 \
    --extra-index-url https://download.pytorch.org/whl/cpu >/dev/null
'

NIGHTLY_VER="$(run 'cat /src/nightly_version.txt')"
log "  nightly version : ${NIGHTLY_VER}  (minute-stamped, monotonic)"

log "Building wheel with version=${NIGHTLY_VER} (~30-40 min)..."
run "
    set -euo pipefail
    cd /src/vllm
    . /opt/venv/bin/activate
    . \$HOME/.cargo/env
    export VLLM_TARGET_DEVICE=cpu
    export CC=gcc-12 CXX=g++-12
    export SETUPTOOLS_SCM_PRETEND_VERSION='${NIGHTLY_VER}'
    export VLLM_VERSION_OVERRIDE='${NIGHTLY_VER}'
    export MAX_JOBS=\$(nproc)
    rm -rf /src/vllm/build /src/vllm/dist
    python setup.py bdist_wheel --plat-name manylinux_2_28_x86_64
    cp /src/vllm/dist/*.whl /out/
    ls -lh /out/
    twine check /out/*.whl
"

log "Wheels staged on host:"
ls -lh "${HOST_OUT_DIR}"

if [[ "${SKIP_UPLOAD}" == "1" ]]; then
    log "SKIP_UPLOAD=1 -> stopping before twine upload."
    exit 0
fi

log "Uploading to PyPI via twine..."
docker exec \
    -e TWINE_USERNAME="__token__" \
    -e TWINE_PASSWORD="${PYPI_TOKEN}" \
    "${CONTAINER_NAME}" \
    bash -ec '
        . /opt/venv/bin/activate
        twine upload --non-interactive --disable-progress-bar /out/*.whl
    '

log "Done. Index page: https://pypi.org/project/${PKG_NAME}/"
log "Install with:    pip install ${PKG_NAME}"