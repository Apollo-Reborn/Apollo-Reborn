# Account-switch crash investigation — September 14, 2026

Reported sequence: start with an API-less account, open Accounts, switch to an
API account. No session log is available. These are two distinct reports, and
the available evidence does not establish a shared root cause.

## Feed-row trap: fixed path, account-specific reproduction still pending

Attachment `apollo-reborn-crash 5.json`, September 12 at 17:32:19 UTC:
3.7.0 / `85797df`, standard no-extensions build, iOS 26.6.2.

The native Apollo UUID is `9E4EC7AC-92B8-3A03-856C-CE3664D76B97`.
Image offsets `0x63fa28`, `0x63f058`, `0x640290` identify a bounds trap while
constructing a feed-shortcut cell. Assembly compares IndexPath.row against the
fresh Swift feed array's count, then branches to `brk #1` when row >= count.
The array contains Home and optionally Popular, All and Moderator Posts.
The matching release dSYM resolves the intervening tweak frames to cell
creation hooks, not the nearby exported names shown in the sanitized report.

UIKit can still request a row from its old count after the account-dependent
feed list shrinks. The new guard asks the data source for its current count
before calling native cell creation. It returns an inert temporary cell for
an obsolete section-zero row and coalesces a reload on the next main-queue
turn. It never reloads inside the cell/layout callback, never forwards the
invalid row, and never reloads a table reassigned to another data source.
Other sections and valid rows retain their native behavior.

Validation:

- 15 AddressSanitizer/UndefinedBehaviorSanitizer host checks pass, including
  a four-row to three-row account model transition, coalescing, rapid switch
  back, and data-source replacement.
- A dedicated simulator fixture requested the obsolete row 3 when native
  Apollo reported 3 feeds. The baseline crashed with EXC_BREAKPOINT at the
  exact three native offsets above. With the new guard, that same request
  returned a noninteractive UITableViewCell and the app survived.
- Full simulator tweak compilation/linking/signing passed on iOS 27.
- Device compilation passed for the modified source; the full package could
  not link with the local pinned SDK because existing Translation and
  FoundationModels symbols were unresolved. No device IPA was produced.

The native fixture synthesizes the stale request; it does not sign into the
reporter's accounts or prove which account property changed first. Switching
between API-less and API accounts should still be verified on the affected
device. The guard covers the observed bounds failure independently of login
transport and whether the table has custom section ordering enabled.

## Allocator trap during logging: unresolved

Attachment `apollo-reborn-crash 4.json`, September 14 at 13:37:21 UTC:
3.7.1 / `c2fa403`, Glass build, iOS 26.6.2.

Thread 14 traps in libsystem_malloc, through libc++abi and ICU calendar/date
formatting. Apollo offsets `0x37c224` and `0x37c654` are the native
EmojiLogFormatter path called by CocoaLumberjack's DDOSLogger. Disassembly
shows setting the date format and then calling stringFromDate: on its stored
NSDateFormatter. Other threads are constructing and laying out feed nodes;
the main thread waits for an AsyncDisplayKit table update.

This is not an out-of-bounds feed-cell stack. It also is not a
memory_termination report: there is no footprint or allocation-failure reason.
The allocator trap could be related to memory pressure or corruption; the
capture cannot establish which, or implicate API-less authentication itself.
Replacing or locking the formatter would not establish a fix for those causes.

20,000 calls to the native EmojiLogFormatter, sharing one formatter across
four workers in the simulator, completed without a crash or missing message
text. This is a concurrency stress check, not proof that the iOS 26.6.2 failure
cannot occur. No formatter change is included. This report remains open for
an affected-device reproduction with allocation/memory diagnostics.
