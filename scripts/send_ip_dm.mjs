#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { finalizeEvent, getPublicKey, nip04, nip19, relayInit } from "nostr-tools";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils";

const DEFAULT_ENV_FILE = ".env";
const PUBLISH_TIMEOUT_MS = 10000;

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

async function ensureWebSocket() {
    if (typeof globalThis.WebSocket !== "undefined") return;

    let wsModule;
    try {
        wsModule = await import("ws");
    } catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        throw new Error(
            `No WebSocket implementation available. Install dependencies with npm install. Original error: ${reason}`,
        );
    }

    const WebSocketImpl = wsModule.WebSocket || wsModule.default;
    if (!WebSocketImpl) throw new Error("Failed to load WebSocket implementation from 'ws'");
    globalThis.WebSocket = WebSocketImpl;
}

function formatRelayErrors(errors) {
    return errors
        .map(
            ({ relay, error }) =>
                `${relay}: ${error instanceof Error ? error.message : typeof error === "string" ? error : "Unknown error"}`,
        )
        .join("; ");
}

async function publishToRelay(relayUrl, signedEvent) {
    const relay = relayInit(relayUrl);

    try {
        await relay.connect();
    } catch (err) {
        throw new Error(`${relayUrl} connect failed: ${err instanceof Error ? err.message : String(err)}`);
    }

    return await new Promise((resolve, reject) => {
        const pub = relay.publish(signedEvent);
        let settled = false;

        const finalize = (action, value) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            try {
                relay.close();
            } catch (_) {}
            action(value);
        };

        const timer = setTimeout(() => finalize(reject, new Error("Publish timeout")), PUBLISH_TIMEOUT_MS);

        pub.on("ok", () => finalize(resolve, relayUrl));
        pub.on("seen", () => finalize(resolve, relayUrl));
        pub.on("failed", (reason) => {
            const err = reason instanceof Error ? reason : new Error(typeof reason === "string" ? reason : "Publish failed");
            finalize(reject, err);
        });
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

    await ensureWebSocket();

    const results = await Promise.allSettled(opts.relays.map((relayUrl) => publishToRelay(relayUrl, signedEvent)));

    const succeeded = [];
    const failed = [];

    results.forEach((result, idx) => {
        const relayUrl = opts.relays[idx];
        if (result.status === "fulfilled") {
            succeeded.push(relayUrl);
        } else {
            failed.push({ relay: relayUrl, error: result.reason });
        }
    });

    if (succeeded.length === 0) {
        throw new Error(`Failed to publish DM to any relay. Details: ${formatRelayErrors(failed)}`);
    }

    console.log(`DM sent via ${succeeded.join(", ")}`);
    if (failed.length > 0) {
        console.warn(`Failed relays: ${formatRelayErrors(failed)}`);
    }
}

async function main() {
    try {
        const opts = parseArgs(process.argv.slice(2));
        loadEnvFile(opts.envFile);
        await sendDm(opts);
        process.exit(0);
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
