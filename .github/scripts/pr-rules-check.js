// Pull request rules check, run by .github/workflows/pr-rules-check.yml.
//
// Pull requests from outside the core team have to show the work behind them
// (CONTRIBUTING.md#pull-request-rules): a linked issue (for a feature, its
// request on request.apolloreborn.app works too; a refactor needs none), what
// kind of change it is, the devices
// it was tested on and a ticked checklist, plus by type:
//   bug fix:  steps that reproduce the bug on main, before and after media
//   feature:  steps to try it, after media (before is optional)
//   refactor: how the author checked that nothing changed (no media)
// .github/pull_request_template.md has a section for each, and this reads
// those sections back out of the description.
//
// Two rules look past the description, because they're about how much there
// is to review rather than how it's written up:
//   - An author can have MAX_OPEN_PRS open at once, drafts included. This one
//     is checked on drafts too.
//   - A change over LARGE_CHANGE_LINES (outside tests/ and docs) needs a
//     maintainer's OK, given as the `large-change-ok` label. Until then it's
//     labelled `needs-size-ok` but stays open: size is a maintainer's call,
//     and a closed PR drops out of sight. Drafts are labelled too, and the
//     size is rechecked on every push, so a PR can't open small and grow.
//
// An author who can't try the change on the hardware it affects (no iPhone
// Duo, say) ticks "Needs a device tester" instead of the reproduced / ran it /
// a person tried it boxes and writes `N/A: <why>` under Before and After. The
// PR then passes, stays open, and is labelled `needs-device-test` so a
// maintainer with the device can try it before it merges.
//
// A newly opened PR (or a draft marked ready for review) that's missing any of
// it is labelled `needs-verification`, gets one comment listing exactly what to
// add, and is closed. When its author edits the description to fill the gaps,
// or a maintainer adds `verification-not-needed`, the label comes off, the comment is updated and
// the PR is reopened (only when this check was what closed it). Edits never
// flag a PR that passed or that predates the check.
//
// Exempt: authors with write access (maintainers), bots, PRs that only change
// docs, and anything labelled `verification-not-needed`. Drafts are only held
// to the open PR limit (and labelled for size) until they're marked ready.
'use strict';

const LABEL = 'needs-verification';
const SKIP_LABEL = 'verification-not-needed';
const SIZE_LABEL = 'large-change-ok';
// On a PR over the size limit that a maintainer hasn't agreed to yet. The PR
// stays open, so maintainers can find these with `label:needs-size-ok`.
const NEEDS_SIZE_LABEL = 'needs-size-ok';
const DEVICE_TEST_LABEL = 'needs-device-test';
// Open PRs one outside author can have at once, drafts and stacked PRs
// included.
const MAX_OPEN_PRS = 3;
// Changed lines (added plus deleted) past which a maintainer has to agree to
// the change before it's reviewed. Tests and docs don't count.
const LARGE_CHANGE_LINES = 500;
const TEST_FILE = /^tests\//i;
const MARKER = '<!-- apollo-reborn:pr-rules -->';
// The size note is its own comment, so the rules comment never overwrites it.
const SIZE_MARKER = '<!-- apollo-reborn:pr-size -->';
// The account GITHUB_TOKEN acts as, so a close this check made can be told
// apart from one a maintainer made.
const CHECK_LOGIN = 'github-actions[bot]';
const MAINTAINER_ASSOCIATIONS = new Set(['OWNER', 'MEMBER', 'COLLABORATOR']);
const WRITE_ROLES = new Set(['admin', 'maintain', 'write']);
// Markdown anywhere, or anything under docs/.
const DOCS_FILE = /(?:^docs\/|\.md$)/i;

// Template sections, matched on the start of the heading text (lowercased,
// punctuation dropped). Keep in sync with .github/pull_request_template.md.
const SECTIONS = {
    type: { prefix: 'type', name: 'Type' },
    summary: { prefix: 'what', name: 'What this changes' },
    steps: { prefix: 'steps', name: 'Steps' },
    before: { prefix: 'before', name: 'Before' },
    after: { prefix: 'after', name: 'After' },
    unchanged: { prefix: 'how i checked nothing changed', name: 'How I checked nothing changed' },
    tested: { prefix: 'tested on', name: 'Tested on' },
    checklist: { prefix: 'checklist', name: 'Checklist' },
    // Not a required section: a closing keyword anywhere also links an issue.
    issue: { prefix: 'issue', name: 'Issue' },
};
// The ticked box under Type picks which sections have to be filled in. Until
// one (and only one) is ticked, only the sections every type needs are checked.
const COMMON_SECTIONS = ['summary', 'tested', 'checklist'];
const TYPES = [
    { name: 'Bug fix', match: /\bbug\b/i, sections: ['summary', 'steps', 'before', 'after', 'tested', 'checklist'] },
    { name: 'Feature', match: /\bfeature\b/i, sections: ['summary', 'steps', 'after', 'tested', 'checklist'] },
    { name: 'Refactor', match: /\brefactor/i, sections: ['summary', 'unchanged', 'tested', 'checklist'] },
];
// Rows of the Tested on table, matched on the first cell. Both iPhone rows
// always need a real result; iPad and iPhone Duo can be "N/A: <reason>" when
// the change can't affect them (say, a network-only fix).
const DEVICE_ROWS = [
    { name: 'older or smaller iPhone', match: /older|smaller/i, skippable: false },
    { name: 'newer or larger iPhone', match: /newer|larger/i, skippable: false },
    { name: 'iPad', match: /ipad/i, skippable: true },
    { name: 'iPhone Duo', match: /duo/i, skippable: true },
];
// "N/A: no layout change, network path only": N/A plus a reason of at least
// eight characters, so a bare "N/A" or "N/A: no iPad" isn't one.
const SKIPPED_WITH_REASON = /^n\/?a\b[\s:—–-]+\S.{7,}$/i;
// The same for a whole Before or After section, which can run over lines.
const SECTION_SKIPPED_WITH_REASON = /^n\/?a\b[\s:—–-]+\S[\s\S]{7,}$/i;
// The template's checklist boxes, found by their wording so an edited order
// doesn't matter; a deleted box counts as unticked. `types` limits a box to
// those PR types. `waivable` boxes can be left unticked when "Needs a device
// tester" is ticked instead.
const CHECKLIST = [
    { name: 'reproduced the bug', match: /reproduced the bug/i, types: ['Bug fix'], waivable: true },
    { name: 'ran it in the app', match: /ran this change/i, waivable: true },
    { name: 'a person tried it', match: /a person tried it/i, waivable: true },
    { name: 'both builds', match: /standard and the liquid glass/i },
    { name: '`make package` passes', match: /make package/i },
    { name: 'read every line', match: /read every line/i },
    { name: 'one change', match: /does one thing/i },
];
const DEVICE_TESTER = /needs a device tester/i;
// What the steps and summary need at least, not counting list markers and
// whitespace, so an untouched "1. 2. 3." doesn't pass.
const MIN_TEXT = 20;

// A screenshot or screen recording: GitHub's own uploads (current and older
// URL forms), an <img>/<video> tag, a markdown image, a direct image or video
// link, or a link on a common image/video host.
const MEDIA = [
    /https:\/\/github\.com\/user-attachments\/assets\/[0-9a-f-]{8,}/i,
    /https:\/\/(?:private-)?user-images\.githubusercontent\.com\/\S+/i,
    /https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/assets\/\d+\/[0-9a-f-]{8,}/i,
    /<(?:img|video|source)\b[^>]*\bsrc\s*=\s*["']?https?:\/\//i,
    /!\[[^\]]*\]\(\s*<?https?:\/\/[^)\s]+/,
    /https?:\/\/\S+?\.(?:png|jpe?g|gif|webp|heic|mp4|mov|m4v|webm)(?:[?#][^\s)\]"'<>]*)?(?=[\s)\]"'<>]|$)/i,
    /https?:\/\/(?:www\.|i\.)?(?:imgur\.com|streamable\.com|youtu\.be|youtube\.com\/(?:watch|shorts))\/?\S+/i,
];
// A table cell left as a placeholder: empty, "-", "?", a bare "no" or "none",
// or one that says it wasn't tested ("N/A", "not tested (no iPad)", ...). A
// real result that starts with "No" or "Not" ("No regressions", "Not
// affected") still counts.
const PLACEHOLDER = /^(?:[-–—?x.]*|no|none|(?:n\/?a|not tested|untested|didn'?t test|did not test|skip(?:ped)?|tbd|todo|unknown)\b.*)$/i;

function stripComments(text) {
    // An unterminated comment hides the rest, the way GitHub renders it.
    return (text || '').replace(/<!--[\s\S]*?(?:-->|$)/g, '');
}

function normalizeHeading(text) {
    return text.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

// The description split at its headings, skipping fenced code so a "# ..."
// line inside the steps isn't read as one.
function sectionsOf(body) {
    const sections = [];
    let current = null;
    let fence = null;
    for (const line of stripComments(body).split(/\r?\n/)) {
        const fenceMatch = line.match(/^ {0,3}(`{3,}|~{3,})/);
        if (fenceMatch) {
            if (!fence) fence = fenceMatch[1][0];
            else if (fenceMatch[1][0] === fence) fence = null;
        }
        const heading = !fence && !fenceMatch && line.match(/^ {0,3}#{1,6}[ \t]+(.*?)[ \t#]*$/);
        if (heading) {
            current = { title: normalizeHeading(heading[1]), lines: [] };
            sections.push(current);
        } else if (current) {
            current.lines.push(line);
        }
    }
    return sections.map((section) => ({ title: section.title, text: section.lines.join('\n') }));
}

function findSection(sections, key) {
    const found = sections.find((section) => section.title.startsWith(SECTIONS[key].prefix));
    return found ? found.text : null;
}

function escapeRegExp(text) {
    return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// "Closes #123", "fixes owner/repo#123" or "resolves <issue URL>".
function closingRefs(text, owner, repo) {
    const repoPath = `${escapeRegExp(owner)}/${escapeRegExp(repo)}`;
    const pattern = new RegExp(
        `\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\b:?\\s+(?:#|${repoPath}#|https://github\\.com/${repoPath}/issues/)(\\d+)`,
        'gi');
    return [...stripComments(text).matchAll(pattern)].map((match) => Number(match[1]));
}

// Any reference to this repo's issues or PRs in the Issue section, with or
// without a closing keyword: "Related to #123", "owner/repo#123" or a URL.
// Numbers are shared between issues and PRs, so run() checks which are
// issues before they count.
function sectionRefs(text, owner, repo) {
    if (!text) return [];
    const repoPath = `${escapeRegExp(owner)}/${escapeRegExp(repo)}`;
    const pattern = new RegExp(
        `(?:^|[^\\w/#])(?:${repoPath})?#(\\d+)\\b|https://github\\.com/${repoPath}/(?:issues|pull)/(\\d+)`,
        'gi');
    return [...text.matchAll(pattern)].map((match) => Number(match[1] || match[2]));
}

// Every issue or PR number the description offers as its issue: closing
// keywords anywhere, plus any reference under Issue.
function issueRefsIn(body, owner, repo) {
    const refs = [...closingRefs(body, owner, repo), ...sectionRefs(findSection(sectionsOf(body), 'issue'), owner, repo)];
    return [...new Set(refs)];
}

// A link to one request on the feature request board, where feature requests
// live instead of GitHub issues.
const FEATURE_REQUEST = /https:\/\/request\.apolloreborn\.app\/posts\/\d+/i;

function linksFeatureRequest(text) {
    return FEATURE_REQUEST.test(stripComments(text));
}

function hasMedia(text) {
    return MEDIA.some((pattern) => pattern.test(text));
}

function meaningfulLength(text) {
    return text
        .replace(/^\s*(?:[-*+]|\d+[.)])[ \t]*/gm, '')
        .replace(/\s+/g, '')
        .length;
}

function plainCell(cell) {
    return (cell || '').replace(/[*_`~]/g, '').trim();
}

function cellFilled(cell) {
    const plain = plainCell(cell);
    return plain.length > 0 && !PLACEHOLDER.test(plain);
}

// Rows of the first markdown table in `text`, as arrays of trimmed cells,
// without the |---| separator.
function tableRows(text) {
    return text.split(/\r?\n/)
        .filter((line) => /^\s*\|/.test(line))
        .map((line) => line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((cell) => cell.trim()))
        .filter((cells) => !cells.every((cell) => /^:?-+:?$/.test(cell)));
}

// Device rows that aren't filled in: model, an iOS version with a number in
// it, real device or simulator, and a result. An iPad or iPhone Duo row with
// "N/A: <reason>" in any cell counts as filled in.
function missingDeviceRows(text) {
    const rows = tableRows(text);
    return DEVICE_ROWS.filter((device) => {
        const row = rows.find((cells) => device.match.test(cells[0] || ''));
        if (!row) return true;
        if (device.skippable && row.slice(1).some((cell) => SKIPPED_WITH_REASON.test(plainCell(cell)))) return false;
        const [, model, ios, kind, result] = row;
        return !(cellFilled(model)
            && cellFilled(ios) && /\d/.test(ios)
            && cellFilled(kind) && /real|device|sim/i.test(kind)
            && cellFilled(result));
    });
}

// The type whose box is the only one ticked under Type, or null.
function typeOf(text) {
    if (text === null) return null;
    const ticked = text.split(/\r?\n/).filter((line) => /^\s*[-*+]\s+\[[xX]\]/.test(line));
    const types = TYPES.filter((type) => ticked.some((line) => type.match.test(line)));
    return types.length === 1 ? types[0] : null;
}

// The checklist's boxes as { text, ticked }.
function boxesIn(text) {
    return (text || '').split(/\r?\n/)
        .map((line) => line.match(/^\s*[-*+]\s+\[([ xX])\]\s*(.*)$/))
        .filter(Boolean)
        .map((match) => ({ text: match[2], ticked: match[1] !== ' ' }));
}

function wantsDeviceTester(checklistText) {
    return boxesIn(checklistText).some((box) => box.ticked && DEVICE_TESTER.test(box.text));
}

// Whether the description asks for a maintainer with the device to try it.
function needsDeviceTest(body) {
    return wantsDeviceTester(findSection(sectionsOf(body), 'checklist'));
}

// The checklist boxes this PR still has to tick, by name.
function untickedItems(checklistText, type) {
    const boxes = boxesIn(checklistText);
    const deviceTester = wantsDeviceTester(checklistText);
    return CHECKLIST
        .filter((item) => !item.types || (type && item.types.includes(type.name)))
        .filter((item) => !(deviceTester && item.waivable))
        .filter((item) => !boxes.some((box) => box.ticked && item.match.test(box.text)))
        .map((item) => item.name);
}

// Before or After media, or "N/A: <reason>" when the author asked for a
// device tester.
function mediaOrSkipped(text, deviceTester) {
    if (hasMedia(text)) return true;
    return deviceTester && SECTION_SKIPPED_WITH_REASON.test(text.trim());
}

function listWords(words) {
    if (words.length < 2) return words.join('');
    return `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}`;
}

function templateUrl(owner, repo) {
    return `https://github.com/${owner}/${repo}/blob/main/.github/pull_request_template.md?plain=1`;
}

// Everything the description is missing, one markdown line each (empty when
// it's all there).
// `issueNumbers`: the referenced numbers that are issues rather than PRs, as
// run() looked them up. Without it every reference counts.
function problemsIn(body, owner, repo, issueNumbers = null) {
    const problems = [];
    const sections = sectionsOf(body);
    const text = {};
    for (const key of Object.keys(SECTIONS)) text[key] = findSection(sections, key);
    const type = typeOf(text.type);
    const required = type ? type.sections : COMMON_SECTIONS;
    // A section is checked only when this PR's type needs it and it's there;
    // a missing one is named once, in the template line.
    const needs = (key) => required.includes(key) && text[key] !== null;

    const missingSections = ['type', ...required].filter((key) => text[key] === null).map((key) => SECTIONS[key].name);
    if (missingSections.length) {
        problems.push(`**Pull request template:** the description has no ${listWords(missingSections)} section${missingSections.length > 1 ? 's' : ''}. Start from the [template](${templateUrl(owner, repo)}).`);
    }
    const isFeature = Boolean(type) && type.name === 'Feature';
    const isRefactor = Boolean(type) && type.name === 'Refactor';
    const deviceTester = text.checklist !== null && wantsDeviceTester(text.checklist);
    // A refactor has no user-facing issue to link (issues here are bug
    // reports), so it says why it's worth doing under What this changes
    // instead, and the size limit keeps big ones in check.
    const refs = issueRefsIn(body, owner, repo);
    const linked = issueNumbers ? refs.some((n) => issueNumbers.has(n)) : refs.length > 0;
    if (!isRefactor && !linked && !(isFeature && linksFeatureRequest(body))) {
        // Only reachable with references when run() found none of them to
        // be issues (a PR, or a number that doesn't exist).
        const notIssues = refs.length
            ? ` (${listWords(refs.map((n) => `#${n}`))} ${refs.length > 1 ? "aren't issues" : "isn't an issue"} in this repo.)`
            : '';
        problems.push((isFeature
            ? '**Issue:** link the issue or feature request this is for, like `Closes #123` or `https://request.apolloreborn.app/posts/123`. If there isn\'t one, post the request first.'
            : "**Issue:** link the issue this is for, like `Closes #123`, or `Related to #123` if this doesn't fully fix it. If there isn't one, open it first (a report from the app or report.apolloreborn.app opens one for you).")
            + notIssues);
    }
    if (text.type !== null && !type) {
        problems.push('**Type:** tick one box: bug fix, feature or refactor.');
    }
    if (needs('summary') && meaningfulLength(text.summary) < MIN_TEXT) {
        problems.push(isRefactor
            ? '**What this changes:** say what the refactor changes and why it\'s worth doing (what it makes simpler, faster or easier to change).'
            : '**What this changes:** say what was wrong or missing, and how this change fixes or adds it.');
    }
    if (needs('steps') && meaningfulLength(text.steps) < MIN_TEXT) {
        problems.push(type.name === 'Feature'
            ? '**Steps:** list the steps to try the feature.'
            : '**Steps:** list the steps that show the bug on current `main`.');
    }
    const skipHint = deviceTester ? " Since you asked for a device tester, `N/A: <why you can't record it>` works too." : '';
    if (needs('before') && !mediaOrSkipped(text.before, deviceTester)) {
        problems.push(`**Before:** add a screenshot or screen recording of the bug on current \`main\`, without your change.${skipHint}`);
    }
    if (needs('after') && !mediaOrSkipped(text.after, deviceTester)) {
        problems.push((type.name === 'Feature'
            ? '**After:** add a screenshot or screen recording of the feature in use.'
            : '**After:** add a screenshot or screen recording of the same steps with your change.') + skipHint);
    }
    if (needs('unchanged') && meaningfulLength(text.unchanged) < MIN_TEXT) {
        problems.push('**How I checked nothing changed:** say what you ran or compared to make sure the refactor behaves the same.');
    }
    if (needs('tested')) {
        const missingRows = missingDeviceRows(text.tested);
        if (missingRows.length) {
            const names = missingRows.map((device) => device.name);
            const skipHint = missingRows.some((device) => device.skippable)
                ? " The iPad and iPhone Duo rows can say `N/A: <why the change can't affect them>` instead."
                : '';
            problems.push(`**Tested on:** fill in the ${listWords(names)} row${names.length > 1 ? 's' : ''} (model, iOS version, real device or simulator, and the result). Simulators are fine.${skipHint}`);
        }
    }
    if (needs('checklist')) {
        const unticked = untickedItems(text.checklist, type);
        if (unticked.length) {
            const waivable = CHECKLIST.filter((item) => item.waivable).map((item) => item.name);
            const deviceHint = !deviceTester && unticked.some((name) => waivable.includes(name))
                ? ' If you can\'t try it on the device it affects, tick "Needs a device tester" instead and say why under Before and After.'
                : '';
            problems.push(`**Checklist:** tick ${listWords(unticked.map((name) => `"${name}"`))} once ${unticked.length > 1 ? "they're" : "it's"} true.${deviceHint}`);
        }
    }
    return problems;
}

// Lines changed outside tests/ and docs, from pulls.listFiles entries.
function changedLines(files) {
    return files
        .filter((file) => !DOCS_FILE.test(file.filename) && !TEST_FILE.test(file.filename))
        .reduce((total, file) => total + (file.additions || 0) + (file.deletions || 0), 0);
}

// Whether the PR is over the size limit without a maintainer's OK.
function oversized(lines, labels) {
    return lines > LARGE_CHANGE_LINES && !labels.includes(SIZE_LABEL);
}

function sizeComment(lines) {
    return `${SIZE_MARKER}
This changes ${lines} lines outside \`tests/\` and docs. Past ${LARGE_CHANGE_LINES}, a maintainer has to agree to a change before it's reviewed, so it's labelled \`${NEEDS_SIZE_LABEL}\` until then. It stays open in the meantime.

If you haven't yet, say in the description why it needs to be this size, or split it into smaller PRs. Once a maintainer agrees, they'll add the \`${SIZE_LABEL}\` label.`;
}

function sizeClearedComment(lines, labels) {
    return `${SIZE_MARKER}
${labels.includes(SIZE_LABEL)
        ? `A maintainer agreed to this change's size (\`${SIZE_LABEL}\`).`
        : `This is now ${lines} lines outside \`tests/\` and docs, within the ${LARGE_CHANGE_LINES}-line limit.`}`;
}

// `others` are the author's other open PRs.
function openPRsProblem(others) {
    if (others.length < MAX_OPEN_PRS) return null;
    const list = listWords(others.map((pr) => `#${pr.number}`));
    return `**Open PRs:** you already have ${others.length} open pull requests (${list}), drafts included. We take up to ${MAX_OPEN_PRS} from one person at a time so each gets a proper review. Once one of them is merged or closed, make any edit to this PR's description and it reopens on its own. (GitHub doesn't let you reopen a PR this check closed yourself, so don't open a new one for it.)`;
}

function missingComment(problems, closed, owner, repo) {
    const next = closed
        ? "It's closed for now. Edit the PR description to fix what's listed and it reopens on its own."
        : "Edit the PR description to fix what's listed.";
    return `${MARKER}
Thanks for the PR! Pull requests from outside the core team need a few things before we can review them, and this one needs:

${problems.map((problem) => `- ${problem}`).join('\n')}

${next} Why we ask for this: [pull request rules](https://github.com/${owner}/${repo}/blob/main/CONTRIBUTING.md#pull-request-rules).`;
}

const DEVICE_TEST_NOTE = `You asked for a device tester, so this is labelled \`${DEVICE_TEST_LABEL}\`. A maintainer with the device will try it before it merges.`;

function clearedComment(reason, reopened, deviceTest) {
    const lead = reason === 'waived'
        ? 'A maintainer marked this PR as not needing the usual checks.'
        : "Thanks, that's everything we need!";
    return `${MARKER}
${lead}${reopened ? ' The PR is open again for review.' : ''}${deviceTest ? ` ${DEVICE_TEST_NOTE}` : ''}`;
}

function labelNames(pr) {
    return (pr.labels || []).map((label) => (typeof label === 'string' ? label : label.name));
}

async function hasWriteAccess(github, owner, repo, username) {
    try {
        const { data } = await github.rest.repos.getCollaboratorPermissionLevel({ owner, repo, username });
        return WRITE_ROLES.has(data.role_name) || WRITE_ROLES.has(data.permission);
    } catch (error) {
        if (error.status === 404) return false;
        throw error;
    }
}

// Why the check doesn't apply to this PR's author or labels, or null.
async function exemption(github, owner, repo, pr) {
    if (pr.user && pr.user.type === 'Bot') return 'opened by a bot';
    if (labelNames(pr).includes(SKIP_LABEL)) return `labelled ${SKIP_LABEL}`;
    if (MAINTAINER_ASSOCIATIONS.has(pr.author_association)) return 'opened by a maintainer';
    // author_association reads CONTRIBUTOR for org members whose membership is
    // private, so ask for the author's permission directly too.
    if (pr.user && await hasWriteAccess(github, owner, repo, pr.user.login)) return 'author has write access';
    return null;
}

function listFiles(github, owner, repo, number) {
    return github.paginate(github.rest.pulls.listFiles, { owner, repo, pull_number: number, per_page: 100 });
}

function onlyDocs(files) {
    return files.length > 0 && files.every((file) => DOCS_FILE.test(file.filename));
}

// The author's other open PRs, drafts included.
async function otherOpenPRs(github, owner, repo, pr) {
    const open = await github.paginate(github.rest.pulls.list, { owner, repo, state: 'open', per_page: 100 });
    return open.filter((other) => other.number !== pr.number && other.user && pr.user && other.user.login === pr.user.login);
}

// Whether the PR's most recent close was this check's (not a maintainer's).
async function closedByCheck(github, owner, repo, number) {
    const events = await github.paginate(github.rest.issues.listEvents, { owner, repo, issue_number: number, per_page: 100 });
    const closes = events.filter((event) => event.event === 'closed');
    const last = closes[closes.length - 1];
    return Boolean(last && last.actor && last.actor.login === CHECK_LOGIN);
}

const LABEL_DETAILS = {
    [LABEL]: { color: 'd93f0b', description: 'Missing what the PR rules ask for' },
    [DEVICE_TEST_LABEL]: { color: 'fbca04', description: 'Needs a maintainer with the device to try it before merging' },
    [SIZE_LABEL]: { color: '0e8a16', description: 'A maintainer agreed to a change over the PR size limit' },
    [NEEDS_SIZE_LABEL]: { color: 'c5def5', description: 'Over the PR size limit; waiting on a maintainer to agree to it' },
};

async function ensureLabel(github, owner, repo, name = LABEL) {
    try {
        await github.rest.issues.getLabel({ owner, repo, name });
    } catch (error) {
        if (error.status !== 404) throw error;
        try {
            await github.rest.issues.createLabel({ owner, repo, name, ...LABEL_DETAILS[name] });
        } catch (createError) {
            // 422: another run created it first.
            if (createError.status !== 422) throw createError;
        }
    }
}

function listComments(github, owner, repo, number) {
    return github.paginate(github.rest.issues.listComments, { owner, repo, issue_number: number, per_page: 100 });
}

// One marker-keyed comment per PR, edited in place rather than stacked.
async function upsertComment(github, owner, repo, number, body, comments, marker = MARKER) {
    const existing = comments.find((comment) =>
        comment.user && comment.user.type === 'Bot' && (comment.body || '').startsWith(marker));
    if (existing) {
        if (existing.body !== body) {
            await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body });
        }
        return;
    }
    await github.rest.issues.createComment({ owner, repo, issue_number: number, body });
}

// Take the flag off: drop the label, reopen the PR if this check closed it,
// and say so in the check's comment.
async function clearFlag(github, owner, repo, pr, reason, core) {
    try {
        await github.rest.issues.removeLabel({ owner, repo, issue_number: pr.number, name: LABEL });
    } catch (error) {
        if (error.status !== 404) throw error;
    }
    let reopened = false;
    if (pr.state === 'closed' && await closedByCheck(github, owner, repo, pr.number)) {
        await github.rest.pulls.update({ owner, repo, pull_number: pr.number, state: 'open' });
        reopened = true;
    }
    const deviceTest = reason === 'complete' && await markDeviceTest(github, owner, repo, pr);
    await upsertComment(github, owner, repo, pr.number, clearedComment(reason, reopened, deviceTest),
        await listComments(github, owner, repo, pr.number));
    core.info(`#${pr.number}: ${reason}, ${LABEL} removed${reopened ? ', reopened' : ''}`);
}

// Label a passing PR whose author asked for a device tester. Returns whether
// it asked. The label is only ever added here: a maintainer takes it off once
// they've tried the change.
async function markDeviceTest(github, owner, repo, pr) {
    if (!needsDeviceTest(pr.body)) return false;
    if (!labelNames(pr).includes(DEVICE_TEST_LABEL)) {
        await ensureLabel(github, owner, repo, DEVICE_TEST_LABEL);
        await github.rest.issues.addLabels({ owner, repo, issue_number: pr.number, labels: [DEVICE_TEST_LABEL] });
    }
    return true;
}

// How many referenced numbers to look up; the rest are ignored.
const MAX_REF_LOOKUPS = 10;

// Which of the description's issue references are issues, not PRs (or
// numbers that don't exist).
async function issueNumbersIn(github, owner, repo, body) {
    const found = new Set();
    for (const number of issueRefsIn(body, owner, repo).slice(0, MAX_REF_LOOKUPS)) {
        try {
            const { data } = await github.rest.issues.get({ owner, repo, issue_number: number });
            if (!data.pull_request) found.add(number);
        } catch (error) {
            if (error.status !== 404 && error.status !== 410) throw error;
        }
    }
    return found;
}

async function removeLabel(github, owner, repo, number, name) {
    try {
        await github.rest.issues.removeLabel({ owner, repo, issue_number: number, name });
    } catch (error) {
        if (error.status !== 404) throw error;
    }
}

// Keep needs-size-ok in step with the PR's size: add it (with a comment) when
// the PR is over the limit without large-change-ok, take it off once it's
// under or a maintainer agrees. It never closes the PR: size is a
// maintainer's call, and a closed PR drops out of sight. Drafts included, so
// a big change surfaces while it's still being built.
async function syncSize(github, owner, repo, pr, files, core) {
    const labels = labelNames(pr);
    const lines = changedLines(files);
    const has = labels.includes(NEEDS_SIZE_LABEL);
    if (oversized(lines, labels)) {
        if (has) return;
        // large-change-ok is created here too, so a maintainer can pick it
        // from the sidebar.
        await ensureLabel(github, owner, repo, SIZE_LABEL);
        await ensureLabel(github, owner, repo, NEEDS_SIZE_LABEL);
        await github.rest.issues.addLabels({ owner, repo, issue_number: pr.number, labels: [NEEDS_SIZE_LABEL] });
        await upsertComment(github, owner, repo, pr.number, sizeComment(lines),
            await listComments(github, owner, repo, pr.number), SIZE_MARKER);
        core.info(`#${pr.number}: ${lines} lines, labelled ${NEEDS_SIZE_LABEL}`);
    } else if (has) {
        await removeLabel(github, owner, repo, pr.number, NEEDS_SIZE_LABEL);
        await upsertComment(github, owner, repo, pr.number, sizeClearedComment(lines, labels),
            await listComments(github, owner, repo, pr.number), SIZE_MARKER);
        core.info(`#${pr.number}: size cleared, ${NEEDS_SIZE_LABEL} removed`);
    }
}

async function run({ github, context, core }) {
    const { owner, repo } = context.repo;
    const payloadPR = context.payload.pull_request;
    if (!payloadPR) return;
    const number = payloadPR.number;

    // Runs for one PR are serialized by the workflow's concurrency group, but
    // a queued event's payload can be older than the PR, so act on the PR as
    // it is now (body, labels, state, draft).
    const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number: number });
    if (pr.merged) return;
    const flagged = labelNames(pr).includes(LABEL);

    const reason = await exemption(github, owner, repo, pr);
    if (reason) {
        core.info(`#${number}: skipped, ${reason}`);
        if (flagged) await clearFlag(github, owner, repo, pr, 'waived', core);
        if (labelNames(pr).includes(NEEDS_SIZE_LABEL)) await removeLabel(github, owner, repo, number, NEEDS_SIZE_LABEL);
        return;
    }
    // Opening, marking ready, or the author reopening it themselves is when a
    // PR gets checked. (GitHub doesn't let an author without write access
    // reopen a PR this check closed, so comments point them at an edit
    // instead; the reopened case covers PRs they closed themselves.) A
    // maintainer reopening it is left alone, and edits only ever clear a flag
    // this check set.
    const action = context.payload.action;
    const sender = context.payload.sender && context.payload.sender.login;
    const fresh = action === 'opened' || action === 'ready_for_review'
        || (action === 'reopened' && Boolean(pr.user) && sender === pr.user.login);

    // Size is synced on opening, marking ready, reopening, every push and a
    // maintainer adding large-change-ok, drafts included. It only labels;
    // closing is left to the description checks below.
    const sizeEvent = fresh || action === 'reopened' || action === 'synchronize'
        || (action === 'labeled' && context.payload.label && context.payload.label.name === SIZE_LABEL);
    let files = null;
    if (sizeEvent) {
        files = await listFiles(github, owner, repo, number);
        await syncSize(github, owner, repo, pr, files, core);
    }
    // A push can't change the description, so past the size it only matters
    // to a PR that's already flagged.
    if (action === 'synchronize' && !flagged) return;
    if (!flagged && !fresh) return;

    if (!files) files = await listFiles(github, owner, repo, number);
    if (onlyDocs(files)) {
        core.info(`#${number}: only changes docs`);
        if (flagged) await clearFlag(github, owner, repo, pr, 'complete', core);
        return;
    }

    // A draft is only held to the open PR limit (and labelled for size,
    // above); the rest is checked once it's marked ready for review.
    const problems = pr.draft ? [] : problemsIn(pr.body, owner, repo, await issueNumbersIn(github, owner, repo, pr.body));
    const tooMany = openPRsProblem(await otherOpenPRs(github, owner, repo, pr));
    if (tooMany) problems.push(tooMany);

    if (!problems.length) {
        if (flagged) await clearFlag(github, owner, repo, pr, 'complete', core);
        else if (!pr.draft && await markDeviceTest(github, owner, repo, pr)) {
            await upsertComment(github, owner, repo, number, `${MARKER}\n${DEVICE_TEST_NOTE}`,
                await listComments(github, owner, repo, number));
            core.info(`#${number}: everything's there, labelled ${DEVICE_TEST_LABEL}`);
        } else core.info(`#${number}: everything's there${pr.draft ? ' (draft)' : ''}`);
        return;
    }

    if (!flagged) {
        await ensureLabel(github, owner, repo);
        await github.rest.issues.addLabels({ owner, repo, issue_number: number, labels: [LABEL] });
    }
    const closing = fresh && pr.state === 'open';
    await upsertComment(github, owner, repo, number, missingComment(problems, closing || pr.state === 'closed', owner, repo),
        await listComments(github, owner, repo, number));
    if (closing) {
        await github.rest.pulls.update({ owner, repo, pull_number: number, state: 'closed' });
    }
    core.info(`#${number}: ${problems.length} missing, labelled ${LABEL}${closing ? ', closed' : ''}`);
}

module.exports = {
    run,
    problemsIn,
    issueRefsIn,
    hasMedia,
    needsDeviceTest,
    oversized,
    openPRsProblem,
    LABEL,
    SKIP_LABEL,
    SIZE_LABEL,
    NEEDS_SIZE_LABEL,
    SIZE_MARKER,
    DEVICE_TEST_LABEL,
    MAX_OPEN_PRS,
    LARGE_CHANGE_LINES,
    MARKER,
    CHECK_LOGIN,
};
