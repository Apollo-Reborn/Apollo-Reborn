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

// The template's checklist with every box ticked except "Needs a device
// tester", which is only for authors who couldn't try the change.
const TEMPLATE_CHECKLIST = TEMPLATE.split('## Checklist')[1]
    .split('\n').filter((line) => /^- \[ \]/.test(line)).join('\n');
const CHECKLIST = TEMPLATE_CHECKLIST.replace(/^- \[ \](?! Needs a device tester)/gm, '- [x]');
const withBox = (checklist, wording, ticked) => checklist.split('\n')
    .map((line) => (line.includes(wording) ? line.replace(/^- \[[ x]\]/, ticked ? '- [x]' : '- [ ]') : line)).join('\n');
const DEVICE_TESTER_CHECKLIST = ['reproduced the bug', 'I ran this change', 'a person tried it']
    .reduce((list, wording) => withBox(list, wording, false), withBox(CHECKLIST, 'Needs a device tester', true));

// A filled-in description, built from the parts so each test can swap one.
const typeBoxes = (ticked) => ['Bug fix', 'Feature', 'Refactor (no change in behavior)']
    .map((name) => `- [${ticked.some((t) => name.startsWith(t)) ? 'x' : ' '}] ${name}`).join('\n');

function prBody(parts = {}) {
    const p = {
        type: typeBoxes(['Bug fix']),
        issue: 'Closes #1530',
        summary: 'GIFs in the feed stayed grey after scrolling back up, because the player was released while offscreen.',
        steps: '1. Open r/gifs\n2. Scroll a GIF offscreen and back\n3. It stays grey',
        before: VIDEO,
        after: SCREENSHOT,
        unchanged: '',
        tested: DEVICE_TABLE,
        checklist: CHECKLIST,
        ...parts,
    };
    return [
        '## Type', '', p.type, '',
        '## Issue', '', p.issue, '',
        '## What this changes', '', p.summary, '',
        '## Steps', '', p.steps, '',
        '## Before', '', p.before, '',
        '## After', '', p.after, '',
        '## How I checked nothing changed', '', p.unchanged, '',
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

    await test('the real template, untouched, asks for the type and the common sections', () => {
        requireEqual(failed(TEMPLATE), ['Issue', 'Type', 'What this changes', 'Tested on', 'Checklist'], 'failed');
    });

    // The real template filled in the way an author of each type would.
    function fillTemplate({ type, steps = true, before = true, after = true, unchanged = false, ipad = '| iPad | iPad Pro 13" | 26.1 | Simulator | Fixed |' }) {
        const [head, checklist] = TEMPLATE.split('## Checklist');
        let filled = head
            .replace(`- [ ] ${type}`, `- [x] ${type}`)
            .replace('\nCloses #\n', '\nCloses #1530\n')
            .replace(/(## What this changes\n\n<!--[^\n]*-->\n)/, '$1\nThe player was released offscreen, so GIFs stayed grey.\n')
            .replace('| Older or smaller iPhone | | | | |', '| Older or smaller iPhone | iPhone SE (3rd gen) | 17.5 | Simulator | Fixed |')
            .replace('| Newer or larger iPhone | | | | |', '| Newer or larger iPhone | iPhone 16 Pro Max | 26.0.1 | Real device | Fixed |')
            .replace('| iPad | | | | |', ipad)
            .replace('| iPhone Duo | | | | |', '| iPhone Duo | iPhone Duo | 27.1 | Simulator | Fixed |');
        if (steps) filled = filled.replace('1.\n2.\n3.', '1. Open r/gifs\n2. Scroll a GIF offscreen and back\n3. It stays grey');
        if (before) filled = filled.replace(/(## Before\n\n<!--[^\n]*-->\n)/, `$1\n${VIDEO}\n`);
        if (after) filled = filled.replace(/(## After\n\n<!--[^\n]*-->\n)/, `$1\n${SCREENSHOT}\n`);
        if (unchanged) filled = filled.replace(/(## How I checked nothing changed\n\n<!--[^\n]*-->\n)/, '$1\nDiffed the feed and comments request logs before and after; identical.\n');
        return `${filled}## Checklist${checklist.replace(/- \[ \](?! Needs a device tester)/g, '- [x]')}`;
    }

    await test('the real template filled in as a bug fix passes (template and check agree)', () => {
        requireEqual(problems(fillTemplate({ type: 'Bug fix' })), [], 'problems');
    });

    await test('the real template filled in as a feature, without Before media, passes', () => {
        requireEqual(problems(fillTemplate({ type: 'Feature', before: false })), [], 'problems');
    });

    await test('the real template filled in as a refactor, with no steps or media, passes', () => {
        requireEqual(problems(fillTemplate({ type: 'Refactor', steps: false, before: false, after: false, unchanged: true })), [], 'problems');
    });

    await test('the real template with an iPad row of "N/A: <reason>" passes', () => {
        const ipad = '| iPad | | | | N/A: network request only, no layout change |';
        requireEqual(problems(fillTemplate({ type: 'Bug fix', ipad })), [], 'problems');
    });

    await test('the real template has a device tester box, unticked', () => {
        requireThat(/^- \[ \] Needs a device tester/m.test(TEMPLATE), 'box');
        requireThat(!check.needsDeviceTest(TEMPLATE), 'not asked for');
    });

    await test('an empty description names the missing sections and the issue', () => {
        requireEqual(failed(''), ['Pull request template', 'Issue'], 'failed');
        requireThat(problems('')[0].includes('no Type, What this changes, Tested on and Checklist sections'), `lists the sections: ${problems('')[0]}`);
    });

    await test('type: none ticked asks for it and holds off on the type-specific sections', () => {
        requireEqual(failed(prBody({ type: typeBoxes([]), before: '', steps: '' })), ['Type'], 'failed');
    });

    await test('type: two ticked asks for one', () => {
        requireEqual(failed(prBody({ type: typeBoxes(['Bug fix', 'Feature']) })), ['Type'], 'failed');
    });

    await test('type: an uppercase [X] counts', () => {
        requireEqual(problems(prBody({ type: '- [X] Bug fix\n- [ ] Feature\n- [ ] Refactor' })), [], 'problems');
    });

    await test('bug fix: Before media is required', () => {
        requireEqual(failed(prBody({ before: '' })), ['Before'], 'failed');
    });

    await test('feature: no Before is fine, but After and the steps to try it are needed', () => {
        const type = typeBoxes(['Feature']);
        requireEqual(problems(prBody({ type, before: '' })), [], 'problems without Before');
        const lines = problems(prBody({ type, before: '', after: 'see the screenshot I took', steps: '1.' }));
        requireEqual(lines.map((l) => l.match(/^\*\*([^:*]+):/)[1]), ['Steps', 'After'], 'failed');
        requireThat(lines[0].includes('try the feature') && lines[1].includes('feature in use'), `feature wording: ${lines}`);
    });

    await test('refactor: no steps or media needed, but it has to say how nothing changed', () => {
        const type = typeBoxes(['Refactor']);
        requireEqual(problems(prBody({ type, steps: '', before: '', after: '', unchanged: 'Ran the feed, comments and inbox before and after; same requests and layout.' })), [], 'problems');
        requireEqual(failed(prBody({ type, steps: '', before: '', after: '', unchanged: '' })), ['How I checked nothing changed'], 'failed');
    });

    await test('refactor: a description without the "How I checked" section names it', () => {
        const body = prBody({ type: typeBoxes(['Refactor']) }).replace(/## How I checked nothing changed\n\n\n/, '');
        requireThat(problems(body)[0].includes('no How I checked nothing changed section'), `got ${problems(body)[0]}`);
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
        ['#1500 (no closing keyword)', true],
        ['Related to #101, #102. See also #201.', true],
        ['https://github.com/Apollo-Reborn/Apollo-Reborn/issues/1500', true],
        ['someone/else#1500', false],
        ['no number at all', false],
        ['Closes https://github.com/someone/else/issues/1', false],
        ['<!-- Closes #1500 -->', false],
    ];
    await test('feature: a request board link counts as its issue', () => {
        const type = typeBoxes(['Feature']);
        requireEqual(problems(prBody({ type, issue: 'Request: https://request.apolloreborn.app/posts/149/add-a-slideshow' })), [], 'problems');
        requireThat(failed(prBody({ type, issue: 'https://request.apolloreborn.app/' })).includes('Issue'), 'board home page is not a request');
        requireThat(problems(prBody({ type, issue: '' }))[0].includes('feature request'), 'feature wording');
    });

    await test('refactor: no issue is needed, but What this changes has to say why', () => {
        const type = typeBoxes(['Refactor']);
        const base = { type, issue: 'Closes #', steps: '', before: '', after: '', unchanged: 'Diffed the feed and comments request logs before and after; identical.' };
        requireEqual(problems(prBody(base)), [], 'no issue passes');
        const line = problems(prBody({ ...base, summary: 'cleanup' }))[0];
        requireThat(line && line.startsWith('**What this changes:**') && line.includes('worth doing'), `refactor wording: ${line}`);
    });

    await test('no type ticked: the issue is still asked for', () => {
        requireThat(failed(prBody({ type: typeBoxes([]), issue: '', before: '', steps: '' })).includes('Issue'), 'asks for it');
    });

    await test('a bare #N only counts under Issue, not elsewhere in the description', () => {
        const body = prBody({ issue: 'none yet', summary: 'See also #201: the player was released while offscreen, so GIFs stayed grey.' });
        requireThat(failed(body).includes('Issue'), 'a mention in What this changes does not count');
        requireEqual(failed(prBody({ issue: 'none yet', summary: 'Closes #1530. The player was released offscreen, so GIFs stayed grey.' })), [], 'a closing keyword anywhere still counts');
    });

    await test('issue refs: closing keywords anywhere plus any reference under Issue', () => {
        const body = prBody({ issue: 'Related to #101 and Apollo-Reborn/Apollo-Reborn#102, see https://github.com/Apollo-Reborn/Apollo-Reborn/pull/201', summary: 'Fixes #1530 in the feed, so GIFs no longer stay grey after scrolling back.' });
        requireEqual(check.issueRefsIn(body, OWNER, REPO).sort((a, b) => a - b), [101, 102, 201, 1530], 'refs');
    });

    await test('issue refs that are all pull requests fail, naming them', () => {
        const body = prBody({ issue: 'See also #201' });
        const line = check.problemsIn(body, OWNER, REPO, new Set()).find((l) => l.startsWith('**Issue:**'));
        requireThat(line && line.includes("#201 isn't an issue"), `got ${line}`);
        requireEqual(check.problemsIn(prBody({ issue: 'See also #201. Related to #101.' }), OWNER, REPO, new Set([101])), [], 'one real issue is enough');
    });

    await test('bug fix: a request board link is not enough', () => {
        requireThat(failed(prBody({ issue: 'https://request.apolloreborn.app/posts/149' })).includes('Issue'), 'fails');
    });

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
        ['result "No"', 'iPad Air | 26.1 | Simulator | No', false],
        ['result "none"', 'iPad Air | 26.1 | Simulator | none', false],
        ['result "didn\'t test it"', 'iPad Air | 26.1 | Simulator | didn\'t test it', false],
        ['result "Skipped"', 'iPad Air | 26.1 | Simulator | Skipped', false],
        ['result "No regressions"', 'iPad Air | 26.1 | Simulator | No regressions', true],
        ['result "Not affected, list scrolls normally"', 'iPad Air | 26.1 | Simulator | Not affected, list scrolls normally', true],
        ['result "None of the bars jump"', 'iPad Air | 26.1 | Simulator | None of the bars jump', true],
        ['kind that is neither', 'iPad Air | 26.1 | yes | Fixed', false],
        ['kind "Sim", bold result', 'iPad Air | 26.1 | Sim | **Works**', true],
        ['kind "real device"', 'iPad mini 6 | 18.5 | real device | ✅', true],
        ['"N/A: <reason>" in Result, rest empty', ' | | | N/A: network request only, no layout', true],
        ['"N/A - <reason>" in Model, rest empty', 'N/A - fix is in the inbox network path | | |', true],
        ['bare "N/A" in every cell', 'N/A | N/A | N/A | N/A', false],
        ['"N/A: no iPad" (reason too short)', ' | | | N/A: no iPad', false],
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
        requireThat(device.includes('N/A: <why'), 'says iPad and Duo can be N/A');
    });

    await test('tested on: an iPhone row can never be N/A', () => {
        const tested = DEVICE_TABLE.replace('| Older or smaller iPhone | iPhone 13 mini | 18.6 | Real device | Fixed |', '| Older or smaller iPhone | | | | N/A: network request only, no layout |');
        const device = problems(prBody({ tested })).find((line) => line.startsWith('**Tested on:**'));
        requireThat(device && device.includes('fill in the older or smaller iPhone row ('), `got ${device}`);
        requireThat(!device.includes('N/A: <why'), 'no N/A hint when only an iPhone row is missing');
    });

    await test('tested on: iPad and Duo both N/A still needs both iPhones', () => {
        const tested = DEVICE_TABLE
            .replace(/\| iPad \|.*$/m, '| iPad | | | | N/A: background refresh only |')
            .replace(/\| iPhone Duo \|.*$/m, '| iPhone Duo | | | | N/A: background refresh only |');
        requireEqual(problems(prBody({ tested })), [], 'both iPhones tested passes');
        const noIphone = tested.replace(/\| Newer or larger iPhone \|.*$/m, '| Newer or larger iPhone | | | | |');
        requireThat(failed(prBody({ tested: noIphone })).includes('Tested on'), 'missing iPhone fails');
    });

    await test('tested on: a list instead of the table fails', () => {
        const tested = '- iPhone 13 mini, iOS 18\n- iPhone 17 Pro Max, iOS 27\n- iPad, iOS 26\n- Duo, iOS 27.1';
        requireThat(failed(prBody({ tested })).includes('Tested on'), 'fails');
    });

    await test('checklist: an unticked box is named, with the device tester hint', () => {
        const checklist = withBox(CHECKLIST, 'a person tried it', false);
        const line = problems(prBody({ checklist })).find((l) => l.startsWith('**Checklist:**'));
        requireThat(line && line.includes('"a person tried it"') && !line.includes('"both builds"'), `got ${line}`);
        requireThat(line.includes('Needs a device tester'), 'hints at the device tester box');
    });

    await test('checklist: an unticked build box gets no device tester hint', () => {
        const line = problems(prBody({ checklist: withBox(CHECKLIST, 'make package', false) })).find((l) => l.startsWith('**Checklist:**'));
        requireThat(line && line.includes('"`make package` passes"') && !line.includes('device tester'), `got ${line}`);
    });

    await test('checklist: deleting boxes fails', () => {
        requireThat(failed(prBody({ checklist: CHECKLIST.split('\n').slice(0, 2).join('\n') })).includes('Checklist'), 'fails');
    });

    await test('checklist: reordered boxes still pass', () => {
        requireEqual(problems(prBody({ checklist: CHECKLIST.split('\n').reverse().join('\n') })), [], 'problems');
    });

    await test('checklist: the reproduced box is only needed for a bug fix', () => {
        const checklist = withBox(CHECKLIST, 'reproduced the bug', false);
        requireThat(failed(prBody({ checklist })).includes('Checklist'), 'bug fix needs it');
        requireEqual(problems(prBody({ checklist, type: typeBoxes(['Feature']), before: '' })), [], 'feature does not');
    });

    await test('device tester: waives the reproduced / ran it / person boxes and takes N/A media', () => {
        const body = prBody({
            checklist: DEVICE_TESTER_CHECKLIST,
            before: 'N/A: only happens on a device I do not have',
            after: 'N/A: same, and the simulator cannot reproduce it',
        });
        requireEqual(problems(body), [], 'problems');
        requireThat(check.needsDeviceTest(body), 'asks for a tester');
    });

    await test('device tester: N/A media without the box fails, and a bare N/A fails either way', () => {
        requireEqual(failed(prBody({ before: 'N/A: only happens on a device I do not have' })), ['Before'], 'without the box');
        const lines = problems(prBody({ checklist: DEVICE_TESTER_CHECKLIST, before: 'N/A' }));
        requireThat(lines.length === 1 && lines[0].startsWith('**Before:**') && lines[0].includes('N/A: <why'), `got ${lines}`);
    });

    await test('device tester: the build and read-every-line boxes are still needed', () => {
        const checklist = withBox(DEVICE_TESTER_CHECKLIST, 'make package', false);
        const line = problems(prBody({ checklist })).find((l) => l.startsWith('**Checklist:**'));
        requireThat(line && line.includes('make package') && !line.includes('a person tried it'), `got ${line}`);
    });

    await test('steps: an untouched "1. 2. 3." fails', () => {
        requireThat(failed(prBody({ steps: '1.\n2.\n3.' })).includes('Steps'), 'fails');
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
    openPRs = [], // the author's other open PRs, by number
    prNumbers = [], // numbers that are pull requests rather than issues
    missingNumbers = [], // numbers that don't exist
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
        files,
        comments: comments.map((c, i) => ({ id: 900 + i, ...c })),
        events: events.map((e) => ({ ...e })),
        nextCommentId: 1000,
        lookups: [], // issue numbers looked up (reads, so not in calls)
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
        async get({ issue_number: n }) {
            store.lookups.push(n);
            if (missingNumbers.includes(n)) throw httpError(404);
            return { data: prNumbers.includes(n) ? { number: n, pull_request: {} } : { number: n } };
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
        async listFiles() {
            return { data: store.files.map((file) => (typeof file === 'string' ? { filename: file, additions: 10, deletions: 2 } : file)) };
        },
        async list() {
            const others = openPRs.map((n) => ({ number: n, user: { login: author } }));
            const someoneElse = [{ number: 1, user: { login: 'someone' } }];
            const self = store.pr.state === 'open' ? [{ number: store.pr.number, user: { login: author } }] : [];
            return { data: [...someoneElse, ...others, ...self] };
        },
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

    await test('an Issue section pointing only at a PR closes the PR, naming it', async () => {
        const h = harness({ body: prBody({ issue: 'See also #201' }), prNumbers: [201] });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'closed', 'closed');
        requireEqual(h.store.lookups, [201], 'looked it up');
        requireThat(h.store.comments[0].body.includes("#201 isn't an issue"), 'names it');
    });

    await test('"Related to" an issue passes when it is an issue', async () => {
        const h = harness({ body: prBody({ issue: 'Related to #101, #102. See also #201.' }), prNumbers: [201] });
        await h.fire('opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test('a number that does not exist does not count', async () => {
        const h = harness({ body: prBody({ issue: 'Related to #99999' }), missingNumbers: [99999] });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'closed', 'closed');
    });

    await test('drafts are not looked up', async () => {
        const h = harness({ body: prBody({ issue: 'Related to #101' }), draft: true });
        await h.fire('opened');
        requireEqual(h.store.lookups, [], 'no lookups');
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

    const big = [{ filename: 'src/ApolloExample.xm', additions: 600, deletions: 0 }];
    const labelsOf = (h) => h.store.pr.labels.map((l) => l.name);
    const sizeComment = (h) => h.store.comments.find((c) => c.body.startsWith(check.SIZE_MARKER));

    await test('a change over the size limit stays open, labelled needs-size-ok, with its own comment', async () => {
        const files = [{ filename: 'src/ApolloExample.xm', additions: 700, deletions: 20 }, { filename: 'tests/example_tests.m', additions: 900, deletions: 0 }];
        const h = harness({ files, repoHasLabel: false });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'open', 'stays open');
        requireEqual(labelsOf(h), [check.NEEDS_SIZE_LABEL], 'labels');
        requireThat(h.calls.some((c) => c[0] === 'createLabel' && c[1] === check.SIZE_LABEL), 'creates large-change-ok for maintainers');
        const comment = sizeComment(h);
        requireThat(comment && comment.body.includes('720 lines') && comment.body.includes('stays open'), `counts only non-test lines: ${comment && comment.body}`);
        requireEqual(h.store.comments.length, 1, 'only the size comment');
    });

    await test('a maintainer adding large-change-ok takes needs-size-ok off and says so', async () => {
        const h = harness({ files: big });
        await h.fire('opened');
        h.store.pr.labels.push({ name: check.SIZE_LABEL });
        await h.fire('labeled', 'maintainer', check.SIZE_LABEL);
        requireEqual(labelsOf(h), [check.SIZE_LABEL], 'labels');
        requireThat(sizeComment(h).body.includes('agreed'), 'comment updated');
        requireEqual(h.store.comments.length, 1, 'updated in place');
    });

    await test('a draft over the size limit is labelled too', async () => {
        const h = harness({ files: big, draft: true, body: '' });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'open', 'open');
        requireEqual(labelsOf(h), [check.NEEDS_SIZE_LABEL], 'labels');
    });

    await test('a push that takes a PR past the size limit labels it and never closes it', async () => {
        for (const draft of [false, true]) {
            const h = harness({ files: big, draft });
            await h.fire('synchronize');
            requireEqual(h.store.pr.state, 'open', `open (draft: ${draft})`);
            requireEqual(labelsOf(h), [check.NEEDS_SIZE_LABEL], `labels (draft: ${draft})`);
            requireThat(!h.calls.some((c) => c[0] === 'update'), 'never closed');
        }
    });

    await test('a push back under the limit takes the label off', async () => {
        const h = harness({ files: big });
        await h.fire('synchronize');
        h.store.files = [{ filename: 'src/ApolloExample.xm', additions: 300, deletions: 0 }];
        await h.fire('synchronize');
        requireEqual(labelsOf(h), [], 'labels');
        requireThat(sizeComment(h).body.includes('300 lines'), 'comment updated');
    });

    await test('a second push over the limit does not comment again', async () => {
        const h = harness({ files: big });
        await h.fire('synchronize');
        const calls = h.calls.length;
        await h.fire('synchronize');
        requireEqual(h.calls.length, calls, 'no new calls');
    });

    await test('a push under the limit, or with large-change-ok, or to an incomplete PR does nothing', async () => {
        for (const options of [{}, { files: big, labels: [check.SIZE_LABEL] }, { body: missingBody }]) {
            const h = harness(options);
            await h.fire('synchronize');
            requireEqual(h.calls, [], `calls for ${JSON.stringify(Object.keys(options))}`);
        }
    });

    await test('a big PR missing paperwork is closed for the paperwork, and size stays a separate label', async () => {
        const h = harness({ files: big, body: missingBody });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'closed', 'closed');
        requireEqual(labelsOf(h).sort(), [check.LABEL, check.NEEDS_SIZE_LABEL].sort(), 'labels');
        const rules = h.store.comments.find((c) => c.body.startsWith(check.MARKER));
        requireThat(rules && !rules.body.includes('lines outside'), 'the rules comment does not mention size');
    });

    await test('a push to a PR a maintainer reopened while flagged does not close it again', async () => {
        const h = harness({ files: big, labels: [check.LABEL], comments: [flaggedComment(`${check.MARKER}\nold`)] });
        await h.fire('synchronize');
        requireEqual(h.store.pr.state, 'open', 'state');
        requireThat(!h.calls.some((call) => call[0] === 'update'), 'never closed');
    });

    await test('verification-not-needed also takes needs-size-ok off', async () => {
        const h = harness({ files: big, labels: [check.NEEDS_SIZE_LABEL, check.SKIP_LABEL] });
        await h.fire('labeled', 'maintainer', check.SKIP_LABEL);
        requireEqual(labelsOf(h), [check.SKIP_LABEL], 'labels');
    });

    await test('lines in tests/ and docs do not count toward the size limit', async () => {
        const files = [{ filename: 'src/A.xm', additions: 400, deletions: 0 }, { filename: 'tests/a.m', additions: 2000, deletions: 0 }, { filename: 'docs/a.md', additions: 900, deletions: 0 }];
        const h = harness({ files });
        await h.fire('opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test(`a ${check.MAX_OPEN_PRS + 1}th open PR from one author is closed, even as a draft`, async () => {
        const h = harness({ draft: true, body: '', openPRs: [1601, 1602, 1603] });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'closed', 'closed');
        const comment = h.store.comments[0].body;
        requireThat(comment.includes('**Open PRs:**') && comment.includes('#1601, #1602 and #1603'), `got ${comment}`);
        requireThat(!comment.includes('**Issue:**'), 'a draft is not checked for the rest');
        requireThat(comment.includes('make any edit to this PR'), 'says an edit reopens it');
    });

    await test(`up to ${check.MAX_OPEN_PRS} open PRs is fine, and other authors' PRs do not count`, async () => {
        const h = harness({ openPRs: [1601, 1602] });
        await h.fire('opened');
        requireEqual(h.calls, [], 'calls');
    });

    await test('a PR closed for the open PR limit reopens on an edit once another one closes', async () => {
        const h = harness({ openPRs: [1601, 1602, 1603] });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'closed', 'closed');
        const h2 = harness({ labels: [check.LABEL], state: 'closed', events: closedByCheck, openPRs: [1601, 1602], comments: h.store.comments });
        await h2.fire('edited');
        requireEqual(h2.store.pr.state, 'open', 'reopened');
    });

    await test('asking for a device tester passes, labels the PR and says so', async () => {
        const body = prBody({ checklist: DEVICE_TESTER_CHECKLIST, before: 'N/A: only happens on a device I do not have', after: 'N/A: no device to record this on' });
        const h = harness({ body });
        await h.fire('opened');
        requireEqual(h.store.pr.state, 'open', 'open');
        requireThat(h.store.pr.labels.some((l) => l.name === check.DEVICE_TEST_LABEL), 'labelled');
        requireThat(h.store.comments[0].body.includes(check.DEVICE_TEST_LABEL), 'comment');
    });

    await test('filling in a closed PR with a device tester request reopens it with the label', async () => {
        const body = prBody({ checklist: DEVICE_TESTER_CHECKLIST, before: 'N/A: only happens on a device I do not have', after: 'N/A: no device to record this on' });
        const h = harness({ body, labels: [check.LABEL], state: 'closed', events: closedByCheck, comments: [flaggedComment(`${check.MARKER}\nold`)] });
        await h.fire('edited');
        requireEqual(h.store.pr.state, 'open', 'open');
        requireEqual(h.store.pr.labels.map((l) => l.name), [check.DEVICE_TEST_LABEL], 'labels');
        requireThat(h.store.comments[0].body.includes('open again') && h.store.comments[0].body.includes(check.DEVICE_TEST_LABEL), 'comment');
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
