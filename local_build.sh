#!/bin/bash
# Reusable local build script for any Terraform provider.
# Provider identity is auto-detected from go.mod — no edits needed when copying.
# For running tests see local_test.sh.

set -e

# ---------------------------------------------------------------------------
# Auto-detect provider identity from go.mod
# Expected module path: github.com/{NAMESPACE}/terraform-provider-{PROVIDER}
# ---------------------------------------------------------------------------
MODULE=$(grep "^module" go.mod | awk '{print $2}')
NAMESPACE=$(echo "$MODULE" | cut -d'/' -f2)
BINARY_NAME=$(echo "$MODULE" | cut -d'/' -f3)
PROVIDER_NAME=$(echo "$BINARY_NAME" | sed 's/terraform-provider-//')

HOSTNAME="local"
VERSION="1.0.0-dev"
OUTPUT_FOLDER="binaries"
ARCHS=("amd64" "arm64")
OSS=("linux" "darwin")

function parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --multiarch|-m)
                MULTIARCH=true
                shift
                ;;
            --install|-i)
                INSTALL=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "  --multiarch|-m    Build for multiple architectures"
                echo "  --install|-i      Install the plugin locally"
                echo "  --help|-h         Show this help message"
                echo ""
                echo "Provider: ${BINARY_NAME} (detected from go.mod)"
                echo "For running tests see: local_test.sh --help"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help or -h for usage information"
                exit 1
                ;;
        esac
    done
}

function detect_local_arch() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    case $(uname -m) in
        x86_64)        ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            echo "❌ Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac
}

function build_plugin() {
    echo "Building ${BINARY_NAME}..."
    if [ "$MULTIARCH" = true ]; then
        for os in "${OSS[@]}"; do
            for arch in "${ARCHS[@]}"; do
                mkdir -p "${OUTPUT_FOLDER}/${os}_${arch}"
                GOOS=${os} GOARCH=${arch} go build -o "${OUTPUT_FOLDER}/${os}_${arch}/${BINARY_NAME}"
                echo "✅ [${os}_${arch}] ${BINARY_NAME} built."
            done
        done
    else
        detect_local_arch
        mkdir -p "${OUTPUT_FOLDER}/${OS}_${ARCH}"
        BINARY_PATH="${OUTPUT_FOLDER}/${OS}_${ARCH}/${BINARY_NAME}"
        GOOS=${OS} GOARCH=${ARCH} go build -o "${BINARY_PATH}"
        echo "✅ ${BINARY_NAME} built → ${BINARY_PATH}"
    fi
}

function install_plugin() {
    if [ "$MULTIARCH" = true ]; then
        echo "❌ --install is not supported with --multiarch."
        exit 1
    fi
    INSTALL_PATH="$HOME/.terraform.d/plugins/${HOSTNAME}/${NAMESPACE}/${PROVIDER_NAME}/${VERSION}/${OS}_${ARCH}"
    echo "Installing to ${INSTALL_PATH} ..."
    mkdir -p "${INSTALL_PATH}"
    cp "${BINARY_PATH}" "${INSTALL_PATH}/terraform-provider-${PROVIDER_NAME}"
    chmod +x "${INSTALL_PATH}/terraform-provider-${PROVIDER_NAME}"
    echo "✅ Plugin installed."
    echo ""
    echo "── ~/.terraformrc ────────────────────────────────────────────"
    echo "provider_installation {"
    echo "  filesystem_mirror {"
    echo "    path    = \"$HOME/.terraform.d/plugins\""
    echo "    include = [\"${HOSTNAME}/${NAMESPACE}/${PROVIDER_NAME}\"]"
    echo "  }"
    echo "  direct {"
    echo "    exclude = [\"${HOSTNAME}/${NAMESPACE}/${PROVIDER_NAME}\"]"
    echo "  }"
    echo "}"
    echo ""
    echo "── main.tf ───────────────────────────────────────────────────"
    echo "terraform {"
    echo "  required_providers {"
    echo "    ${PROVIDER_NAME} = {"
    echo "      source  = \"${HOSTNAME}/${NAMESPACE}/${PROVIDER_NAME}\""
    echo "      version = \"${VERSION}\""
    echo "    }"
    echo "  }"
    echo "}"
    echo "──────────────────────────────────────────────────────────────"
}

function main() {
    parse_args "$@"
    build_plugin
    if [ "$INSTALL" = true ]; then
        install_plugin
    fi
}

main "$@"
