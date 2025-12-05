#!/usr/bin/env bash
set -euo pipefail

RECIPIENT=""
DEFAULT_RELAYS=("wss://relay.nostr.band/" "wss://relay.primal.net")
RELAYS=("${DEFAULT_RELAYS[@]}")
FEED_SOURCE="scripts/joblist.rss"
STATE_FILE=".job-alerts/seen_ids"
NODE_SCRIPT="scripts/send_ip_dm.mjs"
KEY_ENV="NOSTR_PRIVATE_KEY"
ENV_FILE=".env"
ITEM_LIMIT=5
TMP_FEED=""

usage() {
    cat <<'EOF'
Usage: ./scripts/job-alerts.sh --recipient <npub|hex> --relay <wss://relay> [options]

Required:
  --recipient, -r        Target nostr user (npub/nprofile/hex)
  --relay, -l           Relay to publish to (repeat to add more, defaults are wss://relay.nostr.band/ and wss://relay.primal.net)

Options:
  --relays              Comma separated list of relays
  --feed                RSS/Atom feed URL or local file (default: scripts/joblist.rss)
  --state-file          File tracking already delivered job IDs (default: .job-alerts/seen_ids)
  --limit               Max number of entries to include in the DM (default: 5)
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
            --feed)
                FEED_SOURCE="$2"
                shift 2
                ;;
            --state-file)
                STATE_FILE="$2"
                shift 2
                ;;
            --limit)
                ITEM_LIMIT="$2"
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

is_url() {
    [[ "$1" =~ ^https?:// ]]
}

cleanup_tmp_feed() {
    if [[ -n "${TMP_FEED:-}" && -f "$TMP_FEED" ]]; then
        rm -f "$TMP_FEED"
        TMP_FEED=""
    fi
}

ensure_prereqs() {
    command -v node >/dev/null 2>&1 || { log "node is required"; exit 1; }
    command -v python >/dev/null 2>&1 || { log "python is required"; exit 1; }

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

    if is_url "$FEED_SOURCE"; then
        command -v curl >/dev/null 2>&1 || { log "curl is required to fetch remote feeds"; exit 1; }
    else
        if [[ ! -f "$FEED_SOURCE" ]]; then
            log "Feed source '$FEED_SOURCE' not found"
            exit 1
        fi
    fi

    if ! [[ "$ITEM_LIMIT" =~ ^[0-9]+$ ]] || ((ITEM_LIMIT <= 0)); then
        log "--limit must be a positive integer"
        exit 1
    fi
}

fetch_feed() {
    local dest="$1"
    if is_url "$FEED_SOURCE"; then
        curl -fsS "$FEED_SOURCE" -o "$dest"
    else
        cp "$FEED_SOURCE" "$dest"
    fi
}

generate_message() {
    local feed_file="$1"
    local output
    local status
    output=$(
        python - "$feed_file" "$STATE_FILE" "$ITEM_LIMIT" <<'PY'
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET
import email.utils

feed_path = Path(sys.argv[1])
state_path = Path(sys.argv[2])
limit = int(sys.argv[3])

def safe_datetime(value: str) -> datetime:
    if not value:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)
    try:
        dt = email.utils.parsedate_to_datetime(value)
    except Exception:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)

data = feed_path.read_text(encoding="utf-8")
root = ET.fromstring(data)
items = []
for item in root.findall(".//item"):
    title = (item.findtext("title") or "").strip()
    link = (item.findtext("link") or "").strip()
    pub_date = (item.findtext("pubDate") or "").strip()
    items.append((safe_datetime(pub_date), title, link, pub_date))

items.sort(key=lambda entry: entry[0], reverse=True)

seen = []
if state_path.exists():
    seen = [line.strip() for line in state_path.read_text(encoding="utf-8").splitlines() if line.strip()]
seen_set = set(seen)

new_items = [entry for entry in items if entry[2] and entry[2] not in seen_set]
if not new_items:
    sys.exit(2)

selected = new_items[:limit]
timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

lines = [f"Job updates ({len(selected)} new) - {timestamp}", ""]
for idx, (_, title, link, pub_date) in enumerate(selected, start=1):
    pretty_pub = pub_date or "date unknown"
    lines.append(f"{idx}. {title or 'Untitled role'} - {link} ({pretty_pub})")

remaining = len(new_items) - len(selected)
if remaining > 0:
    lines.append("")
    lines.append(f"...and {remaining} more new postings in the feed.")

print("\n".join(lines))

state_path.parent.mkdir(parents=True, exist_ok=True)
updated_links = []
for _, _, link, _ in new_items:
    if link and link not in updated_links:
        updated_links.append(link)
for link in seen:
    if link and link not in updated_links:
        updated_links.append(link)
    if len(updated_links) >= 200:
        break

state_path.write_text("\n".join(updated_links), encoding="utf-8")
PY
    )
    status=$?

    if [[ $status -eq 0 ]]; then
        printf '%s\n' "$output"
        return 0
    fi

    if [[ $status -eq 2 ]]; then
        return 2
    fi

    return $status
}

send_notification() {
    local message="$1"
    local relay_args=()
    for relay in "${RELAYS[@]}"; do
        relay_args+=("--relay" "$relay")
    done

    local cmd=(node "$NODE_SCRIPT" --recipient "$RECIPIENT" --message "$message" --key-env "$KEY_ENV")
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

    TMP_FEED=$(mktemp)
    trap 'cleanup_tmp_feed' EXIT

    fetch_feed "$TMP_FEED"

    local summary
    local status
    summary=$(generate_message "$TMP_FEED")
    status=$?
    if [[ $status -ne 0 ]]; then
        if [[ $status -eq 2 ]]; then
            log "No new job postings found"
            cleanup_tmp_feed
            exit 0
        fi
        log "Failed to generate job summary (exit code $status)"
        cleanup_tmp_feed
        exit "$status"
    fi

    local line_count
    line_count=$(printf "%s" "$summary" | grep -c '^')
    log "Sending job summary covering $line_count lines"
    send_notification "$summary"
    log "Job summary sent successfully"
    cleanup_tmp_feed
}

main "$@"
