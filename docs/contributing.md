# Contributing

1. Read [architecture.md](architecture.md). Decide whether your change belongs in the protocol, the runtime/router, an adapter, or a client.
2. Keep responsibilities separated:
   - Database-specific behaviour goes in adapters.
   - Policy (permissions, masking, limits) goes in the router.
   - Presentation goes in clients.
3. Protocol changes must be additive within v1: new methods and optional fields only. Update [protocol.md](protocol.md), the Dart models and `src/protocol/types.ts`.
4. Test through the protocol (`router.handleRaw` with JSON) against the real engine. Don't use fake databases.
5. Run `tool/check.sh` (or `tool/check.sh --all`) before opening a pull request. CI runs the same checks.

Style: Dart with strict analysis (`strict-casts`, `strict-inference`, `strict-raw-types`), `final class` and immutable models, no unnecessary `dynamic`. TypeScript in strict mode. The webviews build their DOM without `innerHTML`.
