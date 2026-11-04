# keyless-routes.json

API-Key-Free (web session) accounts send some reads to Reddit by more than one route, because www.reddit.com refuses them at their usual path with its 403 block page. The routes and their order are built into the tweak (`src/ApolloWebJSONRoutes.m`). `keyless-routes.json`, at the root of this repository, lets maintainers change them for every install without a release, including for a read that isn't built in.

Installs with API-Key-Free Mode on and **Use Route Updates** on (the default) fetch it from `main` while the app is open: on foreground and every 15 minutes, as a conditional request. A change reaches an install within about 15 minutes of its next foreground.

## Routes

A route is three parts, each from a list built into the app. The file picks parts; it can't give a host or URL.

| Part | Values |
|---|---|
| `host` | `www`, `old`, `api`, `oauth` (each `<host>.reddit.com`) |
| `path` | `same` (unchanged, the default), `dotjson` (`/api/<endpoint>/.json`), `r-all` (`/r/all` in front: `/r/all/api/info.json`; `/api/` paths only) |
| `auth` | `cookie` (the default), `bearer` (`oauth` only) |

`bearer` sends a bearer token minted from the cookie for Reddit's mobile client, and no cookie. It never sends the `token_v2` cookie: that's the desktop web client's token, which oauth.reddit.com refuses for post search. The app mints the bearer in the background while an entry lists a bearer route. A request that finds none ready goes by its next route instead of waiting, so a bearer route should have a cookie route after it. No built-in entry uses it.

A route is written as a name or as its parts. The name is the host, then `-<path>` unless it's `same`, then `+bearer` for bearer auth:

| Name | Parts |
|---|---|
| `www` | `{"host": "www"}` |
| `www-dotjson` | `{"host": "www", "path": "dotjson"}` |
| `old` | `{"host": "old"}` |
| `api` | `{"host": "api"}` |
| `oauth` | `{"host": "oauth"}` (the cookie, no bearer) |
| `oauth+bearer` | `{"host": "oauth", "auth": "bearer"}` |
| `www-r-all` | `{"host": "www", "path": "r-all"}` |

Every other combination works the same way (`old-dotjson`, `oauth-r-all+bearer`, …). Bearer auth on any host but `oauth` is rejected.

`api` isn't in the `/api/` entries: as of 2026-10-24 it refused both of them for the cookie, and the file can list it for them again if Reddit reopens it. For `/api/info` alone, `www.reddit.com/r/all/api/info.json` (`www-r-all`) also answered the cookie then, but since 2026-10-28 www blocks every path under `/r/all`, that one included.

## Built-in entries

| Entry | Routes |
|---|---|
| `GET /api/info`, `GET` and `POST /api/morechildren` | `www-dotjson`, `old` |
| `GET /search`, `/subreddits/search`, `/r/*/search`, `/r/+/search` | `oauth`, `old` |
| `GET /r/all`, `GET /r/all/*` | `oauth`, `api`, `old` |

Search: www blocks post search for the cookie. `oauth.reddit.com` blocks it for tokens issued to Reddit's desktop web client (`cid` `0R-WAMhuoo-MyQ`), which includes the `token_v2` cookie, but accepts tokens minted for the mobile client. Search doesn't need either: `oauth` and `old` both served it signed in to the cookie alone on 2026-10-27 (tested on one account). Of the cookie, `reddit_session` is what matters; `token_v2` isn't needed, and a stale one doesn't break the request. `/r/*/search` is a community search; `/r/+/search` is Apollo's multireddit search, which joins the subreddits with `+` (`/r/a+b+c/search`). Apollo never uses Reddit's `/user/<name>/m/<multi>/search` form.

`/r/all`: www answers every path under `/r/all` with its block page, with the cookie and signed out alike (since 2026-10-27), while `/r/popular`, single subreddits (`r/allergies` too) and `+` lists still load there. Apollo's front page asks for `/r/All/best.json?api_type=json&limit=12&raw_json=1` (keys are matched lowercased, so the capital A doesn't matter). `GET /r/all` covers the bare path and `GET /r/all/*` every sort, and both cover r/all's filter forms (see Patterns). `oauth`, `api` and `old` all served r/all listings signed in to the cookie (tested on 2026-10-27 and 2026-10-28: posts the account had saved or voted on came back marked), and without the cookie none did: oauth and api refused, and old redirected to its login page. api's listings carry the same image fields as www's feeds. `api` needs the `.json` the app always sends for listings; without it, api.reddit.com redirects to www's home page.

## Format

```json
{
  "version": 1,
  "endpoints": {
    "GET /api/info": { "routes": ["old", "www-dotjson"] },
    "POST /api/morechildren": { "routes": ["www-dotjson"] },
    "GET /r/all/*": { "routes": [{ "host": "oauth", "auth": "bearer" }, "old"] },
    "GET /r/+/*": { "routes": ["www", "old"] },
    "GET /user/*/submitted": { "routes": ["www", "oauth"] }
  }
}
```

Each key is `<METHOD> <pattern>`. `routes` lists 1 to 5 routes to try in order. A request goes by the first route that isn't cooling down for that account (and, for bearer auth, has a bearer ready), and a block page sends it again by the next one.

### Patterns

A pattern is a path with `/` between segments, and each segment is one of:

- a lowercase literal (`a-z`, `0-9`, `_`, `-`): `r`, `all`, `inbox`;
- `*`: one name (`/r/*/hot` matches `/r/apple/hot`, not `/r/apple+ios/hot`);
- `+`: two or more names joined with `+` (`/r/+/hot` matches `/r/apple+ios/hot`, not `/r/apple/hot`), so multireddit feeds have their own entries.

Write it the way Reddit's path reads, without `.json`, a query or a trailing slash; a bare path like `/r/all` is its own key. A pattern only matches paths with the same number of segments (`/comments/*` matches `/comments/abc123`, not `/comments/abc123/slug`). When several entries match, the most specific wins: compare the segments left to right, and the first where one has a literal and the other a wildcard decides. So `/r/all/best` beats `/r/all/*`, which beats `/r/*/search` for `/r/all/search`, and `/r/apple/*` beats `/r/*/search` for `/r/apple/search`. A file entry with the same pattern as a built-in one replaces it.

r/all's filter forms match as `all`: `/r/all-<sub>-<sub>/<sort>`, r/all without those subreddits (what All Posts' Exclude Subscriptions sends), and `/r/all+<sub>/<sort>` both match `/r/all/*`. That's r/all's alone. Subreddit names can't contain `-`, Reddit answers `r/popular-<sub>` as a subreddit it can't find, and Popular's Exclude Subscriptions filters the posts it has loaded without a new request.

### Rules

- **Any read** can be added as a `GET`. Only the built-in `POST /api/morechildren` (a POST that only reads) takes a `POST`. Writes can't be added, and are never resent.
- **Not everything at once.** Patterns made only of wildcards (`/*`, `/*/*`) and `/r/` followed only by `*` (`/r/*`, `/r/*/*`) are rejected, so one entry can't move all of browsing to another route. Name the feed instead (`/r/all/*`, `/r/apple/*`, `/r/+/*`). A pattern for an r/all filter form (`/r/all-askreddit/*`) is rejected too, since it matches as `/r/all/*`.
- **Route parts** come from the lists above. `r-all` is for `/api/` patterns only, and `bearer` for `oauth` only.

The app leaves out any entry that breaks these rules and logs why. A file it can't read (not JSON, over 16 KB, more than 32 endpoints, `version` not `1`) is ignored whole, and the app keeps the routes it was using. `"endpoints": {}` means the built-in routes everywhere.

Builds before route parts and patterns leave out, entry by entry, keys they don't know and routes given as objects, so a file using them still works for older installs: they keep their own routes for those entries.

### Route health

Each account keeps per-route counts for each entry, so a block page on `/r/all/best` counts against `/r/all/*` and a success on `/r/apple/best` doesn't clear it. Three block pages in a row put a route on cooldown for an hour, doubling to at most eight hours. Requests no entry matches are counted by their path pattern (`/r/*/hot`, `/r/+/hot`) and listed on the Routes screen under "Blocked paths without another route" when www blocks them; that list is where a new block shows up first.

## Checking a route

Before listing a route, check it serves the read signed in. With the account's cookie alone (copy `reddit_session` from a signed-in browser; `token_v2` isn't needed), request the read by the route and check the answer is JSON for the account rather than the block page or a signed-out listing. Send a full browser User-Agent, as the app does: Reddit answers every host with the block page for a bare `Mozilla/5.0`.

For a listing, save a post or two from it in the browser first. A signed-in answer returns them with `saved: true`, and has a non-empty `data.modhash`:

```bash
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Safari/605.1.15'
curl -s -H 'Cookie: reddit_session=<value>' -A "$UA" 'https://oauth.reddit.com/r/all/best.json?limit=25&raw_json=1' | jq '{modhash: .data.modhash, saved: [.data.children[].data | select(.saved) | .title]}'
```

Run it once without the cookie as well: a route that also answers signed out could fall back to a signed-out listing without any error. Swap the host and path for the route under test (`api.reddit.com`, `old.reddit.com/api/info.json?id=…`). An HTML answer with HTTP 403 is the block page. For `/api/` endpoints, which have no modhash, `GET /api/me.json` on the same host should name the account. A bearer route can't be checked with curl alone; check it in the app (below).

Review the route as well as the JSON. Reddit is limiting `old.reddit.com` to accounts with recent Old Reddit use (it redirects requests without a session to its login page), and plans to retire it, so list `old` after the other routes unless they're blocked for everyone. `oauth` with the cookie is known to work for search; for other endpoints check what it answers first (with the cookie, `/api/v1/me` there returns only `features`).

## Changing the file

1. Check the route as above. In a simulator build, the debug bridge's `routeblock <route>` makes a route get Reddit's real block page, `routehealth` prints which routes answered, and `APOLLO_KEYLESS_ROUTES_URL` (passed as `SIMCTL_CHILD_APOLLO_KEYLESS_ROUTES_URL`, `file://` allowed) points the app at a local copy of this file.
2. Edit the file on `main`. Keep it valid JSON; a rejected file changes nothing.
3. To undo every override, set `"endpoints": {}` or delete the file. Installs drop their overrides on the next check.

The app logs the overrides in effect, with the built-in order each replaces, under `[WebJSON] Route updates`.
