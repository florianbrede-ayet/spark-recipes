# spark-recipes

Reproducible deployment recipes for the two-node NVIDIA GB10 ("Spark")
cluster. Each top-level directory carries pinned artifacts, scripts, templates,
checksums, documentation, and an explicit inventory of any external artifacts
that cannot be redistributed.

## Recipes

| Recipe | Model | Topology | Profile |
|---|---|---|---|
| [`tp2_b12x_dsv4flash_0731_balanced/`](tp2_b12x_dsv4flash_0731_balanced/) | `deepseek-ai/DeepSeek-V4-Flash-0731` @ `7872f01b1d1fe23eabc4c98b48bffcef5a386062` | 2 nodes, tensor-parallel 2, API on rank 0 | GMU 0.87 balanced — maxseq 6, batched 4096, threshold 1024, retention 4096, DSpark k5, FP8 KV |
| [`tp2_glm53flash_autoround_mtp3_pmu128/`](tp2_glm53flash_autoround_mtp3_pmu128/) | `Intel/GLM-5.3-Flash-W4A16-AutoRound` @ `5eee1846f0321058ed73745f9aa16f2aaf0fc0a0` (GPTQ metadata adaptation) | 2 nodes, tensor-parallel 2, API on rank 0 | **Native MTP3 PMU128 (pool 1,920,956, acceptance 52.43%)** — maxseq 6, MNBT 8192, KV 13,500,000,000 B/rank, retention 0, maxlen 1,048,576, block 2304/scheduler 4608, FP8 e4m3 KV, Marlin, image on/video off |
| [`tp2_glm53flash_autoround_dflash2_k7_pmu128/`](tp2_glm53flash_autoround_dflash2_k7_pmu128/) | `Intel/GLM-5.3-Flash-W4A16-AutoRound` @ `5eee1846f0321058ed73745f9aa16f2aaf0fc0a0` + external `incoai/GLM-5.3-Flash-DFlash2` @ `bf582e4eacc1810f76656d1811693ff6c6737d2a` | 2 nodes, tensor-parallel 2, API on rank 0 | **External DFlash2 k7 + PMU128 (pool 1,814,557)** — maxseq 6, MNBT 8192, KV 13,500,000,000 B/rank, retention 0, maxlen 1,048,576, block 2304/scheduler 4608, FP8 e4m3 KV, Marlin; accepted 4,608-aligned producer cache-miss limitation documented and regression-pinned |

## Conventions

Full reproduction bundles follow this shape. Concise as-deployed profiles may instead carry only a README, an exact archival launcher, and a focused validator when the heavyweight artifacts are deliberately not redistributed:

```
<recipe>/
  README.md                  entry point: pins, quick start, doc index
  MANIFEST.md                file-by-file inventory and provenance
  SHA256SUMS                 checksums for the canonical artifacts
  config/                    pinned artifacts + example site config
  docs/                      as-deployed, network, prerequisites, profile,
                             capacity, benchmarks, runbook, rank differences
  recipe/                    canonical recipe YAML and canonical argv references
  scripts/                   numbered lifecycle scripts + validate.sh
  templates/                 in-container launch template
  mods/                      slot for vendor patch bundles (not vendored)
```

Shared ground rules:

* **Dry-run by default.** Anything that changes the network, a service or Docker
  requires an explicit `--apply` *and* an interactive confirmation.
* **Content-addressed pins.** Image IDs, image digests, model revisions and
  artifact hashes are recorded and enforced. Scripts fail on a mismatch rather
  than rewriting the pin.
* **No secrets, ever.** Credentials are placeholders in `*.example` files.
  `scripts/validate.sh` runs a secret scan and a placeholder audit.
* **No bulk artifacts.** No weights, image layers, caches, logs or raw machine
  identifiers.

## Validating a recipe

```bash
cd <recipe> && scripts/validate.sh
```

Runs offline, needs no cluster and no credentials: bash syntax and lint, required
files and cross-references, `SHA256SUMS` verification, canonical-argv render
check, placeholder audit and secret scan.

## License

Repository-authored code and documentation are provided under the
[Apache License 2.0](LICENSE). Vendored, adapted, or excerpted third-party
material retains its original copyright notices and license terms; the root
license does not replace those terms; see [Third-party notices](THIRD_PARTY_NOTICES.md).
External models, container images, and other artifacts referenced but not
distributed here remain subject to their respective providers' licenses and
terms.
