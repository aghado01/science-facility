#!/usr/bin/env bash
#
# upgrade-nushell.sh — Queries GitHub release inventory for nushell/nushell,
# identifies the latest OS-appropriate release, updates pin.json programmatically,
# and installs the complete distribution (engine + plugins) into deps/nushell.
#

set -euo pipefail

# Resolve script directory and roots
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${PACKAGE_ROOT}/../.." && pwd)"
DEFAULT_TARGET_DIR="${PACKAGE_ROOT}/deps/nushell"
PIN_FILE="${SCRIPT_DIR}/pin.json"

TARGET_DIR="${DEFAULT_TARGET_DIR}"
FORCE=false
SKIP_TESTS=false
DRY_RUN=false
NO_PIN_UPDATE=false
REQUESTED_TAG=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET_DIR="$2"
      shift 2
      ;;
    --force|-f)
      FORCE=true
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-pin-update)
      NO_PIN_UPDATE=true
      shift
      ;;
    --version|-v)
      REQUESTED_TAG="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --target <dir>       Target installation directory (default: deps/nushell)
  --force, -f          Force download and install even if already on this version
  --skip-tests         Skip running smoke tests after installation
  --dry-run            Check releases and preview pin update without downloading/installing
  --no-pin-update      Install without updating pin.json
  --version, -v <tag>  Upgrade to a specific version tag instead of latest (e.g. 0.115.1)
  --help, -h           Show this help message
EOF
      exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

# --- 1. Detect Host OS and Architecture ----------------------------------------
OS_RAW="$(uname -s)"
ARCH_RAW="$(uname -m)"

DETECTED_OS="unknown"
case "${OS_RAW}" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    DETECTED_OS="windows"
    EXE_NAME="nu.exe"
    ;;
  Linux*)
    DETECTED_OS="linux"
    EXE_NAME="nu"
    ;;
  Darwin*)
    DETECTED_OS="darwin"
    EXE_NAME="nu"
    ;;
  *)
    DETECTED_OS="unknown"
    EXE_NAME="nu"
    ;;
esac

DETECTED_ARCH="unknown"
case "${ARCH_RAW}" in
  x86_64|amd64)
    DETECTED_ARCH="x86_64"
    ;;
  aarch64|arm64)
    DETECTED_ARCH="aarch64"
    ;;
  armv7*)
    DETECTED_ARCH="armv7"
    ;;
  riscv64*)
    DETECTED_ARCH="riscv64gc"
    ;;
  loongarch64*)
    DETECTED_ARCH="loongarch64"
    ;;
  *)
    DETECTED_ARCH="${ARCH_RAW}"
    ;;
esac

PLATFORM_KEY="${DETECTED_OS}-${DETECTED_ARCH}"
echo "Detected platform: ${PLATFORM_KEY} (OS: ${OS_RAW}, Arch: ${ARCH_RAW})"

if [[ "${DETECTED_OS}" == "unknown" ]]; then
  echo "Error: Unsupported operating system: ${OS_RAW}" >&2
  exit 1
fi

# --- 2. Query GitHub Releases Inventory ---------------------------------------
API_URL="https://api.github.com/repos/nushell/nushell/releases/latest"
if [[ -n "${REQUESTED_TAG}" ]]; then
  API_URL="https://api.github.com/repos/nushell/nushell/releases/tags/${REQUESTED_TAG}"
fi

echo "Querying GitHub release inventory from ${API_URL}..."

CURL_HEADERS=(-H "User-Agent: science-facility-brewery")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CURL_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
elif [[ -n "${GH_TOKEN:-}" ]]; then
  CURL_HEADERS+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

RELEASE_PAYLOAD="$(curl -sSL "${CURL_HEADERS[@]}" "${API_URL}")"

if echo "${RELEASE_PAYLOAD}" | grep -q '"message": *"Not Found"'; then
  echo "Error: Release not found at ${API_URL}" >&2
  exit 1
fi

# Extract all asset download URLs
ALL_DOWNLOAD_URLS="$(echo "${RELEASE_PAYLOAD}" | grep -o 'https://github.com/nushell/nushell/releases/download/[^"]*')"

if [[ -z "${ALL_DOWNLOAD_URLS}" ]]; then
  echo "Error: No release download assets found at ${API_URL}" >&2
  exit 1
fi

# Resolve version tag from URL pattern
RELEASE_TAG="$(echo "${ALL_DOWNLOAD_URLS}" | head -n1 | sed -E 's|.*/download/([^/]+)/.*|\1|')"
echo "Identified release version: ${RELEASE_TAG}"

# --- 3. Identify OS-Appropriate Portable Release Asset ------------------------
DOWNLOAD_URL=""
case "${DETECTED_OS}" in
  windows)
    DOWNLOAD_URL="$(echo "${ALL_DOWNLOAD_URLS}" | grep -i 'windows-msvc\.zip$' | grep "${DETECTED_ARCH}" | head -n1 || true)"
    ;;
  linux)
    DOWNLOAD_URL="$(echo "${ALL_DOWNLOAD_URLS}" | grep -i 'linux-gnu\.tar\.gz$' | grep "${DETECTED_ARCH}" | head -n1 || true)"
    if [[ -z "${DOWNLOAD_URL}" ]]; then
      DOWNLOAD_URL="$(echo "${ALL_DOWNLOAD_URLS}" | grep -i 'linux-musl\.tar\.gz$' | grep "${DETECTED_ARCH}" | head -n1 || true)"
    fi
    ;;
  darwin)
    DOWNLOAD_URL="$(echo "${ALL_DOWNLOAD_URLS}" | grep -i 'apple-darwin\.tar\.gz$' | grep "${DETECTED_ARCH}" | head -n1 || true)"
    ;;
esac

if [[ -z "${DOWNLOAD_URL}" ]]; then
  echo "Error: Could not find matching portable archive asset for ${PLATFORM_KEY} in release ${RELEASE_TAG}" >&2
  exit 1
fi

ASSET_FILENAME="$(basename "${DOWNLOAD_URL}")"
echo "Selected asset: ${ASSET_FILENAME}"
echo "Download URL:   ${DOWNLOAD_URL}"

# Locate SHA256SUMS asset and fetch checksum table
SHA256SUMS_URL="$(echo "${ALL_DOWNLOAD_URLS}" | grep 'SHA256SUMS$' | head -n1 || true)"
SHA256SUMS_TXT=""
if [[ -n "${SHA256SUMS_URL}" ]]; then
  echo "Fetching SHA256SUMS..."
  SHA256SUMS_TXT="$(curl -sSL "${SHA256SUMS_URL}")"
fi

if "${DRY_RUN}"; then
  echo "Dry-run complete. Would update pin.json to version ${RELEASE_TAG} and install ${ASSET_FILENAME} into ${TARGET_DIR}."
  exit 0
fi

# --- 4. Check Current Installed Version ---------------------------------------
CURRENT_EXE="${TARGET_DIR}/${EXE_NAME}"
CURRENT_VERSION=""
if [[ -x "${CURRENT_EXE}" ]] || [[ -f "${CURRENT_EXE}" ]]; then
  CURRENT_VERSION="$("${CURRENT_EXE}" --version 2>&1 | tr -d '\r' | sed -E 's/^(nu )?//' || true)"
fi

# --- 5. Download and Verify Archive -------------------------------------------
SCRATCH_DIR="${REPO_ROOT}/artifacts/nushell-mcp/build/nushell-upgrade-$RANDOM-$$"
mkdir -p "${SCRATCH_DIR}/extract"
mkdir -p "${SCRATCH_DIR}/staged"
mkdir -p "${TARGET_DIR}"

cleanup() {
  rm -rf "${SCRATCH_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

ARCHIVE_PATH="${SCRATCH_DIR}/${ASSET_FILENAME}"
echo "Downloading ${ASSET_FILENAME}..."
curl -sSL -o "${ARCHIVE_PATH}" "${DOWNLOAD_URL}"

EXPECTED_SHA256=""
if [[ -n "${SHA256SUMS_TXT}" ]]; then
  EXPECTED_SHA256="$(echo "${SHA256SUMS_TXT}" | grep "${ASSET_FILENAME}" | awk '{print $1}' | tr -d '\r\n' || true)"
fi

if [[ -n "${EXPECTED_SHA256}" ]]; then
  ACTUAL_SHA256=""
  if command -v sha256sum &>/dev/null; then
    ACTUAL_SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
  elif command -v shasum &>/dev/null; then
    ACTUAL_SHA256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
  elif command -v openssl &>/dev/null; then
    ACTUAL_SHA256="$(openssl dgst -sha256 "${ARCHIVE_PATH}" | awk '{print $NF}')"
  fi

  if [[ -n "${ACTUAL_SHA256}" ]]; then
    if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
      echo "Error: Checksum mismatch for ${ASSET_FILENAME}!" >&2
      echo "Expected: ${EXPECTED_SHA256}" >&2
      echo "Actual:   ${ACTUAL_SHA256}" >&2
      exit 1
    fi
    echo "Archive SHA-256 verified: ${ACTUAL_SHA256}"
  fi
fi

# --- 6. Extract Archive & Verify Execution ------------------------------------
echo "Extracting ${ASSET_FILENAME}..."
if [[ "${ASSET_FILENAME}" == *.zip ]]; then
  if command -v unzip &>/dev/null; then
    unzip -q -o "${ARCHIVE_PATH}" -d "${SCRATCH_DIR}/extract"
  else
    tar -xf "${ARCHIVE_PATH}" -C "${SCRATCH_DIR}/extract"
  fi
elif [[ "${ASSET_FILENAME}" == *.tar.gz ]]; then
  tar -xzf "${ARCHIVE_PATH}" -C "${SCRATCH_DIR}/extract"
fi

SOURCE_DIR=""
for candidate in "${SCRATCH_DIR}/extract"/*/"${EXE_NAME}" "${SCRATCH_DIR}/extract"/"${EXE_NAME}"; do
  if [[ -f "${candidate}" ]]; then
    SOURCE_DIR="$(dirname "${candidate}")"
    break
  fi
done

if [[ -z "${SOURCE_DIR}" ]]; then
  echo "Error: Could not locate ${EXE_NAME} inside extracted archive" >&2
  exit 1
fi

cp -r "${SOURCE_DIR}"/* "${SCRATCH_DIR}/staged/"
chmod +x "${SCRATCH_DIR}/staged"/* 2>/dev/null || true

EXTRACTED_VERSION="$("${SCRATCH_DIR}/staged/${EXE_NAME}" --version 2>&1 | tr -d '\r' | sed -E 's/^(nu )?//' || true)"
if [[ -z "${EXTRACTED_VERSION}" ]]; then
  echo "Error: Extracted binary failed to execute" >&2
  exit 1
fi

echo "Verified extracted binary: ${EXE_NAME} version ${EXTRACTED_VERSION}"

# Compute verified executable hash for active platform
EXE_SHA256=""
STAGED_EXE="${SCRATCH_DIR}/staged/${EXE_NAME}"
if command -v sha256sum &>/dev/null; then
  EXE_SHA256="$(sha256sum "${STAGED_EXE}" | awk '{print $1}')"
elif command -v shasum &>/dev/null; then
  EXE_SHA256="$(shasum -a 256 "${STAGED_EXE}" | awk '{print $1}')"
elif command -v openssl &>/dev/null; then
  EXE_SHA256="$(openssl dgst -sha256 "${STAGED_EXE}" | awk '{print $NF}')"
fi

# --- 7. Programmatically Update pin.json --------------------------------------
if ! "${NO_PIN_UPDATE}" && [[ -n "${SHA256SUMS_TXT}" ]]; then
  echo "Updating ${PIN_FILE} for version ${RELEASE_TAG}..."

  WIN_X64_FILE="nu-${RELEASE_TAG}-x86_64-pc-windows-msvc.zip"
  WIN_ARM64_FILE="nu-${RELEASE_TAG}-aarch64-pc-windows-msvc.zip"
  LINUX_X64_FILE="nu-${RELEASE_TAG}-x86_64-unknown-linux-gnu.tar.gz"
  LINUX_ARM64_FILE="nu-${RELEASE_TAG}-aarch64-unknown-linux-gnu.tar.gz"
  DARWIN_X64_FILE="nu-${RELEASE_TAG}-x86_64-apple-darwin.tar.gz"
  DARWIN_ARM64_FILE="nu-${RELEASE_TAG}-aarch64-apple-darwin.tar.gz"

  WIN_X64_SHA="$(echo "${SHA256SUMS_TXT}" | grep "${WIN_X64_FILE}" | awk '{print $1}' | tr -d '\r\n' || true)"
  WIN_ARM64_SHA="$(echo "${SHA256SUMS_TXT}" | grep "${WIN_ARM64_FILE}" | awk '{print $1}' | tr -d '\r\n' || true)"
  LINUX_X64_SHA="$(echo "${SHA256SUMS_TXT}" | grep "${LINUX_X64_FILE}" | awk '{print $1}' | tr -d '\r\n' || true)"
  LINUX_ARM64_SHA="$(echo "${SHA256SUMS_TXT}" | grep "${LINUX_ARM64_FILE}" | awk '{print $1}' | tr -d '\r\n' || true)"
  DARWIN_X64_SHA="$(echo "${SHA256SUMS_TXT}" | grep "${DARWIN_X64_FILE}" | awk '{print $1}' | tr -d '\r\n' || true)"
  DARWIN_ARM64_SHA="$(echo "${SHA256SUMS_TXT}" | grep "${DARWIN_ARM64_FILE}" | awk '{print $1}' | tr -d '\r\n' || true)"

  cat <<EOF > "${PIN_FILE}"
{
  "schema_version": 1,
  "tool": "nushell",
  "version": "${RELEASE_TAG}",
  "release_url": "https://github.com/nushell/nushell/releases/tag/${RELEASE_TAG}",
  "artifacts": {
    "windows-x64": {
      "url": "https://github.com/nushell/nushell/releases/download/${RELEASE_TAG}/${WIN_X64_FILE}",
      "sha256": "${WIN_X64_SHA}",
      "archive": "zip",
      "executable": "nu.exe"$(if [[ "${PLATFORM_KEY}" == "windows-x64" && -n "${EXE_SHA256}" ]]; then printf ',\n      "executable_sha256": "%s"' "${EXE_SHA256}"; fi)
    },
    "windows-arm64": {
      "url": "https://github.com/nushell/nushell/releases/download/${RELEASE_TAG}/${WIN_ARM64_FILE}",
      "sha256": "${WIN_ARM64_SHA}",
      "archive": "zip",
      "executable": "nu.exe"$(if [[ "${PLATFORM_KEY}" == "windows-arm64" && -n "${EXE_SHA256}" ]]; then printf ',\n      "executable_sha256": "%s"' "${EXE_SHA256}"; fi)
    },
    "linux-x64": {
      "url": "https://github.com/nushell/nushell/releases/download/${RELEASE_TAG}/${LINUX_X64_FILE}",
      "sha256": "${LINUX_X64_SHA}",
      "archive": "tar.gz",
      "executable": "nu"$(if [[ "${PLATFORM_KEY}" == "linux-x64" && -n "${EXE_SHA256}" ]]; then printf ',\n      "executable_sha256": "%s"' "${EXE_SHA256}"; fi)
    },
    "linux-arm64": {
      "url": "https://github.com/nushell/nushell/releases/download/${RELEASE_TAG}/${LINUX_ARM64_FILE}",
      "sha256": "${LINUX_ARM64_SHA}",
      "archive": "tar.gz",
      "executable": "nu"$(if [[ "${PLATFORM_KEY}" == "linux-arm64" && -n "${EXE_SHA256}" ]]; then printf ',\n      "executable_sha256": "%s"' "${EXE_SHA256}"; fi)
    },
    "darwin-x64": {
      "url": "https://github.com/nushell/nushell/releases/download/${RELEASE_TAG}/${DARWIN_X64_FILE}",
      "sha256": "${DARWIN_X64_SHA}",
      "archive": "tar.gz",
      "executable": "nu"$(if [[ "${PLATFORM_KEY}" == "darwin-x64" && -n "${EXE_SHA256}" ]]; then printf ',\n      "executable_sha256": "%s"' "${EXE_SHA256}"; fi)
    },
    "darwin-arm64": {
      "url": "https://github.com/nushell/nushell/releases/download/${RELEASE_TAG}/${DARWIN_ARM64_FILE}",
      "sha256": "${DARWIN_ARM64_SHA}",
      "archive": "tar.gz",
      "executable": "nu"$(if [[ "${PLATFORM_KEY}" == "darwin-arm64" && -n "${EXE_SHA256}" ]]; then printf ',\n      "executable_sha256": "%s"' "${EXE_SHA256}"; fi)
    }
  }
}
EOF
  echo "Updated ${PIN_FILE} successfully."
fi

# --- 8. Stage All Executables & Plugins into Target Directory -----------------
echo "Deploying executables and plugins into ${TARGET_DIR}..."
for src_file in "${SCRATCH_DIR}/staged"/*; do
  [[ -f "${src_file}" ]] || continue
  filename="$(basename "${src_file}")"
  dest_file="${TARGET_DIR}/${filename}"

  if [[ -f "${dest_file}" ]]; then
    if ! cp -f "${src_file}" "${dest_file}" 2>/dev/null; then
      old_file="${dest_file}.old"
      rm -f "${old_file}" 2>/dev/null || true
      mv "${dest_file}" "${old_file}" 2>/dev/null || true
      cp -f "${src_file}" "${dest_file}"
    fi
  else
    cp -f "${src_file}" "${dest_file}"
  fi
done

# Write restore receipt
RECEIPT_FILE="${TARGET_DIR}/restore-receipt.json"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"
cat <<EOF > "${RECEIPT_FILE}"
{
  "schema_version": 1,
  "tool": "nushell",
  "version": "${RELEASE_TAG}",
  "platform": "${PLATFORM_KEY}",
  "artifact_url": "${DOWNLOAD_URL}",
  "artifact_sha256": "${EXPECTED_SHA256:-unknown}",
  "executable_name": "${EXE_NAME}",
  "executable_sha256": "${EXE_SHA256:-unknown}",
  "restored_at": "${NOW_ISO}"
}
EOF

echo "Successfully installed Nushell ${RELEASE_TAG} distribution into ${TARGET_DIR}"

# --- 9. Post-Install Smoke Test ----------------------------------------------
if ! "${SKIP_TESTS}"; then
  echo "Running smoke test battery..."
  TEST_SCRIPT="${PACKAGE_ROOT}/tests/skills-corpus-v1.nu"
  if [[ -f "${TEST_SCRIPT}" ]]; then
    "${TARGET_DIR}/${EXE_NAME}" -n "${TEST_SCRIPT}"
    echo "Smoke test passed."
  else
    "${TARGET_DIR}/${EXE_NAME}" --version
  fi
fi

echo "Nushell ${RELEASE_TAG} upgrade complete and ready."
