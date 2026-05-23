"use client";

import {
    createContext,
    useCallback,
    useContext,
    useEffect,
    useMemo,
    useState,
    type ReactNode,
} from "react";
import { getLocal, setLocal, STORAGE_KEYS } from "@/lib/storage";
import { schedulePushSettings } from "@/lib/cloud-sync";
import {
    DEFAULT_LOCALE,
    SUPPORTED_LOCALES,
    detectDeviceLocale,
    getIntlLocale,
    getLocaleDirection,
    isSupportedLocale,
    type Locale,
} from "./config";
import { defaultMessages, messages, type TranslationKey } from "./messages";

type InterpolationValues = Record<string, string | number>;

interface I18nContextValue {
    locale: Locale;
    dir: "ltr" | "rtl";
    setLocale: (locale: Locale) => void;
    comradeTransition: "activating" | "deactivating" | null;
    completeComradeTransition: () => void;
    t: (key: TranslationKey, values?: InterpolationValues) => string;
    formatNumber: (value: number, options?: Intl.NumberFormatOptions) => string;
    formatDate: (value: Date | number | string, options?: Intl.DateTimeFormatOptions) => string;
}

const I18nContext = createContext<I18nContextValue | null>(null);

function getConnectedWallet(): string | null {
    if (typeof window === "undefined") return null;
    try {
        return localStorage.getItem(STORAGE_KEYS.WALLET_ADDRESS);
    } catch {
        return null;
    }
}

function readInitialLocale(): Locale {
    const settings = getLocal<Record<string, unknown>>(STORAGE_KEYS.SETTINGS, {});
    const saved = typeof settings.language === "string" ? settings.language : null;
    return isSupportedLocale(saved) ? saved : detectDeviceLocale();
}

function interpolate(template: string, values?: InterpolationValues): string {
    if (!values) return template;
    return template.replace(/\{(\w+)\}/g, (_, key: string) => {
        const value = values[key];
        return value == null ? "" : String(value);
    });
}

export function I18nProvider({ children }: { children: ReactNode }) {
    const [locale, setLocaleState] = useState<Locale>(DEFAULT_LOCALE);
    const [hydrated, setHydrated] = useState(false);
    const [comradeTransition, setComradeTransition] = useState<"activating" | "deactivating" | null>(null);

    useEffect(() => {
        setLocaleState(readInitialLocale());
        setHydrated(true);
    }, []);

    const setLocale = useCallback((nextLocale: Locale) => {
        setLocaleState(previousLocale => {
            if (previousLocale !== nextLocale) {
                if (nextLocale === "comrade") {
                    setComradeTransition("activating");
                } else if (previousLocale === "comrade") {
                    setComradeTransition("deactivating");
                }
            }
            return nextLocale;
        });
        const settings = getLocal<Record<string, unknown>>(STORAGE_KEYS.SETTINGS, {});
        setLocal(STORAGE_KEYS.SETTINGS, { ...settings, language: nextLocale });
        const wallet = getConnectedWallet();
        if (wallet) schedulePushSettings(wallet);
    }, []);

    const completeComradeTransition = useCallback(() => {
        setComradeTransition(null);
    }, []);

    useEffect(() => {
        if (!hydrated) return;
        document.documentElement.lang = locale;
        document.documentElement.dir = getLocaleDirection(locale);
    }, [hydrated, locale]);

    const value = useMemo<I18nContextValue>(() => {
        const activeMessages = messages[locale] || messages[DEFAULT_LOCALE];
        const dir = getLocaleDirection(locale);
        const intlLocale = getIntlLocale(locale);
        return {
            locale,
            dir,
            setLocale,
            comradeTransition,
            completeComradeTransition,
            t: (key, values) => interpolate(activeMessages[key] || defaultMessages[key] || key, values),
            formatNumber: (number, options) => new Intl.NumberFormat(intlLocale, options).format(number),
            formatDate: (date, options) => new Intl.DateTimeFormat(intlLocale, options).format(new Date(date)),
        };
    }, [comradeTransition, completeComradeTransition, locale, setLocale]);

    return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nContextValue {
    const context = useContext(I18nContext);
    if (!context) {
        throw new Error("useI18n must be used within I18nProvider");
    }
    return context;
}

export { SUPPORTED_LOCALES };
export type { Locale, TranslationKey };
