/**
 * MegaCloud / RabbitStream Extractor
 * Ported from Aniyomi's MegaCloudExtractor.kt and aniwatch-api's megacloud.ts
 * 
 * Flow:
 * 1. Fetch encrypted sources JSON from getSources API
 * 2. Fetch the obfuscated e1-player.min.js script
 * 3. Extract variable index pairs from the script via regex
 * 4. Use indices to slice the "secret" from the encrypted string
 * 5. Derive AES-256-CBC key + IV using MD5 iterations (OpenSSL KDF)
 * 6. Decrypt ciphertext to get JSON array of .m3u8 URLs
 */
import CryptoJS from 'crypto-js';
import { Capacitor, CapacitorHttp } from '@capacitor/core';

let MEGACLOUD_BASE = 'https://megacloud.blog';
let EMBED_PREFIX = '/embed-2';
function getSourcesUrl() { return `${MEGACLOUD_BASE}${EMBED_PREFIX}/ajax/e-1/getSources?id=`; }
function getScriptUrl() { return `${MEGACLOUD_BASE}/js/player/a/prod/e1-player.min.js?v=`; }
const FALLBACK_KEY_URL = 'https://raw.githubusercontent.com/itzzzme/megacloud-keys/main/key.txt';

const HEADERS = {
    'Referer': 'https://hianime.to/',
    'X-Requested-With': 'XMLHttpRequest',
    'Accept': '*/*',
};

async function requestMegaCloud(url: string, expectsJson = false) {
    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.get({ url, headers: HEADERS });
        if (response.status >= 400) throw new Error(`HTTP Error: ${response.status}`);
        return response.data;
    } else {
        const res = await fetch(url, { headers: HEADERS });
        if (!res.ok) throw new Error(`HTTP Error: ${res.status}`);
        return expectsJson ? res.json() : res.text();
    }
}

export interface MegaCloudResult {
    sources: { file: string; type: string }[];
    tracks: { file: string; label?: string; kind?: string }[];
    intro?: { start: number; end: number };
    outro?: { start: number; end: number };
}

/**
 * Main entry point: given a Megacloud embed URL, returns decrypted .m3u8 sources
 */
export async function extractMegaCloudSources(embedUrl: string): Promise<MegaCloudResult | null> {
    try {
        const parsed = new URL(embedUrl);
        MEGACLOUD_BASE = `${parsed.protocol}//${parsed.host}`;
        const urlParts = parsed.pathname.split('/');
        const videoId = urlParts[urlParts.length - 1].split('?')[0];

        // Extract versioned prefix: /embed-2/v3 from /embed-2/v3/e-1/videoId
        const eIdx = urlParts.findIndex(p => p.startsWith('e-'));
        EMBED_PREFIX = eIdx > 1 ? '/' + urlParts.slice(1, eIdx).join('/') : '/embed-2';

        console.log('[MegaCloud] Base:', MEGACLOUD_BASE, 'Prefix:', EMBED_PREFIX, 'Video ID:', videoId);

        // Step 1: Fetch encrypted sources
        const srcsData = await requestMegaCloud(getSourcesUrl() + videoId, true);

        // If not encrypted, return directly
        if (!srcsData.encrypted || typeof srcsData.sources !== 'string') {
            console.log('[MegaCloud] Sources not encrypted, returning directly');
            return {
                sources: Array.isArray(srcsData.sources) ? srcsData.sources : [],
                tracks: srcsData.tracks || [],
                intro: srcsData.intro,
                outro: srcsData.outro,
            };
        }

        const encryptedSources: string = srcsData.sources;
        console.log('[MegaCloud] Encrypted payload length:', encryptedSources.length);

        // Step 2: Try script-based decryption first
        let decryptedJson: string | null = null;

        try {
            decryptedJson = await decryptViaScript(encryptedSources);
        } catch (e) {
            console.warn('[MegaCloud] Script-based decryption failed, trying fallback key...', e);
        }

        // Step 3: Fallback to hosted key
        if (!decryptedJson) {
            try {
                decryptedJson = await decryptViaFallbackKey(encryptedSources);
            } catch (e) {
                console.error('[MegaCloud] Fallback key decryption also failed', e);
            }
        }

        if (!decryptedJson) {
            console.error('[MegaCloud] All decryption methods failed');
            return null;
        }

        const sources = JSON.parse(decryptedJson);
        return {
            sources: Array.isArray(sources) ? sources.map((s: any) => ({ file: s.file, type: s.type || 'hls' })) : [],
            tracks: srcsData.tracks || [],
            intro: srcsData.intro,
            outro: srcsData.outro,
        };
    } catch (e) {
        console.error('[MegaCloud] Extraction failed', e);
        return null;
    }
}

// ── Script-Based Decryption (Aniyomi method) ──────────────────────────

async function decryptViaScript(encryptedSources: string): Promise<string> {
    // Fetch the obfuscated player script
    const script = await requestMegaCloud(getScriptUrl() + Date.now(), false);
    console.log('[MegaCloud] Player script length:', script.length);

    // Extract variable index pairs
    const vars = extractVariables(script);
    if (vars.length === 0) {
        throw new Error('Failed to extract variables from player script');
    }
    console.log('[MegaCloud] Extracted', vars.length, 'variable pairs');

    // Use indices to separate secret from encrypted source
    const { secret, encryptedSource } = getSecret(encryptedSources, vars);
    console.log('[MegaCloud] Secret length:', secret.length, 'Remaining cipher length:', encryptedSource.length);

    // Decrypt using OpenSSL-compatible AES
    const decrypted = decrypt(encryptedSource, secret);
    if (!decrypted || decrypted.length === 0) {
        throw new Error('Decryption produced empty result');
    }

    return decrypted;
}

/**
 * Extract index pairs from the obfuscated e1-player.min.js script.
 * These pairs indicate [start, length] offsets used to slice the "secret" 
 * from the encrypted sources string.
 */
function extractVariables(script: string): number[][] {
    const regex = /case\s*0x[0-9a-f]+:(?![^;]*=partKey)\s*\w+\s*=\s*(\w+)\s*,\s*\w+\s*=\s*(\w+);/g;
    const vars: number[][] = [];

    let match;
    while ((match = regex.exec(script)) !== null) {
        try {
            const key1 = matchingKey(match[1], script);
            const key2 = matchingKey(match[2], script);
            vars.push([parseInt(key1, 16), parseInt(key2, 16)]);
        } catch {
            // Skip failed matches
        }
    }

    return vars;
}

/**
 * Resolve a variable name to its hex value from the script
 */
function matchingKey(value: string, script: string): string {
    // Check if it's already a hex literal
    if (/^0x[0-9a-fA-F]+$/.test(value)) {
        return value.replace(/^0x/, '');
    }

    const regex = new RegExp(`,${value}=((?:0x)?([0-9a-fA-F]+))`);
    const match = script.match(regex);
    if (match) {
        return match[1].replace(/^0x/, '');
    }
    throw new Error(`Failed to match key for: ${value}`);
}

/**
 * Slice the "secret" out of the encrypted string using the extracted index pairs.
 * The remaining characters form the actual ciphertext to decrypt.
 */
function getSecret(encryptedString: string, values: number[][]): { secret: string; encryptedSource: string } {
    let secret = '';
    const encryptedSourceArray = encryptedString.split('');
    let currentIndex = 0;

    for (const [start, length] of values) {
        const actualStart = start + currentIndex;
        const actualEnd = actualStart + length;
        for (let i = actualStart; i < actualEnd; i++) {
            secret += encryptedString[i];
            encryptedSourceArray[i] = '';
        }
        currentIndex += length;
    }

    return {
        secret,
        encryptedSource: encryptedSourceArray.join(''),
    };
}

/**
 * Derive AES-256-CBC key and IV using OpenSSL's EVP_BytesToKey (MD5-based KDF),
 * then decrypt the ciphertext.
 * 
 * The Base64-decoded ciphertext has the structure:
 * - Bytes 0-7:  "Salted__" magic
 * - Bytes 8-15: 8-byte salt
 * - Bytes 16+:  actual AES ciphertext
 */
function decrypt(encrypted: string, secret: string): string {
    const cypher = CryptoJS.enc.Base64.parse(encrypted);
    const cipherHex = cypher.toString(CryptoJS.enc.Hex);

    // Extract salt (bytes 8-15 = hex chars 16-31)
    const salt = CryptoJS.enc.Hex.parse(cipherHex.substring(16, 32));

    // Extract actual ciphertext (bytes 16+ = hex chars 32+)
    const ciphertext = CryptoJS.enc.Hex.parse(cipherHex.substring(32));

    // Derive key (32 bytes) and IV (16 bytes) using EVP_BytesToKey with MD5
    const password = CryptoJS.enc.Utf8.parse(secret);
    const { key, iv } = evpBytesToKey(password, salt);

    // Decrypt
    const decrypted = CryptoJS.AES.decrypt(
        { ciphertext } as any,
        key,
        { iv, mode: CryptoJS.mode.CBC, padding: CryptoJS.pad.Pkcs7 }
    );

    return decrypted.toString(CryptoJS.enc.Utf8);
}

/**
 * OpenSSL's EVP_BytesToKey key derivation function.
 * Produces 32-byte key + 16-byte IV from password + salt using MD5 iterations.
 */
function evpBytesToKey(password: CryptoJS.lib.WordArray, salt: CryptoJS.lib.WordArray): { key: CryptoJS.lib.WordArray; iv: CryptoJS.lib.WordArray } {
    const targetKeySize = 8;  // 32 bytes = 8 words
    const targetIvSize = 4;   // 16 bytes = 4 words
    const totalSize = targetKeySize + targetIvSize;

    const derivedWords: number[] = [];
    let block: CryptoJS.lib.WordArray | null = null;

    while (derivedWords.length < totalSize) {
        const hasher = CryptoJS.algo.MD5.create();
        if (block) {
            hasher.update(block);
        }
        hasher.update(password);
        hasher.update(salt);
        block = hasher.finalize();

        for (let i = 0; i < block.words.length; i++) {
            derivedWords.push(block.words[i]);
        }
    }

    return {
        key: CryptoJS.lib.WordArray.create(derivedWords.slice(0, targetKeySize)),
        iv: CryptoJS.lib.WordArray.create(derivedWords.slice(targetKeySize, totalSize)),
    };
}

// ── Fallback: Hosted Key Decryption ───────────────────────────────────

async function decryptViaFallbackKey(encryptedSources: string): Promise<string> {
    const keyText = await requestMegaCloud(FALLBACK_KEY_URL, false);
    const key = keyText.trim();
    console.log('[MegaCloud] Using fallback key:', key.substring(0, 8) + '...');

    const decrypted = CryptoJS.AES.decrypt(encryptedSources, key);
    const result = decrypted.toString(CryptoJS.enc.Utf8);

    if (!result || result.length === 0) {
        throw new Error('Fallback key produced empty result');
    }

    return result;
}
