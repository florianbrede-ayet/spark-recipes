"""Load the recipe-reconstructed vLLM core with tiny dependency stubs.

The tests execute the exact final manager/coordinator/hash utilities produced
from the bundled base fixture and patch stack. The exact block pool and other
small supporting sources are bundled fixtures. Only unrelated package
surfaces (logging, config containers, events, and KV spec dataclasses) are
stubbed, so the suite stays CPU-only and needs no installed vLLM or torch.
"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import sys
import types
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, ClassVar

ROOT = Path(
    os.environ.get(
        "DFLASH2_RECIPE_ROOT",
        Path(__file__).resolve().parents[1],
    )
).resolve()
FIXTURE_ROOT = ROOT / "tests" / "fixtures"
RUNTIME_ROOT = Path(
    os.environ.get(
        "DFLASH2_RUNTIME_ROOT",
        ROOT / ".runtime-fixture-must-be-reconstructed-by-tests-run-sh",
    )
).resolve()


def _package(name: str) -> types.ModuleType:
    module = types.ModuleType(name)
    module.__path__ = []  # type: ignore[attr-defined]
    sys.modules[name] = module
    if "." in name:
        parent_name, child = name.rsplit(".", 1)
        parent = sys.modules.get(parent_name) or _package(parent_name)
        setattr(parent, child, module)
    return module


def _module(name: str, **attrs: Any) -> types.ModuleType:
    module = types.ModuleType(name)
    for key, value in attrs.items():
        setattr(module, key, value)
    sys.modules[name] = module
    if "." in name:
        parent_name, child = name.rsplit(".", 1)
        parent = sys.modules.get(parent_name) or _package(parent_name)
        setattr(parent, child, module)
    return module


class _Logger:
    def debug(self, *args: Any, **kwargs: Any) -> None:
        pass

    info = debug
    warning = debug
    warning_once = debug


def cdiv(a: int, b: int) -> int:
    return -(a // -b)


def round_up(a: int, b: int) -> int:
    return cdiv(a, b) * b


@dataclass(frozen=True, kw_only=True)
class KVCacheSpec:
    block_size: int
    participates_in_prefix_caching: bool = True

    @property
    def page_size_bytes(self) -> int:
        return self.block_size


@dataclass(frozen=True, kw_only=True)
class AttentionSpec(KVCacheSpec):
    pass


@dataclass(frozen=True, kw_only=True)
class FullAttentionSpec(AttentionSpec):
    sliding_window: int | None = None


@dataclass(frozen=True, kw_only=True)
class TQFullAttentionSpec(FullAttentionSpec):
    pass


@dataclass(frozen=True, kw_only=True)
class MLAAttentionSpec(FullAttentionSpec):
    pass


@dataclass(frozen=True, kw_only=True)
class RSWASpec(FullAttentionSpec):
    rswa_window: int = 0


@dataclass(frozen=True, kw_only=True)
class SinkFullAttentionSpec(FullAttentionSpec):
    sink_len: int | None = None


@dataclass(frozen=True, kw_only=True)
class HiddenStateCacheSpec(FullAttentionSpec):
    pass


@dataclass(frozen=True, kw_only=True)
class SlidingWindowSpec(AttentionSpec):
    sliding_window: int

    def max_admission_blocks_per_request(
        self, max_in_flight_tokens: int, max_model_len: int
    ) -> int:
        tokens = min(self.sliding_window - 1 + max_in_flight_tokens, max_model_len)
        return cdiv(tokens, self.block_size) + 1


@dataclass(frozen=True, kw_only=True)
class SlidingWindowMLASpec(SlidingWindowSpec):
    pass


@dataclass(frozen=True, kw_only=True)
class KpoolTailSpec(SlidingWindowSpec):
    participates_in_prefix_caching: bool = False


@dataclass(frozen=True, kw_only=True)
class ChunkedLocalAttentionSpec(AttentionSpec):
    attention_chunk_size: int

    def max_admission_blocks_per_request(
        self, max_in_flight_tokens: int, max_model_len: int
    ) -> int:
        return cdiv(
            min(self.attention_chunk_size + max_in_flight_tokens, max_model_len),
            self.block_size,
        )


@dataclass(frozen=True, kw_only=True)
class CrossAttentionSpec(AttentionSpec):
    pass


@dataclass(frozen=True, kw_only=True)
class MambaSpec(KVCacheSpec):
    mamba_cache_mode: str = "align"
    num_speculative_blocks: int = 0


@dataclass(frozen=True, kw_only=True)
class UniformTypeKVCacheSpecs(KVCacheSpec):
    kv_cache_specs: dict[str, KVCacheSpec] = field(default_factory=dict)


@dataclass
class KVCacheGroupSpec:
    kv_cache_spec: KVCacheSpec
    is_eagle_group: bool = False


@dataclass
class KVCacheTensor:
    size: int = 0


@dataclass
class KVCacheConfig:
    num_blocks: int
    kv_cache_groups: list[KVCacheGroupSpec]
    kv_cache_tensors: list[KVCacheTensor] = field(default_factory=list)
    needs_kv_cache_zeroing: bool = False


class KVCacheSpecRegistry:
    _mapping: ClassVar[dict[type[KVCacheSpec], type[Any]]] = {}

    @classmethod
    def register(
        cls,
        spec_cls: type[KVCacheSpec],
        manager_cls: type[Any],
        **kwargs: Any,
    ) -> None:
        del kwargs
        cls._mapping[spec_cls] = manager_cls

    @classmethod
    def get_manager_class(cls, spec: KVCacheSpec) -> type[Any] | None:
        for candidate in type(spec).__mro__:
            if candidate in cls._mapping:
                return cls._mapping[candidate]
        return None


class Request:
    def __init__(
        self,
        request_id: str,
        tokens: list[int],
        block_hashes: list[bytes],
        *,
        num_prompt_tokens: int | None = None,
        shared_prefix_boundary: int = 0,
    ) -> None:
        self.request_id = request_id
        self.all_token_ids = tokens
        self.block_hashes = block_hashes
        self.num_prompt_tokens = (
            len(tokens) if num_prompt_tokens is None else num_prompt_tokens
        )
        self.shared_prefix_boundary = shared_prefix_boundary
        self.lora_request = None


class _Event:
    def __init__(self, **kwargs: Any) -> None:
        self.__dict__.update(kwargs)


def _load(name: str, path: Path) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    parent_name, child = name.rsplit(".", 1)
    setattr(sys.modules[parent_name], child, module)
    spec.loader.exec_module(module)
    return module


def _install_stubs() -> types.ModuleType:
    for name in (
        "vllm",
        "vllm.config",
        "vllm.distributed",
        "vllm.utils",
        "vllm.v1",
        "vllm.v1.core",
    ):
        if name not in sys.modules:
            _package(name)

    envs = _module(
        "vllm.envs",
        VLLM_PREFIX_CACHE_RETENTION_INTERVAL=0,
        VLLM_KV_EVENTS_USE_INT_BLOCK_HASHES=False,
        VLLM_USE_V1=True,
    )
    sys.modules["vllm"].envs = envs
    _module("vllm.logger", init_logger=lambda name: _Logger())
    _module("vllm.utils.math_utils", cdiv=cdiv, round_up=round_up)
    _module("vllm.utils.mem_utils", format_gib=lambda value: str(value))
    _module("vllm.utils.torch_utils", get_dtype_size=lambda dtype: 2)
    _module(
        "vllm.utils.hashing",
        sha256_cbor=lambda value: hashlib.sha256(repr(value).encode()).digest(),
        xxhash_cbor=lambda value: hashlib.sha256(repr(value).encode()).digest(),
    )
    _module("vllm.v1.utils", tensor_data=lambda value: value)
    _module("vllm.v1.request", Request=Request)
    _module(
        "vllm.distributed.kv_events",
        MEDIUM_GPU="gpu",
        AllBlocksCleared=_Event,
        BlockRemoved=_Event,
        BlockStored=_Event,
        KVCacheEvent=_Event,
    )
    _module("vllm.v1.core.kv_cache_metrics", KVCacheMetricsCollector=object)
    _module(
        "vllm.v1.kv_cache_spec_registry",
        KVCacheSpecRegistry=KVCacheSpecRegistry,
    )
    iface_attrs = {
        cls.__name__: cls
        for cls in (
            KVCacheSpec,
            AttentionSpec,
            FullAttentionSpec,
            TQFullAttentionSpec,
            MLAAttentionSpec,
            RSWASpec,
            SinkFullAttentionSpec,
            HiddenStateCacheSpec,
            SlidingWindowSpec,
            SlidingWindowMLASpec,
            KpoolTailSpec,
            ChunkedLocalAttentionSpec,
            CrossAttentionSpec,
            MambaSpec,
            UniformTypeKVCacheSpecs,
            KVCacheGroupSpec,
            KVCacheTensor,
            KVCacheConfig,
        )
    }
    _module("vllm.v1.kv_cache_interface", **iface_attrs)
    config_module = sys.modules["vllm.config"]
    config_module.VllmConfig = type("VllmConfig", (), {})
    return envs


envs = _install_stubs()
kv_utils = _load(
    "vllm.v1.core.kv_cache_utils",
    RUNTIME_ROOT / "vllm/v1/core/kv_cache_utils.py",
)
block_pool = _load(
    "vllm.v1.core.block_pool",
    RUNTIME_ROOT / "vllm/v1/core/block_pool.py",
)
manager = _load(
    "vllm.v1.core.single_type_kv_cache_manager",
    RUNTIME_ROOT / "vllm/v1/core/single_type_kv_cache_manager.py",
)

KVCacheSpecRegistry._mapping.clear()
KVCacheSpecRegistry._mapping.update(
    {
        FullAttentionSpec: manager.FullAttentionManager,
        TQFullAttentionSpec: manager.FullAttentionManager,
        MLAAttentionSpec: manager.FullAttentionManager,
        RSWASpec: manager.RSWAManager,
        SinkFullAttentionSpec: manager.SinkFullAttentionManager,
        HiddenStateCacheSpec: manager.FullAttentionManager,
        SlidingWindowSpec: manager.SlidingWindowManager,
        SlidingWindowMLASpec: manager.SlidingWindowManager,
        KpoolTailSpec: manager.KpoolTailManager,
        ChunkedLocalAttentionSpec: manager.ChunkedLocalAttentionManager,
        CrossAttentionSpec: manager.CrossAttentionManager,
        MambaSpec: manager.MambaManager,
    }
)
coordinator = _load(
    "vllm.v1.core.kv_cache_coordinator",
    RUNTIME_ROOT / "vllm/v1/core/kv_cache_coordinator.py",
)


def chained_hashes(tokens: list[int], unit: int = 128) -> list[bytes]:
    """Deterministic chained hash list with vLLM's prefix-identity property."""
    result: list[bytes] = []
    parent = b""
    for start in range(0, len(tokens) - unit + 1, unit):
        payload = b"".join(
            int(token).to_bytes(4, "big", signed=False)
            for token in tokens[start : start + unit]
        )
        parent = hashlib.sha256(parent + payload).digest()
        result.append(parent)
    return result


def make_request(
    request_id: str,
    length: int,
    *,
    tokens: list[int] | None = None,
    prompt_length: int | None = None,
    shared_prefix_boundary: int = 0,
) -> Request:
    if tokens is None:
        tokens = [i % 65521 for i in range(length)]
    assert len(tokens) >= length
    return Request(
        request_id,
        tokens,
        chained_hashes(tokens),
        num_prompt_tokens=length if prompt_length is None else prompt_length,
        shared_prefix_boundary=shared_prefix_boundary,
    )


def new_pool(num_blocks: int = 1024, hash_unit: int = 128):
    return block_pool.BlockPool(
        num_gpu_blocks=num_blocks,
        enable_caching=True,
        hash_block_size=hash_unit,
    )


def new_swa_manager(
    pool: Any,
    *,
    group_id: int = 0,
    page: int = 1152,
    window: int = 2048,
    scheduler: int = 4608,
    alignment: int = 128,
    use_eagle: bool = False,
):
    spec = SlidingWindowSpec(block_size=page, sliding_window=window)
    result = manager.SlidingWindowManager(
        spec,
        block_pool=pool,
        enable_caching=True,
        kv_cache_group_id=group_id,
        scheduler_block_size=scheduler,
        max_admission_blocks_per_request=10,
    )
    result.cache_hit_alignment_tokens = alignment
    result.use_eagle = use_eagle
    return result


def allocate_request_blocks(swa: Any, request: Request, length: int) -> list[Any]:
    blocks = swa.block_pool.get_new_blocks(cdiv(length, swa.block_size))
    swa.req_to_blocks[request.request_id].extend(blocks)
    return blocks
