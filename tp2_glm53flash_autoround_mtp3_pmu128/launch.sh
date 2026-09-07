#!/usr/bin/env bash
set -euo pipefail

# GLM-5.3-Flash W4A16-AutoRound (GPTQ-adapted) native MTP3 + PMU128 on the
# two-node GB10 pair: rank 0 = API head (fabric 10.0.7.1), rank 1 = headless
# worker (fabric 10.0.7.2). Patches and the SM121 kpool overlay are baked into
# the pinned image, so no patch bind mounts are used. Start rank 1 FIRST,
# wait ~20 s, then rank 0. Docker restart policy is manual (--restart no).

RANK="${1:?usage: launch.sh <0|1>}"; [[ "$RANK" == 0 || "$RANK" == 1 ]]

IMAGE="${IMAGE:-spark-recipes/glm53-autoround-mtp3-pmu128:20260903}"
NAME="${NAME:-spark_glm53_autoround_mtp3_pmu128}"
MODEL_HOST="${MODEL_HOST:-/home/ubuntu/models/Intel-GLM-5.3-Flash-W4A16-AutoRound-5eee1846-gptq}"
MODEL="${MODEL:-/models/intel-glm53-gptq}"
CACHE_HOST="${CACHE_HOST:-/home/ubuntu/.cache/intel-glm53-vllm}"
HEAD="${HEAD:-10.0.7.1}"
MPORT="${MPORT:-29531}"
PORT="${PORT:-8888}"

if [[ "$RANK" == 0 ]]; then HOST_IP=10.0.7.1; HEADLESS=(); else HOST_IP=10.0.7.2; HEADLESS=(--headless); fi

test -f "$MODEL_HOST/config.json"
docker image inspect "$IMAGE" >/dev/null
mkdir -p "$CACHE_HOST"
docker rm -f "$NAME" >/dev/null 2>&1 || true

exec docker run --gpus all -d --name "$NAME" --restart no --network host --ipc host --shm-size 32g --ulimit memlock=-1:-1 --cap-add IPC_LOCK --device /dev/infiniband:/dev/infiniband \
 -v "$MODEL_HOST:$MODEL:ro" \
 -v "$CACHE_HOST:/cache" \
 -e VLLM_HOST_IP="$HOST_IP" -e HF_HOME=/cache/huggingface -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
 -e VLLM_ENGINE_READY_TIMEOUT_S=3600 -e VLLM_PREFIX_CACHE_RETENTION_INTERVAL=0 -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
 -e TORCH_CUDA_ARCH_LIST=12.1a -e FLASHINFER_CUDA_ARCH_LIST=12.1a -e FLASHINFER_DISABLE_VERSION_CHECK=1 \
 -e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA=rocep1s0f0 -e NCCL_IB_GID_INDEX=3 -e NCCL_IB_ROCE_VERSION_NUM=2 -e NCCL_IB_ADDR_FAMILY=AF_INET -e NCCL_IB_ADDR_RANGE=10.0.7.0/30 \
 -e NCCL_SOCKET_IFNAME=enp1s0f0np0 -e GLOO_SOCKET_IFNAME=enp1s0f0np0 -e TP_SOCKET_IFNAME=enp1s0f0np0 -e MN_IF_NAME=enp1s0f0np0 \
 -e NCCL_NVLS_ENABLE=0 -e NCCL_CROSS_NIC=0 -e NCCL_IB_MERGE_NICS=0 -e NCCL_CUMEM_ENABLE=0 -e NCCL_IGNORE_CPU_AFFINITY=1 -e NCCL_DEBUG=WARN -e TORCH_NCCL_ASYNC_ERROR_HANDLING=1 \
 "$IMAGE" "$MODEL" --served-model-name Intel/GLM-5.3-Flash-W4A16-AutoRound --host 0.0.0.0 --port "$PORT" --trust-remote-code \
 --tensor-parallel-size 2 --distributed-executor-backend mp --nnodes 2 --node-rank "$RANK" --master-addr "$HEAD" --master-port "$MPORT" \
 --gpu-memory-utilization 0.85 --max-model-len 1048576 --max-num-seqs 6 --block-size 2304 --moe-backend marlin \
 --enable-prefix-caching --enable-prompt-tokens-details --prefix-match-unit 128 --kv-cache-dtype fp8_e4m3 --kv-cache-memory 13500000000 --max-num-batched-tokens 8192 \
 --limit-mm-per-prompt '{"image":4,"video":0}' \
 --speculative-config '{"method":"mtp","num_speculative_tokens":3,"disable_eagle_block_drop":true}' \
 --tool-call-parser glm47 --enable-auto-tool-choice --reasoning-parser glm45 "${HEADLESS[@]}"
