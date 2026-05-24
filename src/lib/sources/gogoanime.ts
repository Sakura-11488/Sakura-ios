import { Capacitor, CapacitorHttp } from "@capacitor/core";

const API_BASE = (
    process.env.NEXT_PUBLIC_CONSUMET_URL || ""
).replace(/\/+$/, '');

const HIANIME_BASE = "https://hianime.dk";
const HIANIME_MIRRORS = [HIANIME_BASE, "https://hianime.to"];
const HIANIME_UA =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";

export interface AnimeSourceErrorPayload {
    message: string;
    code?: string;
    stage?: string;
    status?: number;
    details?: Record<string, unknown>;
}

export class AnimeSourceError extends Error {
    code?: string;
    stage?: string;
    status?: number;
    details?: Record<string, unknown>;

    constructor(payload: AnimeSourceErrorPayload) {
        super(payload.message);
        this.name = "AnimeSourceError";
        this.code = payload.code;
        this.stage = payload.stage;
        this.status = payload.status;
        this.details = payload.details;
    }
}

function toSourceError(value: unknown, fallback: AnimeSourceErrorPayload): AnimeSourceError {
    if (value instanceof AnimeSourceError) {
        return value;
    }
    if (value instanceof Error) {
        return new AnimeSourceError({
            ...fallback,
            message: value.message || fallback.message,
        });
    }
    return new AnimeSourceError(fallback);
}

async function parseFetchError(res: Response): Promise<AnimeSourceError> {
    let body: any = null;
    try {
        body = await res.json();
    } catch {
        body = null;
    }

    return new AnimeSourceError({
        message: body?.error || `HTTP ${res.status}`,
        code: body?.code,
        stage: body?.stage,
        status: res.status,
        details: body?.details,
    });
}

function parseNativeErrorBody(data: unknown, status: number): AnimeSourceError {
    let body: any = data;
    if (typeof body === "string") {
        try {
            body = JSON.parse(body);
        } catch {
            body = null;
        }
    }
    return new AnimeSourceError({
        message: body?.error || `HTTP ${status}`,
        code: body?.code,
        stage: body?.stage,
        status,
        details: body?.details,
    });
}

async function apiGet(path: string, timeout = 15000) {
    if (!API_BASE) throw new Error("NEXT_PUBLIC_CONSUMET_URL not set");
    const url = `${API_BASE}${path}`;

    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.get({
            url,
            connectTimeout: timeout,
            readTimeout: timeout,
        });
        if (response.status >= 400) {
            throw parseNativeErrorBody(response.data, response.status);
        }
        const payload = response.data;
        return typeof payload === "string" ? JSON.parse(payload) : payload;
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    try {
        const res = await fetch(url, { signal: controller.signal });
        if (!res.ok) throw await parseFetchError(res);
        return res.json();
    } finally {
        clearTimeout(timer);
    }
}

export function isConfigured(): boolean {
    return !!API_BASE;
}

function parseAnimeIdFromHtml(html: string): string | null {
    const match = html.match(/data-id="(\d+)"/);
    return match?.[1] || null;
}

async function fetchWatchPageHtml(slug: string): Promise<string | null> {
    for (const base of HIANIME_MIRRORS) {
        const url = `${base}/watch/${slug}`;
        try {
            if (Capacitor.isNativePlatform()) {
                const response = await CapacitorHttp.get({
                    url,
                    connectTimeout: 20000,
                    readTimeout: 20000,
                    headers: {
                        "User-Agent": HIANIME_UA,
                        Accept: "text/html,application/xhtml+xml",
                    },
                });
                if (response.status >= 400) continue;
                const html = typeof response.data === "string" ? response.data : "";
                if (html && parseAnimeIdFromHtml(html)) return html;
                continue;
            }

            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 15000);
            try {
                const res = await fetch(url, {
                    signal: controller.signal,
                    headers: {
                        "User-Agent": HIANIME_UA,
                        Accept: "text/html,application/xhtml+xml",
                    },
                });
                if (!res.ok) continue;
                const html = await res.text();
                if (html && parseAnimeIdFromHtml(html)) return html;
            } finally {
                clearTimeout(timer);
            }
        } catch {
            // Try the next mirror.
        }
    }
    return null;
}

async function resolveAnimeIdFromWatchPage(slug: string): Promise<string | null> {
    const html = await fetchWatchPageHtml(slug);
    if (!html) return null;
    return parseAnimeIdFromHtml(html);
}

async function loadNativeEpisodesForSlug(slug: string): Promise<{ id: string; number: number; title: string }[]> {
    if (!Capacitor.isNativePlatform()) return [];
    try {
        const { Anime } = await import("@/plugins/anime");
        const result = await Anime.getEpisodes({ animeId: slug });
        const parsed = JSON.parse(result.episodes) as { id?: string; number?: number; title?: string }[];
        if (!Array.isArray(parsed)) return [];
        return parsed
            .map((item) => ({
                id: String(item.id || ""),
                number: Number(item.number || 0),
                title: String(item.title || `Episode ${item.number || "?"}`),
            }))
            .filter((episode) => episode.id && episode.number > 0);
    } catch {
        return [];
    }
}

let _lastError = '';
let _lastErrorDetails: AnimeSourceErrorPayload | null = null;
export function getLastConsumetError(): string { return _lastError; }
export function getLastConsumetErrorDetails(): AnimeSourceErrorPayload | null { return _lastErrorDetails; }

export async function searchAnimeSource(query: string): Promise<{ id: string; title: string; slug?: string; animeId?: string; poster?: string }[]> {
    try {
        _lastError = '';
        _lastErrorDetails = null;
        const reqPath = `/api/search?keyword=${encodeURIComponent(query)}`;
        console.log(`[HiAnime] Searching: ${API_BASE}${reqPath}`);
        const data = await apiGet(reqPath);
        const results = data.results || data.animes || [];
        if (!Array.isArray(results) || results.length === 0) {
            _lastError = `No results for "${query}"`;
            _lastErrorDetails = { message: _lastError, code: "NO_SEARCH_RESULTS", stage: "search" };
            return [];
        }
        console.log(`[HiAnime] Found ${results.length} results for "${query}"`);
        return results.map((r: any) => {
            let rawSlug = r.slug || r.id || '';
            rawSlug = rawSlug.replace(/^watch\//, '').replace(/\/ep-\d+$/, '');
            return {
                id: rawSlug,
                title: r.name || r.title || '',
                slug: rawSlug,
                animeId: r.animeId || '',
                poster: r.poster || '',
            };
        }).filter((r: any) => r.id && r.title);
    } catch (error: any) {
        const sourceError = toSourceError(error, {
            message: `Search "${query}" failed`,
            code: "SEARCH_FAILED",
            stage: "search",
            details: { query },
        });
        _lastError = `Search "${query}": ${sourceError.message}`;
        _lastErrorDetails = {
            message: sourceError.message,
            code: sourceError.code,
            stage: sourceError.stage,
            status: sourceError.status,
            details: sourceError.details,
        };
        console.error('[HiAnime] Search error:', sourceError);
        return [];
    }
}

export async function getAnimeInfo(slug: string): Promise<{ animeId: string; name: string; description: string; poster: string } | null> {
    try {
        _lastError = '';
        _lastErrorDetails = null;
        const data = await apiGet(`/api/info/${encodeURIComponent(slug)}`);
        let animeId = data.animeId || "";
        if (!animeId) {
            animeId = (await resolveAnimeIdFromWatchPage(slug)) || "";
        }
        if (!animeId) return null;
        _slugByAnimeId.set(animeId, slug);
        return {
            animeId,
            name: data.name || "",
            description: data.description || "",
            poster: data.poster || "",
        };
    } catch (error) {
        const fallbackAnimeId = await resolveAnimeIdFromWatchPage(slug);
        if (fallbackAnimeId) {
            _slugByAnimeId.set(fallbackAnimeId, slug);
            return {
                animeId: fallbackAnimeId,
                name: "",
                description: "",
                poster: "",
            };
        }
        const sourceError = toSourceError(error, {
            message: `Failed to resolve provider info for "${slug}"`,
            code: "INFO_FAILED",
            stage: "info",
            details: { slug },
        });
        _lastError = sourceError.message;
        _lastErrorDetails = {
            message: sourceError.message,
            code: sourceError.code,
            stage: sourceError.stage,
            status: sourceError.status,
            details: sourceError.details,
        };
        console.error('[HiAnime] Info error:', sourceError);
        return null;
    }
}

const _serverIdsCache = new Map<string, string>();
const _slugByAnimeId = new Map<string, string>();

export function setSlugForAnimeId(animeId: string, slug: string) {
    _slugByAnimeId.set(animeId, slug);
}

export async function getAnimeSourceEpisodes(animeIdOrSlug: string): Promise<{ id: string; number: number; title: string }[]> {
    try {
        _lastError = '';
        _lastErrorDetails = null;
        let animeId = animeIdOrSlug;

        if (!/^\d+$/.test(animeId)) {
            const info = await getAnimeInfo(animeId);
            if (!info?.animeId) {
                const nativeEpisodes = await loadNativeEpisodesForSlug(animeId);
                if (nativeEpisodes.length > 0) {
                    return nativeEpisodes.map((episode) => ({
                        id: episode.id,
                        number: episode.number,
                        title: episode.title,
                    }));
                }
                console.warn(`[HiAnime] Could not resolve animeId for slug "${animeIdOrSlug}"`);
                return [];
            }
            animeId = info.animeId;
        }

        console.log(`[HiAnime] Fetching episodes for animeId=${animeId}`);
        const data = await apiGet(`/api/episodes/${animeId}`);
        if (!data.episodes || !Array.isArray(data.episodes)) return [];

        console.log(`[HiAnime] Got ${data.episodes.length} episodes`);
        return data.episodes
            .filter((ep: any) => ep.number > 0)
            .map((ep: any) => {
                const compactId = `hi-${animeId}-${ep.number}`;
                if (ep.serverIds) {
                    _serverIdsCache.set(compactId, ep.serverIds);
                }
                return {
                    id: compactId,
                    number: ep.number ?? 0,
                    title: ep.title || `Episode ${ep.number ?? '?'}`,
                };
            });
    } catch (error) {
        const sourceError = toSourceError(error, {
            message: `Failed to fetch episode list for "${animeIdOrSlug}"`,
            code: "EPISODES_FAILED",
            stage: "episodes",
            details: { animeIdOrSlug },
        });
        _lastError = sourceError.message;
        _lastErrorDetails = {
            message: sourceError.message,
            code: sourceError.code,
            stage: sourceError.stage,
            status: sourceError.status,
            details: sourceError.details,
        };
        console.error('[HiAnime] Episodes error:', sourceError);
        return [];
    }
}

export function getServerIdsForEpisode(episodeId: string): string | null {
    return _serverIdsCache.get(episodeId) || null;
}

export async function getStreamingSources(episodeId: string, category: 'sub' | 'dub' = 'sub'): Promise<{
    sources: { url: string; isM3U8: boolean; quality: string }[];
    subtitles: { file: string; label?: string }[];
    referer?: string;
    intro?: { start: number; end: number } | null;
    outro?: { start: number; end: number } | null;
    category?: string;
    availableCategories?: string[];
} | null> {
    try {
        _lastError = '';
        _lastErrorDetails = null;
        console.log(`[HiAnime] getStreamingSources called with: ${episodeId} category=${category}`);

        if (!episodeId.startsWith('hi-')) {
            throw new AnimeSourceError({
                message: `Unknown HiAnime episode format: ${episodeId}`,
                code: "INVALID_EPISODE_ID",
                stage: "mapping",
                details: { episodeId, category },
            });
        }

        const parts = episodeId.match(/^hi-(\d+)-(\d+)$/);
        if (!parts) {
            throw new AnimeSourceError({
                message: `Could not parse HiAnime episode id "${episodeId}"`,
                code: "INVALID_EPISODE_ID",
                stage: "mapping",
                details: { episodeId, category },
            });
        }
        const [, animeId, epNum] = parts;

        const slug = _slugByAnimeId.get(animeId);
        if (!slug) {
            console.log(`[HiAnime] No slug cached for animeId=${animeId}, refetching...`);
            await getAnimeSourceEpisodes(animeId);
        }

        const resolvedSlug = _slugByAnimeId.get(animeId);
        if (!resolvedSlug) {
            throw new AnimeSourceError({
                message: `Could not resolve provider slug for anime ${animeId}`,
                code: "MISSING_SLUG",
                stage: "mapping",
                details: { animeId, episodeId, category },
            });
        }

        try {
            const data = await apiGet(`/api/m3u8/${encodeURIComponent(resolvedSlug)}/${epNum}?category=${category}`, 30000);
            if (data?.sources?.length > 0) {
                const src = data.sources[0];
                console.log(`[HiAnime] SUCCESS (m3u8, ${category}): ${src.url.substring(0, 80)}...`);
                return {
                    sources: [{
                        url: src.url,
                        isM3U8: src.isM3U8 !== false,
                        quality: src.quality || 'auto',
                    }],
                    subtitles: (data.subtitles || []).map((s: any) => ({
                        file: s.url || s.file || '',
                        label: s.lang || s.label || 'Unknown',
                    })),
                    referer: data.headers?.Referer || HIANIME_BASE + '/',
                    intro: data.intro || null,
                    outro: data.outro || null,
                    category: data.category || category,
                    availableCategories: data.availableCategories || ['sub'],
                };
            }
            throw new AnimeSourceError({
                message: `No stream sources returned for episode ${episodeId}`,
                code: "NO_STREAM_SOURCES",
                stage: "extractor",
                details: {
                    animeId,
                    slug: resolvedSlug,
                    episodeId,
                    category,
                    availableCategories: data?.availableCategories || ['sub'],
                },
            });
        } catch (error: any) {
            const sourceError = toSourceError(error, {
                message: `Stream extraction failed for episode ${episodeId}`,
                code: "STREAM_REQUEST_FAILED",
                stage: "extractor",
                details: { animeId, slug: resolvedSlug, episodeId, category },
            });
            console.warn(`[HiAnime] m3u8 extraction failed: ${sourceError.message}`);
            throw sourceError;
        }
    } catch (error) {
        const sourceError = toSourceError(error, {
            message: `Streaming sources failed for episode ${episodeId}`,
            code: "STREAMING_FAILED",
            stage: "extractor",
            details: { episodeId, category },
        });
        _lastError = sourceError.message;
        _lastErrorDetails = {
            message: sourceError.message,
            code: sourceError.code,
            stage: sourceError.stage,
            status: sourceError.status,
            details: sourceError.details,
        };
        console.error('[HiAnime] Streaming sources error:', sourceError);
        throw sourceError;
    }
}
