# Implementation Plans

Current iPad redesign implementation and validation are recorded in Plan 003.
The historical plans remain as design and audit context; implementation status
does not imply that physical-device release gates have passed.

## Execution order & status

| Plan | Title | Priority | Effort | Depends on | Status |
|------|-------|----------|--------|------------|--------|
| 001 | Unify the adaptive iPad pane chrome | P1 | L | — | INCORPORATED with revisions into 002 |
| 002 | Complete iPad pane redesign: 14 packages / 17 findings | P1–P3 | XL | 001 incorporated | IMPLEMENTED; release validation open |
| 003 | Implementation results and verification | — | — | 002 | Current evidence and remaining gates |

Current results: [003 — implementation and verification](003-ipad-pane-implementation-results.md).

## Dependency notes

- Plan 001 is self-contained. Keep it as one reviewed change because the
  destination placement, title treatment, search takeover, and immersive-header
  boundary are four parts of one chrome state machine; landing only one can make
  the visual hierarchy less coherent.

## Findings considered and rejected

- Replace Apollo's two navigation controllers with one custom pane-wide toolbar:
  rejected because it would discard Apollo's real navigation items, back-stack
  behavior, keyboard commands, and Liquid Glass integration—the central safety
  premise of PR #886.
- Remove Liquid Glass or the immersive header globally: rejected because the
  problem is pane-specific ownership and hierarchy, not either feature by
  itself. Preserve current iPhone and pane-disabled behavior.
- Force the destination sidebar permanently: rejected because UIKit deliberately
  provides a user-controlled sidebar/tab-bar toggle. Prefer the sidebar on first
  presentation at wide widths, then respect an explicit user choice.
