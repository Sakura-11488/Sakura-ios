import * as cheerio from "cheerio";
import { Capacitor, CapacitorHttp } from '@capacitor/core';

const BASE_URL = "https://hianime.to";

async function requestHianime(url: string, expectsJson = false) {
    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.get({ url });
        if (response.status >= 400) throw new Error(`HTTP Error: ${response.status}`);
        return response.data;
    } else {
        const res = await fetch(url);
        if (!res.ok) throw new Error(`HTTP Error: ${res.status}`);
        return expectsJson ? res.json() : res.text();
    }
}

export async function searchHiAnime(query: string) {
    if (Capacitor.isNativePlatform()) {
        try {
            const { Anime } = await import("@/plugins/anime");
            const res = await Anime.searchHiAnime({ query });
            return JSON.parse(res.results);
        } catch (e) {
            console.error("Native HiAnime Search Error", e);
            return [];
        }
    }

    try {
        const html = await requestHianime(`${BASE_URL}/search?keyword=${encodeURIComponent(query)}`);
        const $ = cheerio.load(html);

        const results: any[] = [];
        $('.flw-item').each((_, el) => {
            const a = $(el).find('a.dynamic-name');
            const title = a.attr('title') || a.text();
            let href = a.attr('href') || '';

            const idMatch = href.match(/-(\d+)(?:\?|$)/);
            if (idMatch && title) {
                results.push({ id: idMatch[1], title });
            }
        });
        return results;
    } catch (e) {
        console.error("HiAnime Search Error", e);
        return [];
    }
}

export async function getHiAnimeEpisodes(animeId: string) {
    if (Capacitor.isNativePlatform()) {
        try {
            const { Anime } = await import("@/plugins/anime");
            const res = await Anime.getEpisodes({ animeId });
            return JSON.parse(res.episodes);
        } catch (e) {
            console.error("Native HiAnime Episodes Error", e);
            return [];
        }
    }

    try {
        const data = await requestHianime(`${BASE_URL}/ajax/v2/episode/list/${animeId}`, true);
        const $ = cheerio.load(data.html);

        const episodes: any[] = [];
        $('.ep-item').each((_, el) => {
            const epId = $(el).attr('data-id');
            const epNum = $(el).attr('data-number');
            const title = $(el).attr('title');
            if (epId) {
                episodes.push({
                    id: epId,
                    number: Number(epNum),
                    title: title || `Episode ${epNum}`
                });
            }
        });
        return episodes;
    } catch (e) {
        console.error("HiAnime Episodes Error", e);
        return [];
    }
}

export async function getHiAnimeServers(episodeId: string) {
    try {
        const data = await requestHianime(`${BASE_URL}/ajax/v2/episode/servers?episodeId=${episodeId}`, true);
        const $ = cheerio.load(data.html);

        const servers: any[] = [];
        $('.server-item').each((_, el) => {
            servers.push({
                serverId: $(el).attr('data-id'),
                name: $(el).find('a').text().trim(),
                type: $(el).attr('data-type') // sub or dub
            });
        });
        return servers;
    } catch (e) {
        console.error("HiAnime Servers Error", e);
        return [];
    }
}

export async function getHiAnimeSources(serverId: string) {
    try {
        const data = await requestHianime(`${BASE_URL}/ajax/v2/episode/sources?id=${serverId}`, true);
        return {
            url: data.link,
            isIframe: data.type === 'iframe'
        };
    } catch (e) {
        console.error("HiAnime Sources Error", e);
        return null;
    }
}
