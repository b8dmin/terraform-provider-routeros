#!/bin/bash
# Run acceptance tests for the RouterOS Terraform provider.
# Mirrors CI setup from .github/workflows/module_testing.yml.
#
# RouterOS source priority:
#   1. ROS_HOSTURL + ROS_USERNAME already in env  → use as-is (no Docker)
#   2. Running container from a previous --start-ros → picked up automatically
#
# Typical dev workflow:
#   ./local_test.sh --start-ros
#   <edit code, repeat:>
#   ./local_test.sh [-run SomeTest]
#   ./local_test.sh --stop-ros

set -e

# ---------------------------------------------------------------------------
# RouterOS Docker defaults
# ---------------------------------------------------------------------------
ROS_DOCKER_IMAGE="vaerhme/routeros"
ROS_DOCKER_VERSION="${ROS_VERSION:-7.12}"
ROS_CONTAINER_NAME="routeros-local-test"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
RUN_FILTER=""

function parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --start-ros)
                CMD="start-ros"
                shift
                ;;
            --stop-ros)
                CMD="stop-ros"
                shift
                ;;
            --ros-version)
                ROS_DOCKER_VERSION="$2"
                shift 2
                ;;
            --ignore-tests|-it)
                IGNORE_TESTS=true
                shift
                ;;
            -run)
                RUN_FILTER="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [options] [-run TestName]"
                echo ""
                echo "RouterOS lifecycle:"
                echo "  --start-ros         Start RouterOS Docker container and keep it running"
                echo "  --stop-ros          Stop and remove the RouterOS Docker container"
                echo "  --ros-version VER   RouterOS version for Docker (default: ${ROS_DOCKER_VERSION})"
                echo "                      Alternatively set ROS_VERSION env var"
                echo ""
                echo "Test options:"
                echo "  -run TestName       Run only tests matching the pattern (passed to go test)"
                echo "  --ignore-tests|-it  Continue even if tests fail"
                echo ""
                echo "  If ROS_HOSTURL + ROS_USERNAME are already in the environment,"
                echo "  the running container is not used."
                echo ""
                echo "Examples:"
                echo "  # Dev loop (start once, re-run tests freely):"
                echo "  $0 --start-ros"
                echo "  $0 -run TestAccInterfaceWirelessSecurityProfiles"
                echo "  $0 -run TestAccInterfaceWirelessSecurityProfiles"
                echo "  $0 --stop-ros"
                echo ""
                echo "  # External RouterOS (no Docker):"
                echo "  ROS_HOSTURL=https://192.168.1.1 ROS_USERNAME=admin $0"
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

# ---------------------------------------------------------------------------
# RouterOS Docker lifecycle
# ---------------------------------------------------------------------------

function ros_is_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${ROS_CONTAINER_NAME}$"
}

function ros_container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${ROS_CONTAINER_NAME}$"
}

function ros_start() {
    if ros_is_running; then
        echo "ℹ️  RouterOS container '${ROS_CONTAINER_NAME}' is already running."
        ros_export_env
        return 0
    fi

    if ros_container_exists; then
        echo "⚠️  Stale container '${ROS_CONTAINER_NAME}' found — removing."
        docker rm "${ROS_CONTAINER_NAME}" > /dev/null
    fi

    echo "Starting RouterOS ${ROS_DOCKER_VERSION} (${ROS_DOCKER_IMAGE}:v${ROS_DOCKER_VERSION})..."
    docker run -d --name "${ROS_CONTAINER_NAME}" \
        --platform linux/amd64 \
        --cap-add=NET_ADMIN \
        --device /dev/net/tun \
        -p 443:443 -p 8728:8728 -p 8729:8729 \
        "${ROS_DOCKER_IMAGE}:v${ROS_DOCKER_VERSION}" > /dev/null

    echo "Waiting for RouterOS to boot..."
    for i in $(seq 1 24); do
        if docker logs "${ROS_CONTAINER_NAME}" 2>&1 | grep -q "MikroTik"; then
            echo "✅ RouterOS booted."
            break
        fi
        if [ "$i" -eq 24 ]; then
            echo "❌ RouterOS did not start in 120s."
            ros_stop
            exit 1
        fi
        sleep 5
    done

    echo "Running setup script..."
    ROS_USERNAME=admin ROS_PASSWORD='' ROS_IP_ADDRESS=127.0.0.1 \
        go run .github/scripts/setup_routeros.go 2>/dev/null
    echo "✅ RouterOS ready."

    ros_export_env
}

function ros_export_env() {
    export ROS_HOSTURL=https://127.0.0.1
    export ROS_USERNAME=admin
    export ROS_PASSWORD=''
    export ROS_INSECURE=true
    export ROS_VERSION="${ROS_DOCKER_VERSION}"
}

function ros_stop() {
    if ros_container_exists; then
        echo "Stopping RouterOS container..."
        docker stop "${ROS_CONTAINER_NAME}" > /dev/null
        docker rm   "${ROS_CONTAINER_NAME}" > /dev/null
        echo "✅ RouterOS container removed."
    else
        echo "ℹ️  No RouterOS container '${ROS_CONTAINER_NAME}' found."
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

function run_tests() {
    if [ -z "$ROS_HOSTURL" ] || [ -z "$ROS_USERNAME" ]; then
        # Try to pick up a running container from a previous --start-ros
        if ros_is_running; then
            echo "ℹ️  Using running container '${ROS_CONTAINER_NAME}'."
            ros_export_env
        else
            echo "❌ No RouterOS available."
            echo "   Use --start-ros to start a container, --with-routeros for a one-shot run,"
            echo "   or set ROS_HOSTURL + ROS_USERNAME in the environment."
            exit 1
        fi
    fi

    local test_args="-timeout 30m -v ./routeros"
    if [ -n "$RUN_FILTER" ]; then
        test_args="${test_args} -run ${RUN_FILTER}"
    fi

    echo "Running tests against ${ROS_HOSTURL} (ROS_VERSION=${ROS_VERSION:-unknown})..."
    [ -n "$RUN_FILTER" ] && echo "Filter: -run ${RUN_FILTER}"

    set +e
    TF_ACC=1 go test ${test_args}
    TEST_EXIT=$?
    set -e

    if [ $TEST_EXIT -ne 0 ]; then
        if [ "$IGNORE_TESTS" = true ]; then
            echo "❌ Tests failed but ignoring (--ignore-tests)."
        else
            echo "❌ Tests failed."
            exit $TEST_EXIT
        fi
    else
        echo "✅ Tests passed."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main() {
    parse_args "$@"

    case "${CMD}" in
        start-ros)
            ros_start
            echo ""
            echo "RouterOS is running. You can now run tests with:"
            echo "  $0 [-run TestName]"
            echo "  $0 --stop-ros   (when done)"
            ;;
        stop-ros)
            ros_stop
            ;;
        *)
            run_tests
            ;;
    esac
}

main "$@"
