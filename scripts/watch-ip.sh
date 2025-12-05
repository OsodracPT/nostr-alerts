#!/usr/bin/env bash
set -euo pipefail

RECIPIENT=""
DEFAULT_RELAYS=("wss://relay.nostr.band/" "wss://relay.primal.net")
RELAYS=("${DEFAULT_RELAYS[@]}")
STATE_FILE=".ip-monitor/last_ip"
MESSAGE_TEMPLATE="Public IP changed from {old_ip} to {new_ip} at {timestamp}"
IP_PROVIDER_URL="https://api.ipify.org"
NODE_SCRIPT="scripts/send_ip_dm.mjs"
KEY_ENV="NOSTR_PRIVATE_KEY"
ENV_FILE=".env"

usage() {
    cat <<'EOF'
Usage: ./scripts/watch-ip.sh --recipient <npub|hex> --relay <wss://relay> [options]

Required:
  --recipient, -r        Target nostr user (npub/nprofile/hex)
  --relay, -l           Relay to publish to (repeat to add more, defaults are wss://relay.nostr.band/ and wss://relay.primal.net)

Options:
  --relays              Comma separated list of relays
  --state-file          File used to cache the last known IP (default: .ip-monitor/last_ip)
  --message-template    Template for the DM body (default shown in script)
                        Tokens: {new_ip}, {old_ip}, {timestamp}
  --ip-url              Override the IP provider URL (default: https://api.ipify.org)
  --node-script         Path to the DM sender script (default: scripts/send_ip_dm.mjs)
  --key-env             Env var containing your nsec/hex (default: NOSTR_PRIVATE_KEY)
  --env-file            Path to a .env file (default: .env if present)
  --help, -h            Display this help text
EOF
}

log() {
    printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --recipient|-r)
                RECIPIENT="$2"
                shift 2
                ;;
            --relay|-l)
                RELAYS+=("$2")
                shift 2
                ;;
            --relays)
                IFS=',' read -r -a extra_relays <<< "$2"
                for relay in "${extra_relays[@]}"; do
                    [[ -n "$relay" ]] && RELAYS+=("$relay")
                done
                shift 2
                ;;
            --state-file)
                STATE_FILE="$2"
                shift 2
                ;;
            --message-template)
                MESSAGE_TEMPLATE="$2"
                shift 2
                ;;
            --ip-url)
                IP_PROVIDER_URL="$2"
                shift 2
                ;;
            --node-script)
                NODE_SCRIPT="$2"
                shift 2
                ;;
            --key-env)
                KEY_ENV="$2"
                shift 2
                ;;
            --env-file)
                ENV_FILE="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

load_env_file() {
    if [[ -z "$ENV_FILE" ]]; then
        return
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ "$ENV_FILE" == ".env" ]]; then
            return
        fi
        log "Env file '$ENV_FILE' not found"
        exit 1
    fi

    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
}

ensure_prereqs() {
    command -v curl >/dev/null 2>&1 || { log "curl is required"; exit 1; }
    command -v node >/dev/null 2>&1 || { log "node is required"; exit 1; }

    if [[ -z "$RECIPIENT" ]]; then
        log "--recipient is required"
        exit 1
    fi

    if [[ ${#RELAYS[@]} -eq 0 ]]; then
        log "Provide at least one --relay"
        exit 1
    fi

    if [[ -z "${!KEY_ENV-}" ]]; then
        log "Environment variable $KEY_ENV must be set with your private key"
        exit 1
    fi
}

fetch_public_ip() {
    curl -fsS --max-time 10 "$IP_PROVIDER_URL"
}

send_notification() {
    local new_ip="$1"
    local old_ip="$2"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local payload="${MESSAGE_TEMPLATE//\{new_ip\}/$new_ip}"
    local safe_old="${old_ip:-unknown}"
    payload="${payload//\{old_ip\}/$safe_old}"
    payload="${payload//\{timestamp\}/$timestamp}"

    local relay_args=()
    for relay in "${RELAYS[@]}"; do
        relay_args+=("--relay" "$relay")
    done

    local cmd=(node "$NODE_SCRIPT" --recipient "$RECIPIENT" --message "$payload" --key-env "$KEY_ENV")
    if [[ -n "$ENV_FILE" ]]; then
        cmd+=("--env-file" "$ENV_FILE")
    fi
    cmd+=("${relay_args[@]}")
    "${cmd[@]}"
}

main() {
    parse_args "$@"
    load_env_file
    ensure_prereqs

    local state_dir
    state_dir=$(dirname "$STATE_FILE")
    mkdir -p "$state_dir"

    local previous_ip=""
    if [[ -f "$STATE_FILE" ]]; then
        previous_ip=$(<"$STATE_FILE")
    fi

    local current_ip
    if ! current_ip=$(fetch_public_ip); then
        log "Unable to retrieve public IP"
        exit 1
    fi

    if [[ -n "$previous_ip" && "$current_ip" == "$previous_ip" ]]; then
        log "IP unchanged ($current_ip). No action taken."
        exit 0
    fi

    log "Public IP changed to $current_ip"
    send_notification "$current_ip" "$previous_ip"
    printf '%s' "$current_ip" >"$STATE_FILE"
}

main "$@"
