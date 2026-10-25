# keyless-routes.json

API-Key-Free (web session) accounts send some reads to Reddit by more than one route, because www.reddit.com refuses them at their usual path with its 403 block page. The routes and their order are built into the tweak (`src/ApolloWebJSONRoutes.m`). `keyless-routes.json`, at the root of this repository, lets maintainers change them for every install without a release.

Installs with API-Key-Free Mode on and **Use Route Updates** on (the default) fetch it from `main` while the app is open: on foreground and every 15 minutes, as a conditional request. A change reaches an install within about 15 minutes of its next foreground.

## Routes

| Name | Sends the request to |
|---|---|
| `www` | `www.reddit.com`, path unchanged |
| `www-dotjson` | `www.reddit.com/api/<endpoint>/.json` |
| `old` | `old.reddit.com`, path unchanged |
| `api` | `api.reddit.com`, path unchanged |

These are the only routes. The file names them; it can't give a host or URL. `api` isn't in the built-in table: as of 2026-10-24 it refused both built-in endpoints for the cookie, and it's there so the file can use it again if Reddit reopens it. For `/api/info` alone, `www.reddit.com/r/all/api/info.json` also answered the cookie then; it isn't a route, but it's the next one to add if the others close.

## Format

```json
{
  "version": 1,
  "endpoints": {
    "GET /api/info": { "routes": ["old", "www-dotjson"] },
    "POST /api/morechildren": { "routes": ["www-dotjson"] },
    "GET /api/foo": { "routes": ["www-dotjson"] }
  }
}
```

Each key is `<METHOD> /api/<name>`, and `routes` lists 1 to 4 route names to try in order. A request goes by the first route that isn't cooling down for that account, and a block page sends it again by the next one.

- **Built-in endpoints** (`GET /api/info`, `GET` and `POST /api/morechildren`) take any order or subset of the four routes.
- **Other endpoints** can be added as a `GET` only, on exactly `/api/<name>`, with any of the four routes. Feeds and comment threads can't be added, so the file can't move general browsing to another route.
- Writes can't be added, and are never resent.

The app leaves out any entry that breaks these rules and logs why. A file it can't read (not JSON, over 16 KB, more than 32 endpoints, `version` not `1`) is ignored whole, and the app keeps the routes it was using. `"endpoints": {}` means the built-in routes everywhere.

## Changing a route

Review the route as well as the JSON. Reddit is limiting `old.reddit.com` to accounts with recent Old Reddit use, so list `old` only where the other routes are blocked, and after them unless they're blocked for everyone.

1. Check the new route works for an API-Key-Free session before listing it. In a simulator build, the debug bridge's `routeblock <route>` makes a route get Reddit's real block page, `routehealth` prints which routes answered, and `APOLLO_KEYLESS_ROUTES_URL` (passed as `SIMCTL_CHILD_APOLLO_KEYLESS_ROUTES_URL`, `file://` allowed) points the app at a local copy of this file.
2. Edit the file on `main`. Keep it valid JSON; a rejected file changes nothing.
3. To undo every override, set `"endpoints": {}` or delete the file. Installs drop their overrides on the next check.

The app logs the overrides in effect, with the built-in order each replaces, under `[WebJSON] Route updates`.
