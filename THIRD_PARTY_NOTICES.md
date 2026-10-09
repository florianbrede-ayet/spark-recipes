# Third-party notices

The root Apache License 2.0 applies only to repository-authored material.
Third-party material that is bundled here retains its own copyright and license
terms. Third-party material that is only *referenced* — external source
repositories, container images and model weights — is not redistributed by this
repository and remains entirely subject to its own providers' terms; the
sections below say which is which.

## technigmaai GLM-5.3-Flash NVFP4 two-Spark deployment (referenced, not bundled)

`tp2_glm53flash_nvfp4_technigma_kv13876_b8192/` is a site overlay on
[`technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks`](https://github.com/technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks).
That repository has **no repository-wide (root) license and therefore no blanket
grant**. Selected files there do retain their own **scoped** licenses, which
cover that material only:

* `licenses/vllm-Apache-2.0.txt` — Apache-2.0, for its vLLM-derived sources.
* `files/display-kv-r28/LICENSE.AGPL-3.0` — AGPL-3.0-only, for the
  display-reserved KV allocator, which derives from
  [`coolbho3k/DeepSeek-v4.1-Flash-2x-DGX-Spark`](https://github.com/coolbho3k/DeepSeek-v4.1-Flash-2x-DGX-Spark)
  and is noted as such in upstream's own `THIRD_PARTY_NOTICES.md`.

Because nothing grants redistribution of that repository as a whole, **none of
its files are bundled here**: not the Compose files, `.env.example`,
`files/chat_template.jinja`, the display-KV allocator, the helper scripts, the
image build recipes or the documentation. The recipe binds the project by commit
(`74b42ffd9ef58ee80781db98c17aecfbdfccd6d5`) and by SHA-256 of each file it
uses, and the operator clones it directly from upstream. Copyright in that
project remains with its authors; all credit for the image, the Compose
topology, the display-KV override and the R28 qualification work is theirs.

The file-scoped terms above are respected by reference, not by relicensing: the
Apache-2.0 and AGPL-3.0-only files exist in the container image and in the
operator's own checkout, **not** in this repository, and their obligations
attach where those files are actually distributed.

The container image
`technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks@sha256:1169f797539454e3c286557d49fddd488488957d9a3f10638b01052998370622`
is referenced by digest and not redistributed. It bundles, among others, the
[local-inference-lab](https://huggingface.co/local-inference-lab) vLLM fork and
B12X, upstream [vLLM](https://github.com/vllm-project/vllm) (Apache-2.0), NVIDIA
CUDA and container components, FlashInfer, InstantTensor, LMCache, Triton,
PyTorch, transformers, safetensors and xgrammar. Each keeps its own license and
terms, which apply when you pull and run the image.

The model `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` at revision
`a608241037e4c2565356bff7ca293f2133888f88` is referenced by revision only. No
weights are distributed here and no license for them is granted by this
repository; review the model repository's own license and terms before
downloading or redistributing the checkpoint.

## Inco AI DFlash 2 configuration fixture

`tp2_glm53flash_autoround_dflash2_k7_pmu128/tests/fixtures/dflash2-config.json`
is an unmodified copy of `config.json` from
[`incoai/GLM-5.3-Flash-DFlash2`](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2)
at revision `bf582e4eacc1810f76656d1811693ff6c6737d2a`, authored and published by
Inco AI. Its SHA-256 is
`c4aeac0101196a6e26705b34c45230bcd0c7c68ee2d2d1efdb242087f3712573`.

The source model repository identifies its license as
[Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International
(CC BY-NC-ND 4.0)](https://creativecommons.org/licenses/by-nc-nd/4.0/), for
research and evaluation. This repository does not distribute the model
weights. No changes were made to the bundled configuration fixture.

The vLLM-derived source fixtures and overlays carrying inline
`SPDX-License-Identifier: Apache-2.0` and copyright notices remain subject to
those notices and the Apache License 2.0.

## MiaAI-Lab TensorFold recipe and the PR #78 spill tier (bundled as a patch, Apache-2.0)

`tp2_glm53flash_exl3_tensorfold_v18_spill_c8/recipe-v1.8-spill.patch` is a diff
against [`MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold`](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold)
at commit `33b50fde06fd7ea604cbc6a663880068ab1e2ee4`. That repository is
licensed under the Apache License 2.0.

The diff modifies these upstream files:

* `README.md`, `CHANGELOG.md`, `CREDITS.md`, `NOTICE`;
* `start.sh`, `stop.sh`, `scripts/config.sh`;
* `tools/pool_room_check.py`, `tools/test_queued_cancellation.py`.

It also adds new files, among them `patches/0084-glm-spill-tier.patch`. That
patch ports the spill tier from upstream pull request #78 by wojo (also proposed
to TensorFold as ashhart/TensorFold#427) onto recipe v1.8. At image build time it
modifies [TensorFold](https://github.com/ashhart/TensorFold) v0.6.0 sources
(Apache-2.0).

The diff itself marks every file it changes. Upstream's `NOTICE` is retained and
extended, and copyright remains with the respective authors.

The checkpoint `Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold` and the drafter
`incoai/GLM-5.3-Flash-DFlash2` (CC BY-NC-ND 4.0) are referenced by revision only
and not redistributed.

## MiaAI-Lab TensorFold recipe v1.10 (referenced, not bundled)

`tp2_glm53flash_exl3_tensorfold_v110_c8/` only references
[`MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold`](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold)
at commit `7d42f905388a8d7fa91e2dc9458e0a4a68001540` (Apache-2.0) and its
published container image by digest. No files from that repository or the image
are bundled; the directory holds only our settings, a validator and checksums.
The checkpoint and the DFlash2 drafter (CC BY-NC-ND 4.0) are referenced by
revision only.
