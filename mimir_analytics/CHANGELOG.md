# Changelog

## Unreleased

Session ingest preserves unknown usage and cost as null and retains cache counts,
input-token basis, coverage and in-flight state. Parity cost totals remain null
when an included attempt has unknown cost. Existing databases gain nullable
columns; zeros previously synthesized during ingest require re-ingesting retained
source records to recover unknown values.

Dependency-direction tests guard the declared dependency sets and module references in `lib/`.

First public release.
