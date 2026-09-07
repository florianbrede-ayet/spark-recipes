# Mods — and why an exact launch is currently impossible

The recipe declares exactly two mods, in this order:

```yaml
mods:
  - mods/instanttensor-hybrid-draft-loader
  - mods/dsv4-reasoning-effort-fix
```

**Neither is vendored here, and neither can be certified.** They are
vendor-framework patch bundles. The read-only audit evidence records that they
were *applied*, but not their *contents*, so no trustworthy digest for either
one exists anywhere in this bundle.

`config/mods-pins.env` therefore carries the literal token `UNAVAILABLE` for
both digests. That is a statement about the evidence, not a placeholder to fill
in casually.

## What that means in practice

**`scripts/40-start.sh` fails closed.** An exact launch requires every declared
mod to be supplied, pinned, and matching its digest in `config/mods-pins.env`.
While any digest is `UNAVAILABLE`, that is unachievable and the script refuses
to start rather than quietly launching something it cannot vouch for.

A launch is still possible, but only as an explicitly non-exact one:

```bash
scripts/40-start.sh --apply --non-exact-mods
```

which demands a second typed confirmation and then stamps
`/workspace/MODS_NON_EXACT` into **both** containers. From that moment,
`scripts/60-verify-deployment.sh` reads the marker and reports **NON-EXACT**,
and exact verification fails. There is no way to launch non-exactly and later
have the deployment described as a restoration of the audited one.

## What they did

* **`instanttensor-hybrid-draft-loader`** — lets the DSpark speculative draft
  model load from lazy safetensors while the target model keeps the
  InstantTensor fast path. The audited startup log confirms it was active:

  > `Hybrid draft loading: using lazy safetensors for speculative draft weights
  > while preserving InstantTensor for the target model
  > (INSTANTTENSOR_DRAFT_LOADER=auto).`

* **`dsv4-reasoning-effort-fix`** — corrects handling of
  `--default-chat-template-kwargs.reasoning_effort=high` for DeepSeek V4.

Without them, draft-weight loading and `reasoning_effort` behaviour may differ
from the audited deployment even though the Docker and vLLM invocations are
byte-identical (which `scripts/30-render.sh --check` proves independently).

## Supplying and pinning your own

Only the two declared names are accepted. Any other directory under `mods/`, and
any executable file dropped directly into `mods/`, is rejected by
`assert_no_foreign_mods()` before anything is applied — in every mode, exact or
not.

```
mods/
  instanttensor-hybrid-draft-loader/
    run.sh
    MOD.sha256          <- written by scripts/25-pin-mods.sh
    ...
  dsv4-reasoning-effort-fix/
    run.sh
    MOD.sha256
    ...
```

### The manifest mechanism

`MOD.sha256` is the mod's canonical manifest: the SHA-256 of every file in the
directory except the manifest itself, relative paths, byte-sorted
(`LC_ALL=C`). The mod's single **content digest** is the SHA-256 of that
manifest. It is deterministic across machines and independent of timestamps and
of the order `find` happens to walk the tree.

```bash
scripts/25-pin-mods.sh                 # report state, write nothing
scripts/25-pin-mods.sh --apply         # write MOD.sha256 into each supplied mod
```

`--apply` prints the resulting digests as ready-to-paste lines:

```
PIN_MOD_DIGEST_INSTANTTENSOR_HYBRID_DRAFT_LOADER="…"
PIN_MOD_DIGEST_DSV4_REASONING_EFFORT_FIX="…"
```

**Copying those into `config/mods-pins.env` is deliberately a manual step.**
The script will not do it for you, because that edit is the moment a human
asserts "these bytes are the audited ones". Pasting a digest for a directory you
cannot independently confirm converts an honest *unknown* into a false claim of
exactness, and every downstream verification would then agree with the lie.

### Certification states

| State | Meaning |
|---|---|
| `EXACT` | Every declared mod supplied, manifest matches contents, digest matches the pin. |
| `NOT SUPPLIED` | The directory is absent. |
| `NOT PINNED` | Supplied but has no `MOD.sha256`. |
| `TAMPERED` | Contents no longer match the mod's own `MOD.sha256`. |
| `UNPINNABLE` | Pinned digest is `UNAVAILABLE` — today's state for both mods. |
| `MISMATCH` | Supplied digest differs from the pin. |

Anything other than `EXACT` for all declared mods means the launch can only
proceed as `NON-EXACT`.

## What is not covered

Mods you add are third-party content: they are excluded from `SHA256SUMS` and
from version control, and `scripts/validate.sh` does not inspect them. Their
contents — including making sure they contain no credentials — remain your
responsibility.

## How verification sees all this

`scripts/60-verify-deployment.sh` reads the marker file from inside each
container, on both ranks, and:

* `MODS_EXACT` present → certification `EXACT`;
* `MODS_NON_EXACT` present → certification `NON-EXACT`, and the check fails;
* neither present → `UNCERTIFIED`, and the check fails, because the container
  was not started by `scripts/40-start.sh` and nothing is known about its mods;
* the two ranks disagreeing → a failure in its own right.

`--allow-non-exact` downgrades only that failure to a warning. The report still
says NON-EXACT. Nothing in this bundle will ever call such a deployment exact.
