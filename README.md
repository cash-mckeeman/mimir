# Mimir libraries

| Package | On Hex | Runtime dependencies | Optional |
|---|---|---|---|
| `mimir` | 0.7.0 | req, jason, telemetry | — |
| `mimir_workflows` | 0.7.0 | telemetry | — |
| `mimir_orchestration` | 0.7.0 | mimir, mimir_workflows, jason, telemetry | jido, req_llm, req_managed_agents (tested range) |
| `mimir_analytics` | not yet | duckdbex, jason, req | — |

Minor releases share a version across packages. Patch releases may update one package.

The `mimir` package has no runtime dependency on an agent runtime or LLM client library. The table shows each package’s dependency footprint.
