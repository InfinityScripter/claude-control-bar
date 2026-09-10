# The ping receiver

One Cloudflare Worker that counts the app's anonymous daily ping. PRIVACY.md describes the
ping from the user's side; this is the other end.

## Deploy

```sh
cd tools/analytics
npx wrangler login
npx wrangler deploy
```

The project's copy runs at `https://ccb-ping.infinityscripter.workers.dev`, which is what
`AnalyticsPing.endpoint` in `Sources/Model/AnalyticsPing.swift` and PRIVACY.md name. A fork
deploys its own, then changes both together; a build with the endpoint left empty never sends
anything and shows no switch in Settings.

Do not enable Logpush or Workers Logs on this Worker: PRIVACY.md promises the receiver keeps
no request logs, and both of those are request logs.

## Count

Analytics Engine answers SQL over the API. One row per ping, so the number of rows on a day is
the number of copies alive that day:

```sh
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/analytics_engine/sql" \
  -H "Authorization: Bearer $API_TOKEN" \
  --data "SELECT toStartOfInterval(timestamp, INTERVAL '1' DAY) AS day,
                 blob4 AS channel, count() AS copies
          FROM ccb_pings
          WHERE timestamp > NOW() - INTERVAL '30' DAY
          GROUP BY day, channel ORDER BY day"
```

`blob1` is the app version, `blob2` the macOS major version, `blob3` the architecture, `blob4`
the install channel. There is nothing else in the table, by construction: the Worker writes
four blobs and a `1`, and never reads the request's address.

## Try it without deploying

```sh
cd tools/analytics && npx wrangler dev
curl -i -X POST localhost:8787/v1/ping -H 'content-type: application/json' \
  -d '{"v":1,"app":"0.13.0","os":"15","arch":"arm64","channel":"dmg"}'
```

Any response is `204 No Content`, valid ping or not.
