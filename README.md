# nostr-alerts

Simple tooling for sending encrypted Nostr DMs whenever your public IP changes.

## Requirements

- Node.js 18+ (required for the ESM scripts)
- npm (or another package manager) to install dependencies
- `curl` (used by the Bash scripts to fetch remote data)
- `python` (used inside `job-alerts.sh` to parse RSS feeds)
- Access to at least one reachable Nostr relay

Install dependencies once:

```bash
npm install
```

## Configuration

1. Copy `.env.example` to `.env` (or supply a path via `--env-file`) and fill in your private key:
   ```
   NOSTR_PRIVATE_KEY="nsec1..."
   ```
   The value can also be in raw hex form. Existing shell environment variables take precedence, so you can still `export` a key for ad-hoc overrides.
2. Decide which relays you want to publish the DM to. The scripts default to `wss://relay.nostr.band/` and `wss://relay.primal.net`, and you can add more with repeated `--relay` flags or a comma list via `--relays`.
3. Identify the recipient (hex pubkey, `npub`, or `nprofile`).

## Scripts

### Send a one-off DM

```bash
node scripts/send_ip_dm.mjs \
  --recipient npub1recipient... \
  --message "Hello from nostr-alerts" \
  --relay wss://relay.example
```

Key options:
- `--relays wss://relay.one,wss://relay.two` - Provide multiple relays in a single flag
- `--key-env CUSTOM_ENV` - Read the private key from a different environment variable
- `--env-file /path/to/.env.prod` - Load secrets from a specific env file (defaults to `.env` when present)

### Check the public IP once and alert on changes

The bash script reads the last known IP from `.ip-monitor/last_ip`, compares it against the current value, and only sends a DM if it changed.

```bash
bash scripts/watch-ip.sh \
  --recipient npub1recipient... \
  --relay wss://relay.example
```

Useful flags:
- `--state-file /path/to/cache/ip_state` - Custom location for the cached IP
- `--message-template "IP {old_ip} -> {new_ip} at {timestamp}"` - Customize the DM body
- `--ip-url https://ifconfig.me` - Choose another IP provider
- `--relays wss://relay.one,wss://relay.two` - Multiple relays in one flag
- `--key-env CUSTOM_ENV` - Use a different private-key environment variable
- `--env-file /path/to/.env.prod` - Load environment variables from a specific file (defaults to `.env` when present)

### Weekly job alerts from an RSS feed

`scripts/job-alerts.sh` parses an RSS/Atom feed (defaults to `scripts/joblist.rss` for local testing), keeps track of which job links you've already seen, and sends a DM summarizing the newly posted roles.

Run it manually or schedule it weekly via cron:

```bash
bash scripts/job-alerts.sh \
  --recipient npub1recipient... \
  --relay wss://relay.example \
  --feed https://example.com/job-feed.rss
```

Key flags:
- `--limit 5` - Number of new jobs to include in the DM body
- `--state-file ~/.cache/job-alerts/seen_ids` - Alternate location for the seen-job cache
- `--feed <url-or-path>` - Either a remote RSS/Atom URL (fetched with `curl`) or a local file path
- `--key-env / --env-file` - Same behavior as the other scripts for secret management

If the feed has no new links since the last run, the script exits quietly so your cron logs stay clean.

### Keyword scans against jobs-io.de

`scripts/jobs-io-alerts.sh` emulates the Jobs-IO “Erweiterte Suche” form. It sends one POST request per keyword (defaults: system administrator, system engineer, security engineer, system analyst), tracks already-delivered job links inside `.jobs-io-alerts/state.json`, and DM's a compact summary of the newly-discovered postings.

```bash
bash scripts/jobs-io-alerts.sh \
  --recipient npub1recipient... \
  --relay wss://relay.example \
  --keywords "cloud engineer,devops engineer" \
  --limit 5
```

Key flags:
- `--keyword/--keywords` - Append more search phrases (comma separated or repeated flags)
- `--limit 5` - Number of fresh matches to include for each keyword (default 3)
- `--state-file ~/.cache/jobs-io-alerts.json` - Custom cache location for seen postings
- `--key-env / --env-file` - Same secret handling as the other scripts

When no keyword returns a new posting the script exits quietly so cron stays silent.

## Troubleshooting

- **Missing private key** - Ensure `NOSTR_PRIVATE_KEY` is defined in your `.env` file or exported in the shell (or pass `--key-env`/`--env-file`).
- **Relay errors** - Confirm the relays are reachable and allow publishing from your key.
- **Permission issues on cache/state files** - Update `--state-file` (job alerts) or `--state-file` (IP watcher) to locations writable by the cron user.
