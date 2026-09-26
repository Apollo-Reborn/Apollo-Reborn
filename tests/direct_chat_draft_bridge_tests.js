#!/usr/bin/env node
// Executes the JavaScript extracted from ApolloDirectChatWeb.xm with a small
// Shadow-DOM/Matrix fixture. The test deliberately uses a percent-encoded room
// and fetch(new URL(...), init), matching Reddit's current client behavior.
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(`${__dirname}/../src/ApolloDirectChatWeb.xm`, 'utf8');
const start = source.indexOf('static NSString *ApolloDirectChatDraftScript(void)');
const end = source.indexOf('\n}\n\n// WKUserContentController', start);
if (start < 0 || end < 0) throw new Error('could not extract draft bridge');
const fragment = source.slice(start, end);
const parts = [];
for (const line of fragment.split('\n')) {
    const match = line.match(/^\s*(?:return\s+)?@?"((?:\\.|[^"\\])*)"/);
    if (match) parts.push(JSON.parse(`"${match[1]}"`));
}
const bridge = parts.join('');

function requireThat(ok, message) { if (!ok) throw new Error(message); }

function fixture(thread = false) {
    let now = 1000;
    const notices = [];
    const listeners = {};
    const host = { shadowRoot: null };
    const shadow = { host, querySelectorAll: selector => selector === '*' ? [] : [input, send] };
    host.shadowRoot = shadow;
    const input = {
        value: '',
        matches: selector => selector.includes('textarea'),
        getBoundingClientRect: () => ({ width: 300, height: 44 }),
        getRootNode: () => shadow,
        dispatchEvent: event => {
            if (event.options?.composed && event.options?.bubbles) listeners.input?.({ composedPath: () => [input, shadow, host], target: input, event });
        },
    };
    const send = { getBoundingClientRect: () => ({ width: 44, height: 44 }) };
    const document = {
        querySelectorAll: selector => selector === '*' ? [host] : [],
        addEventListener: (name, fn) => { listeners[name] = fn; },
    };
    let fetchImpl = () => Promise.resolve({ status: 200 });
    const window = {
        webkit: { messageHandlers: { apolloChatDraft: { postMessage: value => notices.push(value) } } },
        fetch: (...args) => fetchImpl(...args),
    };
    class XMLHttpRequest { open() {} send() {} addEventListener() {} }
    host.getAttribute = key => key === 'composer-type' && thread ? 'thread' : null;
    const TestDate = class extends Date { static now() { return now; } };
    const context = { window, document, location: { pathname: '/chat/room/!id%3Areddit.com', href: 'https://www.reddit.com/chat/room/!id%3Areddit.com' }, URL, Request: class Request {}, XMLHttpRequest, FormData: class FormData {}, InputEvent: class InputEvent { constructor(type, options) { this.type = type; this.options = options; } }, Date: TestDate, Promise, console };
    vm.runInNewContext(bridge, context);
    return { notices, listeners, input, context, type(text) { input.value = text; listeners.input({ composedPath: () => [input, shadow, host] }); }, advance(ms) { now += ms; }, setFetch(fn) { fetchImpl = fn; } };
}

async function run() {
    // Restored text crosses the actual shadow boundary only because the bridge
    // uses composed:true, then sends unchanged successfully.
    { const f = fixture(); requireThat(f.context.window.__apolloChatDraftRestore('/chat/room/!id%3Areddit.com', 'R'), 'restores into shadow composer'); requireThat(f.notices.some(n => n.kind === 'changed' && n.text === 'R'), 'restore emits changed through composed event'); await f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/r'), { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'R' }) }); requireThat(f.notices.some(n => n.kind === 'send' && n.text === 'R'), 'unchanged restored draft sends'); }
    { const f = fixture(true); f.type('thread'); requireThat(f.notices.length === 0, 'thread composer is ignored'); }
    // Request-before-clear succeeds while the request is still pending.
    { const f = fixture(); let resolve; f.setFetch(() => new Promise(r => { resolve = r; })); f.type('A'); const pending = f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/t1'), { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }); f.type(''); resolve({ status: 200 }); await pending; requireThat(f.notices.some(n => n.kind === 'sending' && n.text === 'A'), 'tracks URL-object Matrix request'); requireThat(f.notices.some(n => n.kind === 'send' && n.status === 200), 'reports pending request success after clear'); }
    // Request-before-clear failure still reports the immutable candidate.
    { const f = fixture(); let reject; f.setFetch(() => new Promise((_, r) => { reject = r; })); f.input.value = 'A'; f.listeners.input({ composedPath: () => [f.input] }); const pending = f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/t1b'), { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }); f.input.value = ''; f.listeners.input({ composedPath: () => [f.input] }); reject(new Error('offline')); await pending.catch(() => {}); requireThat(f.notices.some(n => n.kind === 'failed' && n.text === 'A'), 'request-before-clear failure preserves candidate'); }
    // Clear-before-request keeps the nonempty candidate on success and failure.
    { const f = fixture(); f.input.value = 'A'; f.listeners.input({ composedPath: () => [f.input] }); f.input.value = ''; f.listeners.input({ composedPath: () => [f.input] }); f.listeners.input({ composedPath: () => [f.input] }); f.advance(100); await f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/t2a'), { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }); requireThat(f.notices.some(n => n.kind === 'send' && n.text === 'A'), 'clear-before-request tolerates duplicate empty input events'); }
    { const f = fixture(); f.input.value = 'A'; f.listeners.input({ composedPath: () => [f.input] }); f.input.value = ''; f.listeners.input({ composedPath: () => [f.input] }); f.setFetch(() => Promise.reject(new Error('offline'))); await f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/t2'), { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }).catch(() => {}); requireThat(f.notices.some(n => n.kind === 'sending' && n.text === 'A'), 'clear-before-request retains candidate'); requireThat(f.notices.some(n => n.kind === 'failed'), 'rejection reports failure'); }
    { const f = fixture(); f.type('manual'); f.type(''); requireThat(f.notices.filter(n => n.kind === 'changed').at(-1).text === '', 'manual clear emits empty changed'); requireThat(!f.notices.some(n => n.kind === 'sending'), 'manual clear without request emits no send'); }
    // A manually cleared value is not a permanent send candidate. A later
    // failed request with identical text must not resurrect that old draft.
    { const f = fixture(); f.type('A'); f.type(''); f.advance(751); f.setFetch(() => Promise.reject(new Error('offline'))); await f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/stale'), { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }).catch(() => {}); requireThat(!f.notices.some(n => n.kind === 'sending' || n.kind === 'failed'), 'expired manual clear candidate is not restored'); }
    { const f = fixture(); f.type('A'); await f.context.window.fetch(new URL('https://matrix.redditspace.com/not-chat'), { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }); await f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/t4'), { method: 'PUT', body: JSON.stringify({ msgtype: 'm.notice', body: 'A' }) }); requireThat(!f.notices.some(n => n.kind === 'sending'), 'wrong endpoint or payload emits no send'); }
    // Intentional clear has no send notification; an older request completion retains its route snapshot.
    { const f = fixture(); let resolve; f.setFetch(() => new Promise(r => { resolve = r; })); f.input.value = 'A'; f.listeners.input({ composedPath: () => [f.input] }); const pending = f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/t3'), { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }); f.input.value = 'B'; f.listeners.input({ composedPath: () => [f.input] }); f.input.value = ''; f.listeners.input({ composedPath: () => [f.input] }); f.context.location.pathname = '/chat/room/other'; resolve({ status: 500 }); await pending; const sent = f.notices.find(n => n.kind === 'send'); requireThat(sent && sent.text === 'A' && sent.path.includes('%3A'), 'pending send remains immutable across edit/route change'); }

    // Reddit retries a failed send with the same txn id; the retry has to be
    // tracked so its success clears the preserved draft.
    { const f = fixture(); let attempt = 0; f.setFetch(() => Promise.resolve({ status: ++attempt === 1 ? 500 : 200 })); f.type('A'); const u = () => new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/retry1'); const init = { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }; await f.context.window.fetch(u(), init); f.type(''); f.advance(2000); await f.context.window.fetch(u(), init); requireThat(f.notices.filter(n => n.kind === 'sending').length === 2, 'delayed retry of the same send is tracked after composer clear'); requireThat(f.notices.some(n => n.kind === 'send' && n.status === 200), 'retry success is reported'); }
    // After a successful send the same text is no longer a candidate.
    { const f = fixture(); f.type('A'); const init = { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }; await f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/ok1'), init); await f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/ok2'), init); requireThat(f.notices.filter(n => n.kind === 'sending').length === 1, 'a delivered send is not matched again'); }
    // The retry exception is bound to one transaction, content generation,
    // and a short lifetime so it cannot revive an intentional clear.
    { const f = fixture(); f.setFetch(() => Promise.resolve({ status: 500 })); f.type('A'); const init = { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }; await f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/original'), init); f.type(''); f.advance(2000); await f.context.window.fetch(new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/different'), init); requireThat(f.notices.filter(n => n.kind === 'sending').length === 1, 'a different transaction cannot reuse the failed candidate'); }
    { const f = fixture(); f.setFetch(() => Promise.resolve({ status: 500 })); f.type('A'); const u = new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/newer'); const init = { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }; await f.context.window.fetch(u, init); f.type(''); f.advance(2000); f.type('B'); await f.context.window.fetch(u, init); requireThat(f.notices.filter(n => n.kind === 'sending').length === 1, 'an old transaction cannot claim a newer draft'); }
    { const f = fixture(); f.setFetch(() => Promise.resolve({ status: 500 })); f.type('A'); const u = new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/newer-same'); const init = { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }; await f.context.window.fetch(u, init); f.type(''); f.advance(2000); f.type('A'); await f.context.window.fetch(u, init); requireThat(f.notices.filter(n => n.kind === 'sending').length === 1, 'an old transaction cannot claim a newer same-text draft'); }
    { const f = fixture(); let status = 500; f.setFetch(() => Promise.resolve({ status })); f.type('A'); const old = new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/interleaved-old'); const different = new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/interleaved-different'); const init = { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }; await f.context.window.fetch(old, init); f.type(''); f.advance(2000); await f.context.window.fetch(different, init); status = 200; await f.context.window.fetch(old, init); requireThat(f.notices.filter(n => n.kind === 'sending').length === 2, 'a rejected transaction does not block the legitimate retry'); requireThat(f.notices.some(n => n.kind === 'send' && n.status === 200), 'interleaved legitimate retry success is reported'); }
    { const f = fixture(); f.setFetch(() => Promise.resolve({ status: 500 })); f.type('A'); const old = new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/tombstone-old'); const different = new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/tombstone-different'); const init = { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }; await f.context.window.fetch(old, init); f.type(''); f.advance(2000); await f.context.window.fetch(different, init); f.type('A'); await f.context.window.fetch(old, init); requireThat(f.notices.filter(n => n.kind === 'sending').length === 1, 'a rejected transaction cannot erase the old transaction tombstone'); }
    { const f = fixture(); f.setFetch(() => Promise.resolve({ status: 500 })); f.type('A'); const u = new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/expired'); const init = { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }; await f.context.window.fetch(u, init); f.type(''); f.advance(10001); await f.context.window.fetch(u, init); requireThat(f.notices.filter(n => n.kind === 'sending').length === 1, 'an expired retry candidate is rejected'); }
    // A late failure from an overlapping request must not recreate retry state
    // after another request for the same snapshot has already succeeded.
    { const f = fixture(); const resolvers = []; f.setFetch(() => new Promise(r => resolvers.push(r))); f.type('A'); const init = { method: 'PUT', body: JSON.stringify({ msgtype: 'm.text', body: 'A' }) }; const u1 = new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/race1'); const u2 = new URL('https://matrix.redditspace.com/_matrix/client/v3/rooms/x/send/m.room.message/race2'); const first = f.context.window.fetch(u1, init), second = f.context.window.fetch(u2, init); resolvers[0]({ status: 200 }); await first; resolvers[1]({ status: 500 }); await second; f.type(''); f.advance(2000); f.setFetch(() => Promise.resolve({ status: 200 })); await f.context.window.fetch(u2, init); requireThat(f.notices.filter(n => n.kind === 'sending').length === 2, 'late failure cannot recreate a delivered candidate'); }
}
run().then(() => console.log('direct_chat_draft_bridge_tests: 19 scenarios passed'));
