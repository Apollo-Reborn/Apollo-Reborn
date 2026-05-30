// ==UserScript==
// @name         Open in Apollo (Apollo-Reborn)
// @namespace    https://github.com/Apollo-Reborn/Apollo-Reborn
// @version      1.0.0
// @description  Open Reddit links in the Apollo app on iOS. Auto-redirects reddit.com pages to the apollo:// scheme, and rewrites Reddit links on search-result pages so they open in Apollo too.
// @author       Apollo-Reborn
// @match        *://*.reddit.com/*
// @match        *://www.google.com/*
// @match        *://www.bing.com/*
// @match        *://duckduckgo.com/*
// @run-at       document-start
// @grant        none
// @homepageURL  https://github.com/Apollo-Reborn/Apollo-Reborn
// ==/UserScript==
//
// This is an app-independent alternative to Apollo's bundled Safari extension —
// useful for the "no-extensions" IPA variant (where Apollofari.appex is stripped)
// and jailbreak/.deb installs. Install it via the free "Userscripts" app on the
// App Store (a Safari extension). Like Apollo's own extension, it is Safari-only
// on iOS: Chrome/Firefox/etc. on iOS can't run extensions or userscript managers.
//
// The reddit-redirect logic mirrors ApolloURLByConvertingResolvedURLToApolloScheme
// in the tweak (src/ApolloCommon.m): keep the full path + query and let Apollo
// parse it, so comment permalinks, profiles, and /s/ share links all work.
//
// The search-result rewriting idea is borrowed from AnthonyGress's userscript:
// https://github.com/AnthonyGress/Open-In-Apollo (reimplemented here, with /s/
// share-link support added).

(function () {
    "use strict";

    // Returns an apollo:// URL for a reddit content link, or null otherwise.
    function toApolloURL(href) {
        var url;
        try {
            url = new URL(href, window.location.href);
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

        var path = url.pathname || "/";
        if (path === "" || path === "/") {
            return null;
        }

        return "apollo://" + host + path + (url.search || "");
    }

    // Some search engines wrap result links in a redirector. Unwrap the common
    // ones so we see the real destination.
    function unwrapSearchHref(href) {
        var url;
        try {
            url = new URL(href, window.location.href);
        } catch (e) {
            return href;
        }
        var host = url.hostname.toLowerCase();
        // Google: https://www.google.com/url?q=<real>
        if (host.indexOf("google.") !== -1 && url.pathname === "/url") {
            return url.searchParams.get("q") || url.searchParams.get("url") || href;
        }
        // DuckDuckGo: https://duckduckgo.com/l/?uddg=<encoded real>
        if (host.indexOf("duckduckgo.com") !== -1 && url.pathname === "/l/") {
            return url.searchParams.get("uddg") || href;
        }
        return href;
    }

    // ---- Mode A: we're on reddit.com — auto-redirect into Apollo. ----

    var lastHandledURL = "";

    function redirectCheck() {
        var href = window.location.href;
        if (href === lastHandledURL) {
            return;
        }
        var apolloURL = toApolloURL(href);
        if (!apolloURL) {
            return;
        }
        lastHandledURL = href;
        window.stop();
        window.location.replace(apolloURL);
    }

    // ---- Mode B: we're on a search engine — rewrite Reddit result links. ----

    function rewriteResultLinks() {
        var anchors = document.querySelectorAll("a[href]");
        for (var i = 0; i < anchors.length; i++) {
            var a = anchors[i];
            if (a.dataset && a.dataset.apolloRewritten === "1") {
                continue;
            }
            var target = unwrapSearchHref(a.href);
            var apolloURL = toApolloURL(target);
            if (apolloURL) {
                a.href = apolloURL;
                if (a.dataset) {
                    a.dataset.apolloRewritten = "1";
                }
            }
        }
    }

    function observe(callback) {
        callback();
        var observer = new MutationObserver(function () {
            callback();
        });
        var root = document.documentElement || document;
        observer.observe(root, { childList: true, subtree: true });
        window.addEventListener("popstate", callback);
    }

    var onReddit = /(^|\.)reddit\.com$/i.test(window.location.hostname) ||
                   /(^|\.)redd\.it$/i.test(window.location.hostname);

    if (onReddit) {
        observe(redirectCheck);
    } else {
        // Search-result pages render after document-start; wait for DOM.
        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", function () {
                observe(rewriteResultLinks);
            });
        } else {
            observe(rewriteResultLinks);
        }
    }
})();
