#!/usr/bin/env node
// Executes the two scripts from ApolloYouTubePlayback.m (issue #1647):
//  - the page-world play() watcher, against a stand-in <video> whose play()
//    WebKit refuses with NotAllowedError (what Low Power Mode, a hot phone, or
//    mediaTypesRequiringUserActionForPlayback = all do to a script play());
//  - the retry Apollo runs through callAsyncJavaScript, as an async function
//    body, against a stand-in embed document.
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(`${__dirname}/../src/ApolloYouTubePlayback.m`, 'utf8');

function extract(name, terminator) {
    const start = source.indexOf(`static NSString *const ${name} = @""`);
    const end = source.indexOf(terminator, start);
    if (start < 0 || end < 0) throw new Error(`could not extract ${name}`);
    const parts = [];
    for (const line of source.slice(start, end + terminator.length).split('\n')) {
        const match = line.match(/^\s*"((?:\\.|[^"\\])*)"/);
        if (match) parts.push(JSON.parse(`"${match[1]}"`));
    }
    return parts.join('');
}

const watcher = extract('kApolloYouTubePlaybackScript', '"})();";');
const retry = extract('kApolloYouTubePlaybackRetryScript', '"return \'playing\';";');

function requireThat(ok, message) { if (!ok) throw new Error(message); }

function error(name) { const e = new Error(name); e.name = name; return e; }

function fixture({ hostname = 'www.youtube.com', outcome = 'NotAllowedError' } = {}) {
    const reports = [];
    class HTMLMediaElement {}
    // WebKit's play(): resolves, or rejects with the given error name.
    HTMLMediaElement.prototype.play = function () {
        this.plays = (this.plays || 0) + 1;
        return outcome ? Promise.reject(error(outcome)) : Promise.resolve();
    };
    class HTMLVideoElement extends HTMLMediaElement {}
    class HTMLAudioElement extends HTMLMediaElement {}
    const context = {
        location: { hostname },
        HTMLMediaElement, HTMLVideoElement, HTMLAudioElement, Promise,
        webkit: { messageHandlers: { apolloYouTubePlayback: { postMessage: code => reports.push(code) } } },
    };
    context.window = context;
    vm.createContext(context);
    vm.runInContext(watcher, context);
    return { context, reports, video: () => new HTMLVideoElement(), audio: () => new HTMLAudioElement() };
}

const settle = () => new Promise(resolve => setImmediate(resolve));

(async () => {
    // A refused play() on the video is reported once, and YouTube still gets
    // play()'s own rejection.
    {
        const f = fixture();
        const video = f.video();
        let seen = null;
        await video.play().catch(e => { seen = e.name; });
        await settle();
        requireThat(seen === 'NotAllowedError', `YouTube sees the rejection (got ${seen})`);
        requireThat(f.reports.length === 1 && f.reports[0] === 'refused', `refusal reported (got ${JSON.stringify(f.reports)})`);
        await video.play().catch(() => {});
        await f.video().play().catch(() => {});
        await settle();
        requireThat(f.reports.length === 1, 'one report per page');
    }

    // A play() that starts reports nothing.
    {
        const f = fixture({ outcome: null });
        await f.video().play();
        await settle();
        requireThat(f.reports.length === 0, 'started video reports nothing');
    }

    // Other failures (a pause before the play started, a bad source) aren't
    // autoplay refusals.
    for (const name of ['AbortError', 'NotSupportedError']) {
        const f = fixture({ outcome: name });
        await f.video().play().catch(() => {});
        await settle();
        requireThat(f.reports.length === 0, `${name} is not reported`);
    }

    // Audio elements are left alone.
    {
        const f = fixture();
        await f.audio().play().catch(() => {});
        await settle();
        requireThat(f.reports.length === 0, 'audio refusal is not reported');
    }

    // The watcher's own branch never surfaces as an unhandled rejection.
    {
        let unhandled = 0;
        const onUnhandled = () => { unhandled++; };
        process.on('unhandledRejection', onUnhandled);
        const f = fixture();
        const result = f.video().play();
        result.catch(() => {});
        await settle(); await settle();
        process.off('unhandledRejection', onUnhandled);
        requireThat(unhandled === 0, `no unhandled rejection from the watcher (got ${unhandled})`);
    }

    // Apollo's own page (and about:blank frames) are left alone.
    {
        const f = fixture({ hostname: 'com.christianselig.apollo' });
        const original = f.context.HTMLMediaElement.prototype.play;
        await f.video().play().catch(() => {});
        await settle();
        requireThat(f.reports.length === 0, 'non-YouTube frame reports nothing');
        requireThat(f.context.HTMLMediaElement.prototype.play === original, 'non-YouTube frame is not wrapped');
    }

    // A second injection into the same frame doesn't wrap twice.
    {
        const f = fixture();
        const wrapped = f.context.HTMLMediaElement.prototype.play;
        vm.runInContext(watcher, f.context);
        requireThat(f.context.HTMLMediaElement.prototype.play === wrapped, 'watcher installs once per frame');
    }

    // The retry: plays YouTube's main video if it's still paused.
    {
        const run = videos => {
            const document = {
                querySelector(selector) {
                    if (selector === 'video.html5-main-video') return videos.find(v => v.main) || null;
                    if (selector === 'video') return videos[0] || null;
                    return null;
                },
            };
            const body = new Function('document', `return (async () => { ${retry} })();`);
            return body(document);
        };
        const stub = (props) => Object.assign({ paused: true, plays: 0, play() { this.plays++; this.paused = false; return Promise.resolve(); } }, props);

        const main = stub({ main: true });
        const ad = stub({});
        requireThat(await run([ad, main]) === 'playing', 'paused main video is played');
        requireThat(main.plays === 1 && ad.plays === 0, 'the main video, not the first one, is played');

        const plain = stub({});
        requireThat(await run([plain]) === 'playing', 'falls back to the only <video>');

        const playing = stub({ main: true, paused: false });
        requireThat(await run([playing]) === 'already-playing' && playing.plays === 0, 'a playing video is left alone');

        requireThat(await run([]) === 'no-video', 'no video, nothing to do');

        const refused = stub({ main: true, play() { return Promise.reject(error('NotAllowedError')); } });
        let thrown = null;
        await run([refused]).catch(e => { thrown = e.name; });
        requireThat(thrown === 'NotAllowedError', 'a refused retry surfaces as an error to Apollo');
    }

    console.log('youtube playback retry tests passed');
})().catch(e => { console.error(e); process.exit(1); });
