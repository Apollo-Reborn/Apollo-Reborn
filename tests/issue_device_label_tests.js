#!/usr/bin/env node
// Runs .github/scripts/issue-device-label.js (the "Bug report device label"
// workflow): Device values as reporters actually wrote them, both body
// formats, the edit rule, and the add-only flow against a stand-in for the
// GitHub issues API.
'use strict';

const label = require('../.github/scripts/issue-device-label.js');

const { duo: DUO, ipad: IPAD, mac: MAC, iphone: IPHONE } = label.LABELS;

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
function requireEqual(actual, expected, message) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    if (a !== e) throw new Error(`${message}: expected ${e}, got ${a}`);
}

// What GitHub renders for a Bug Report form submission.
function formBody(device) {
    return [
        '### Describe the bug',
        '',
        'Videos on my iPad stop playing after I scroll.',
        '',
        '### iOS version',
        '',
        'iOS 27.1',
        '',
        '### Device',
        '',
        device,
        '',
        '### Installation method',
        '',
        'AltStore Classic/SideStore',
    ].join('\n');
}

// What report.apolloreborn.app files (Environment table).
function reportBody(device) {
    return [
        '## Describe the bug',
        'Scrolling on the Mac keeps going after I touch the screen.',
        '',
        '## Environment',
        '| | |',
        '|---|---|',
        '| Apollo Reborn version | `4.0.1` |',
        '| iOS version | `27.2` |',
        `| Device | ${device} |`,
        '| Installation method | AltStore Classic/SideStore |',
        '',
        '## Additional context',
        'Happens on my iPhone too.',
    ].join('\n');
}

// ------------------------------------------------------------ device values

// Real values from open and closed issues (issue number in the name), plus a
// few that must not match.
const VALUE_CASES = [
    // iPhone Duo
    ['iPhone Duo (#1538)', 'iPhone Duo', [DUO]],
    ['iPhone duo (#1679)', 'iPhone duo', [DUO]],
    ['Iphone duo (#1667)', 'Iphone duo', [DUO]],
    ['bare Duo (#1742)', 'Duo', [DUO]],
    ['no space: iPhoneDuo', 'iPhoneDuo', [DUO]],
    // iPad
    ['iPad Pro 11 inch (#1483)', 'iPad Pro 11 inch', [IPAD]],
    ['iPad Pro m1 (#1521)', 'iPad Pro m1', [IPAD]],
    ['iPad mini 6 (#1548)', 'iPad mini 6', [IPAD]],
    ['iPad Air M3: Air is the iPad\'s (#1449)', 'iPad Air M3', [IPAD]],
    ['Ipad (#964)', 'Ipad', [IPAD]],
    ['iPad Pro 11-inch (M4) (#1397)', 'iPad Pro 11-inch (M4)', [IPAD]],
    ['iPad Pro 11” 3rd Gen (#615)', 'iPad Pro 11” 3rd Gen', [IPAD]],
    ['ipad pro 12.9 m1 (#893)', 'ipad pro 12.9 m1', [IPAD]],
    ['model identifier iPad13,4', 'iPad13,4', [IPAD]],
    // Mac
    ['Mac', 'Mac', [MAC]],
    ['macOS', 'macOS 26.5', [MAC]],
    ['MacBook Air: Air is the Mac\'s', 'MacBook Air M2', [MAC]],
    ['Mac mini', 'Mac mini M4', [MAC]],
    ['iMac', 'iMac 24"', [MAC]],
    // iPhone
    ['iPhone 13 (#701)', 'iPhone 13', [IPHONE]],
    ['iPhone Air (#1451)', 'iPhone Air', [IPHONE]],
    ['iphone 17 pro max (#1453)', 'iphone 17 pro max', [IPHONE]],
    ['IPhone 18 pro (#1714)', 'IPhone 18 pro', [IPHONE]],
    ['iPhone 13 mini (#1628)', 'iPhone 13 mini', [IPHONE]],
    ['iPhone SE 3 Gen (#1085)', 'iPhone SE 3 Gen', [IPHONE]],
    ['iPhone XR (#899)', 'iPhone XR', [IPHONE]],
    ['iPhone 6S (#1509)', 'iPhone 6S', [IPHONE]],
    ['IPhone 17Pro (#858)', 'IPhone 17Pro', [IPHONE]],
    ['iPhone 18pro (#1458)', 'iPhone 18pro', [IPHONE]],
    ['bare iPhone (#702)', 'iPhone', [IPHONE]],
    ['typo "Pro Mac" for Max is not a Mac (#986)', 'iPhone 16 Pro Mac', [IPHONE]],
    ['bare 18 pro max (#1433)', '18 pro max', [IPHONE]],
    ['bare 16 pro (#1519)', '16 pro', [IPHONE]],
    ['bare 17 pm (#1698)', '17 pm', [IPHONE]],
    ['bare 15PM (#1733)', '15PM', [IPHONE]],
    ['bare 16pm (#1029)', '16pm', [IPHONE]],
    ['bare 16e (#1175)', '16e', [IPHONE]],
    ['bare 13 (#763)', '13', [IPHONE]],
    ['bare 17 max (#1135)', '17 max', [IPHONE]],
    ['bare Air', 'Air', [IPHONE]],
    ['iP15 pro max (#1197)', 'iP15 pro max', [IPHONE]],
    // Several devices in one field
    ['Duo / 18 Pro Max / 16 Pro (#1701)', 'iPhone Duo / iPhone 18 Pro Max / iPhone 16 Pro', [DUO, IPHONE]],
    ['iPhone 12 Pro Max/iPhone 16 Pro Max (#1546)', 'iPhone 12 Pro Max/iPhone 16 Pro Max', [IPHONE]],
    ['iPhone & iPad (#811)', 'iPhone 16 pro max & iPad Pro 5th gen', [IPAD, IPHONE]],
    ['iPhone then iPad, no separator (#827)', 'iPhone 16 Pro Max iPad Pro 5th gen', [IPAD, IPHONE]],
    ['"or" with iPad Air (#906)', 'iPhone 16 pro or iPad Air', [IPAD, IPHONE]],
    ['Any Mac or iPad (#635)', 'Any Mac or iPad', [IPAD, MAC]],
    ['bare model after a separator', 'Duo, 16 pro', [DUO, IPHONE]],
    ['iPhone, then a real Mac', 'iPhone 16 Pro, Mac', [MAC, IPHONE]],
    ['iPhone and a real Mac', 'iPhone 16 Pro and MacBook Pro', [MAC, IPHONE]],
    // No match
    ['empty', '', []],
    ['an iOS version is not a model', '26.1', []],
    ['a size is not a model', '13 inch', []],
    ['a year is not a model', '2018', []],
    ['Android phone', 'Pixel 9', []],
    ['unknown', 'Not sure', []],
    ['"Machine" is not a Mac', 'Machine', []],
];

(async () => {
    for (const [name, value, expected] of VALUE_CASES) {
        await test(`value: ${name}`, () => {
            requireEqual(label.labelsForValue(value), expected, JSON.stringify(value));
        });
    }

    // ------------------------------------------------------------ body formats

    await test('form field', () => {
        requireEqual(label.deviceFields(formBody('iPhone 16 Pro')), ['iPhone 16 Pro'], 'fields');
        requireEqual(label.labelsForBody(formBody('iPhone 16 Pro')), [IPHONE], 'labels');
    });

    await test('form field with CRLF line endings', () => {
        requireEqual(label.labelsForBody(formBody('iPad mini 7').replace(/\n/g, '\r\n')), [IPAD], 'labels');
    });

    await test('form field as the last section', () => {
        requireEqual(label.labelsForBody('### Describe the bug\n\nx\n\n### Device\n\niPhone Duo'), [DUO], 'labels');
    });

    await test('empty form field (_No response_)', () => {
        requireEqual(label.labelsForBody(formBody('_No response_')), [], 'labels');
    });

    await test('other text in a form body is ignored (mentions iPad and iOS 27.1)', () => {
        requireEqual(label.labelsForBody(formBody('iPhone 15 Pro')), [IPHONE], 'labels');
    });

    await test('report table row', () => {
        requireEqual(label.deviceFields(reportBody('iPhone Duo')), ['iPhone Duo'], 'fields');
        requireEqual(label.labelsForBody(reportBody('iPhone Duo')), [DUO], 'labels');
    });

    await test('report table row with the value in backticks', () => {
        requireEqual(label.deviceFields(reportBody('`iPad Pro M4`')), ['iPad Pro M4'], 'fields');
        requireEqual(label.labelsForBody(reportBody('`iPad Pro M4`')), [IPAD], 'labels');
    });

    await test('report table row with a bold key', () => {
        requireEqual(label.labelsForBody('| **Device** | `16 pro` |'), [IPHONE], 'labels');
    });

    await test('report table row with several devices', () => {
        requireEqual(label.labelsForBody(reportBody('iPhone Duo / iPhone 18 Pro Max / iPhone 16 Pro')), [DUO, IPHONE], 'labels');
    });

    await test('other text in a report body is ignored (mentions Mac and iPhone)', () => {
        requireEqual(label.labelsForBody(reportBody('iPad mini 6')), [IPAD], 'labels');
    });

    await test('no Device field', () => {
        requireEqual(label.deviceFields('I have Apollo installed on MacOS.\n\nOperating System - MacOS 26.5'), [], 'fields');
        requireEqual(label.labelsForBody(null), [], 'null body');
    });

    await test('a "### Device …" heading with more words is not the field', () => {
        requireEqual(label.deviceFields('### Devices tested\n\niPad, iPhone Duo'), [], 'fields');
    });

    await test('long runs of whitespace stay fast (no quadratic backtracking)', () => {
        // An issue body can be up to 65,536 characters. Before the separator
        // lost its `\s*` padding, 60k spaces took ~14 s.
        const spaces = ' '.repeat(60000);
        const bodies = [
            formBody(`iPhone${spaces}x`),
            formBody(`a${spaces}b`),
            `| Device | a${spaces}b |`,
            formBody(`16${spaces}x`),
            formBody(`Mac${spaces}\t`.repeat(2)),
        ];
        const started = Date.now();
        for (const body of bodies) label.labelsForBody(body);
        const elapsed = Date.now() - started;
        if (elapsed > 1000) throw new Error(`took ${elapsed} ms`);
    });

    // ------------------------------------------------------------ what to add

    await test('opened: every matching label', () => {
        const issue = { body: reportBody('iPhone Duo / 16 Pro'), labels: [{ name: 'bug' }] };
        requireEqual(label.labelsToAdd('opened', issue, undefined), [DUO, IPHONE], 'labels');
    });

    await test('opened: labels already on the issue are left out', () => {
        const issue = { body: reportBody('iPhone Duo / 16 Pro'), labels: [{ name: DUO }] };
        requireEqual(label.labelsToAdd('opened', issue, undefined), [IPHONE], 'labels');
    });

    await test('edited: a device the edit newly names is added', () => {
        const issue = { body: formBody('iPhone Duo / iPhone 16 Pro'), labels: [{ name: IPHONE }] };
        requireEqual(label.labelsToAdd('edited', issue, { body: { from: formBody('iPhone 16 Pro') } }), [DUO], 'labels');
    });

    await test('edited: a label a maintainer removed is not re-added by an unrelated edit', () => {
        // Reporter wrote iPhone, a maintainer swapped the label for Duo, then
        // the reporter edited the body to attach a log.
        const before = formBody('iPhone 16 Pro');
        const issue = { body: `${before}\n\n[apollo.log](https://github.com/user-attachments/files/1/apollo.log)`, labels: [{ name: DUO }] };
        requireEqual(label.labelsToAdd('edited', issue, { body: { from: before } }), [], 'labels');
    });

    await test('edited: a title-only edit adds nothing', () => {
        const issue = { body: formBody('iPad Air'), labels: [] };
        requireEqual(label.labelsToAdd('edited', issue, { title: { from: 'old' } }), [], 'labels');
    });

    await test('edited: a Device field added in the edit is labelled', () => {
        const issue = { body: formBody('Mac'), labels: [] };
        requireEqual(label.labelsToAdd('edited', issue, { body: { from: 'no field yet' } }), [MAC], 'labels');
    });

    // --------------------------------------------------------------- run flow

    function fakeGitHub() {
        const calls = [];
        return {
            calls,
            rest: {
                issues: {
                    addLabels: async (params) => { calls.push(['addLabels', params]); },
                    removeLabel: async (params) => { calls.push(['removeLabel', params]); },
                },
            },
        };
    }
    function fakeContext(action, issue, changes) {
        return { repo: { owner: 'o', repo: 'r' }, payload: { action, issue, changes } };
    }
    const core = { info: () => {} };

    await test('run: opened adds the labels in one call', async () => {
        const github = fakeGitHub();
        const issue = { number: 7, body: reportBody('iPhone Duo / iPhone 18 Pro Max'), labels: [] };
        await label.run({ github, context: fakeContext('opened', issue), core });
        requireEqual(github.calls, [['addLabels', { owner: 'o', repo: 'r', issue_number: 7, labels: [DUO, IPHONE] }]], 'calls');
    });

    await test('run: nothing matching makes no call', async () => {
        const github = fakeGitHub();
        await label.run({ github, context: fakeContext('opened', { number: 8, body: formBody('Pixel 9'), labels: [] }), core });
        await label.run({ github, context: fakeContext('opened', { number: 9, body: 'no field', labels: [] }), core });
        requireEqual(github.calls, [], 'calls');
    });

    await test('run: never removes a label, even one the field no longer names', async () => {
        const github = fakeGitHub();
        const issue = { number: 10, body: formBody('iPad Pro'), labels: [{ name: IPHONE }] };
        await label.run({ github, context: fakeContext('edited', issue, { body: { from: formBody('iPhone 16') } }), core });
        requireEqual(github.calls, [['addLabels', { owner: 'o', repo: 'r', issue_number: 10, labels: [IPAD] }]], 'calls');
    });

    await test('run: pull requests are skipped', async () => {
        const github = fakeGitHub();
        await label.run({ github, context: fakeContext('opened', { number: 11, body: formBody('iPad'), labels: [], pull_request: {} }), core });
        requireEqual(github.calls, [], 'calls');
    });

    if (failures) {
        console.error(`\n${failures} test(s) failed`);
        process.exit(1);
    }
    console.log('\nall issue device label tests passed');
})();
