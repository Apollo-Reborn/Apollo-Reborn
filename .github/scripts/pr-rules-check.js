// Pull request rules check, run by .github/workflows/pr-rules-check.yml.
//
// Pull requests from outside the core team have to show the work behind them
// (CONTRIBUTING.md#pull-request-rules): a linked issue, what kind of change it
// is, the devices it was tested on and a ticked checklist, plus by type:
//   bug fix:  steps that reproduce the bug on main, before and after media
//   feature:  steps to try it, after media (before is optional)
//   refactor: how the author checked that nothing changed (no media)
// .github/pull_request_template.md has a section for each, and this reads
// those sections back out of the description.
//
// A newly opened PR (or a draft marked ready for review) that's missing any of
// it is labelled `needs-verification`, gets one comment listing exactly what to
// add, and is closed. When its author edits the description to fill the gaps,
// or a maintainer adds `verification-not-needed`, the label comes off, the
// comment is updated and the PR is reopened (only when this check was what
// closed it). Edits never flag a PR that passed or that predates the check.
//
// Exempt: authors with write access (maintainers), bots, drafts (until they're
// marked ready), PRs that only change docs, and anything labelled
// `verification-not-needed`.
'use strict';

const LABEL = 'needs-verification';
const SKIP_LABEL = 'verification-not-needed';
const MARKER = '<!-- apollo-reborn:pr-rules -->';
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
// How many boxes the template's checklist has; deleting one doesn't pass.
const CHECKLIST_ITEMS = 7;
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
function linksIssue(text, owner, repo) {
    const repoPath = `${escapeRegExp(owner)}/${escapeRegExp(repo)}`;
    const pattern = new RegExp(
        `\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\b:?\\s+(?:#\\d+|${repoPath}#\\d+|https://github\\.com/${repoPath}/issues/\\d+)`,
        'i');
    return pattern.test(stripComments(text));
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

function countBoxes(text) {
    return {
        ticked: (text.match(/^\s*[-*+]\s+\[[xX]\]/gm) || []).length,
        unticked: (text.match(/^\s*[-*+]\s+\[ \]/gm) || []).length,
    };
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
function problemsIn(body, owner, repo) {
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
    if (!linksIssue(body, owner, repo)) {
        problems.push("**Issue:** link the issue this is for, like `Closes #123`. If there isn't one, open it first; features and refactors need an issue a maintainer has agreed to.");
    }
    if (text.type !== null && !type) {
        problems.push('**Type:** tick one box: bug fix, feature or refactor.');
    }
    if (needs('summary') && meaningfulLength(text.summary) < MIN_TEXT) {
        problems.push('**What this changes:** say what was wrong or missing, and how this change fixes or adds it.');
    }
    if (needs('steps') && meaningfulLength(text.steps) < MIN_TEXT) {
        problems.push(type.name === 'Feature'
            ? '**Steps:** list the steps to try the feature.'
            : '**Steps:** list the steps that show the bug on current `main`.');
    }
    if (needs('before') && !hasMedia(text.before)) {
        problems.push('**Before:** add a screenshot or screen recording of the bug on current `main`, without your change.');
    }
    if (needs('after') && !hasMedia(text.after)) {
        problems.push(type.name === 'Feature'
            ? '**After:** add a screenshot or screen recording of the feature in use.'
            : '**After:** add a screenshot or screen recording of the same steps with your change.');
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
        const { ticked, unticked } = countBoxes(text.checklist);
        if (unticked > 0 || ticked < CHECKLIST_ITEMS) {
            problems.push(`**Checklist:** tick every box once it's true (${ticked} of ${CHECKLIST_ITEMS} ticked).`);
        }
    }
    return problems;
}

function missingComment(problems, closed, owner, repo) {
    const next = closed
        ? "It's closed for now. Edit the PR description to add what's missing and it reopens on its own."
        : "Edit the PR description to add what's missing.";
    return `${MARKER}
Thanks for the PR! Pull requests from outside the core team need a few things before we can review them, and this one is missing:

${problems.map((problem) => `- ${problem}`).join('\n')}

${next} Why we ask for this: [pull request rules](https://github.com/${owner}/${repo}/blob/main/CONTRIBUTING.md#pull-request-rules).`;
}

function clearedComment(reason, reopened) {
    const lead = reason === 'waived'
        ? 'A maintainer marked this PR as not needing the usual checks.'
        : "Thanks, that's everything we need!";
    return `${MARKER}
${lead}${reopened ? ' The PR is open again for review.' : ''}`;
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

async function onlyDocs(github, owner, repo, number) {
    const files = await github.paginate(github.rest.pulls.listFiles, { owner, repo, pull_number: number, per_page: 100 });
    return files.length > 0 && files.every((file) => DOCS_FILE.test(file.filename));
}

// Whether the PR's most recent close was this check's (not a maintainer's).
async function closedByCheck(github, owner, repo, number) {
    const events = await github.paginate(github.rest.issues.listEvents, { owner, repo, issue_number: number, per_page: 100 });
    const closes = events.filter((event) => event.event === 'closed');
    const last = closes[closes.length - 1];
    return Boolean(last && last.actor && last.actor.login === CHECK_LOGIN);
}

async function ensureLabel(github, owner, repo) {
    try {
        await github.rest.issues.getLabel({ owner, repo, name: LABEL });
    } catch (error) {
        if (error.status !== 404) throw error;
        try {
            await github.rest.issues.createLabel({
                owner,
                repo,
                name: LABEL,
                color: 'd93f0b',
                description: "Missing the reproduction, media or testing the PR rules ask for",
            });
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
async function upsertComment(github, owner, repo, number, body, comments) {
    const existing = comments.find((comment) =>
        comment.user && comment.user.type === 'Bot' && (comment.body || '').startsWith(MARKER));
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
    await upsertComment(github, owner, repo, pr.number, clearedComment(reason, reopened),
        await listComments(github, owner, repo, pr.number));
    core.info(`#${pr.number}: ${reason}, ${LABEL} removed${reopened ? ', reopened' : ''}`);
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
        return;
    }
    if (pr.draft) {
        core.info(`#${number}: draft, checked once it's marked ready for review`);
        return;
    }

    // Opening, marking ready, or the author reopening it themselves is when a
    // PR gets checked. A maintainer reopening it is left alone, and edits only
    // ever clear a flag this check set.
    const action = context.payload.action;
    const sender = context.payload.sender && context.payload.sender.login;
    const fresh = action === 'opened' || action === 'ready_for_review'
        || (action === 'reopened' && Boolean(pr.user) && sender === pr.user.login);
    if (!flagged && !fresh) return;

    let problems = problemsIn(pr.body, owner, repo);
    if (problems.length && await onlyDocs(github, owner, repo, number)) {
        core.info(`#${number}: only changes docs`);
        problems = [];
    }
    if (!problems.length) {
        if (flagged) await clearFlag(github, owner, repo, pr, 'complete', core);
        else core.info(`#${number}: everything's there`);
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
    hasMedia,
    LABEL,
    SKIP_LABEL,
    MARKER,
    CHECK_LOGIN,
    CHECKLIST_ITEMS,
};
