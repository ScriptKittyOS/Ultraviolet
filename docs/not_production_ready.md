# What Is Still Not Production-Ready

Status: explicit non-production-ready list after DB qualification work.

What is now true:
- the default umbrella suite is green
- a controlled DB-backed qualification path exists and passes locally
- migrations run successfully against a real local PostgreSQL qualification database
- hub -> store -> read-model round trips are proven in controlled local integration tests
- bounded db-backed collab runtime startup is qualified as a runtime/startup path only
- bounded db-backed + agent-enabled runtime startup is qualified in its current limited form

What is still not production-ready:

1. Production deployment qualification
- this pass proves controlled local integration truth
- one production boot path is now measured: a `MIX_ENV=prod` release from a clean clone boots into safe mode (`:safe_no_repo`) when `HACKTUI_START_REPO=false` is set explicitly, and refuses with a message naming both choices when it is unset (slice 38, one container run)
- it does not prove production deployment behavior beyond that boot

2. Slack transport readiness
- the Slack boundary runtime is present
- full signed transport and delivery behavior is not qualified here

3. MCP serving/runtime qualification
- dispatch and tool boundaries exist
- full runtime serving behavior is not qualified here

4. Broad Jido runtime qualification
- one bounded Jido investigation flow is qualified
- broader Jido rollout is intentionally not claimed

5. Sensor transport hardening
- not qualified in this pass

6. Operational recovery maturity
- boot and recovery docs exist
- repeated, production-like recovery drills are not part of this pass

7. Release hardening beyond controlled qualification
- no production readiness claim is justified from this pass alone
