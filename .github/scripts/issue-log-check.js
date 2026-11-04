// Bug report log check, run by .github/workflows/issue-log-check.yml.
//
// The Bug Report and Login & API Key Help forms strongly encourage a debug log
// or crash log but let people continue without one. A new issue from one of
// those forms that has no log attached is labelled `needs-log` and gets one
// comment explaining how to export a log; it stays open. As soon as its
// author edits a log into the issue or posts one in a comment, the label is
// removed and the comment is updated. The check never closes or reopens an
// issue, and only a newly opened issue gets flagged, so old issues are left
// alone.
//
// Exempt: issues created by a bot (report.apolloreborn.app files issues
// through its GitHub App and enforces the log itself; its anonymous reporters
// can't reply here), maintainers' own issues, issues from forms that don't ask
// for a log (the heading below is missing), and anything a maintainer labels
// `log-not-needed`.
'use strict';

const LABEL = 'needs-log';
const SKIP_LABEL = 'log-not-needed';
const MARKER = '<!-- apollo-reborn:needs-log -->';
// The heading GitHub renders for the log field. Keep in sync with the
// `label:` of the `logs` field in bug_report.yml and login_api_help.yml.
const LOG_SECTION = '### Debug log or crash log';
const MAINTAINER_ASSOCIATIONS = new Set(['OWNER', 'MEMBER', 'COLLABORATOR']);

// An uploaded file a log or crash report would arrive as. GitHub accepts .log,
// .txt, .json and archives (not .ips/.crash, which the forms say to zip).
// Images and videos don't count.
const ATTACHED_LOG = /https:\/\/github\.com\/(?:user-attachments\/files\/\d+|[\w.-]+\/[\w.-]+\/files\/\d+)\/[^\s)\]"'<>]+?\.(?:log|txt|json|jsonc|zip|gz|tgz|ips|crash)(?=[\s)\]"'<>?#]|$)/i;
// A log pasted as text instead: Export Debug Logs' headers, an iOS crash
// report (.ips JSON or the older text format) or Reborn's sanitized crash JSON.
const PASTED_LOG = [
    /(?:ApolloFix|Apollo AI) Logs — /,
    /===== (?:Current session|Persistent login diagnostics|Persistent list\/tab-bar diagnostics)/,
    /"bug_type"\s*:\s*"\d+"/,
    /^Incident Identifier:/m,
    /"report_type"\s*:\s*"apollo_reborn_crash"/,
];
// ...or enough raw Export Debug Logs lines ("[12:34:56.789] [Tag] ...", or
// "[10-14 12:34:56.789] ..." from the cross-launch sections) to be a real
// excerpt rather than a single quoted line.
const LOG_LINE = /^\s*\[(?:\d{2}-\d{2} )?\d{2}:\d{2}:\d{2}\.\d{3}\] \S/gm;
const MIN_PASTED_LOG_LINES = 5;

const MISSING_LOG_COMMENT = `${MARKER}
Thanks for the report! There's no debug log or crash log on this one yet, and without one we may not be able to figure out what went wrong. If you can, please add one.

**To add a log:** reproduce the bug, then (before closing Apollo) go to **Settings → Apollo Reborn → Advanced → Export Debug Logs**, save the file, and drag it into an edit of this issue or into a new comment here.

**If it crashed:** also attach the crash report from **Settings → Apollo Reborn → Privacy → Crash Reports** (open the report, then **Export Sanitized Report…**), or the \`Apollo-…\` \`.ips\` file from iOS **Settings → Privacy & Security → Analytics & Improvements → Analytics Data**. GitHub doesn't accept \`.ips\` files, so zip it first.

Next time, the easiest way is **Settings → Apollo Reborn → Bug Reports** in the app: it attaches the log for you and doesn't need a GitHub account. Feature ideas go on [request.apolloreborn.app](https://request.apolloreborn.app/).`;

const LOG_RECEIVED_COMMENT = `${MARKER}
Thanks for adding the log!`;

function hasLog(text) {
    if (!text) return false;
    if (ATTACHED_LOG.test(text)) return true;
    if (PASTED_LOG.some((pattern) => pattern.test(text))) return true;
    return (text.match(LOG_LINE) || []).length >= MIN_PASTED_LOG_LINES;
}

function labelNames(issue) {
    return (issue.labels || []).map((label) => (typeof label === 'string' ? label : label.name));
}

// Why the check doesn't apply to this issue, or null when it does.
function exemption(issue) {
    if (!(issue.body || '').includes(LOG_SECTION)) return 'not filed with a form that asks for a log';
    if (issue.user && issue.user.type === 'Bot') return 'filed by a bot (report.apolloreborn.app enforces the log itself)';
    if (MAINTAINER_ASSOCIATIONS.has(issue.author_association)) return 'filed by a maintainer';
    if (labelNames(issue).includes(SKIP_LABEL)) return `labelled ${SKIP_LABEL}`;
    return null;
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
                description: 'No debug log or crash log attached yet',
            });
        } catch (createError) {
            // 422: another run created it first.
            if (createError.status !== 422) throw createError;
        }
    }
}

function listComments(github, owner, repo, issueNumber) {
    return github.paginate(github.rest.issues.listComments, {
        owner,
        repo,
        issue_number: issueNumber,
        per_page: 100,
    });
}

// One marker-keyed comment per issue, edited in place rather than stacked.
async function upsertComment(github, owner, repo, issueNumber, body, comments) {
    const existing = comments.find((comment) =>
        comment.user && comment.user.type === 'Bot' && (comment.body || '').startsWith(MARKER));
    if (existing) {
        if (existing.body !== body) {
            await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body });
        }
        return;
    }
    await github.rest.issues.createComment({ owner, repo, issue_number: issueNumber, body });
}

async function run({ github, context, core }) {
    const { owner, repo } = context.repo;
    const payloadIssue = context.payload.issue;
    if (!payloadIssue || payloadIssue.pull_request) return;
    const issueNumber = payloadIssue.number;

    // Runs for one issue are serialized by the workflow's concurrency group,
    // but a queued event's payload can be older than the issue, so act on the
    // issue as it is now (labels, state, body).
    const { data: issue } = await github.rest.issues.get({ owner, repo, issue_number: issueNumber });
    const reason = exemption(issue);
    if (reason) {
        core.info(`#${issueNumber}: skipped, ${reason}`);
        return;
    }

    const flagged = labelNames(issue).includes(LABEL);
    const opened = context.eventName === 'issues' && context.payload.action === 'opened';

    if (opened && !flagged) {
        if (hasLog(issue.body)) {
            core.info(`#${issueNumber}: log attached`);
            return;
        }
        await ensureLabel(github, owner, repo);
        await github.rest.issues.addLabels({ owner, repo, issue_number: issueNumber, labels: [LABEL] });
        await upsertComment(github, owner, repo, issueNumber, MISSING_LOG_COMMENT,
            await listComments(github, owner, repo, issueNumber));
        core.info(`#${issueNumber}: no log, labelled ${LABEL}`);
        return;
    }

    // Everything else only ever clears a flag this check set. Look at
    // the issue and ALL of its author's comments, not just this event's: a
    // queued run can be superseded by a newer one (the concurrency group
    // keeps only the latest pending run), so a log posted in a comment right
    // before an edit must still count when the edit's run is the one left.
    if (!flagged) return;
    const comments = await listComments(github, owner, repo, issueNumber);
    const logAdded = hasLog(issue.body) || comments.some((comment) =>
        comment.user && issue.user && comment.user.login === issue.user.login && hasLog(comment.body));
    if (!logAdded) {
        core.info(`#${issueNumber}: still no log`);
        return;
    }

    try {
        await github.rest.issues.removeLabel({ owner, repo, issue_number: issueNumber, name: LABEL });
    } catch (error) {
        if (error.status !== 404) throw error;
    }
    await upsertComment(github, owner, repo, issueNumber, LOG_RECEIVED_COMMENT, comments);
    core.info(`#${issueNumber}: log added, ${LABEL} removed`);
}

module.exports = {
    run,
    hasLog,
    exemption,
    LABEL,
    SKIP_LABEL,
    MARKER,
    LOG_SECTION,
};
