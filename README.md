# Evidence for sgl-project/sglang PR: mixed chunk prefill mamba checkpoint fix (#39342)

Raw GPU validation evidence for the branch `fix/gdn-mixed-chunk-track-39342`
(base `242d8a70c`, GPU-tested production commit `2b26b465`, production tree
`019ba85c`; see `SHAS.txt`). Collected 2026-09-14 on one RunPod L40 with
`Qwen/Qwen3.5-4B` at revision `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`,
Triton GDN kernels and Triton attention. Scripts: `test/manual/mixed_chunk_mamba/`
on the PR branch.

| path | content |
|---|---|
| `evidence-39342.tar.gz`, `SHA256SUMS` | every result JSON, server log (with the `[39342]` probe lines), `.meta` file and environment record from the pod, plus the applied instrumentation patch |
| `reprocessed/` | the seven mixed/reference probe pairs re-joined with the final comparator (`status` / `verdict` per pair) |
| `probe_summaries/` | per-phase probe summaries and the original comparisons as printed on the pod |
| `harness/` | the six shared-prefix harness runs (base/fix x arms A/B/C, breakable prefill graphs) |
| `env/` | versions, GPU, driver, model files |
| `cleanup/` | the dummy-server check of the launcher's process-group cleanup (nine cases) |

The per-slot fingerprint in the probe files is five scalars of the first
mamba layer's state (SSM sum, sum of squares, abs-max; conv sum, sum of
squares); equal fingerprints are strong evidence of the same computation, not
a proof of tensor equality across all layers.
