# Reddit endpoint migration audit

Last validated: October 1, 2026

## Why this exists

Reddit announced several separate platform changes:

- RSS feeds stop working on November 13, 2026.
- New public Data API access requests stop on October 31, 2026. Access begins
  closing for unregistered apps and users on January 12, 2027, with remaining
  public access scheduled to close in March 2027.
- Old Reddit is already login-gated. Reddit plans to limit non-moderator access
  to accounts that used it within the prior six months.

These are different changes. Old Reddit does not have a published shutdown date,
and a working RSS URL today does not change the announced November deadline.

Primary sources:

- [Reddit infrastructure update](https://www.reddit.com/r/modnews/comments/1wubgvt/continuing_our_infrastructure_updates_whats/)
- [Reddit Data API migration announcement](https://www.reddit.com/r/redditdev/comments/1wubcvf/moving_data_api_apps_to_the_developer_platform/)

## Repository findings

Apollo Reborn has no RSS parser, `.rss` request, or RSS-backed feature. No RSS
code migration is required.

The app does depend on Reddit APIs. Its registered OAuth client flow remains a
core transport, so the broader Developer Platform migration needs separate
tracking as Reddit publishes requirements for existing third-party clients. A
cookie or anonymous `www.reddit.com/*.json` request is not a durable substitute
for registered access.

The Old Reddit dependency removal is split across two reviewable changes:

1. Upstream PR #1327 moves keyless media hydration to current Reddit JSON and
   moves current-flair lookup to authenticated subreddit `about.json`.
2. The follow-up removes legacy flair-option HTML parsing, the direct Old Reddit
   trophy scrape, and Old Reddit login routing. It also retires Old Reddit as an
   outbound share host and removes user guidance that required its preferences
   page.

## Intentional compatibility that remains

Apollo should continue to recognize existing Old Reddit URLs in posts, deleted
comment sources, upload callbacks, and the Safari extension. Those paths parse
or normalize inbound links and do not make Old Reddit a runtime dependency.

Legacy response-shape repair and CSS-sprite flair rendering also remain. They
describe data formats still returned by current endpoints, not a dependency on a
legacy hostname.

## Known limitations

- Badge Book first tries Reddit's authenticated trophy API, then the current
  profile WebView. Reddit has returned forbidden responses for some third-party
  bearers, and current profile markup does not consistently expose trophies.
  Achievements continue to load separately. Trophy rows may therefore be slower
  or unavailable until Reddit provides a stable supported endpoint.
- OAuth sign-in on iOS 15 and earlier uses the existing external-browser manual
  flow. API-Key-Free web-session login cannot import external browser cookies, so
  it tries Reddit's current page and explains that a new or refreshed session may
  require iOS 16 or later. Existing saved sessions continue until they expire.
- Reddit's announced public Data API closure is larger than this Old Reddit
  migration. It cannot be solved by hostname replacement and should not be
  hidden behind anonymous JSON fallbacks.
