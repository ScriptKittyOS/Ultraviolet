# Runtime Modes Matrix

Status: current verified runtime matrix.

| Mode | Required env/config | Starts Repo | Starts collab runtime | Starts agent runtime | Starts Jido instance | Intended use | Qualification status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Safe no-repo mode | default settings | No | No | No | No | local development, compile/test, architecture work | verified by default suite |
| Production safe mode (release) | `MIX_ENV=prod` release, `HACKTUI_START_REPO=false` and `HACKTUI_MARKING` set explicitly, no `HACKTUI_DB_*` needed | No | No | No | No | a clean-clone release booting with no database; `HacktuiStore.Health.status/0` reports `:safe_no_repo` | verified in one container run |
| Production, variable absent (release) | `MIX_ENV=prod` release, `HACKTUI_START_REPO` or `HACKTUI_MARKING` unset | refuses to boot | — | — | — | the refusal names the variable and its valid choices; absence is not a posture | verified in one container run |
| DB-backed mode | `source .env`, `HACKTUI_START_REPO=true` | Yes | No | No | No | persistence integration and local DB-backed runtime work | verified in controlled local qualification |
| Collaboration-enabled mode | `HACKTUI_COLLAB_PROVIDERS=slack` | Optional | Yes | No | No | exercising collab boundary startup and Slack routing/renderer code | runtime-gated only; not full transport-qualified |
| Agent-enabled mode | `HACKTUI_AGENT_BACKENDS=jido` | Optional | No | Yes | Yes | bounded Jido workflow execution and agent boundary startup | verified for bounded investigation flow |
| DB-backed + hub mode | `source .env`, `HACKTUI_START_REPO=true` | Yes | No | No | No | hub/store round-trip qualification | verified in controlled local qualification |
| DB-backed + agent-enabled mode | `source .env`, `HACKTUI_START_REPO=true`, `HACKTUI_AGENT_BACKENDS=jido` | Yes | No | Yes | Yes | bounded DB-backed agent runtime smoke | verified in controlled local smoke qualification |
| DB-backed + collab mode | `source .env`, `HACKTUI_START_REPO=true`, `HACKTUI_COLLAB_PROVIDERS=slack` | Yes | Yes | No | No | future collaboration qualification | not qualified in this pass |

`HACKTUI_MARKING` is a classification banner (`U`, `S//NOFORN`, `TS//SI/NOFORN`) that every
record inherits when its observation carries none; outside production it defaults to `U`. The
runtime runs at system-high within one enclave and feeds a cross-domain solution: the marking
is carried, never enforced, and this is not an accredited multi-level system.
