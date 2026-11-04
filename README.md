# KoPass A2A card check

`aio2404/a2a-card-check` is a dependency-free GitHub Action that asks the public [KoPass](https://kopass.app) validator to check an A2A agent card. It adds each result to the GitHub job summary, emits one annotation per KoPass finding, and exposes the validation result as step outputs.

## Use it in a workflow

```yaml
name: Check my A2A card

on: [push]

jobs:
  a2a-card:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - id: a2a
        uses: aio2404/a2a-card-check@v1
        with:
          url: https://example.com/.well-known/agent-card.json
          fail-on: warning
```

The action sends the supplied URL to `POST https://kopass.app/api/v1/web/a2a/validator` with the `en` locale. See the [KoPass A2A conformance method](https://kopass.app/a2a/conformance) for what is measured.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `url` | Yes | — | URL of an A2A agent or agent card. |
| `fail-on` | No | `error` | `error` fails when the card is invalid or unreachable; `warning` also fails for warning findings; `never` does not fail for validation findings. API and network failures always fail because no result is available. |
| `api-url` | No | `https://kopass.app` | Base URL of the KoPass API, useful for controlled test environments. |

## Outputs

| Output | Description |
| --- | --- |
| `grade` | KoPass grade returned by the validator. |
| `valid` | `true` when the validator considers the card valid. |
| `reachable` | `true` when KoPass could reach the card. |
| `report-url` | The KoPass agent page when the agent is known; otherwise the pre-filled KoPass validator URL. |

## What the job summary contains

The GitHub Actions job summary shows the grade, `valid` and `reachable` values, discovered protocol versions, and a Markdown table of findings. It also includes a clickable KoPass badge and report link, followed by the KoPass attribution line. This is a text description of the generated summary; no screenshot is included here.

## Rate limit

The public endpoint allows 10 reads per IP address every five minutes. If KoPass returns HTTP 429, the action waits for the supplied `Retry-After` value (at most 60 seconds) and retries once. Network errors and 5xx responses are retried once; 422 responses, exhausted limits, and unavailable responses fail clearly without fabricated findings.

## Display the badge

KoPass badges are based on the agent `origin`, encoded as unpadded base64url. For example, once your agent origin is known, create the token locally:

```bash
printf '%s' 'https://example.com' | base64 | tr '+/' '-_' | tr -d '=\n'
```

Then use it in Markdown (replace `<token>`):

```markdown
[![KoPass A2A card](https://kopass.app/a2a/badge/<token>.svg)](https://kopass.app/a2a/validator)
```

When KoPass returns an origin, the action adds the exact badge and best available report link to the job summary. Without an origin, it keeps the report link and explicitly omits the unsupported badge.
