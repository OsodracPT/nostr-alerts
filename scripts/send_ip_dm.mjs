#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { SimplePool, finalizeEvent, getPublicKey, nip04, nip19 } from "nostr-tools";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils";

const DEFAULT_ENV_FILE = ".env";

function printUsage() {
    console.log(`Usage: node scripts/send_ip_dm.mjs --recipient <npub|hex> --message <text> --relay <wss://relay>

Required:
  --recipient, -r        Target user (npub, nprofile, or hex pubkey)
  --message, -m          Message body for the DM
  --relay, -l            Relay to publish to (repeat for more relays)

Options:
  --relays               Comma separated relay list
  --key-env              Env var holding sender nsec/hex (default: NOSTR_PRIVATE_KEY)
  --env-file             Path to a .env file (default: .env if present)
  --help                 Show this help text`);
}

function parseArgs(argv) {
    const opts = {
        recipient: "",
        message: "",
        relays: [],
        keyEnv: "NOSTR_PRIVATE_KEY",
        envFile: DEFAULT_ENV_FILE,
    };

    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        const consumeValue = () => {
            i += 1;
            if (i >= argv.length) throw new Error(`Missing value for ${arg}`);
            return argv[i];
        };

        switch (arg) {
            case "--recipient":
            case "-r":
                opts.recipient = consumeValue();
                break;
            case "--message":
            case "-m":
                opts.message = consumeValue();
                break;
            case "--relay":
            case "-l":
                opts.relays.push(consumeValue());
                break;
            case "--relays": {
                const relayList = consumeValue()
                    .split(",")
                    .map((entry) => entry.trim())
                    .filter(Boolean);
                opts.relays.push(...relayList);
                break;
            }
            case "--key-env":
                opts.keyEnv = consumeValue();
                break;
            case "--env-file":
                opts.envFile = consumeValue();
                break;
            case "--help":
            case "-h":
                printUsage();
                process.exit(0);
            default:
                throw new Error(`Unknown argument: ${arg}`);
        }
    }

    opts.relays = Array.from(new Set(opts.relays));
    return opts;
}

function parseRecipient(input) {
    if (input.startsWith("npub1")) {
        const decoded = nip19.decode(input);
        if (decoded.type !== "npub") throw new Error("Invalid npub");
        return decoded.data;
    }

    if (input.startsWith("nprofile1")) {
        const decoded = nip19.decode(input);
        if (decoded.type !== "nprofile") throw new Error("Invalid nprofile");
        return decoded.data.pubkey;
    }

    if (/^[0-9a-f]{64}$/i.test(input)) {
        return input.toLowerCase();
    }

    throw new Error("Recipient must be hex, npub, or nprofile");
}

function parsePrivateKey(value) {
    if (!value) throw new Error("Sender private key not found in environment");

    if (value.startsWith("nsec1")) {
        const decoded = nip19.decode(value);
        if (decoded.type !== "nsec") throw new Error("Invalid nsec value");
        const bytes = decoded.data;
        return { bytes, hex: bytesToHex(bytes) };
    }

    if (/^[0-9a-f]{64}$/i.test(value)) {
        const bytes = hexToBytes(value);
        return { bytes, hex: value.toLowerCase() };
    }

    throw new Error("Private key must be hex or nsec");
}

function loadEnvFile(envFile) {
    if (!envFile) return;
    const resolvedPath = path.resolve(envFile);
    if (!fs.existsSync(resolvedPath)) {
        if (envFile === DEFAULT_ENV_FILE) return;
        throw new Error(`Env file not found: ${envFile}`);
    }

    const contents = fs.readFileSync(resolvedPath, "utf8");
    contents
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line && !line.startsWith("#"))
        .forEach((line) => {
            const eqIndex = line.indexOf("=");
            if (eqIndex <= 0) return;
            const key = line.slice(0, eqIndex).trim();
            if (!key) return;
            let value = line.slice(eqIndex + 1).trim();
            if (
                (value.startsWith('"') && value.endsWith('"')) ||
                (value.startsWith("'") && value.endsWith("'"))
            ) {
                value = value.slice(1, -1);
            }
            if (!(key in process.env)) {
                process.env[key] = value;
            }
        });
}

async function sendDm(opts) {
    if (!opts.recipient) throw new Error("--recipient is required");
    if (!opts.message) throw new Error("--message is required");
    if (opts.relays.length === 0) throw new Error("Provide at least one --relay");

    const envValue = process.env[opts.keyEnv];
    const { bytes: skBytes, hex: skHex } = parsePrivateKey(envValue);
    const pubkey = getPublicKey(skBytes);
    const recipientPubkey = parseRecipient(opts.recipient);

    const encryptedContent = await nip04.encrypt(skHex, recipientPubkey, opts.message);
    const unsignedEvent = {
        kind: 4,
        pubkey,
        created_at: Math.floor(Date.now() / 1000),
        tags: [["p", recipientPubkey]],
        content: encryptedContent,
    };

    const signedEvent = finalizeEvent(unsignedEvent, skBytes);

    const pool = new SimplePool();
    const publishedRelays = await pool.publish(opts.relays, signedEvent);
    pool.close(opts.relays);

    if (!publishedRelays || publishedRelays.length === 0) {
        throw new Error("Event not acknowledged by any relay");
    }

    console.log(`DM sent via ${publishedRelays.join(", ")}`);
}

async function main() {
    try {
        const opts = parseArgs(process.argv.slice(2));
        loadEnvFile(opts.envFile);
        await sendDm(opts);
    } catch (err) {
        if (err instanceof Error) {
            console.error(err.message);
        } else {
            console.error(err);
        }
        process.exit(1);
    }
}

main();
