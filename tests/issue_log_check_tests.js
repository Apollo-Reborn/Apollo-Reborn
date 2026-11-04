#!/usr/bin/env node
// Runs .github/scripts/issue-log-check.js (the "Bug report log check"
// workflow) against an in-memory stand-in for the GitHub issues API: log
// detection on real issue formats, and the close / reopen flow.
'use strict';

const check = require('../.github/scripts/issue-log-check.js');

let failures = 0;
async function test(name, body) {
    try {
        await body();
        console.log(`ok - ${name}`);
    } catch (error) {
        failures++;
        console.error(`FAIL - ${name}: ${error.message}`);
    }
}
function requireThat(ok, message) { if (!ok) throw new Error(message); }
function requireEqual(actual, expected, message) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    if (a !== e) throw new Error(`${message}: expected ${e}, got ${a}`);
}

// What GitHub renders for a Bug Report form submission (an empty optional
// field renders as "_No response_").
function formBody(logField, extra = '') {
    return [
        '### Pre-submission checklist',
        '',
        "- [X] I searched existing issues and this hasn't been reported yet.",
        "- [X] I'm running the latest version of Apollo Reborn.",
        '',
        '### Describe the bug',
        '',
        'Videos in comments stop playing after I scroll.',
        '',
        check.LOG_SECTION,
        '',
        logField,
        '',
        '### Did you attach a debug log or crash log?',
        '',
        "No, continue without a log (I understand my issue may not get fixed without one)",
        '',
        '### Screenshots / screen recordings',
        '',
        extra || '_No response_',
    ].join('\n');
}

const LOG_FILE = '[apollo-reborn-2026-10-14-183012.log](https://github.com/user-attachments/files/32356799/apollo-reborn-2026-10-14-183012.log)';
const SCREENSHOT = '<img width="1206" height="2622" alt="IMG_0001" src="https://github.com/user-attachments/assets/30726e0b-0b87-4cfb-94b0-6c93b679b6ba" />';
const VIDEO = 'https://github.com/user-attachments/assets/546c64d8-ba92-4945-bab3-fb149ac9efbf';

function exportedLogExcerpt(lines) {
    const out = [];
    for (let i = 0; i < lines; i++) out.push(`[18:30:${String(10 + i).padStart(2, '0')}.123] [Media] player state ${i}`);
    return out.join('\n');
}

// ---------------------------------------------------------------- detection

const DETECTION_CASES = [
    ['attached .log', LOG_FILE, true],
    ['attached .txt (real #1160 format)', '[DebugVideo.txt](https://github.com/user-attachments/files/32356762/DebugVideo.txt)', true],
    ['attached sanitized crash .json', '[apollo-reborn-crash-123.json](https://github.com/user-attachments/files/1/apollo-reborn-crash-123.json)', true],
    ['attached zipped .ips', '[Apollo-2026-10-14-183012.ips.zip](https://github.com/user-attachments/files/2/Apollo-2026-10-14-183012.ips.zip)', true],
    ['legacy repo files link', 'https://github.com/Apollo-Reborn/Apollo-Reborn/files/12345678/apollo.log', true],
    ['pasted .ips (real #415 format)', '```\n{"app_name":"Apollo","timestamp":"2026-06-10 00:03:50.00 -0600","bug_type":"309","os_version":"iPhone OS 26.5.1 (23F81)"}\n```', true],
    ['pasted legacy crash text', 'Incident Identifier: A22FE7F1-C5F8-485C-886A-8854156C9B45\nHardware Model: iPhone18,1', true],
    ['pasted sanitized crash JSON', '{\n  "report_type" : "apollo_reborn_crash",\n  "schema_version" : 1\n}', true],
    ['pasted Export Debug Logs header', 'ApolloFix Logs — Oct 14, 2026 at 6:30 PM (412 entries)\n\n[18:30:10.123] [Media] x', true],
    ['pasted cross-launch section header', '===== Persistent login diagnostics (spans previous sessions; survives force-quit) =====', true],
    ['pasted excerpt of five log lines', exportedLogExcerpt(5), true],
    ['pasted cross-launch dated lines', [1, 2, 3, 4, 5].map((i) => `[10-14 18:30:0${i}.123] [KeychainTrace] read ${i}`).join('\n'), true],
    ['two quoted log lines are not a log', exportedLogExcerpt(2), false],
    ['n/a', 'N/A', false],
    ['the form\'s "Yes, it\'s attached above" answer alone', "### Did you attach a debug log or crash log?\n\nYes, it's attached above", false],
    ['the form\'s "continue without a log" answer', "### Did you attach a debug log or crash log?\n\nNo, continue without a log (I understand my issue may not get fixed without one)", false],
    ['empty optional field', '_No response_', false],
    ['screenshot only', SCREENSHOT, false],
    ['screen recording only', VIDEO, false],
    ['a log link on another site', 'https://pastebin.com/raw/abc123.log', false],
    ['file named like a log but an image', '[shot.log.png](https://github.com/user-attachments/files/3/shot.log.png)', false],
];

async function detectionTests() {
    for (const [name, text, expected] of DETECTION_CASES) {
        await test(`hasLog: ${name}`, () => {
            requireEqual(check.hasLog(formBody(text)), expected, 'hasLog');
        });
    }
}

// ------------------------------------------------------------- API stand-in

function httpError(status) {
    const error = new Error(`HTTP ${status}`);
    error.status = status;
    return error;
}

function harness({ body, author = 'reporter', association = 'NONE', userType = 'User', labels = [], state = 'open', repoHasLabel = true, comments = [] }) {
    const store = {
        issue: {
            number: 1500,
            state,
            body,
            author_association: association,
            user: { login: author, type: userType },
            labels: labels.map((name) => ({ name })),
        },
        repoLabels: repoHasLabel ? [check.LABEL] : [],
        comments: comments.map((c, i) => ({ id: 900 + i, ...c })),
        nextCommentId: 1000,
    };
    const calls = [];
    const issues = {
        async get() { return { data: JSON.parse(JSON.stringify(store.issue)) }; },
        async getLabel({ name }) {
            if (!store.repoLabels.includes(name)) throw httpError(404);
            return { data: { name } };
        },
        async createLabel({ name }) {
            calls.push(['createLabel', name]);
            store.repoLabels.push(name);
            return { data: { name } };
        },
        async addLabels({ labels: added }) {
            calls.push(['addLabels', added]);
            for (const name of added) store.issue.labels.push({ name });
            return { data: store.issue.labels };
        },
        async removeLabel({ name }) {
            calls.push(['removeLabel', name]);
            const before = store.issue.labels.length;
            store.issue.labels = store.issue.labels.filter((label) => label.name !== name);
            if (store.issue.labels.length === before) throw httpError(404);
            return { data: store.issue.labels };
        },
        async listComments() { return { data: store.comments.map((c) => ({ ...c })) }; },
        async createComment({ body: commentBody }) {
            calls.push(['createComment']);
            store.comments.push({ id: store.nextCommentId++, body: commentBody, user: { login: 'github-actions[bot]', type: 'Bot' } });
            return { data: {} };
        },
        async updateComment({ comment_id: id, body: commentBody }) {
            calls.push(['updateComment', id]);
            store.comments.find((c) => c.id === id).body = commentBody;
            return { data: {} };
        },
        async update({ state: newState, state_reason: reason }) {
            calls.push(['update', newState, reason || null]);
            store.issue.state = newState;
            return { data: {} };
        },
    };
    const github = {
        rest: { issues },
        async paginate(method, params) { return (await method(params)).data; },
    };
    const core = { info() {} };
    function event(eventName, action, comment) {
        const payload = { action, issue: { number: store.issue.number } };
        if (comment) payload.comment = comment;
        return { eventName, payload, repo: { owner: 'Apollo-Reborn', repo: 'Apollo-Reborn' } };
    }
    return {
        store,
        calls,
        async fire(eventName, action, comment) {
            // A comment event's comment already exists when the run reads the thread.
            if (comment && action === 'created') store.comments.push({ id: store.nextCommentId++, ...comment });
            await check.run({ github, context: event(eventName, action, comment), core });
        },
    };
}

const flaggedComment = (body) => ({ body, user: { login: 'github-actions[bot]', type: 'Bot' } });

async function flowTests() {
    await test('a new report without a log is labelled and commented on once, and stays open', async () => {
        const h = harness({ body: formBody('N/A'), repoHasLabel: false });
        await h.fire('issues', 'opened');
        requireEqual(h.calls, [
            ['createLabel', check.LABEL],
            ['addLabels', [check.LABEL]],
            ['createComment'],
        ], 'calls');
        requireEqual(h.store.issue.state, 'open', 'state');
        requireThat(h.store.comments[0].body.startsWith(check.MARKER), 'comment carries the marker');
        requireThat(h.store.comments[0].body.includes('Export Debug Logs'), 'comment says how to export a log');
        requireThat(!/closed|reopen/i.test(h.store.comments[0].body), 'comment does not talk about closing');
    });

    await test('a new report with a log is left alone', async () => {
        const h = harness({ body: formBody(LOG_FILE) });
        await h.fire('issues', 'opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test('a log edited in before the opening run is seen (run re-reads the issue)', async () => {
        const h = harness({ body: formBody('N/A') });
        h.store.issue.body = formBody(LOG_FILE);
        await h.fire('issues', 'opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test('report.apolloreborn.app issues (bot author) are exempt', async () => {
        const h = harness({ body: formBody('N/A'), author: 'apollo-reborn-reporter[bot]', userType: 'Bot' });
        await h.fire('issues', 'opened');
        requireEqual(h.calls, [], 'calls');
    });

    for (const association of ['OWNER', 'MEMBER', 'COLLABORATOR']) {
        await test(`${association} issues are exempt`, async () => {
            const h = harness({ body: formBody('N/A'), association });
            await h.fire('issues', 'opened');
            requireEqual(h.calls, [], 'calls');
        });
    }

    await test('a past contributor still needs a log', async () => {
        const h = harness({ body: formBody('N/A'), association: 'CONTRIBUTOR' });
        await h.fire('issues', 'opened');
        requireEqual(h.store.issue.labels.map((l) => l.name), [check.LABEL], 'labels');
    });

    await test('Question form issues (no log field) are exempt', async () => {
        const h = harness({ body: '### Your question\n\nHow do I change the app icon?' });
        await h.fire('issues', 'opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test('log-not-needed exempts an issue', async () => {
        const h = harness({ body: formBody('N/A'), labels: [check.SKIP_LABEL] });
        await h.fire('issues', 'opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test('editing a log into a flagged issue clears the label and updates the comment in place', async () => {
        const h = harness({
            body: formBody(LOG_FILE),
            labels: ['bug', check.LABEL],
            comments: [{ body: 'first!', user: { login: 'someone', type: 'User' } }, flaggedComment(`${check.MARKER}\nold text`)],
        });
        await h.fire('issues', 'edited');
        requireEqual(h.calls, [['removeLabel', check.LABEL], ['updateComment', 901]], 'calls');
        requireEqual(h.store.comments.length, 2, 'no extra comment');
        requireThat(h.store.comments[1].body.includes('Thanks for adding the log'), 'comment updated');
        requireEqual(h.store.issue.labels.map((l) => l.name), ['bug'], 'labels');
    });

    await test("the author's comment with a log clears the label", async () => {
        const h = harness({ body: formBody('N/A'), labels: [check.LABEL], comments: [flaggedComment(`${check.MARKER}\nold`)] });
        await h.fire('issue_comment', 'created', { body: `here you go ${LOG_FILE}`, user: { login: 'reporter', type: 'User' } });
        requireEqual(h.store.issue.labels, [], 'labels');
        requireEqual(h.store.issue.state, 'open', 'state');
    });

    await test("a log comment still counts when a later edit's run is the one that executes", async () => {
        const h = harness({
            body: formBody('N/A'),
            labels: [check.LABEL],
            comments: [flaggedComment(`${check.MARKER}\nold`), { body: LOG_FILE, user: { login: 'reporter', type: 'User' } }],
        });
        await h.fire('issues', 'edited');
        requireEqual(h.store.issue.labels, [], 'labels');
    });

    await test("someone else's comment with a log doesn't clear the label", async () => {
        const h = harness({ body: formBody('N/A'), labels: [check.LABEL] });
        await h.fire('issue_comment', 'created', { body: LOG_FILE, user: { login: 'bystander', type: 'User' } });
        requireEqual(h.calls, [], 'calls');
    });

    await test('an edit without a log keeps the label', async () => {
        const h = harness({ body: formBody('still N/A'), labels: [check.LABEL] });
        await h.fire('issues', 'edited');
        requireEqual(h.calls, [], 'calls');
    });

    await test('edits and comments never flag an issue (old issues stay untouched)', async () => {
        const h = harness({ body: formBody('N/A') });
        await h.fire('issues', 'edited');
        await h.fire('issue_comment', 'created', { body: 'any update?', user: { login: 'reporter', type: 'User' } });
        requireEqual(h.calls, [], 'calls');
    });

    await test('the check never reopens or closes: a flagged issue a maintainer closed stays closed when the log arrives', async () => {
        const h = harness({ body: formBody(LOG_FILE), labels: [check.LABEL], state: 'closed', comments: [flaggedComment(`${check.MARKER}\nold`)] });
        await h.fire('issues', 'edited');
        requireEqual(h.calls, [['removeLabel', check.LABEL], ['updateComment', 900]], 'calls');
        requireEqual(h.store.issue.state, 'closed', 'state');
    });
}

(async () => {
    await detectionTests();
    await flowTests();
    if (failures) {
        console.error(`${failures} issue log check test(s) failed`);
        process.exit(1);
    }
    console.log('issue log check tests passed');
})();
