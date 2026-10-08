#!/usr/bin/env node
// Executes the caption guard extracted from ApolloYouTubeCaptions.xm against a
// stand-in for iOS 27 WebKit's YouTube caption quirk
// (__InjectedScript_YouTubeCaptionQuirk.js, 24A434). The stand-in keeps the
// quirk's calls that matter here: addTextTrack('forced') + mode 'hidden' on
// setup, loadModule('captions') + mode 'showing' when the video leaves inline
// mode, captionsEnabled/captionTracks published on every caption change, and
// the 'togglecaptions' / 'selectcaptiontrack' Media Session handlers.
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(`${__dirname}/../src/ApolloYouTubeCaptions.xm`, 'utf8');
const start = source.indexOf('static NSString *const kApolloYouTubeCaptionsScript = @""');
const end = source.indexOf('"})();";', start);
if (start < 0 || end < 0) throw new Error('could not extract caption guard');
const parts = [];
for (const line of source.slice(start, end + '"})();"'.length).split('\n')) {
    const match = line.match(/^\s*"((?:\\.|[^"\\])*)"/);
    if (match) parts.push(JSON.parse(`"${match[1]}"`));
}
const guard = parts.join('');

function requireThat(ok, message) { if (!ok) throw new Error(message); }

function fixture({ hostname = 'www.youtube.com', mediaSession = true, youTubeOn = false } = {}) {
    let now = 0;
    const timers = [];
    const reports = [];

    // WebKit's TextTrack: `_mode` is what WebKit renders from.
    class TextTrack { constructor(kind, label) { this.kind = kind; this.label = label; this._mode = 'disabled'; } }
    Object.defineProperty(TextTrack.prototype, 'mode', {
        configurable: true, enumerable: true,
        get() { return this._mode; },
        set(value) { this._mode = String(value); },
    });
    class HTMLMediaElement {
        constructor(player) { this.player = player; this.textTracks = []; }
        closest(selector) { return selector === '.html5-video-player' ? this.player : null; }
    }
    HTMLMediaElement.prototype.addTextTrack = function (kind, label) {
        const track = new TextTrack(kind, label);
        this.textTracks.push(track);
        return track;
    };

    class MediaSession { constructor() { this._enabled = false; this._tracks = []; this.handlers = {}; } }
    MediaSession.prototype.setActionHandler = function (action, handler) { this.handlers[action] = handler; };
    Object.defineProperty(MediaSession.prototype, 'captionsEnabled', {
        configurable: true, enumerable: true,
        get() { return this._enabled; },
        set(value) { this._enabled = !!value; },
    });
    Object.defineProperty(MediaSession.prototype, 'captionTracks', {
        configurable: true, enumerable: true,
        get() { return this._tracks; },
        set(value) { this._tracks = value; },
    });
    const session = mediaSession ? new MediaSession() : undefined;

    // YouTube's player API, reduced to what the quirk and the guard call.
    const tracklist = [{ languageCode: 'en', displayName: 'English', vss_id: '.en' },
                       { languageCode: 'de', displayName: 'German', vss_id: '.de' }];
    const player = {
        subs: youTubeOn, unloads: 0, loads: 0, onCaptionsChanged: null,
        isSubtitlesOn() { return this.subs; },
        changed() { if (this.onCaptionsChanged) this.onCaptionsChanged(); },
        loadModule(name) { if (name === 'captions') { this.loads++; this.subs = true; this.changed(); } },
        unloadModule(name) { if (name === 'captions') { this.unloads++; this.subs = false; this.changed(); } },
        toggleSubtitles() { this.subs = !this.subs; this.changed(); },
        setOption(module, key, value) { if (key === 'track') { this.subs = !!(value && value.languageCode); this.changed(); } },
        getOption(module, key) { return key === 'tracklist' ? tracklist : null; },
    };

    const context = {
        location: { hostname },
        TextTrack, HTMLMediaElement,
        navigator: session ? { mediaSession: session } : {},
        document: { getElementById: id => (id === 'movie_player' ? player : null) },
        setTimeout: fn => { timers.push(fn); return timers.length; },
        Date: class extends Date { static now() { return now; } },
        webkit: { messageHandlers: { apolloYouTubeCaptions: { postMessage: code => reports.push(code) } } },
    };
    context.window = context;
    vm.createContext(context);
    vm.runInContext(guard, context);

    // The quirk runs after the guard: the guard is a document-start user script,
    // the quirk is injected when YouTube inserts its <video>.
    function installQuirk() {
        const video = new HTMLMediaElement(player);
        const mirror = video.addTextTrack('forced', 'YouTube Captions');
        mirror.mode = 'hidden';
        const sync = () => {
            if (!session) return;
            session.captionTracks = tracklist.map(track => ({ label: track.displayName, language: track.languageCode, enabled: player.subs }));
            session.captionsEnabled = player.isSubtitlesOn();
        };
        player.onCaptionsChanged = sync;
        if (session) {
            session.setActionHandler('togglecaptions', () => player.toggleSubtitles());
            session.setActionHandler('selectcaptiontrack', details => {
                const list = player.getOption('captions', 'tracklist') || [];
                if (details.trackIndex >= 0 && details.trackIndex < list.length) player.setOption('captions', 'track', list[details.trackIndex]);
                else player.setOption('captions', 'track', {});
            });
        }
        sync();
        return {
            mirror,
            enterFullscreen() { player.loadModule('captions'); mirror.mode = 'showing'; },
            exitFullscreen() { mirror.mode = 'hidden'; },
        };
    }

    return {
        context, session, player, reports, installQuirk,
        flush() { while (timers.length) timers.shift()(); },
        advance(ms) { now += ms; },
        menu(action, details) { return session.handlers[action](Object.assign({ action }, details)); },
    };
}

// Default: the quirk's "showing" is applied as "hidden", and YouTube's captions
// end up off with the menu told they are off.
{
    const f = fixture({ youTubeOn: true });
    const quirk = f.installQuirk();
    requireThat(f.reports.includes('guarding'), 'forced mirror track is guarded');
    requireThat(quirk.mirror._mode === 'hidden', 'mirror starts hidden');
    requireThat(f.session._enabled === false, 'menu is told captions are off even though YouTube switched them on');
    quirk.enterFullscreen();
    requireThat(quirk.mirror.mode === 'showing', 'quirk still reads back the mode it asked for');
    requireThat(quirk.mirror._mode === 'hidden', 'fullscreen keeps the mirror hidden');
    f.flush();
    requireThat(!f.player.subs, "YouTube's captions are turned back off after the quirk's loadModule");
    requireThat(f.player.unloads >= 1, 'unloadModule was used');
    requireThat(f.session._enabled === false, 'menu stays Off');
    quirk.exitFullscreen();
    requireThat(quirk.mirror._mode === 'hidden', 'leaving fullscreen passes "hidden" through');
}

// Subtitles menu On (WebKit sends selectcaptiontrack 0), then Off (-1).
{
    const f = fixture();
    const quirk = f.installQuirk();
    quirk.enterFullscreen();
    f.flush();
    f.menu('selectcaptiontrack', { trackIndex: 0 });
    requireThat(quirk.mirror._mode === 'showing', 'menu pick shows the mirror');
    requireThat(f.player.subs, "the quirk's handler turned YouTube's captions on");
    requireThat(f.session._enabled === true, 'menu is told captions are on once the user asked');
    f.flush();
    requireThat(f.player.subs, 'a user pick is not undone');
    requireThat(f.reports.includes('user-on'), 'user-on reported');
    let modeWhenYouTubeDropped = null;
    const unload = f.player.setOption.bind(f.player);
    f.player.setOption = (module, key, value) => { modeWhenYouTubeDropped = quirk.mirror._mode; unload(module, key, value); };
    f.menu('selectcaptiontrack', { trackIndex: -1 });
    requireThat(modeWhenYouTubeDropped === 'hidden', 'mirror is hidden before YouTube drops its cues');
    requireThat(!f.player.subs && quirk.mirror._mode === 'hidden', 'menu Off hides captions');
    requireThat(f.reports.includes('user-off'), 'user-off reported');
}

// togglecaptions flips what the user sees and skips the quirk's toggle when
// YouTube's state already matches.
{
    const f = fixture();
    const quirk = f.installQuirk();
    quirk.enterFullscreen();
    f.flush();
    f.menu('togglecaptions');
    requireThat(f.player.subs && quirk.mirror._mode === 'showing', 'toggle turns captions on');
    f.menu('togglecaptions');
    requireThat(!f.player.subs && quirk.mirror._mode === 'hidden', 'second toggle turns them off');
    f.player.subs = true;   // YouTube switched itself back on in between
    f.menu('togglecaptions');
    requireThat(f.player.subs && quirk.mirror._mode === 'showing', 'toggle on does not flip an already-on YouTube off');
}

// YouTube re-enabling its captions over and over can't spin the page.
{
    const f = fixture();
    const quirk = f.installQuirk();
    quirk.enterFullscreen();
    f.flush();   // the fullscreen turn-off counts toward the same window
    for (let i = 0; i < 20; i++) { f.player.subs = true; f.player.changed(); f.flush(); }
    requireThat(f.player.unloads === 8, `at most 8 turn-offs per 10 s (got ${f.player.unloads})`);
    requireThat(quirk.mirror._mode === 'hidden', 'mirror stays hidden past the limit');
    requireThat(f.session._enabled === false, 'menu stays Off past the limit');
    f.advance(10001);
    f.player.subs = true; f.player.changed(); f.flush();
    requireThat(!f.player.subs, 'turn-offs resume once the window has passed');
}

// Apollo's own page (and about:blank frames) are left alone.
{
    const f = fixture({ hostname: 'com.christianselig.apollo' });
    const quirk = f.installQuirk();
    quirk.enterFullscreen();
    f.flush();
    requireThat(quirk.mirror._mode === 'showing', 'non-YouTube frame is untouched');
    requireThat(f.reports.length === 0, 'non-YouTube frame reports nothing');
}

// A second injection into the same frame doesn't wrap twice.
{
    const f = fixture();
    const wrapped = f.context.HTMLMediaElement.prototype.addTextTrack;
    vm.runInContext(guard, f.context);
    requireThat(f.context.HTMLMediaElement.prototype.addTextTrack === wrapped, 'guard installs once per frame');
}

// No Media Session (older iOS): the mirror guard alone still works.
{
    const f = fixture({ mediaSession: false });
    const quirk = f.installQuirk();
    quirk.enterFullscreen();
    f.flush();
    requireThat(quirk.mirror._mode === 'hidden', 'mirror hidden without Media Session');
}

console.log('youtube caption guard tests passed');
