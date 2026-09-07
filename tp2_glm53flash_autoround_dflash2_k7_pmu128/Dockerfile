# External-DFlash2 k7 PMU128 image for GLM-5.3-Flash (Intel W4A16
# AutoRound checkpoint adapted to GPTQ metadata). Portable pin = this
# digest-pinned base plus the final in-container hashes enforced below.
FROM ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6

ARG VLLM_DIST=/usr/local/lib/python3.12/dist-packages

COPY apply_runtime_patches.py /tmp/spark-recipe/apply_runtime_patches.py
COPY patches/0001-vllm-53388-native-mtp-block-drop.patch \
     patches/0002-vllm-53906-coordinator-partial-hits.patch \
     patches/0003-vllm-scheduler-lcm-mamba-block-align.patch \
     patches/dflash2-pmu128-swa-fine-hits.patch \
     patches/sparse_attn_indexer_kpool_sm121.py \
     /tmp/spark-recipe/patches/

# Every changed and unchanged runtime input is SHA-gated before the first
# write. The second pass independently verifies the exact final image bytes.
RUN set -eu; \
    python3 /tmp/spark-recipe/apply_runtime_patches.py --root "$VLLM_DIST"; \
    python3 /tmp/spark-recipe/apply_runtime_patches.py --root "$VLLM_DIST" --verify-only; \
    rm -rf /tmp/spark-recipe

LABEL org.opencontainers.image.description="GLM-5.3-Flash external DFlash2 k7 PMU128 (spark-recipes)" \
      org.opencontainers.image.base.digest="sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6" \
      org.opencontainers.image.revision.vllm="487ecf187d3dfe74d2cf6119a92881dba403c219" \
      org.opencontainers.image.revision.dflash-overlay="050081dc41ce6edd4d3f15fa19dc3410ba4210e3"
