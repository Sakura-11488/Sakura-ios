#import <Capacitor/Capacitor.h>

CAP_PLUGIN(AnimePlugin, "Anime",
    CAP_PLUGIN_METHOD(playEpisode, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(playLocalEpisode, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(downloadEpisode, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(cancelDownload, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(searchHiAnime, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(getEpisodes, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(clearCache, CAPPluginReturnPromise);
)
