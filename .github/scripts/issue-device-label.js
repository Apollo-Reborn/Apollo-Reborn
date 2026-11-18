// Device labels for bug reports, run by .github/workflows/issue-device-label.yml.
//
// Every bug report says which device it happened on, and the form factor
// decides which simulator the bug gets reproduced on. This reads the Device
// field and adds the matching `device: …` label: iPhone Duo, iPad, Mac or
// (regular) iPhone. The label is only the form factor; the exact model stays
// in the field.
//
// The field arrives in two shapes:
//   - the GitHub Bug Report form (`device` input in bug_report.yml), which
//     renders as a `### Device` heading, a blank line, then the value;
//   - report.apolloreborn.app, whose Environment table has a
//     `| Device | iPhone Duo |` row (sometimes with the value in backticks).
//
// One field can name several devices ("iPhone Duo / iPhone 18 Pro Max"), and
// every one that matches gets its label. Nothing matching means no label.
// Labels are only ever added, never removed. On an edit, only a device the
// edit newly names is added, so a label a maintainer took off stays off when
// the reporter later edits something else (e.g. to attach a log).
'use strict';

const LABELS = {
    duo: 'device: iPhone Duo',
    ipad: 'device: iPad',
    mac: 'device: Mac',
    iphone: 'device: iPhone',
};
// Output order, so the labels and the log read the same way every run.
const LABEL_ORDER = [LABELS.duo, LABELS.ipad, LABELS.mac, LABELS.iphone];

// The Bug Report form's field: `### Device`, then everything up to the next
// heading. Keep in sync with the `label:` of the `device` input in
// bug_report.yml.
const FORM_FIELD = /^###[ \t]+Device[ \t]*\n([\s\S]*?)(?=^#{1,6}[ \t]|(?![\s\S]))/gim;
// report.apolloreborn.app's Environment table row.
const TABLE_ROW = /^[ \t]*\|[ \t]*(?:\*\*)?Device(?:\*\*)?[ \t]*\|([^|\n]*)\|/gim;
// What an empty optional form field or an unfilled table cell renders as.
const EMPTY_VALUE = /^(?:_no response_|_not provided_|n\/?a|none|-+)$/i;

// Where one device ends and the next starts: "/", ",", ";", "&", "+",
// newlines, brackets, "and", "or". A comma between digits is part of a model
// identifier ("iPad13,4"), not a separator. No `\s*` around it (entries are
// trimmed instead): split() retries at every position, so whitespace on both
// sides backtracks quadratically on a long run of spaces.
const SEPARATOR = /[\/;&+()\[\]\n]|,(?!\d)|\b(?:and|or)\b/i;

// The words that can follow an iPhone name ("16 Pro Max", "15PM", "SE 3rd
// gen", "18pro"). Consuming them stops "iPhone 16 Pro Mac" (a typo for Max)
// from also reading as a Mac, and the "Air" in "iPhone Air" as a second
// device.
const MODEL_TOKEN = String.raw`\s*(?:\d{1,2}(?:st|nd|rd|th)?(?![\d.])|(?:pro|max|mac|plus|mini|pm|air|se|xr|xs|x|e|s|r|gen(?:eration)?)(?![a-z]))`;
// One device mention. Order matters where two could start at the same place:
// "iPhone Duo" is a Duo, not an iPhone. iPad and Mac take their "Air", "Pro"
// and "mini" with them so those aren't read again as an iPhone Air.
const DEVICE = new RegExp([
    String.raw`(?<duo>iphone\s*duo(?![a-z])|\bduo(?![a-z]))`,
    String.raw`(?<ipad>ipad[a-z]*(?:\s+(?:air|pro|mini))?)`,
    String.raw`(?<mac>\b(?:i?mac(?:os|book)?)(?![a-z])(?:\s+(?:air|pro|mini|studio))?)`,
    String.raw`(?<iphone>(?:iphone|\bip(?=\d))(?:${MODEL_TOKEN})*)`,
    // A bare model at the start of an entry: "18 pro max", "16 pro", "17 pm",
    // "15PM", "13", "Air", "SE 3", "XR". A number has to be followed by a model
    // word or end the entry, so "26.1" or "13 inch" isn't read as one.
    String.raw`(?<bare>^(?:\d{1,2}(?![\d.])(?=(?:${MODEL_TOKEN})|\s*$)|(?:air|se|xr|xs|x)(?![a-z]))(?:${MODEL_TOKEN})*)`,
].join('|'), 'gi');

// Every Device value in an issue body, cleaned of backticks and emphasis.
function deviceFields(body) {
    const text = String(body || '').replace(/\r\n?/g, '\n');
    const values = [];
    for (const pattern of [FORM_FIELD, TABLE_ROW]) {
        pattern.lastIndex = 0;
        for (const match of text.matchAll(pattern)) {
            const value = match[1].replace(/[`*]/g, '').trim();
            if (value && !EMPTY_VALUE.test(value)) values.push(value);
        }
    }
    return values;
}

// The labels one Device value maps to.
function labelsForValue(value) {
    const found = new Set();
    for (const entry of String(value || '').split(SEPARATOR)) {
        const text = entry.trim();
        if (!text) continue;
        DEVICE.lastIndex = 0;
        for (const match of text.matchAll(DEVICE)) {
            const kind = Object.keys(match.groups).find((name) => match.groups[name] !== undefined);
            found.add(kind === 'bare' ? LABELS.iphone : LABELS[kind]);
        }
    }
    return LABEL_ORDER.filter((label) => found.has(label));
}

// The labels an issue body's Device field(s) map to.
function labelsForBody(body) {
    const found = new Set();
    for (const value of deviceFields(body)) {
        for (const label of labelsForValue(value)) found.add(label);
    }
    return LABEL_ORDER.filter((label) => found.has(label));
}

function labelNames(issue) {
    return (issue.labels || []).map((label) => (typeof label === 'string' ? label : label.name));
}

// What to add for this event: everything the body names when the issue is
// opened; on an edit, only what the edit newly names (a title-only edit adds
// nothing). Labels already on the issue are left out.
function labelsToAdd(eventAction, issue, changes) {
    let wanted = labelsForBody(issue.body);
    if (eventAction === 'edited') {
        if (!changes || !changes.body) return [];
        const before = new Set(labelsForBody(changes.body.from));
        wanted = wanted.filter((label) => !before.has(label));
    }
    const present = new Set(labelNames(issue));
    return wanted.filter((label) => !present.has(label));
}

async function run({ github, context, core }) {
    const { owner, repo } = context.repo;
    const issue = context.payload.issue;
    if (!issue || issue.pull_request) return;
    const issueNumber = issue.number;

    const values = deviceFields(issue.body);
    if (values.length === 0) {
        core.info(`#${issueNumber}: no Device field`);
        return;
    }
    core.info(`#${issueNumber}: Device ${values.map((value) => JSON.stringify(value)).join(', ')}`);

    // Adding is idempotent and order doesn't matter, so runs for the same
    // issue don't need to be serialized. Labels on the payload can be a moment
    // old; a label that got added meanwhile is just added again (a no-op).
    const labels = labelsToAdd(context.payload.action, issue, context.payload.changes);
    if (labels.length === 0) {
        core.info(`#${issueNumber}: nothing to add`);
        return;
    }
    await github.rest.issues.addLabels({ owner, repo, issue_number: issueNumber, labels });
    core.info(`#${issueNumber}: added ${labels.join(', ')}`);
}

module.exports = {
    run,
    deviceFields,
    labelsForValue,
    labelsForBody,
    labelsToAdd,
    LABELS,
};
