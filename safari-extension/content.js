// Apollo-Reborn — "Open in Apollo" Safari Web Extension content script.
//
// Redirects Reddit web pages straight to the apollo:// scheme so the link
// opens in the (sideloaded) Apollo app. This is the JS mirror of
// ApolloURLByConvertingResolvedURLToApolloScheme (src/ApolloCommon.m): we keep
// the full path + query and let Apollo's own URL handler do the parsing, so
// comment permalinks, user profiles, and /s/ share links all work without a
// brittle per-segment regex. /s/ links are resolved in-app by ApolloShareLinks.
//
// Why this differs from the stock Apollo extension: the stock "Automatic" mode
// routed through an external interstitial page whose auto-open relied on an iOS
// Smart App Banner bound to the App Store build (app id 979274575). A sideloaded
// Apollo-Reborn is not that App Store app, so the banner never recognized it and
// users were stranded on the interstitial. We drop that dependency entirely and
// always redirect straight into Apollo. (See README / CHANGELOG for the domain.)

(function () {
    "use strict";

    // Guards against re-redirecting the same URL (e.g. when the SPA mutates the
    // DOM after we've already kicked off navigation).
    var lastHandledURL = "";

    // Mirror of ApolloURLByConvertingResolvedURLToApolloScheme.
    // Returns an apollo:// URL string, or null if this isn't a reddit content link.
    function toApolloURL(href) {
        var url;
        try {
            url = new URL(href);
        } catch (e) {
            return null;
        }

        var host = url.hostname.toLowerCase();
        if (host === "reddit.com" || host.endsWith(".reddit.com")) {
            host = "reddit.com";
        } else if (host === "redd.it" || host.endsWith(".redd.it")) {
            // Keep the redd.it host as-is; Apollo's handler accepts it too.
        } else {
            return null;
        }

        // Don't hijack a bare host (e.g. https://reddit.com/ or the homepage);
        // only act on actual content paths (/r/..., /u/..., /user/..., etc.).
        var path = url.pathname || "/";
        if (path === "" || path === "/") {
            return null;
        }

        return "apollo://" + host + path + (url.search || "");
    }

    function runCheck() {
        var href = window.location.href;
        if (href === lastHandledURL) {
            return; // already handled this URL
        }

        var apolloURL = toApolloURL(href);
        if (!apolloURL) {
            return;
        }

        lastHandledURL = href;
        window.stop();
        window.location.replace(apolloURL);
    }

    function start(isAutomatic) {
        // The popup lets the user turn auto-open off. When off, leave the page
        // alone (the toolbar action and the iOS Share sheet still work).
        if (isAutomatic === false) {
            return;
        }

        runCheck();

        // Reddit is a single-page app: the URL can change without a full
        // navigation. Re-check on history changes and DOM mutations. This
        // replaces the deprecated DOMNodeInserted listener the stock script used.
        window.addEventListener("popstate", runCheck);

        var observer = new MutationObserver(function () {
            runCheck();
        });
        observer.observe(document.documentElement || document, {
            childList: true,
            subtree: true
        });
    }

    // The popup stores { automaticObj: { isAutomatic: bool } }; default true.
    try {
        browser.storage.local.get(function (item) {
            var automaticObj = item && item.automaticObj;
            var isAutomatic = (automaticObj === undefined || automaticObj === null)
                ? true
                : automaticObj.isAutomatic;
            start(isAutomatic);
        });
    } catch (e) {
        // If storage is unavailable for any reason, default to automatic.
        start(true);
    }
})();
