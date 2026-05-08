/**
 * Sakura AI — client-side chat transport.
 *
 * The model provider key must stay server-side. The app calls the
 * `sakura-ai-chat` Supabase Edge Function, which holds the provider secret,
 * handles model fallback, and applies a small per-wallet/IP rate limit.
 */

const SAKURA_AI_FUNCTION = "sakura-ai-chat";

export interface ChatMessage {
    role: "system" | "user" | "assistant" | "tool";
    content: string | null;
    name?: string;
    tool_call_id?: string;
    tool_calls?: ToolCall[];
}

export interface ToolCall {
    id: string;
    type: "function";
    function: {
        name: string;
        arguments: string; // JSON string per OpenAI spec
    };
}

export interface ToolDefinition {
    type: "function";
    function: {
        name: string;
        description: string;
        parameters: Record<string, unknown>;
    };
}

export interface ChatResponse {
    message: ChatMessage;
    finish_reason: "stop" | "tool_calls" | "length" | "content_filter" | string;
}

function getProxyConfig() {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || "";
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || "";
    const explicitUrl = process.env.NEXT_PUBLIC_SAKURA_AI_PROXY_URL || "";
    const url = explicitUrl || (supabaseUrl ? `${supabaseUrl.replace(/\/+$/, "")}/functions/v1/${SAKURA_AI_FUNCTION}` : "");
    if (!url || !anonKey) {
        throw new Error("Sakura AI is not configured yet. Update the app after enabling the Sakura AI proxy.");
    }
    return { url, anonKey };
}

function trimErrorMessage(value: string): string {
    return value.length > 180 ? `${value.slice(0, 180)}…` : value;
}

async function callSakuraAiProxy(
    messages: ChatMessage[],
    tools: ToolDefinition[],
    walletAddress?: string,
): Promise<ChatResponse> {
    const { url, anonKey } = getProxyConfig();
    const res = await fetch(url, {
        method: "POST",
        headers: {
            apikey: anonKey,
            Authorization: `Bearer ${anonKey}`,
            "Content-Type": "application/json",
            ...(walletAddress ? { "x-sakura-wallet": walletAddress } : {}),
        },
        body: JSON.stringify({
            messages,
            tools,
        }),
    });
    if (!res.ok) {
        const body = await res.text();
        let detail = "";
        let retryAfter = 0;
        try {
            const parsed = JSON.parse(body);
            detail = parsed?.error || "";
            retryAfter = Number(parsed?.retry_after_seconds || 0);
        } catch {
            detail = body;
        }
        console.error("[sakura-ai] proxy HTTP error", res.status, trimErrorMessage(detail || body));
        if (res.status === 429) {
            const wait = retryAfter > 0 ? ` Wait about ${retryAfter} seconds and try again.` : " Try again shortly.";
            throw new Error(`Sakura AI is taking a tiny breather right now.${wait}`);
        }
        throw new Error(`Sakura AI is having trouble right now (request failed, code ${res.status}). Try again in a moment.`);
    }
    const json = await res.json();
    if (!json?.message) {
        console.error("[sakura-ai] proxy empty message", JSON.stringify(json).slice(0, 500));
        throw new Error("Sakura AI returned an empty response. Try again.");
    }
    return { message: json.message, finish_reason: json.finish_reason };
}

/**
 * Resilient single-shot completion. Tries primary model, falls back through
 * the FALLBACK_MODELS chain on transient errors (rate limits, model retired).
 */
export async function groqChat(
    messages: ChatMessage[],
    tools: ToolDefinition[],
    walletAddress?: string,
): Promise<ChatResponse> {
    return callSakuraAiProxy(messages, tools, walletAddress);
}
