# Native-MTP3 PMU128 service image for GLM-5.3-Flash (Intel W4A16-AutoRound
# checkpoint adapted to GPTQ metadata). Portable pin = digest-pinned base
# inputs plus the final in-container file hashes enforced below; node-local
# image IDs are not part of the pin.
FROM ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6

ARG VLLM_DIST=/usr/local/lib/python3.12/dist-packages

COPY apply_runtime_patches.py /tmp/spark-recipe/apply_runtime_patches.py
COPY patches/0001-vllm-53388-native-mtp-block-drop.patch \
     patches/0002-vllm-53906-coordinator-partial-hits.patch \
     patches/0003-vllm-scheduler-lcm-mamba-block-align.patch \
     patches/sparse_attn_indexer_kpool_sm121.py \
     /tmp/spark-recipe/patches/

# Fail-closed patch application (exact before/after SHA gates + syntax check
# of every patched file), then an independent second verification pass.
RUN set -eu; \
    python3 /tmp/spark-recipe/apply_runtime_patches.py --root "$VLLM_DIST"; \
    python3 /tmp/spark-recipe/apply_runtime_patches.py --root "$VLLM_DIST" --verify-only; \
    rm -rf /tmp/spark-recipe

LABEL org.opencontainers.image.description="GLM-5.3-Flash native MTP3 PMU128 (spark-recipes)" \
      org.opencontainers.image.base.digest="sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6"
