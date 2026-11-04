# iPad menu commands

These commands belong to the opt-in iPad Layout beta. The app delegate adds
native main menus with UIMenuBuilder; iPadOS 26 and later display them in the
system menu bar. Supported earlier iPadOS releases retain the Command-key HUD.
Each command resolves through the responder chain of the current window and
uses the touched/explicitly focused column. Standard text editing and system
window menus remain in place.

| Action | Shortcut |
| --- | --- |
| Posts / Inbox / Profile / Search / Settings | Command-1 / 2 / 3 / 4 / 5 |
| Jump to Subreddit | Command-L |
| Subreddit directory | Command-Shift-L |
| New Post in current subreddit | Command-N |
| Reply to selected comment | Command-R |
| Refresh current column | Command-Shift-R |
| Find in current column | Command-F |
| Show / Hide Sidebar | Command-Control-S |
| Focus list / detail column | Command-Option-1 / 2 |
| Narrow / widen list column | Control-Option-Left / Right |
| Previous / next item | Up / Down |
| Open selected item | Right |
| Back / forward | Command-[ / ] (Left also goes back) |
| Deselect item | Escape |
| Open selected media | Return |
| Page down / up | Space / Shift-Space |
| Scroll to top / bottom | Command-Up / Down |
| Open detail in new window | Command-Shift-O |
| New Window (system menu) | Command-Option-N |

Jump accepts a subreddit name or an r/ prefix, validates before enabling Go,
and always opens Posts within the originating scene. New Post and Reply invoke
Apollo's native action handlers and composers, retaining its account, posting
and draft rules. Reply needs a selected comment; use Down/Up after focusing the
detail column. Commands are unavailable during text entry, presented sheets,
inactive scenes or navigation transitions. Empty/hidden columns and unrelated
screens disable their contextual commands. Holding a creation/navigation key
does not repeatedly open composers; selection, paging and width adjustment may
repeat on iPadOS 26.

Browsing keys keep Apollo's existing table-navigation priority over UIKit's
generic focus movement. Validation disables those actions during text input and
modal presentation, leaving editor and composer keys with their native owners.

The pane owns Apollo's existing browsing keys while this layout is active,
preventing a sibling navigation controller from handling them in the wrong
column. Other native keys, including the existing jump bar's Escape and composer
shortcuts, remain intact. iPhone and the classic layout install no menu hooks.

## Implementation reference

Apple: [What's new in UIKit — menu bar](https://developer.apple.com/videos/play/wwdc2025/243/).
Main menu configuration is applied once after app launch; validation updates
availability and the sidebar title without rebuilding the whole menu on scroll.
Browsing-key priority follows [UIKeyCommand.wantsPriorityOverSystemBehavior](https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior).

## Verification

Validated on the existing Apollo-iPad-Audit-13 simulator with Xcode device
interaction, plus simulator and device builds and the pane-policy checks.
Responder-dispatched commands verified:

- Subreddits selects the native directory row; Posts restores its feed position.
- Jump from Settings selects Posts and opens Apple in the originating scene.
  Invalid names disable Go, and all browsing actions disable while typing.
- New Post from feed and reader opens the native empty composer in Apple.
- New Post also opens the Apple composer with its empty reader focused, and
  remains disabled in the subreddit directory with that same focus.
- Selecting a comment and Reply opens that exact comment's native composer.
  Both composers were canceled empty, without submitting account actions.
- List/detail focus, previous/next selection, opening a reader, sidebar
  hide/show, Page Down, Scroll to Top, and Find execute in the focused column.
- Find found 40 matches for `apple`, stepped forward/backward, and closing
  the panel restored ordinary text/link rendering without reloading the reader.
- UIKit's menu builder reports File, View, Navigate and Post installed; logs
  contain no duplicate-shortcut errors. System New Window retains Command-Option-N
  so New Post can use Command-N.

Evidence is under `.sim/sidebar-audit/evidence/ipad-menus/`. Physical keyboard
events and visible system-menu clicks remain unverified: Xcode's interaction
tool does not synthesize modifier keys, and the simulator menu bar could not be
reliably revealed through touch or the available pointer controls. New-window,
width-adjustment, gallery/history and locked/archived-comment conditions still
need hands-on coverage. This is not a claim of complete beta release readiness.

On the final candidate, a documented Device Hub keypress attempt with keyboard
capture off hit the host's lock command; capture on produced no Apollo change,
including one content-focus retry. The original capture-off setting was
restored. These attempts do not establish working physical shortcut delivery.
Final posting-context UI and logs are in `candidate5`; menu registration and
keyboard attempts are in `candidate4`. Find cleanup is shown
in the paired `candidate3/find-active` and `candidate3/find-closed` captures.

Simulator-only `panemenu check` logs availability; `panemenu Name` validates and
dispatches a command through the application's responder chain. This fixture
does not synthesize physical keys.
