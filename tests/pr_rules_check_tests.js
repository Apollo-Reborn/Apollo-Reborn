#!/usr/bin/env node
// Runs .github/scripts/pr-rules-check.js (the "Pull request rules" workflow)
// against an in-memory stand-in for the GitHub API: what counts as a filled-in
// description (checked against the real pull request template), and the
// close / reopen flow.
'use strict';

const fs = require('fs');
const path = require('path');
const check = require('../.github/scripts/pr-rules-check.js');

const OWNER = 'Apollo-Reborn';
const REPO = 'Apollo-Reborn';
const TEMPLATE = fs.readFileSync(path.join(__dirname, '..', '.github', 'pull_request_template.md'), 'utf8');

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

const SCREENSHOT = '<img width="1206" height="2622" alt="IMG_0001" src="https://github.com/user-attachments/assets/30726e0b-0b87-4cfb-94b0-6c93b679b6ba" />';
const VIDEO = 'https://github.com/user-attachments/assets/546c64d8-ba92-4945-bab3-fb149ac9efbf';

const DEVICE_TABLE = [
    '| Device | Model | iOS | Real device or simulator | Result |',
    '|---|---|---|---|---|',
    '| Older or smaller iPhone | iPhone 13 mini | 18.6 | Real device | Fixed |',
    '| Newer or larger iPhone | iPhone 17 Pro Max | 27.0 | Simulator | Fixed |',
    '| iPad | iPad Air 11" | 26.1 | Simulator | Fixed, no layout change |',
    '| iPhone Duo | iPhone Duo | 27.1 | Simulator | Fixed, closed and open |',
].join('\n');

// A filled-in description, built from the parts so each test can swap one.
function prBody(parts = {}) {
    const p = {
        issue: 'Closes #1530',
        summary: 'GIFs in the feed stayed grey after scrolling back up, because the player was released while offscreen.',
        steps: '1. Open r/gifs\n2. Scroll a GIF offscreen and back\n3. It stays grey',
        before: VIDEO,
        after: SCREENSHOT,
        tested: DEVICE_TABLE,
        checklist: Array.from({ length: check.CHECKLIST_ITEMS }, (_, i) => `- [x] item ${i + 1}`).join('\n'),
        ...parts,
    };
    return [
        '## Issue', '', p.issue, '',
        '## What this fixes', '', p.summary, '',
        '## Steps to reproduce', '', p.steps, '',
        '## Before', '', p.before, '',
        '## After', '', p.after, '',
        '## Tested on', '', p.tested, '',
        '## Checklist', '', p.checklist,
    ].join('\n');
}

const problems = (body) => check.problemsIn(body, OWNER, REPO);
// Which rules failed, by the bold name each problem line starts with.
const failed = (body) => problems(body).map((line) => line.match(/^\*\*([^:*]+):/)[1]);

// ---------------------------------------------------------------- detection

async function detectionTests() {
    await test('a filled-in description passes', () => {
        requireEqual(problems(prBody()), [], 'problems');
    });

    await test('the real template, untouched, fails every rule', () => {
        requireEqual(failed(TEMPLATE),
            ['Issue', 'What this fixes', 'Steps to reproduce', 'Before', 'After', 'Tested on', 'Checklist'], 'failed');
    });

    await test('the real template, filled in, passes (template and check agree)', () => {
        const filled = TEMPLATE
            .replace('Closes #', 'Closes #1530')
            .replace(/(## What this fixes\n\n<!--[^\n]*-->\n)/, '$1\nThe player was released offscreen, so GIFs stayed grey.\n')
            .replace('1.\n2.\n3.', '1. Open r/gifs\n2. Scroll a GIF offscreen and back\n3. It stays grey')
            .replace(/(## Before\n\n<!--[^\n]*-->\n)/, `$1\n${VIDEO}\n`)
            .replace(/(## After\n\n<!--[^\n]*-->\n)/, `$1\n${SCREENSHOT}\n`)
            .replace('| Older or smaller iPhone | | | | |', '| Older or smaller iPhone | iPhone SE (3rd gen) | 17.5 | Simulator | Fixed |')
            .replace('| Newer or larger iPhone | | | | |', '| Newer or larger iPhone | iPhone 16 Pro Max | 26.0.1 | Real device | Fixed |')
            .replace('| iPad | | | | |', '| iPad | iPad Pro 13" | 26.1 | Simulator | Fixed |')
            .replace('| iPhone Duo | | | | |', '| iPhone Duo | iPhone Duo | 27.1 | Simulator | Fixed |')
            .replace(/- \[ \]/g, '- [x]');
        requireEqual(problems(filled), [], 'problems');
    });

    await test('an empty description names the missing sections and the issue', () => {
        requireEqual(failed(''), ['Pull request template', 'Issue'], 'failed');
        requireThat(problems('')[0].includes('What this fixes, Steps to reproduce, Before, After, Tested on and Checklist sections'), 'lists every section');
    });

    await test('a description with only some sections names just the missing ones', () => {
        const body = prBody().replace(/## Tested on[\s\S]*?(?=## Checklist)/, '');
        requireEqual(failed(body), ['Pull request template'], 'failed');
        requireThat(problems(body)[0].includes('no Tested on section.'), 'names Tested on');
    });

    const ISSUE_CASES = [
        ['Closes #123', true],
        ['fixes #9', true],
        ['Resolves: #1500', true],
        ['Fixed Apollo-Reborn/Apollo-Reborn#1500', true],
        ['Closes https://github.com/Apollo-Reborn/Apollo-Reborn/issues/1500', true],
        ['Closes #', false],
        ['#1500 (no closing keyword)', false],
        ['Closes https://github.com/someone/else/issues/1', false],
        ['<!-- Closes #1500 -->', false],
    ];
    for (const [issue, ok] of ISSUE_CASES) {
        await test(`issue link: ${issue}`, () => {
            requireEqual(failed(prBody({ issue })).includes('Issue'), !ok, 'Issue failed');
        });
    }

    const MEDIA_CASES = [
        ['GitHub video upload', VIDEO, true],
        ['GitHub image upload (<img>)', SCREENSHOT, true],
        ['markdown image', '![before](https://github.com/user-attachments/assets/0b1c2d3e-0000-4000-8000-000000000000)', true],
        ['older user-images upload', '![x](https://user-images.githubusercontent.com/1/2-3.png)', true],
        ['direct .mp4 link', 'https://example.com/clip.mp4', true],
        ['direct .gif link with a query', 'https://example.com/a.gif?raw=true', true],
        ['imgur', 'https://imgur.com/a/AbC123', true],
        ['streamable', 'https://streamable.com/xyz12', true],
        ['text only', 'It was broken, trust me.', false],
        ['a link to the PR branch file view', 'https://github.com/someone/Apollo-Reborn/blob/fix/thing/README.md', false],
        ['media only inside a comment', `<!-- ${VIDEO} -->`, false],
        ['empty', '', false],
    ];
    for (const [name, media, ok] of MEDIA_CASES) {
        await test(`before/after media: ${name}`, () => {
            const before = failed(prBody({ before: media }));
            const after = failed(prBody({ after: media }));
            requireEqual(before.includes('Before'), !ok, 'Before failed');
            requireEqual(after.includes('After'), !ok, 'After failed');
        });
    }

    const row = (cells) => DEVICE_TABLE.replace('| iPad | iPad Air 11" | 26.1 | Simulator | Fixed, no layout change |', `| iPad | ${cells} |`);
    const DEVICE_CASES = [
        ['empty iPad row', '| | | |', false],
        ['model N/A', 'N/A | 26.1 | Simulator | Fixed', false],
        ['iOS with no number', 'iPad Air | latest | Simulator | Fixed', false],
        ['result "not tested (no iPad)"', 'iPad Air | 26.1 | Simulator | not tested (no iPad)', false],
        ['result "-"', 'iPad Air | 26.1 | Simulator | -', false],
        ['kind that is neither', 'iPad Air | 26.1 | yes | Fixed', false],
        ['kind "Sim", bold result', 'iPad Air | 26.1 | Sim | **Works**', true],
        ['kind "real device"', 'iPad mini 6 | 18.5 | real device | ✅', true],
    ];
    for (const [name, cells, ok] of DEVICE_CASES) {
        await test(`tested on: ${name}`, () => {
            const lines = problems(prBody({ tested: row(cells) }));
            const device = lines.find((line) => line.startsWith('**Tested on:**'));
            requireEqual(Boolean(device), !ok, 'Tested on failed');
            if (device) requireThat(device.includes('fill in the iPad row ('), `names only the iPad row: ${device}`);
        });
    }

    await test('tested on: every missing row is named, rows can be in any order', () => {
        const tested = DEVICE_TABLE.split('\n').filter((line) => !/iPad|Duo/.test(line)).reverse().join('\n');
        const device = problems(prBody({ tested })).find((line) => line.startsWith('**Tested on:**'));
        requireThat(device && device.includes('fill in the iPad and iPhone Duo rows'), `got ${device}`);
    });

    await test('tested on: a list instead of the table fails', () => {
        const tested = '- iPhone 13 mini, iOS 18\n- iPhone 17 Pro Max, iOS 27\n- iPad, iOS 26\n- Duo, iOS 27.1';
        requireThat(failed(prBody({ tested })).includes('Tested on'), 'fails');
    });

    await test('checklist: one unticked box fails, with the count', () => {
        const checklist = prBody().split('## Checklist\n\n')[1].replace('- [x] item 3', '- [ ] item 3');
        const line = problems(prBody({ checklist })).find((l) => l.startsWith('**Checklist:**'));
        requireThat(line && line.includes(`(${check.CHECKLIST_ITEMS - 1} of ${check.CHECKLIST_ITEMS} ticked)`), `got ${line}`);
    });

    await test('checklist: deleting boxes fails', () => {
        requireThat(failed(prBody({ checklist: '- [x] item 1\n- [X] item 2' })).includes('Checklist'), 'fails');
    });

    await test('steps: an untouched "1. 2. 3." fails', () => {
        requireThat(failed(prBody({ steps: '1.\n2.\n3.' })).includes('Steps to reproduce'), 'fails');
    });

    await test('headings at ### and with extra words still count', () => {
        const body = prBody().replace(/^## /gm, '### ').replace('### Before', '### Before (current main)');
        requireEqual(problems(body), [], 'problems');
    });

    await test('a "# comment" inside a code block in the steps is not a heading', () => {
        const steps = '1. Run this:\n```sh\n# Before\nscripts/run-in-sim.sh --glass\n```\n2. Open r/gifs and scroll';
        requireEqual(problems(prBody({ steps })), [], 'problems');
    });

    await test('CRLF line endings (descriptions edited in the browser) pass', () => {
        requireEqual(problems(prBody().replace(/\n/g, '\r\n')), [], 'problems');
    });
}

// ------------------------------------------------------------- API stand-in

function httpError(status) {
    const error = new Error(`HTTP ${status}`);
    error.status = status;
    return error;
}

const bot = { login: check.CHECK_LOGIN, type: 'Bot' };
const flaggedComment = (body) => ({ body, user: bot });

function harness({
    body = prBody(),
    author = 'outsider',
    association = 'CONTRIBUTOR',
    role = null, // the author's repo role; null = not a collaborator (404)
    userType = 'User',
    labels = [],
    state = 'open',
    draft = false,
    merged = false,
    files = ['src/ApolloMedia.xm'],
    events = [],
    comments = [],
    repoHasLabel = true,
}) {
    const store = {
        pr: {
            number: 1700,
            state,
            draft,
            merged,
            body,
            author_association: association,
            user: { login: author, type: userType },
            labels: labels.map((name) => ({ name })),
        },
        repoLabels: repoHasLabel ? [check.LABEL] : [],
        comments: comments.map((c, i) => ({ id: 900 + i, ...c })),
        events: events.map((e) => ({ ...e })),
        nextCommentId: 1000,
    };
    const calls = [];
    const issues = {
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
            for (const name of added) store.pr.labels.push({ name });
            return { data: store.pr.labels };
        },
        async removeLabel({ name }) {
            calls.push(['removeLabel', name]);
            const before = store.pr.labels.length;
            store.pr.labels = store.pr.labels.filter((label) => label.name !== name);
            if (store.pr.labels.length === before) throw httpError(404);
            return { data: store.pr.labels };
        },
        async listComments() { return { data: store.comments.map((c) => ({ ...c })) }; },
        async listEvents() { return { data: store.events.map((e) => ({ ...e })) }; },
        async createComment({ body: commentBody }) {
            calls.push(['createComment']);
            store.comments.push({ id: store.nextCommentId++, body: commentBody, user: bot });
            return { data: {} };
        },
        async updateComment({ comment_id: id, body: commentBody }) {
            calls.push(['updateComment', id]);
            store.comments.find((c) => c.id === id).body = commentBody;
            return { data: {} };
        },
    };
    const pulls = {
        async get() { return { data: JSON.parse(JSON.stringify(store.pr)) }; },
        async listFiles() { return { data: files.map((filename) => ({ filename })) }; },
        async update({ state: newState }) {
            calls.push(['update', newState]);
            store.pr.state = newState;
            store.events.push({ event: newState === 'closed' ? 'closed' : 'reopened', actor: { login: check.CHECK_LOGIN } });
            return { data: {} };
        },
    };
    const repos = {
        async getCollaboratorPermissionLevel() {
            if (!role) throw httpError(404);
            return { data: { role_name: role, permission: role === 'maintain' ? 'write' : role } };
        },
    };
    const github = {
        rest: { issues, pulls, repos },
        async paginate(method, params) { return (await method(params)).data; },
    };
    const core = { info() {} };
    return {
        store,
        calls,
        async fire(action, sender = author, label = null) {
            const payload = { action, pull_request: { number: store.pr.number }, sender: { login: sender } };
            if (label) payload.label = { name: label };
            await check.run({ github, context: { eventName: 'pull_request_target', payload, repo: { owner: OWNER, repo: REPO } }, core });
        },
    };
}

const missingBody = prBody({ before: 'trust me', tested: '' });
const closedByCheck = [{ event: 'closed', actor: { login: check.CHECK_LOGIN } }];

async function flowTests() {
    await test('an outside PR missing things is labelled, commented on once, and closed', async () => {
        const h = harness({ body: missingBody, repoHasLabel: false });
        await h.fire('opened');
        requireEqual(h.calls, [
            ['createLabel', check.LABEL],
            ['addLabels', [check.LABEL]],
            ['createComment'],
            ['update', 'closed'],
        ], 'calls');
        const comment = h.store.comments[0].body;
        requireThat(comment.startsWith(check.MARKER), 'comment carries the marker');
        requireThat(comment.includes('**Before:**') && comment.includes('**Tested on:**'), 'comment lists what is missing');
        requireThat(!comment.includes('**After:**'), 'comment leaves out what is there');
        requireThat(comment.includes("closed for now") && comment.includes('reopens on its own'), 'comment says how to reopen');
        requireThat(comment.includes('CONTRIBUTING.md#pull-request-rules'), 'comment links the rules');
    });

    await test('a complete outside PR is left alone', async () => {
        const h = harness({});
        await h.fire('opened');
        requireEqual(h.calls, [], 'calls');
        requireEqual(h.store.pr.state, 'open', 'state');
    });

    await test('a first-time contributor is checked too', async () => {
        const h = harness({ body: missingBody, association: 'FIRST_TIME_CONTRIBUTOR' });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'closed', 'state');
    });

    for (const association of ['OWNER', 'MEMBER', 'COLLABORATOR']) {
        await test(`${association} PRs are exempt`, async () => {
            const h = harness({ body: '', association });
            await h.fire('opened');
            requireEqual(h.calls, [], 'calls');
        });
    }

    for (const role of ['admin', 'maintain', 'write']) {
        await test(`an author with ${role} access is exempt even when author_association says CONTRIBUTOR`, async () => {
            const h = harness({ body: '', role });
            await h.fire('opened');
            requireEqual(h.calls, [], 'calls');
        });
    }

    await test('an author with triage access is still checked', async () => {
        const h = harness({ body: missingBody, role: 'triage' });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'closed', 'state');
    });

    await test('bot PRs are exempt', async () => {
        const h = harness({ body: '', author: 'dependabot[bot]', userType: 'Bot' });
        await h.fire('opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test('drafts are skipped until marked ready, then checked', async () => {
        const h = harness({ body: missingBody, draft: true });
        await h.fire('opened');
        requireEqual(h.calls, [], 'calls while draft');
        h.store.pr.draft = false;
        await h.fire('ready_for_review');
        requireEqual(h.store.pr.state, 'closed', 'state after ready');
    });

    await test('docs-only PRs are exempt', async () => {
        const h = harness({ body: '', files: ['README.md', 'docs/theme-builder-RE.md'] });
        await h.fire('opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test('a docs PR that also changes code is checked', async () => {
        const h = harness({ body: missingBody, files: ['README.md', 'src/Tweak.xm'] });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'closed', 'state');
    });

    await test('verification-not-needed on opening exempts a PR', async () => {
        const h = harness({ body: '', labels: [check.SKIP_LABEL] });
        await h.fire('opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test('filling in a closed PR reopens it, drops the label and updates the comment in place', async () => {
        const h = harness({
            labels: ['bug', check.LABEL],
            state: 'closed',
            events: closedByCheck,
            comments: [{ body: 'nice', user: { login: 'someone', type: 'User' } }, flaggedComment(`${check.MARKER}\nold`)],
        });
        await h.fire('edited');
        requireEqual(h.calls, [['removeLabel', check.LABEL], ['update', 'open'], ['updateComment', 901]], 'calls');
        requireEqual(h.store.pr.state, 'open', 'state');
        requireEqual(h.store.pr.labels.map((l) => l.name), ['bug'], 'labels');
        requireThat(h.store.comments[1].body.includes('open again for review'), 'comment says it reopened');
        requireEqual(h.store.comments.length, 2, 'no extra comment');
    });

    await test('an edit that still misses something updates the list and keeps it closed', async () => {
        const h = harness({ body: prBody({ tested: '' }), labels: [check.LABEL], state: 'closed', events: closedByCheck, comments: [flaggedComment(`${check.MARKER}\nold`)] });
        await h.fire('edited');
        requireEqual(h.calls, [['updateComment', 900]], 'calls');
        requireEqual(h.store.pr.state, 'closed', 'state');
        requireThat(h.store.comments[0].body.includes('**Tested on:**') && !h.store.comments[0].body.includes('**Before:**'), 'list reflects the edit');
    });

    await test('a maintainer adding verification-not-needed reopens a PR the check closed', async () => {
        const h = harness({ body: missingBody, labels: [check.LABEL, check.SKIP_LABEL], state: 'closed', events: closedByCheck, comments: [flaggedComment(`${check.MARKER}\nold`)] });
        await h.fire('labeled', 'icpryde', check.SKIP_LABEL);
        requireEqual(h.calls, [['removeLabel', check.LABEL], ['update', 'open'], ['updateComment', 900]], 'calls');
        requireThat(h.store.comments[0].body.includes('not needing the usual checks'), 'comment says it was waived');
    });

    await test('a PR a maintainer closed after the check is not reopened when it is filled in', async () => {
        const h = harness({
            labels: [check.LABEL],
            state: 'closed',
            events: [...closedByCheck, { event: 'reopened', actor: { login: 'outsider' } }, { event: 'closed', actor: { login: 'icpryde' } }],
            comments: [flaggedComment(`${check.MARKER}\nold`)],
        });
        await h.fire('edited');
        requireEqual(h.calls, [['removeLabel', check.LABEL], ['updateComment', 900]], 'calls');
        requireEqual(h.store.pr.state, 'closed', 'state');
        requireThat(!h.store.comments[0].body.includes('open again'), 'comment does not claim a reopen');
    });

    await test('the author reopening it without filling it in closes it again', async () => {
        const h = harness({ body: missingBody, labels: [check.LABEL], state: 'open', events: closedByCheck, comments: [flaggedComment(`${check.MARKER}\nold`)] });
        await h.fire('reopened');
        requireEqual(h.store.pr.state, 'closed', 'state');
    });

    await test('a maintainer reopening it is left alone (and edits after that do not re-close it)', async () => {
        const h = harness({ body: missingBody, labels: [check.LABEL], state: 'open', comments: [flaggedComment(`${check.MARKER}\nold`)] });
        await h.fire('reopened', 'icpryde');
        await h.fire('edited');
        requireEqual(h.store.pr.state, 'open', 'state');
        requireThat(!h.calls.some((call) => call[0] === 'update'), 'never closed');
        requireThat(!h.store.comments[0].body.includes('closed for now'), 'comment does not say closed');
    });

    await test('edits never flag a PR that passed or predates the check', async () => {
        const h = harness({ body: missingBody });
        await h.fire('edited');
        await h.fire('reopened', 'icpryde');
        requireEqual(h.calls, [], 'calls');
    });

    await test('merged PRs are never touched', async () => {
        const h = harness({ body: '', labels: [check.LABEL], state: 'closed', merged: true });
        await h.fire('edited');
        requireEqual(h.calls, [], 'calls');
    });
}

(async () => {
    await detectionTests();
    await flowTests();
    if (failures) {
        console.error(`${failures} pull request rules check test(s) failed`);
        process.exit(1);
    }
    console.log('pull request rules check tests passed');
})();
