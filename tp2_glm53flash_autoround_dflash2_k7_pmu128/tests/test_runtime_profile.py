from __future__ import annotations

import ast
import hashlib
import json
import math
import types
import unittest

import exact_image_harness as h

P = 1152
H = 128
W = 2048
S = 4608


class ExactRuntimeProfileTests(unittest.TestCase):
    def _publish(
        self,
        manager,
        request,
        length: int,
        *,
        retention: int | None = 0,
    ):
        blocks = h.allocate_request_blocks(manager, request, length)
        manager.cache_blocks(request, length, retention_interval=retention)
        return blocks

    def _find(self, manager, request, maximum: int, *, drop: bool = False):
        return manager.find_longest_cache_hit(
            block_hashes=request.block_hashes,
            max_length=maximum,
            kv_cache_group_ids=[manager.kv_cache_group_id],
            block_pool=manager.block_pool,
            kv_cache_spec=manager.kv_cache_spec,
            drop_eagle_block=drop,
            alignment_tokens=manager.cache_hit_alignment_tokens,
        )

    def _assert_exact_window(self, pool, blocks, hit: int) -> None:
        first = max(0, hit - (W - 1)) // P
        end = h.cdiv(hit, P)
        self.assertEqual(len(blocks), end)
        for index, block in enumerate(blocks):
            if index < first:
                self.assertIs(block, pool.null_block)
            else:
                self.assertIsNot(block, pool.null_block)

    def _target_coordinator(self, *, use_eagle: bool = False):
        specs = [
            h.FullAttentionSpec(block_size=S),
            h.KpoolTailSpec(block_size=4, sliding_window=4),
            h.MambaSpec(
                block_size=S,
                mamba_cache_mode="align",
                num_speculative_blocks=0,
            ),
            h.SlidingWindowSpec(block_size=P, sliding_window=W),
        ]
        config = h.KVCacheConfig(
            num_blocks=4096,
            kv_cache_groups=[
                h.KVCacheGroupSpec(spec, is_eagle_group=(use_eagle and index == 3))
                for index, spec in enumerate(specs)
            ],
        )
        return h.coordinator.HybridKVCacheCoordinator(
            config,
            max_model_len=1_048_576,
            max_in_flight_tokens=8192,
            use_eagle=use_eagle,
            enable_caching=True,
            enable_kv_cache_events=False,
            dcp_world_size=1,
            pcp_world_size=1,
            scheduler_block_size=S,
            hash_block_size=H,
        )

    @staticmethod
    def _scheduler_split_function():
        """Extract the installed scheduler function without importing vLLM."""
        source = (
            h.RUNTIME_ROOT / "vllm/v1/core/sched/scheduler.py"
        ).read_text(encoding="utf-8")
        tree = ast.parse(source)
        function = next(
            node
            for owner in tree.body
            if isinstance(owner, ast.ClassDef) and owner.name == "Scheduler"
            for node in owner.body
            if isinstance(node, ast.FunctionDef)
            and node.name == "_mamba_block_aligned_split"
        )
        function.decorator_list = []
        for args in (
            function.args.posonlyargs,
            function.args.args,
            function.args.kwonlyargs,
        ):
            for arg in args:
                arg.annotation = None
        function.returns = None
        module = ast.fix_missing_locations(ast.Module(body=[function], type_ignores=[]))
        namespace = {}
        exec(compile(module, "exact-scheduler-extract", "exec"), namespace)
        return namespace[function.name]

    def _full_hybrid_scheduler_replay(self, prompt: int):
        """Materialize exact scheduler stops, then run hybrid reconciliation."""
        coord = self._target_coordinator()
        shared = prompt - 1
        producer_tokens = [51000] + [
            1000 + ((index * 31) % 97) for index in range(1, shared)
        ] + [60001]
        producer = h.make_request(
            "aligned-producer", prompt, tokens=producer_tokens, prompt_length=prompt
        )
        producer.num_computed_tokens = 0
        producer.num_tokens = prompt
        scheduler = types.SimpleNamespace(
            block_size=S,
            max_num_scheduled_tokens=8192,
            scheduler_config=types.SimpleNamespace(long_prefill_token_threshold=0),
            use_eagle_block_drop=False,
            hash_block_size=H,
            mamba_partial_cache_hit=True,
        )
        split = self._scheduler_split_function()
        chunk_ends = []
        while producer.num_computed_tokens < prompt:
            offered = min(8192, prompt - producer.num_computed_tokens)
            scheduled = split(scheduler, producer, offered)
            self.assertGreater(scheduled, 0)
            end = producer.num_computed_tokens + scheduled
            chunk_ends.append(end)
            for group_id, cache_manager in enumerate(coord.single_type_managers):
                if group_id == 1:  # kpool is intentionally non-cacheable.
                    continue
                needed = h.cdiv(end, cache_manager.block_size) - len(
                    cache_manager.req_to_blocks[producer.request_id]
                )
                if needed > 0:
                    cache_manager.req_to_blocks[producer.request_id].extend(
                        coord.block_pool.get_new_blocks(needed)
                    )
            coord.cache_blocks(producer, end)
            coord.new_step_starts()
            producer.num_computed_tokens = end

        coord.free(producer.request_id)
        coord.new_step_starts()
        consumer = h.make_request(
            "aligned-consumer",
            prompt,
            tokens=producer_tokens[:-1] + [60002],
            prompt_length=prompt,
        )
        _, per_group_hits = coord.find_longest_cache_hit_per_group(
            consumer.block_hashes, shared
        )
        _, common_hit, _ = coord.find_longest_cache_hit(
            consumer.block_hashes, shared
        )
        return chunk_ends, per_group_hits, common_hit

    def test_target_geometry_enables_fine_hits_and_propagates_alignment(self):
        coord = self._target_coordinator()
        self.assertTrue(coord.enable_partial_hash_hits)
        self.assertEqual(coord._cache_hit_alignment_tokens, H)
        self.assertEqual(
            [manager.cache_hit_alignment_tokens for manager in coord.single_type_managers],
            [H, H, H, H],
        )
        self.assertNotIn(1, [gid for group in coord.attention_groups for gid in group.group_ids])
        self.assertIsInstance(
            coord.single_type_managers[3], h.manager.SlidingWindowManager
        )
        self.assertEqual(
            coord.single_type_managers[3]._max_admission_blocks_per_request, 10
        )

    def test_pmu128_alignment_residues_and_former_4607_boundary(self):
        cases = {
            "aligned": (4608, 4609, 4608),
            "residue1": (4609, 4610, 4608),
            "residue127": (4735, 4736, 4608),
            "former4607": (4607, 4608, 4480),
        }
        for label, (maximum, producer_length, expected) in cases.items():
            with self.subTest(label=label):
                pool = h.new_pool(128)
                swa = h.new_swa_manager(pool)
                producer = h.make_request(label, producer_length)
                self._publish(swa, producer, producer_length)
                blocks, hit = self._find(swa, producer, maximum)
                self.assertEqual(hit, expected)
                self._assert_exact_window(pool, blocks[0], hit)

    def test_divergent_suffix_cannot_reuse_deeper_alias(self):
        length = 4992
        tokens_a = [index % 65521 for index in range(length)]
        tokens_b = tokens_a.copy()
        tokens_b[4900] += 1
        pool = h.new_pool(128)
        swa = h.new_swa_manager(pool)
        producer = h.make_request("producer-a", length, tokens=tokens_a)
        consumer = h.make_request("consumer-b", length, tokens=tokens_b)
        physical = self._publish(swa, producer, length)

        self.assertIsNone(pool.get_cached_block(consumer.block_hashes[38], [0]))
        self.assertEqual(
            pool.get_cached_block(producer.block_hashes[38], [0]), [physical[4]]
        )
        blocks, hit = self._find(swa, consumer, length)
        self.assertEqual(hit, 4864)
        self.assertIs(blocks[0][-1], physical[4])

    def test_prompt_endpoint_and_longer_continuation_alias_same_tail(self):
        producer_length = 4992
        tokens = [index % 65521 for index in range(producer_length + H)]
        pool = h.new_pool(128)
        swa = h.new_swa_manager(pool)
        producer = h.make_request(
            "producer", producer_length, tokens=tokens, prompt_length=producer_length
        )
        tail = self._publish(swa, producer, producer_length)[4]

        replay_blocks, replay_hit = self._find(swa, producer, producer_length - 1)
        continuation = h.make_request(
            "continuation", producer_length + H, tokens=tokens
        )
        continuation_blocks, continuation_hit = self._find(
            swa, continuation, producer_length
        )
        self.assertEqual((replay_hit, continuation_hit), (4864, 4992))
        self.assertIs(replay_blocks[0][-1], tail)
        self.assertIs(continuation_blocks[0][-1], tail)
        self.assertEqual(tail.block_hash_num_tokens, 4992)
        alias = h.kv_utils.make_block_hash_with_group_id(
            producer.block_hashes[4864 // H - 1], 0
        )
        self.assertIn(alias, pool.cached_block_hashes_by_block[tail.block_id])

    def test_eviction_removes_aliases_and_missing_interior_page_rewinds(self):
        length = 4992
        pool = h.new_pool(128)
        swa = h.new_swa_manager(pool)
        producer = h.make_request("eviction", length)
        physical = self._publish(swa, producer, length, retention=None)

        pool.evict_blocks({physical[3].block_id})
        _, hit = self._find(swa, producer, length)
        self.assertEqual(hit, 3456)

        alias_hashes = [producer.block_hashes[value // H - 1] for value in (4864, 4992)]
        pool.evict_blocks({physical[4].block_id})
        for block_hash in alias_hashes:
            self.assertIsNone(pool.get_cached_block(block_hash, [0]))
        self.assertNotIn(physical[4].block_id, pool.cached_block_hashes_by_block)

    def test_null_tail_is_never_published(self):
        length = 4992
        pool = h.new_pool(128)
        swa = h.new_swa_manager(pool)
        request = h.make_request("null-tail", length)
        swa.req_to_blocks[request.request_id].extend(pool.get_new_blocks(4))
        swa.req_to_blocks[request.request_id].append(pool.null_block)
        swa.cache_blocks(request, length, retention_interval=0)
        for boundary in (4864, 4992):
            self.assertIsNone(
                pool.get_cached_block(request.block_hashes[boundary // H - 1], [0])
            )

    def test_retention_zero_keeps_exact_fine_window_at_200k_boundary(self):
        hit_target = 199_936
        coord = self._target_coordinator()
        swa = coord.single_type_managers[3]
        request = h.make_request("retention0", hit_target + 1)
        physical = self._publish(swa, request, hit_target + 1)
        blocks, hit = self._find(swa, request, hit_target)
        self.assertEqual(hit, hit_target)
        self._assert_exact_window(coord.block_pool, blocks[0], hit)

        first = max(0, hit - (W - 1)) // P
        end = h.cdiv(hit, P)
        self.assertEqual((first, end), (171, 174))
        self.assertIsNone(physical[170].block_hash)
        self.assertIsNotNone(physical[171].block_hash)
        self.assertIsNotNone(physical[172].block_hash)
        self.assertIsNotNone(physical[173].block_hash)

    def test_partial_hit_cow_pins_both_endpoints_until_copy_completion(self):
        length = 4992
        pool = h.new_pool(128)
        swa = h.new_swa_manager(pool)
        producer = h.make_request("cow-producer", length)
        self._publish(swa, producer, length, retention=None)
        swa.free(producer.request_id)

        consumer = h.make_request("cow-consumer", length + 1)
        hit_blocks, hit = self._find(swa, consumer, length)
        self.assertEqual(hit, length)
        source = hit_blocks[0][-1]
        self.assertEqual(source.ref_cnt, 0)
        needed = swa.get_num_blocks_to_allocate(
            consumer.request_id,
            length + 1,
            hit_blocks[0],
            hit,
            hit,
            length + 1,
        )
        self.assertEqual(needed, 4)  # one CoW + three eviction candidates
        swa.add_local_computed_blocks(consumer.request_id, hit_blocks[0], hit, 0)
        returned = swa.allocate_new_blocks(consumer.request_id, length + 1, length + 1)
        copies = swa.take_pending_cow_copies()
        self.assertEqual(len(copies), 1)
        copy_source, destination = copies[0]
        self.assertIs(copy_source, source)
        self.assertIs(returned[0], destination)
        self.assertEqual((source.ref_cnt, destination.ref_cnt), (1, 2))
        self.assertIs(swa.req_to_blocks[consumer.request_id][4], destination)

        swa.free(consumer.request_id)
        self.assertEqual((source.ref_cnt, destination.ref_cnt), (1, 1))
        pool.free_blocks([source, destination])
        self.assertEqual((source.ref_cnt, destination.ref_cnt), (0, 0))

    def test_mamba_same_step_producer_consumer_is_deferred(self):
        coord = self._target_coordinator()
        pool = coord.block_pool
        mamba = coord.single_type_managers[2]
        spec = mamba.kv_cache_spec
        producer = h.make_request("mamba-producer", 4992)
        h.allocate_request_blocks(mamba, producer, 4992)
        mamba.cache_blocks(producer, 4992, retention_interval=0)
        hit_blocks, hit = mamba.find_longest_cache_hit(
            producer.block_hashes,
            4992,
            [2],
            pool,
            spec,
            False,
            H,
        )
        self.assertEqual(hit, 4992)
        all_group_hits = ([], [], hit_blocks[0], [])
        blocked = coord.get_num_blocks_to_allocate(
            "mamba-consumer",
            4993,
            all_group_hits,
            0,
            hit,
            hit,
            4993,
        )
        self.assertGreater(blocked, pool.num_gpu_blocks)
        coord.new_step_starts()
        admitted_next_step = coord.get_num_blocks_to_allocate(
            "mamba-consumer",
            4993,
            all_group_hits,
            0,
            hit,
            hit,
            4993,
        )
        self.assertLessEqual(admitted_next_step, pool.num_gpu_blocks)

    def test_eagle_drop_uses_physical_page_and_retention_keeps_peek(self):
        desired_hit = 4608
        endpoint = desired_hit + P
        pool = h.new_pool(128)
        swa = h.new_swa_manager(pool, use_eagle=True)
        producer = h.make_request("eagle", endpoint + 1)
        physical = self._publish(swa, producer, endpoint + 1)

        drop_blocks, drop_hit = self._find(swa, producer, endpoint, drop=True)
        self.assertEqual(drop_hit, desired_hit)
        self._assert_exact_window(pool, drop_blocks[0], drop_hit)
        self.assertIsNotNone(physical[4].block_hash)  # endpoint/peek page
        self.assertIsNone(physical[1].block_hash)

        no_drop_blocks, no_drop_hit = self._find(
            swa, producer, endpoint, drop=False
        )
        self.assertEqual(no_drop_hit, endpoint)
        self._assert_exact_window(pool, no_drop_blocks[0], no_drop_hit)

        boundaries = swa._reachable_hit_boundaries(producer)
        self.assertEqual(boundaries[0], desired_hit)
        producer.shared_prefix_boundary = desired_hit
        self.assertEqual(swa._reachable_hit_boundaries(producer), [desired_hit, desired_hit])

    def test_mixed_group_fixed_point_and_kpool_opt_out(self):
        coord = self._target_coordinator()
        tokens = [index % 65521 for index in range(11_137)]

        full_req = h.make_request("full", 11_008, tokens=tokens)
        full = coord.single_type_managers[0]
        h.allocate_request_blocks(full, full_req, 11_008)
        full.cache_blocks(full_req, 11_008, retention_interval=None)

        mamba_req = h.make_request("mamba", 9216, tokens=tokens)
        mamba = coord.single_type_managers[2]
        h.allocate_request_blocks(mamba, mamba_req, 9216)
        mamba.cache_blocks(mamba_req, 9216, retention_interval=None)
        mamba.new_step_starts()

        swa_req = h.make_request("swa", 11_009, tokens=tokens)
        swa = coord.single_type_managers[3]
        h.allocate_request_blocks(swa, swa_req, 11_009)
        swa.cache_blocks(swa_req, 11_009, retention_interval=None)

        query_hashes = h.chained_hashes(tokens)
        per_group_blocks, per_group_hits = coord.find_longest_cache_hit_per_group(
            query_hashes, 11_008
        )
        self.assertEqual(per_group_hits, (11_008, 0, 9216, 11_008))
        self.assertEqual(per_group_blocks[1], [])

        common_blocks, common_hit, uncached = coord.find_longest_cache_hit(
            query_hashes, 11_008
        )
        self.assertEqual(common_hit, 9216)
        self.assertEqual(uncached, 1792)
        self.assertEqual(common_blocks[1], [])
        self.assertEqual(len(common_blocks[0]), h.cdiv(common_hit, S))

    def test_full_hybrid_aligned_producer_is_accepted_current_limitation(self):
        """Pin the known bad behavior; this is not a correctness assertion.

        A 4,608-aligned producer omits the 36,736 scheduler stop. SWA can find
        36,736, while full attention and Mamba only expose 32,256; retention
        then makes fixed-point reconciliation collapse to zero. The desired
        result is 36,736 hit / 128 compute, but the installed stack returns
        zero hit / 36,864 compute. The adjacent ordinary prompt still works.
        """
        chunks, per_group, observed = self._full_hybrid_scheduler_replay(36_864)
        desired = ((36_864 - 1) // H) * H
        self.assertEqual(desired, 36_736)
        self.assertNotIn(desired, chunks)
        self.assertEqual(per_group, (32_256, 0, 32_256, 36_736))
        self.assertEqual(observed, 0)  # EXPECTED ACCEPTED LIMITATION
        self.assertEqual(36_864 - observed, 36_864)

        neighbor_chunks, neighbor_groups, neighbor_hit = (
            self._full_hybrid_scheduler_replay(36_865)
        )
        self.assertIn(36_864, neighbor_chunks)
        self.assertEqual(neighbor_groups, (36_864, 0, 36_864, 36_864))
        self.assertEqual((neighbor_hit, 36_865 - neighbor_hit), (36_864, 1))

    def test_exact_source_copy_path_drop_gate_and_dflash_lookahead(self):
        hashes = {
            h.RUNTIME_ROOT / "vllm/v1/core/kv_cache_utils.py":
                "cb7daec1354727696da42d4a7c42f770eb260304195d690ebd7a22427201062e",
            h.RUNTIME_ROOT / "vllm/v1/core/block_pool.py":
                "ddee56dccb2208411b3a035918e917ce8f56a9858471e9ca12b420d5d79bc69c",
            h.RUNTIME_ROOT / "vllm/v1/core/kv_cache_manager.py":
                "9747090b01f758487ac7488fb0721c7cfe5507e8aeb55f4ea3795349bfff0968",
            h.RUNTIME_ROOT / "vllm/v1/core/sched/scheduler.py":
                "acf44a9dbc1fba5347d7dec57deb928cd101653fe7ef0816b7bdd723e29f0478",
            h.RUNTIME_ROOT / "vllm/config/speculative.py":
                "7a1a93810f3232c4ff9b40e69e8c95d80d566eb2eca07523c027153ac9b39134",
            h.FIXTURE_ROOT / "vllm_config_487ecf.py":
                "e535d12d22ee5c0ba06b255fcda4332a88bd74786f296921efcffb4a131b5adb",
            h.FIXTURE_ROOT / "worker_utils_487ecf.py":
                "3dcd6ad34ee1d1db2875f7f7dd51d90ee0e64041ab282180687770a38b26acb1",
            h.FIXTURE_ROOT / "gpu_model_runner_487ecf.py":
                "5be64e11d25f9802a1970089e9203ae4b18977b340471a6d0761f0274b54c4b6",
        }
        for path, expected in hashes.items():
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected)

        scheduler_text = (
            h.RUNTIME_ROOT / "vllm/v1/core/sched/scheduler.py"
        ).read_text()
        kv_manager_text = (
            h.RUNTIME_ROOT / "vllm/v1/core/kv_cache_manager.py"
        ).read_text()
        self.assertIn("take_kv_cache_block_copies", kv_manager_text)
        self.assertIn("kv_cache_block_copies=pending_kv_cache_block_copies", scheduler_text)
        self.assertIn("self.sched_step_seq + 1", scheduler_text)
        self.assertIn("_free_cow_retained_blocks", scheduler_text)

        speculative_path = h.RUNTIME_ROOT / "vllm/config/speculative.py"
        tree = ast.parse(speculative_path.read_text())
        gate = next(
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.FunctionDef) and node.name == "use_eagle_block_drop"
        )
        self.assertIn(
            "self.use_eagle() and (not self.disable_eagle_block_drop)",
            ast.unparse(gate),
        )

        vllm_config = (h.FIXTURE_ROOT / "vllm_config_487ecf.py").read_text()
        compact = " ".join(vllm_config.split())
        self.assertIn("if speculative_config.use_dflash():", compact)
        self.assertIn("return self.num_speculative_tokens + 1", compact)

        worker_utils = (h.FIXTURE_ROOT / "worker_utils_487ecf.py").read_text()
        worker_runner = (
            h.FIXTURE_ROOT / "gpu_model_runner_487ecf.py"
        ).read_text()
        self.assertIn("def copy_kv_cache_blocks_inplace(", worker_utils)
        self.assertIn("blocks[dst_indices] = blocks[src_indices]", worker_utils)
        self.assertIn("copy_kv_cache_blocks_inplace(", worker_runner)

    def test_50457_full_attention_booking_exceeds_13_5gb_goal(self):
        config_path = h.FIXTURE_ROOT / "dflash2-config.json"
        self.assertEqual(
            hashlib.sha256(config_path.read_bytes()).hexdigest(),
            "c4aeac0101196a6e26705b34c45230bcd0c7c68ee2d2d1efdb242087f3712573",
        )
        config = json.loads(config_path.read_text())
        self.assertEqual(config["layer_types"], ["sliding_attention"] * 5)
        self.assertEqual(
            (
                config["num_hidden_layers"],
                config["num_key_value_heads"],
                config["head_dim"],
                config["sliding_window"],
                config["dtype"],
            ),
            (5, 8, 128, W, "bfloat16"),
        )
        bytes_per_token = 5 * 8 * (128 + 128) * 2
        max_num_seqs = 6
        full_booking = (
            max_num_seqs * math.ceil(200_000 / P) * P * bytes_per_token
        )
        swa_pages = h.cdiv(W - 1 + 8192, P) + 1
        swa_booking = max_num_seqs * swa_pages * P * bytes_per_token
        self.assertEqual(full_booking, 24_631_050_240)
        self.assertEqual(swa_booking, 1_415_577_600)
        self.assertGreater(full_booking, 13_500_000_000)
        self.assertLess(swa_booking, 13_500_000_000)

    def test_launcher_is_baked_image_only_and_has_exact_target_parameters(self):
        launcher = (h.ROOT / "launch.sh").read_text()
        required_once = (
            "--prefix-match-unit 128",
            "--kv-cache-memory 13500000000",
            "--max-num-seqs 6",
            "--max-num-batched-tokens 8192",
            "/home/ubuntu/models/GLM-5.3-Flash-DFlash2-bf582e4e",
            '"method":"dflash"',
            '"num_speculative_tokens":7',
            '"attention_backend":"FLASH_ATTN"',
            '"kv_cache_dtype":"auto"',
            '"disable_eagle_block_drop":true',
            "spark-recipes/glm53-autoround-dflash2-k7-pmu128:20260904",
        )
        for value in required_once:
            self.assertEqual(launcher.count(value), 1, value)
        self.assertIn("VLLM_PREFIX_CACHE_RETENTION_INTERVAL=0", launcher)
        self.assertIn("HF_HUB_OFFLINE=1", launcher)
        self.assertIn("TRANSFORMERS_OFFLINE=1", launcher)
        self.assertEqual(launcher.count("\n -v \""), 3)
        self.assertNotIn("dist-packages", launcher)
        self.assertNotIn("PATCH_HOST", launcher)


if __name__ == "__main__":
    unittest.main(verbosity=2)
