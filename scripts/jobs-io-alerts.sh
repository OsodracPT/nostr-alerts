#!/usr/bin/env bash
set -euo pipefail

RECIPIENT=""
DEFAULT_RELAYS=("wss://relay.nostr.band/" "wss://relay.primal.net")
RELAYS=("${DEFAULT_RELAYS[@]}")
KEYWORDS=(
  "system administrator"
  "system engineer"
  "security engineer"
  "system analyst"
)
NODE_SCRIPT="scripts/send_ip_dm.mjs"
KEY_ENV="NOSTR_PRIVATE_KEY"
ENV_FILE=".env"
STATE_FILE=".jobs-io-alerts/state.json"
ITEM_LIMIT=3

usage() {
    cat <<'EOF'
Usage: ./scripts/jobs-io-alerts.sh --recipient <npub|hex> --relay <wss://relay> [options]

Required:
  --recipient, -r        Target nostr user (npub/nprofile/hex)
  --relay, -l           Relay to publish to (repeat to add more, defaults are wss://relay.nostr.band/ and wss://relay.primal.net)

Options:
  --relays              Comma separated list of relays
  --keyword             Add a keyword to scan (can be repeated)
  --keywords            Comma-separated list of additional keywords
  --limit               Max results per keyword (default: 3)
  --state-file          JSON file caching seen job links (default: .jobs-io-alerts/state.json)
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
            --keyword)
                KEYWORDS+=("$2")
                shift 2
                ;;
            --keywords)
                IFS=',' read -r -a extra_keywords <<< "$2"
                for kw in "${extra_keywords[@]}"; do
                    [[ -n "${kw//[[:space:]]/}" ]] && KEYWORDS+=("$kw")
                done
                shift 2
                ;;
            --limit)
                ITEM_LIMIT="$2"
                shift 2
                ;;
            --state-file)
                STATE_FILE="$2"
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

    if ! [[ "$ITEM_LIMIT" =~ ^[0-9]+$ ]] || ((ITEM_LIMIT <= 0)); then
        log "--limit must be a positive integer"
        exit 1
    fi

    if [[ ${#KEYWORDS[@]} -eq 0 ]]; then
        log "At least one keyword is required"
        exit 1
    fi
}

run_keyword_scan() {
    local python_output
    local status
    python_output=$(
        python - "$STATE_FILE" "$ITEM_LIMIT" "${KEYWORDS[@]}" <<'PY'
import sys
import json
import html
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List

STATE_FILE = Path(sys.argv[1])
LIMIT = int(sys.argv[2])
KEYWORDS = sys.argv[3:]
URL = "https://jobs-io.de/joboffers/advanced.html"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (compatible; nostr-alerts/1.0)",
    "Content-Type": "application/x-www-form-urlencoded",
}

def fetch_html(keyword: str) -> str:
    payload = {
        "filterMode": "ADVANCED",
        "name": keyword,
        "sortType": "RECENTLY_PUBLISHED",
        "doSearch": "Suchen",
    }
    data = urllib.parse.urlencode(payload).encode("utf-8")
    req = urllib.request.Request(URL, data=data, headers=HEADERS, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        charset = resp.headers.get_content_charset() or "utf-8"
        return resp.read().decode(charset, errors="replace")

import re
LI_RE = re.compile(r"<li class=\"selected[^>]*\>(.*?)</li>", re.DOTALL | re.IGNORECASE)
TITLE_RE = re.compile(r"<span class=\"text\">(.*?)</span>", re.DOTALL | re.IGNORECASE)
DEADLINE_RE = re.compile(r"id=\"deadline_[^\"]+\">\s*([^<]+)", re.IGNORECASE)
LOCATION_RE = re.compile(r"Ort:\s*([^,<]+),\s*([^<|]+)", re.IGNORECASE)
ORG_RE = re.compile(r"<span class=\"orgName\">.*?<a[^>]*>(.*?)</a>", re.DOTALL | re.IGNORECASE)
LINK_RE = re.compile(r"<a href=\"([^\"]+)\"[^>]+title=\"Externer Link: Stellenangebot im Original\"", re.IGNORECASE)
PUBLISHED_RE = re.compile(r"Ver[^<]*ffentlicht am:\s*([^<]+)", re.IGNORECASE)


def strip_html(value: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", " ", value)).strip()


def parse_jobs(html_text: str) -> List[Dict[str, str]]:
    jobs = []
    for block in LI_RE.findall(html_text):
        title_match = TITLE_RE.search(block)
        link_match = LINK_RE.search(block)
        if not title_match or not link_match:
            continue
        title = strip_html(title_match.group(1))
        link = html.unescape(link_match.group(1))
        deadline = strip_html(DEADLINE_RE.search(block).group(1)) if DEADLINE_RE.search(block) else "Unbekannt"
        loc_match = LOCATION_RE.search(block)
        city = strip_html(loc_match.group(1)) if loc_match else ""
        country = strip_html(loc_match.group(2)) if loc_match else ""
        org_match = ORG_RE.search(block)
        org = strip_html(org_match.group(1)) if org_match else ""
        published_match = PUBLISHED_RE.search(block)
        published = strip_html(published_match.group(1)) if published_match else ""
        jobs.append(
            {
                "title": title,
                "link": link,
                "deadline": deadline,
                "city": city,
                "country": country,
                "org": org,
                "published": published,
            }
        )
    return jobs


def load_state() -> Dict[str, List[str]]:
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state: Dict[str, List[str]]):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")

state = load_state()
summary_lines = []
any_new = False
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
summary_lines.append(f"jobs-io keyword scan {now}")
summary_lines.append("")

for keyword in KEYWORDS:
    keyword_norm = keyword.strip()
    if not keyword_norm:
        continue
    try:
        html_text = fetch_html(keyword_norm)
    except Exception as exc:
        summary_lines.append(f"{keyword_norm}: Fehler beim Abruf ({exc})")
        continue
    jobs = parse_jobs(html_text)
    if not jobs:
        summary_lines.append(f"{keyword_norm}: Keine Treffer im Feed")
        summary_lines.append("")
        continue
    seen_links = set(state.get(keyword_norm, []))
    new_jobs = [job for job in jobs if job["link"] not in seen_links]
    if not new_jobs:
        summary_lines.append(f"{keyword_norm}: keine neuen Treffer")
        summary_lines.append("")
        continue
    any_new = True
    summary_lines.append(f"{keyword_norm}: {len(new_jobs)} neue Treffer")
    for job in new_jobs[:LIMIT]:
        location = ", ".join(filter(None, [job["city"], job["country"]]))
        summary_lines.append(
            f"- {job['title']} ({location}) | Deadline {job['deadline']} | {job['org']} | {job['link']}"
        )
    if len(new_jobs) > LIMIT:
        summary_lines.append(f"  ... +{len(new_jobs) - LIMIT} weitere neue Stellen")
    summary_lines.append("")
    updated_links = [job["link"] for job in new_jobs if job["link"]]
    updated_links.extend(list(seen_links))
    state[keyword_norm] = updated_links[:200]

if not any_new:
    sys.exit(2)

save_state(state)
print("\n".join(summary_lines).rstrip())
PY
    )
    status=$?

    if [[ $status -eq 0 ]]; then
        printf '%s\n' "$python_output"
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

    local summary
    if ! summary=$(run_keyword_scan); then
        local status=$?
        if [[ $status -eq 2 ]]; then
            log "No new jobs across all keywords"
            exit 0
        fi
        log "Job keyword scan failed (exit code $status)"
        exit "$status"
    fi

    log "Sending keyword-based job summary"
    send_notification "$summary"
    log "Keyword job summary sent"
}

main "$@"
