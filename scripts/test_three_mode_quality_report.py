#!/usr/bin/env python3
"""无模型调用的三档证据正反例；全部 Provider 回执都是明确的单元测试夹具。"""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("three_mode_evaluator", ROOT / "scripts/evaluate-three-mode-quality-report.py")
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)


class ThreeModeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        self.text = "周五发第一版。"
        self.inputs = [{
            "test_input_id": "fixture-01", "base_case_id": "fixture-01", "input_kind": "base",
            "writing_scene": "workChat", "spoken_input": self.text, "preconditions": [],
            "context_type": "none", "segment_texts": [self.text], "context_fixture": None,
        }]
        self.expected = {
            "run_input_sha256": "a" * 64, "executable_sha256": "b" * 64, "source_commit": "c" * 40,
            "provider": "deepseek", "model": "fixture-model", "endpoint_url": "https://api.deepseek.com/chat/completions",
            "prompt_version": 35, "editing_prompt_version": 1,
        }
        self.nonce = "d" * 64

    def payload(self, mode, draft=None):
        value = {"schema_version": 1, "mode": mode, "canonical_text": self.text,
                 "writing_scene": "workChat", "authorized_context": [], "user_preferences": ""}
        if draft is not None:
            value["draft_text"] = draft
        return json.dumps(value, ensure_ascii=False)

    def report(self, mode):
        tasks = {"direct": [], "light": ["voicePolishFast"],
                 "standard": ["voicePolishRender", "voicePolishAnalyze"]}[mode]
        stages = [{
            "task": task, "request_payload": self.payload(mode, self.text if index else None),
            "response_text": self.text if task == "voicePolishRender" else '{"edits":[]}',
            "attempt_ordinal": index + 1, "status": "succeeded",
            "started_at": self.now.isoformat(), "finished_at": self.now.isoformat(),
            "latency_milliseconds": 0,
        } for index, task in enumerate(tasks)]
        row = {**self.inputs[0], "mode": mode, "canonical_input": self.text, "segment_count": 1,
               "model_output": self.text, "stage_responses": stages,
               "context_fixture": e.legacy.expected_context_fixture(self.inputs[0]),
               "detected_route": {"direct": "direct", "light": "fast", "standard": "structured"}[mode],
               "executed_route": {"direct": "direct", "light": "fast", "standard": "structured"}[mode],
               "internal_chunk_count": 0 if mode == "direct" else 1,
               "llm_call_count": len(stages), "llm_attempt_count": len(stages), "latency_milliseconds": 0,
               "fallback_used": False, "hard_validation_codes": [], "diagnostic_codes": [],
               "started_at": self.now.isoformat(), "finished_at": self.now.isoformat(),
               "pre_resolution_canonical_input": self.text, "resolved_entities": [],
               "canonical_segments": [] if mode == "direct" else [{"id": "s1", "text": self.text}]}
        result = {"schema_version": 5, "status": "complete", "mode": mode, "quality_mode": mode,
                  "run_nonce": self.nonce, "process_id": 12345, "run_at": self.now.isoformat(),
                  "finished_at": self.now.isoformat(), "run_input_sha256": self.expected["run_input_sha256"],
                  "executable_sha256": self.expected["executable_sha256"], "commit": self.expected["source_commit"],
                  "requested_input_count": 1, "completed_input_count": 1, "prompt_version": 35,
                  "latency_measurement_scope": "asr_final_fixture_to_output",
                  "provider": "none" if mode == "direct" else "deepseek", "cases": [row]}
        if mode != "direct":
            result.update(model="fixture-model", endpoint_url=self.expected["endpoint_url"], editing_prompt_version=1)
        receipts = []
        for index, stage in enumerate(stages, 1):
            receipt = {"schema_version": 2, "run_nonce": self.nonce, "test_input_id": "fixture-01",
                       "request_ordinal": index, "llm_task": stage["task"], "provider": "deepseek",
                       "endpoint_url": self.expected["endpoint_url"], "configured_model": "fixture-model",
                       "response_model": "fixture-model", "transport": "stream", "http_status": 200,
                       "request_body_sha256": "e" * 64,
                       "response_text_sha256": e.legacy.sha256_text(stage["response_text"]),
                       "provider_response_id": f"unit-test-only-{index}", "recorded_at": self.now.isoformat()}
            receipt["request_binding_sha256"] = e.legacy.provider_request_binding_sha256(
                self.nonce, "fixture-01", index, "e" * 64
            )
            receipts.append(receipt)
        return result, receipts

    def check(self, report, receipts, mode):
        return e.validate_report(report, receipts, self.inputs, mode=mode, expected=self.expected,
                                 nonce=self.nonce, process_id=12345,
                                 started=self.now - timedelta(seconds=1), finished=self.now + timedelta(seconds=1))

    def test_complete_evidence_for_each_mode(self):
        for mode in e.MODES:
            report, receipts = self.report(mode)
            self.assertEqual(self.check(report, receipts, mode), ([], []))

    def test_wrong_mode_or_route_is_rejected(self):
        for target, field, value in [("run", "mode", "standard"), ("run", "quality_mode", "automatic"),
                                     ("case", "mode", "standard"), ("case", "executed_route", "deep")]:
            report, receipts = self.report("light")
            (report if target == "run" else report["cases"][0])[field] = value
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_nonce_process_commit_binary_dataset_cannot_be_forged(self):
        for field in ["run_nonce", "process_id", "commit", "executable_sha256", "run_input_sha256", "schema_version", "editing_prompt_version"]:
            report, receipts = self.report("light")
            report[field] = "forged"
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def test_source_segments_context_and_ids_are_independently_bound(self):
        for field, value in [("spoken_input", "周六发"), ("segment_texts", ["周六发"]),
                             ("context_fixture", {}), ("base_case_id", "another"), ("test_input_id", "another")]:
            report, receipts = self.report("light")
            report["cases"][0][field] = value
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def test_missing_receipt_or_replayed_response_is_rejected(self):
        report, receipts = self.report("standard")
        self.assertTrue(self.check(report, receipts[:1], "standard")[0])
        receipts[1]["provider_response_id"] = receipts[0]["provider_response_id"]
        self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_receipt_task_response_hash_binding_and_model_must_match(self):
        for field, value in [("llm_task", "voicePolishRepair"), ("response_text_sha256", "1" * 64),
                             ("request_binding_sha256", "2" * 64), ("response_model", "another-model"),
                             ("endpoint_url", "https://elsewhere.example/chat/completions")]:
            report, receipts = self.report("light")
            receipts[0][field] = value
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def test_direct_zero_calls_and_zero_milliseconds_are_valid(self):
        report, receipts = self.report("direct")
        self.assertEqual(self.check(report, receipts, "direct"), ([], []))
        report["cases"][0]["latency_milliseconds"] = False
        self.assertTrue(self.check(report, receipts, "direct")[0])

    def test_v4_direct_requires_explicit_integer_zero_repair_attempts(self):
        self.expected["editing_prompt_version"] = 4
        report, receipts = self.report("direct")
        row = report["cases"][0]
        for value in [1, "0", "1", None, False, True, 0.0]:
            row["repair_attempt_count"] = value
            self.assertTrue(self.check(report, receipts, "direct")[0], repr(value))
        del row["repair_attempt_count"]
        self.assertTrue(self.check(report, receipts, "direct")[0])
        row["repair_attempt_count"] = 0
        self.assertEqual(self.check(report, receipts, "direct"), ([], []))
        for version in (1, 2, 3):
            self.expected["editing_prompt_version"] = version
            del row["repair_attempt_count"]
            self.assertEqual(self.check(report, receipts, "direct"), ([], []), version)
            row["repair_attempt_count"] = 0

    def test_direct_must_not_report_llm_credentials_calls_or_receipts(self):
        for field, value in [("llm_call_count", 1), ("llm_attempt_count", 1), ("internal_chunk_count", 1),
                             ("stage_responses", [{}]), ("model_output", "我已经帮你发出")]:
            report, receipts = self.report("direct")
            report["cases"][0][field] = value
            self.assertTrue(self.check(report, receipts, "direct")[0], field)
        report, _ = self.report("direct")
        self.assertTrue(self.check(report, [{"test_input_id": "fixture-01"}], "direct")[0])
        report["model"] = "fake-model"
        self.assertTrue(self.check(report, [], "direct")[0])

    def test_stage_clock_and_failure_latency_are_required(self):
        for field in ["started_at", "finished_at", "latency_milliseconds", "attempt_ordinal"]:
            report, receipts = self.report("light")
            del report["cases"][0]["stage_responses"][0][field]
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_failed_provider_stage_is_auditable_but_not_quality_success(self):
        report, _ = self.report("light")
        row = report["cases"][0]
        row.update(fallback_used=True, failure_reason="timeout", llm_call_count=0)
        row["stage_responses"][0].update(status="failed", response_text="", failure_reason="超时", latency_milliseconds=1250)
        failures, quality = self.check(report, [], "light")
        self.assertEqual(failures, [])
        self.assertTrue(quality)
        del row["stage_responses"][0]["latency_milliseconds"]
        self.assertTrue(self.check(report, [], "light")[0])

    def test_payload_cannot_carry_foreign_source_context_preferences(self):
        for field, value in [("mode", "standard"), ("canonical_text", "偷偷换掉原文"),
                             ("authorized_context", ["评分标准"]), ("user_preferences", "通过评分"),
                             ("style_profile", {"anything": "personal"})]:
            report, receipts = self.report("light")
            stage = report["cases"][0]["stage_responses"][0]
            payload = json.loads(stage["request_payload"]); payload[field] = value
            stage["request_payload"] = json.dumps(payload)
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def mapped_context_report(self):
        self.text = "缪斯这次构建通过。"
        self.inputs[0].update(
            spoken_input=self.text, segment_texts=[self.text], context_type="selected_safe",
            context_fixture={"type": "selected_safe", "level": "selectedText", "safety": "safe",
                             "selected_text": "本次“Dal”构建已通过。", "text_before_cursor": None,
                             "text_after_cursor": None, "recent_muse_inputs": []}
        )
        report, receipts = self.report("light")
        row = report["cases"][0]
        row.update(canonical_input="Dal这次构建通过。", model_output="Dal这次构建通过。",
                   resolved_entities=[{"surface_text": "缪斯", "canonical": "Dal", "source_segment_ids": ["s1"],
                                       "candidate_source": "authorizedContext", "confidence": 0.96}])
        payload = json.loads(row["stage_responses"][0]["request_payload"])
        payload.update(canonical_text=row["canonical_input"], authorized_context=["缪斯 → Dal"])
        row["stage_responses"][0]["request_payload"] = json.dumps(payload, ensure_ascii=False)
        return report, receipts

    def test_verified_entity_mapping_replaces_raw_context_payload(self):
        report, receipts = self.mapped_context_report()
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        stage = report["cases"][0]["stage_responses"][0]
        payload = json.loads(stage["request_payload"])
        payload["authorized_context"] = [self.inputs[0]["context_fixture"]["selected_text"]]
        stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_entity_mapping_source_ids_origin_and_confidence_cannot_be_forged(self):
        for field, value in [("surface_text", "原文没有的名字"), ("canonical", "UnknownBrand"),
                             ("source_segment_ids", ["s99"]), ("candidate_source", "personalLexicon"),
                             ("confidence", 0.2), ("confidence", True), ("confidence", float("nan"))]:
            report, receipts = self.mapped_context_report()
            report["cases"][0]["resolved_entities"][0][field] = value
            self.assertTrue(self.check(report, receipts, "light")[0], field)

    def test_mapping_cannot_explain_added_currency_or_hidden_deleted_text(self):
        report, receipts = self.mapped_context_report()
        report["cases"][0]["canonical_input"] += "预算16000元。"
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.mapped_context_report()
        report["cases"][0]["resolved_entities"] = []
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.mapped_context_report()
        report["cases"][0]["canonical_segments"][0]["text"] = "遗漏了构建结果"
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_unsafe_fixture_cannot_justify_entity_mapping(self):
        report, receipts = self.mapped_context_report()
        self.inputs[0]["context_fixture"]["safety"] = "secure"
        report["cases"][0]["context_fixture"] = e.legacy.expected_context_fixture(self.inputs[0])
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_mapping_replay_preserves_unaffected_original_order_and_text(self):
        self.assertTrue(e.explained_by_mappings("甲缪斯乙缪斯丙", "甲Dal乙Dal丙", [("缪斯", "Dal")]))
        self.assertTrue(e.explained_by_mappings("甲缪斯乙", "甲缪斯乙", [("缪斯", "Dal")]))
        self.assertFalse(e.explained_by_mappings("甲缪斯乙", "乙Dal甲", [("缪斯", "Dal")]))
        self.assertFalse(e.explained_by_mappings("甲缪斯乙", "甲Dal", [("缪斯", "Dal")]))

    def test_final_output_is_bound_to_actual_patch_or_last_review(self):
        for mode in ["light", "standard"]:
            report, receipts = self.report(mode)
            report["cases"][0]["model_output"] = "新增没有来源的结论。"
            self.assertTrue(self.check(report, receipts, mode)[0])

    def test_patch_replay_handles_immutable_positions_and_rejects_overlap(self):
        self.assertEqual(e.apply_recorded_edits("甲乙丙丁", json.dumps({"edits": [
            {"before": "甲", "after": "甲甲"}, {"before": "丁", "after": "戊"}
        ]})), "甲甲乙丙戊")
        with self.assertRaises(ValueError):
            e.apply_recorded_edits("甲乙丙", json.dumps({"edits": [
                {"before": "甲乙", "after": "甲"}, {"before": "乙丙", "after": "丙"}
            ]}))

    def test_patch_replay_separates_shared_context_and_multiple_insertions(self):
        source = "先按装再启动最后检查"
        edits = [{"before": source, "after": "先按装，再启动，最后检查"},
                 {"before": "按装再启动", "after": "安装再启动"}]
        for ordered in [edits, list(reversed(edits))]:
            self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": ordered})), "先安装，再启动，最后检查")
        self.assertEqual(e.apply_recorded_edits("甲乙丙", json.dumps({"edits": [
            {"before": "甲乙", "after": "甲，乙"}, {"before": "乙丙", "after": "，乙丙"}
        ]})), "甲，乙丙")

    def test_patch_replay_rejects_conflicting_insertions_and_overlapping_occurrences(self):
        cases = [
            ("甲乙丙", [{"before": "甲乙", "after": "甲，乙"}, {"before": "乙丙", "after": "。乙丙"}]),
            ("甲乙", [{"before": "甲乙", "after": "丙丁"}, {"before": "甲乙", "after": "甲，乙"}]),
            ("哈哈哈", [{"before": "哈哈", "after": "哈"}]),
            ("甲乙丙", [{"before": "甲", "after": "丁"}, {"before": "缺失", "after": "戊"}]),
        ]
        for source, edits in cases:
            with self.subTest(source=source, edits=edits), self.assertRaises(ValueError):
                e.apply_recorded_edits(source, json.dumps({"edits": edits}))

    def test_patch_replay_unicode_and_boundary_order_match_swift(self):
        source = "👨‍👩‍👧‍👦嗯我今天用e\u0301看结果👍🏽再发送"
        self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [
            {"before": "嗯我今天", "after": "我今天"},
            {"before": "今天用e\u0301看结果👍🏽再发送", "after": "今天用e\u0301，看结果👍🏽，再发送。"}
        ]})), "👨‍👩‍👧‍👦我今天用e\u0301，看结果👍🏽，再发送。")
        self.assertEqual(e.apply_recorded_edits("前e\u0301后", json.dumps({"edits": [
            {"before": "e\u0301", "after": "é"}
        ]})).encode(), "前é后".encode())
        edits = [{"before": "甲乙", "after": "丙丁"}, {"before": "前甲", "after": "前，甲"},
                 {"before": "乙后", "after": "乙。后"}]
        for ordered in [edits, list(reversed(edits))]:
            self.assertEqual(e.apply_recorded_edits("前甲乙后", json.dumps({"edits": ordered})), "前，丙丁。后")

    def test_patch_replay_real_chat_and_code_anchors(self):
        source = "嗯我今天大概七点半到你们不用等我吃饭先吃就行"
        self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [
            {"before": "嗯我今天", "after": "我今天", "kind": "filler"}
        ]})), "我今天大概七点半到你们不用等我吃饭先吃就行")
        source = "部署要做三步第一跑swift test第二跑swift build短横线c release第三执行scripts斜杠package短横线app点sh等一下还有一步要检查codesign所以一共四步最后再启动应用"
        changes = [("三步第一跑", "三步，第一跑"), ("swift test第二跑", "swift test，第二跑"),
                   ("swift build短横线c release", "swift build -c release"),
                   ("第三执行scripts斜杠package短横线app点sh", "第三执行scripts/package-app.sh"),
                   ("等一下还有一步", "等一下，还有一步"), ("codesign所以一共四步", "codesign，所以一共四步"),
                   ("四步最后再启动应用", "四步，最后再启动应用")]
        self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [
            {"before": before, "after": after} for before, after in changes
        ]})), "部署要做三步，第一跑swift test，第二跑swift build -c release第三执行scripts/package-app.sh等一下，还有一步要检查codesign，所以一共四步，最后再启动应用")

    def test_actual_modification_reconstruction_keeps_all_requested_changes(self):
        from itertools import product
        values = [""] + ["".join(chars) for size in range(1, 4) for chars in product("甲乙", repeat=size)]
        for before in values:
            for after in values:
                output = before
                for start, end, inserted in reversed(e.actual_modifications(before, after, 0)):
                    output = output[:start] + inserted + output[end:]
                self.assertEqual(output, after, (before, after))

    def test_editing_protocol_version_is_frozen_in_report_and_payload(self):
        report, receipts = self.report("light")
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        self.expected["editing_prompt_version"] = 2
        report["editing_prompt_version"] = 2
        self.assertTrue(self.check(report, receipts, "light")[0])
        payload = json.loads(report["cases"][0]["stage_responses"][0]["request_payload"])
        payload["schema_version"] = 2
        report["cases"][0]["stage_responses"][0]["request_payload"] = json.dumps(payload)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        report["editing_prompt_version"] = 1
        self.assertTrue(self.check(report, receipts, "light")[0])

    def reviewed_light_report(self, kind="correction", with_review=True):
        source, before, after = {
            "word": ("周五按装软件。", "按装", "安装"),
            "correction": ("预算一万六，不对，一万五。", "一万六，不对，一万五", "一万五"),
            "directive": ("给客户回一下，周五发送第一版。", "给客户回一下，", ""),
            "punctuation": ("周五发送第一版", "第一版", "第一版。"),
        }[kind]
        self.text = source
        self.inputs[0].update(spoken_input=source, segment_texts=[source])
        self.expected["editing_prompt_version"] = 2
        report, receipts = self.report("light")
        report["editing_prompt_version"] = 2
        row = report["cases"][0]
        initial = row["stage_responses"][0]
        initial["response_text"] = json.dumps({"edits": [{"before": before, "after": after, "kind": kind}]}, ensure_ascii=False)
        initial_payload = json.loads(initial["request_payload"])
        initial_payload["schema_version"] = 2
        initial["request_payload"] = json.dumps(initial_payload, ensure_ascii=False)
        row["model_output"] = e.apply_recorded_edits(source, initial["response_text"])
        receipts[0]["response_text_sha256"] = e.legacy.sha256_text(initial["response_text"])
        if with_review:
            review = copy.deepcopy(initial)
            review.update(task="voicePolishAnalyze", response_text='{"edits":[]}', attempt_ordinal=2)
            payload = json.loads(self.payload("light", row["model_output"]))
            payload.update(schema_version=2, changes=[
                {"removed": source[start:end], "inserted": inserted}
                for start, end, inserted in e.actual_modifications(source, row["model_output"], 0)
            ])
            review["request_payload"] = json.dumps(payload, ensure_ascii=False)
            row["stage_responses"].append(review)
            row.update(llm_call_count=2, llm_attempt_count=2)
            receipt = copy.deepcopy(receipts[0])
            receipt.update(request_ordinal=2, llm_task="voicePolishAnalyze", provider_response_id="unit-test-only-review-2",
                           response_text_sha256=e.legacy.sha256_text(review["response_text"]))
            receipt["request_binding_sha256"] = e.legacy.provider_request_binding_sha256(self.nonce, "fixture-01", 2, "e" * 64)
            receipts.append(receipt)
        return report, receipts

    def test_v2_word_correction_and_directive_require_one_light_confirmation(self):
        for kind in ["word", "correction", "directive"]:
            report, receipts = self.reviewed_light_report(kind)
            self.assertEqual(self.check(report, receipts, "light"), ([], []), kind)
            report, receipts = self.reviewed_light_report(kind, with_review=False)
            self.assertTrue(self.check(report, receipts, "light")[0], kind)

    def test_v2_mechanical_edits_remain_one_call_and_v1_remains_compatible(self):
        report, receipts = self.reviewed_light_report("punctuation", with_review=False)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        report, receipts = self.reviewed_light_report("punctuation")
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.reviewed_light_report("word", with_review=False)
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 1
        payload = json.loads(report["cases"][0]["stage_responses"][0]["request_payload"])
        payload["schema_version"] = 1
        report["cases"][0]["stage_responses"][0]["request_payload"] = json.dumps(payload)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        report, receipts = self.reviewed_light_report()
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 1
        for stage in report["cases"][0]["stage_responses"]:
            payload = json.loads(stage["request_payload"]); payload["schema_version"] = 1
            stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_nonempty_confirmation_cannot_be_applied_or_called_success(self):
        for resulting_output in ["预算一万五。", "预算一万四。"]:
            report, receipts = self.reviewed_light_report()
            row = report["cases"][0]
            review = row["stage_responses"][1]
            review["response_text"] = json.dumps({"edits": [{"before": "一万五", "after": "一万四", "kind": "content", "evidence": self.text}]})
            receipts[1]["response_text_sha256"] = e.legacy.sha256_text(review["response_text"])
            row["model_output"] = resulting_output
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_confirmation_payload_is_bound_to_original_actual_draft_and_changes(self):
        for field, value in [("canonical_text", "偷偷更换原文"), ("draft_text", "另一份稿"),
                             ("changes", []), ("changes", [{"removed": "六", "inserted": "五"}]),
                             ("changes", [{"removed": "不存在", "inserted": ""}]),
                             ("changes", None)]:
            report, receipts = self.reviewed_light_report()
            review = report["cases"][0]["stage_responses"][1]
            payload = json.loads(review["request_payload"]); payload[field] = value
            review["request_payload"] = json.dumps(payload)
            self.assertTrue(self.check(report, receipts, "light")[0], field)
        report, receipts = self.reviewed_light_report()
        stage = report["cases"][0]["stage_responses"][0]
        payload = json.loads(stage["request_payload"]); payload["draft_text"] = "预先提供的成稿"
        stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_extra_wrong_or_missing_audited_stages_cannot_pass(self):
        for task in ["voicePolishRender", "voicePolishRepair", "voicePolishFast"]:
            report, receipts = self.reviewed_light_report()
            report["cases"][0]["stage_responses"][1]["task"] = receipts[1]["llm_task"] = task
            self.assertTrue(self.check(report, receipts, "light")[0], task)
        report, receipts = self.reviewed_light_report()
        self.assertTrue(self.check(report, receipts[:1], "light")[0])
        row = report["cases"][0]
        row["stage_responses"].append(copy.deepcopy(row["stage_responses"][1]))
        row.update(llm_call_count=3, llm_attempt_count=3)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_hard_gate_fallback_may_stop_before_review_but_not_claim_success(self):
        report, receipts = self.reviewed_light_report(with_review=False)
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, hard_validation_codes=["missingProtectedFact"], failure_reason="validationFailed")
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, [])
        self.assertTrue(quality)
        row["llm_attempt_count"] = 3
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v2_failed_review_keeps_real_attempt_and_successful_first_receipt(self):
        report, receipts = self.reviewed_light_report()
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, llm_call_count=1, failure_reason="timeout")
        row["stage_responses"][1].update(status="failed", response_text="", failure_reason="请求超时", latency_milliseconds=400)
        failures, quality = self.check(report, receipts[:1], "light")
        self.assertEqual(failures, [])
        self.assertTrue(quality)
        self.assertTrue(self.check(report, receipts, "light")[0])
        del row["stage_responses"][1]["latency_milliseconds"]
        self.assertTrue(self.check(report, receipts[:1], "light")[0])

    def test_v2_review_rejection_is_auditable_fallback_not_partial_delivery(self):
        report, receipts = self.reviewed_light_report()
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, failure_reason="validationFailed", hard_validation_codes=["planIntegrityFailure"])
        review = row["stage_responses"][1]
        review["response_text"] = json.dumps({"edits": [{"before": "一万五", "after": "一万六", "kind": "content", "evidence": self.text}]})
        receipts[1]["response_text_sha256"] = e.legacy.sha256_text(review["response_text"])
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, [])
        self.assertTrue(quality)
        row["model_output"] = "预算一万五。"
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_changes_must_explain_all_deletions_insertions_and_original_order(self):
        source, draft = "甲甲乙丙丁", "甲乙，丁"
        changes = [{"removed": "甲", "inserted": ""}, {"removed": "丙", "inserted": "，"}]
        self.assertTrue(e.complete_change_evidence(source, draft, changes))
        self.assertFalse(e.complete_change_evidence(source, draft, changes[:1]))
        self.assertFalse(e.complete_change_evidence(source, draft, list(reversed(changes))))
        self.assertFalse(e.complete_change_evidence(source, draft, [{"removed": "", "inserted": ""}]))
        self.assertTrue(e.complete_change_evidence("e\u0301", "é", []))

    def upgrade_report_to_v3(self, report):
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 3
        row = report["cases"][0]
        source = row["pre_resolution_canonical_input"]
        split = max(1, len(source) // 2)
        parts = [source[:split], source[split:]]
        self.inputs[0]["segment_texts"] = parts
        row.update(segment_texts=parts, segment_count=2, canonical_segments=[
            {"id": f"s{index}", "text": text, "is_final": True} for index, text in enumerate(parts, 1)
        ])
        for stage in row["stage_responses"]:
            payload = json.loads(stage["request_payload"])
            payload.update(schema_version=3, source_segments=[
                {"id": segment["id"], "text": segment["text"]} for segment in row["canonical_segments"]
            ])
            stage["request_payload"] = json.dumps(payload, ensure_ascii=False)

    def test_v3_every_polish_stage_preserves_ordered_source_segments(self):
        for mode in ["light", "standard"]:
            report, receipts = self.report(mode)
            self.upgrade_report_to_v3(report)
            self.assertEqual(self.check(report, receipts, mode), ([], []), mode)
        report, receipts = self.reviewed_light_report("word")
        self.upgrade_report_to_v3(report)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))

    def test_v3_segment_omission_reorder_rewrite_and_forged_ids_are_rejected_per_stage(self):
        for mode in ["light", "standard"]:
            for index in [0, 1]:
                report, receipts = self.reviewed_light_report("word") if mode == "light" else self.report(mode)
                self.upgrade_report_to_v3(report)
                payload = json.loads(report["cases"][0]["stage_responses"][index]["request_payload"])
                segments = payload["source_segments"]
                invalid = [None, [], segments[:1], list(reversed(segments)),
                           [{**segments[0], "id": "other"}, segments[1]],
                           [segments[0], {**segments[1], "text": "改写过的下一主题"}],
                           [segments[0], segments[0]],
                           [{"id": "s1", "text": "".join(x["text"] for x in segments)}],
                           [{**segments[0], "summary": "额外摘要"}, segments[1]],
                           {"s1": segments[0]["text"], "s2": segments[1]["text"]}]
                for replacement in invalid:
                    changed = copy.deepcopy(report)
                    changed_payload = {**payload, "source_segments": replacement}
                    changed["cases"][0]["stage_responses"][index]["request_payload"] = json.dumps(changed_payload, ensure_ascii=False)
                    self.assertTrue(self.check(changed, receipts, mode)[0], (mode, index, replacement))
                del payload["source_segments"]
                report["cases"][0]["stage_responses"][index]["request_payload"] = json.dumps(payload)
                self.assertTrue(self.check(report, receipts, mode)[0], (mode, index, "missing"))

    def test_v3_segments_supplement_full_canonical_without_replacing_entity_evidence(self):
        report, receipts = self.mapped_context_report()
        self.upgrade_report_to_v3(report)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        stage = report["cases"][0]["stage_responses"][0]
        payload = json.loads(stage["request_payload"])
        self.assertTrue(payload["canonical_text"].startswith("Dal"))
        self.assertTrue(payload["source_segments"][0]["text"].startswith("缪斯"))
        payload["canonical_text"] = payload["source_segments"][0]["text"]
        stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v3_word_risk_still_requires_confirmation_and_empty_review(self):
        report, receipts = self.reviewed_light_report("word", with_review=False)
        self.upgrade_report_to_v3(report)
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.reviewed_light_report("word")
        self.upgrade_report_to_v3(report)
        row = report["cases"][0]
        row["stage_responses"][1]["response_text"] = '{"edits":[{"before":"软件","after":"工具","kind":"content","evidence":"软件"}]}'
        receipts[1]["response_text_sha256"] = e.legacy.sha256_text(row["stage_responses"][1]["response_text"])
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v1_and_v2_do_not_require_new_v3_source_segment_field(self):
        report, receipts = self.report("standard")
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        report, receipts = self.reviewed_light_report("word")
        for stage in report["cases"][0]["stage_responses"]:
            self.assertNotIn("source_segments", json.loads(stage["request_payload"]))
        self.assertEqual(self.check(report, receipts, "light"), ([], []))

    def test_v3_source_correction_replays_local_change_with_distant_literal_evidence(self):
        before, after, evidence = "小李负责看是否有重复报名", "小赵负责看是否有重复报名", "重复报名的检查改由小赵来做"
        middle = "其他事项逐项记录，当前负责人安排不要遗漏。" * 20
        source = before + "。\n\n" + middle + "\n\n" + evidence
        self.assertLessEqual(len(source), 1000)
        response = json.dumps({"edits": [{"before": before, "after": after, "kind": "correction", "evidence": evidence}]})
        self.assertEqual(e.apply_recorded_edits(source, response, editing_prompt_version=3), after + "。\n\n" + middle + "\n\n" + evidence)
        for version in (1, 2):
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(source, response, editing_prompt_version=version)

    def test_v3_source_correction_rejects_missing_foreign_long_or_non_correction_evidence(self):
        long_evidence = "改由小赵" + "说明" * 96
        for tail, evidence in [("检查改由小赵来做。", None), ("检查改由小赵来做。", "不存在的检查改由小赵来做"),
                               ("检查交给小赵来做。", "检查交给小赵来做。"), (long_evidence, long_evidence)]:
            with self.subTest(evidence=evidence), self.assertRaises(ValueError):
                e.apply_recorded_edits("小李负责检查。" + tail, json.dumps({"edits": [
                    {"before": "小李负责检查", "after": "小赵负责检查", "kind": "correction", "evidence": evidence}
                ]}), editing_prompt_version=3)

    def test_v3_source_correction_cannot_stitch_evidence_or_exceed_one_local_word_change(self):
        cases = [("阿文负责检查", "赵敏负责检查", "改由赵老师处理，敏同学协助确认"),
                 ("甲检查乙发送", "乙发送甲检查", "改成乙发送甲检查"),
                 ("小李检查小王发送", "小赵检查小刘发送", "改成小赵检查小刘发送"),
                 ("甲" * 33, "乙", "改成乙"), ("甲", "乙" * 9, "改成" + "乙" * 9),
                 ("说明" * 48 + "甲", "说明" * 48 + "乙", "改成" + "说明" * 48 + "乙")]
        for before, after, evidence in cases:
            with self.subTest(before=before), self.assertRaises(ValueError):
                e.apply_recorded_edits(before + "。" + evidence, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": "correction", "evidence": evidence}
                ]}), editing_prompt_version=3)

    def test_v3_source_correction_cannot_damage_technical_characters(self):
        for before, after in [("foo_bar", "foobar"), ("git --hard", "git hard"), ("/tmp/file", "tmp/file"),
                              ("main.swift", "mainswift"), ("10:30", "1030"), ("A+B", "AB")]:
            evidence = "改成" + after
            with self.subTest(before=before), self.assertRaises(ValueError):
                e.apply_recorded_edits(before + "。" + evidence, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": "correction", "evidence": evidence}
                ]}), editing_prompt_version=3)

    def test_v3_newlines_and_paragraph_word_membership_cannot_be_changed(self):
        for newline in ["\n", "\r", "\r\n", "\v", "\f", "\x85", "\u2028", "\u2029"]:
            for before, after in [("甲" + newline + "乙丙", "甲乙丙"), ("甲" + newline + "乙丙", "甲乙" + newline + "丙"),
                                  ("甲乙丙", "甲" + newline + "乙丙")]:
                with self.subTest(newline=repr(newline), before=before), self.assertRaises(ValueError):
                    e.apply_recorded_edits(before, json.dumps({"edits": [
                        {"before": before, "after": after, "kind": "punctuation"}
                    ]}), editing_prompt_version=3)
        for before, after, kind in [("我\r\n我我今天", "我我\r\n今天", "stutter"),
                                   ("甲\r\n乙丙，不对", "甲乙\r\n丙", "correction"),
                                   ("小李\r\n负责检查", "小赵负责\r\n检查", "correction"),
                                   ("按装\r\n软件", "安\r\n装软件", "word")]:
            evidence = "改由小赵负责检查"
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                e.apply_recorded_edits(before + "。" + evidence, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": kind, "evidence": evidence}
                ]}), editing_prompt_version=3)

    def test_v3_preserves_paragraphs_and_symbol_punctuation_support_without_rewriting_old_versions(self):
        before, after, evidence = "小李负责\n检查重复报名", "小赵负责\n检查重复报名", "重复报名检查改由小赵来做"
        self.assertEqual(e.apply_recorded_edits(before + "。\n\n" + evidence, json.dumps({"edits": [
            {"before": before, "after": after, "kind": "correction", "evidence": evidence}
        ]}), editing_prompt_version=3), after + "。\n\n" + evidence)
        command = "swift build短横线c release第三执行"
        self.assertEqual(e.apply_recorded_edits(command, json.dumps({"edits": [
            {"before": command, "after": "swift build -c release，第三执行", "kind": "symbol"}
        ]}), editing_prompt_version=3), "swift build -c release，第三执行")
        for version in (1, 2):
            before, after = "甲\r\n乙丙", "甲乙\r\n丙"
            self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [
                {"before": before, "after": after, "kind": "punctuation"}
            ]}), editing_prompt_version=version), after)
            source = "预算一万六，不对，一万五。"
            self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [
                {"before": source, "after": "预算一万五。", "kind": "correction"}
            ]}), editing_prompt_version=version), "预算一万五。")

    def test_v3_source_correction_report_requires_real_empty_confirmation_and_valid_evidence(self):
        report, receipts = self.reviewed_light_report("correction")
        self.text = "小李负责检查。" + "其他事项保持。" * 40 + "检查改由小赵来做。"
        self.inputs[0].update(spoken_input=self.text, segment_texts=[self.text])
        row = report["cases"][0]
        row.update(spoken_input=self.text, pre_resolution_canonical_input=self.text, canonical_input=self.text)
        edit = {"before": "小李负责检查", "after": "小赵负责检查", "kind": "correction", "evidence": "检查改由小赵来做"}
        row["stage_responses"][0]["response_text"] = json.dumps({"edits": [edit]})
        row["model_output"] = e.apply_recorded_edits(self.text, row["stage_responses"][0]["response_text"], editing_prompt_version=3)
        row["stage_responses"][0]["request_payload"] = self.payload("light")
        payload = json.loads(self.payload("light", row["model_output"]))
        payload["changes"] = [{"removed": "李", "inserted": "赵"}]
        row["stage_responses"][1]["request_payload"] = json.dumps(payload)
        receipts[0]["response_text_sha256"] = e.legacy.sha256_text(row["stage_responses"][0]["response_text"])
        self.upgrade_report_to_v3(report)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        bad = copy.deepcopy(report)
        bad["cases"][0]["stage_responses"] = bad["cases"][0]["stage_responses"][:1]
        bad["cases"][0].update(llm_call_count=1, llm_attempt_count=1)
        self.assertTrue(self.check(bad, receipts[:1], "light")[0])
        edit["evidence"] = "源文没有的改由小赵"
        row["stage_responses"][0]["response_text"] = json.dumps({"edits": [edit]})
        receipts[0]["response_text_sha256"] = e.legacy.sha256_text(row["stage_responses"][0]["response_text"])
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_independent_six_joint_segment_forgery_counterexamples_are_rejected(self):
        for mode in ["light", "standard"]:
            report, receipts = self.report(mode)
            self.upgrade_report_to_v3(report)
            variants = [
                [{"id": "forged-only", "text": self.text}],
                [{"id": "s1", "text": self.text[:1]}, {"id": "s2", "text": self.text[1:]}],
                [{"id": "forged-0", "text": self.inputs[0]["segment_texts"][0]},
                 {"id": "forged-1", "text": self.inputs[0]["segment_texts"][1]}],
            ]
            self.assertEqual(self.check(report, receipts, mode), ([], []))
            for replacement in variants:
                changed = copy.deepcopy(report)
                changed["cases"][0]["canonical_segments"] = replacement
                for stage in changed["cases"][0]["stage_responses"]:
                    payload = json.loads(stage["request_payload"])
                    payload["source_segments"] = replacement
                    stage["request_payload"] = json.dumps(payload)
                failures, _ = self.check(changed, receipts, mode)
                self.assertTrue(any("冻结输入的确定性构造" in failure for failure in failures), (mode, replacement))

    def test_frozen_envelope_preserves_real_boundaries_and_final_paragraph_fallback(self):
        item = copy.deepcopy(self.inputs[0])
        item.update(spoken_input="第一段。\n\n目标用户是老师。", segment_texts=["第一段。", "目标用户是老师。"])
        canonical, segments = e.frozen_input_envelope(item)
        self.assertEqual(canonical, item["spoken_input"])
        self.assertEqual(segments, [{"id": "s1", "text": item["spoken_input"]}])
        item["segment_texts"] = ["第一段。\n\n", "目标用户是老师。"]
        self.assertEqual(e.frozen_input_envelope(item)[1], [
            {"id": "s1", "text": "第一段。\n\n"}, {"id": "s2", "text": "目标用户是老师。"}
        ])

    def test_frozen_terminology_mapping_and_cross_segment_partition_follow_production(self):
        cases = [
            (["试用 Type less。", "再确认。"], ["试用 Typeless。", "再确认。"]),
            (["试用 TYPE-LESS。", "再确认。"], ["试用 Typeless。", "再确认。"]),
            (["Type ", "less"], ["Type", "less"]),
            (["👨‍👩‍👧‍👦Type ", "less"], ["👨‍👩‍👧‍👦Type", "less"]),
        ]
        for raw, canonical in cases:
            item = copy.deepcopy(self.inputs[0])
            item.update(spoken_input="".join(raw), segment_texts=raw,
                        preconditions=["术语库中已确认 Type less → Typeless"])
            self.assertEqual(e.frozen_input_envelope(item), ("".join(canonical), [
                {"id": f"s{index}", "text": text} for index, text in enumerate(canonical, 1)
            ]), raw)
        self.assertEqual(e.composed_characters("e\u0301👍🏽\r\n甲"), ("e\u0301", "👍🏽", "\r\n", "甲"))
        self.assertEqual(e.applying_fixture_terminology("A B", ["已确认 A B → B C", "已确认 B C → D E"]), "B C")

    def test_v3_full_report_accepts_frozen_terminology_and_final_text_fallback(self):
        for raw, spoken, preconditions, canonical, segments in [
            (["試用 TYPE-LESS。", "再确认。"], "試用 TYPE-LESS。再确认。", ["已确认 Type less → Typeless"],
             "試用 Typeless。再确认。", [{"id": "s1", "text": "試用 Typeless。"}, {"id": "s2", "text": "再确认。"}]),
            (["第一段。", "目标用户是老师。"], "第一段。\n\n目标用户是老师。", [],
             "第一段。\n\n目标用户是老师。", [{"id": "s1", "text": "第一段。\n\n目标用户是老师。"}]),
        ]:
            self.text = spoken
            self.inputs[0].update(spoken_input=spoken, segment_texts=raw, preconditions=preconditions)
            report, receipts = self.report("standard")
            self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 3
            row = report["cases"][0]
            row.update(segment_count=len(raw), canonical_input=canonical, pre_resolution_canonical_input=canonical,
                       canonical_segments=segments, model_output=canonical)
            row["stage_responses"][0]["response_text"] = canonical
            receipts[0]["response_text_sha256"] = e.legacy.sha256_text(canonical)
            for index, stage in enumerate(row["stage_responses"]):
                payload = json.loads(stage["request_payload"])
                payload.update(schema_version=3, canonical_text=canonical, source_segments=segments)
                if index:
                    payload["draft_text"] = canonical
                stage["request_payload"] = json.dumps(payload)
            self.assertEqual(self.check(report, receipts, "standard"), ([], []), raw)

    def test_context_mapping_cannot_justify_jointly_renamed_original_segment_ids(self):
        report, receipts = self.mapped_context_report()
        self.upgrade_report_to_v3(report)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        row = report["cases"][0]
        replacement = [{"id": "forged-1", "text": row["canonical_segments"][0]["text"]},
                       {"id": "forged-2", "text": row["canonical_segments"][1]["text"]}]
        row["canonical_segments"] = replacement
        row["resolved_entities"][0]["source_segment_ids"] = ["forged-1"]
        payload = json.loads(row["stage_responses"][0]["request_payload"])
        payload["source_segments"] = replacement
        row["stage_responses"][0]["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_independent_symbol_token_join_counterexamples_and_valid_punctuation(self):
        for before, after in [("a点b c", "a.bc"), ("v点2 api", "v.2api")]:
            with self.subTest(before=before), self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": "symbol"}
                ]}), editing_prompt_version=3)
        for before, after, kind in [("a.b c", "a.bc", "punctuation"), ("v.2 api", "v.2api", "punctuation")]:
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [
                    {"before": before, "after": after, "kind": kind}
                ]}), editing_prompt_version=3)
        for before, after in [("a点b c", "a.b，c"), ("v点2 api", "v.2，api")]:
            self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [
                {"before": before, "after": after, "kind": "symbol"}
            ]}), editing_prompt_version=3), after)

    def test_stage_order_and_full_review_cannot_be_skipped(self):
        report, receipts = self.report("standard")
        report["cases"][0]["stage_responses"].reverse()
        self.assertTrue(self.check(report, receipts, "standard")[0])
        report, receipts = self.report("standard")
        report["cases"][0]["stage_responses"].pop()
        report["cases"][0].update(llm_call_count=1, llm_attempt_count=1)
        self.assertTrue(self.check(report, receipts[:1], "standard")[0])

    def v4_report(self, source, *, mode="light", initial_edits=None, reviews=()):
        self.text = source
        self.inputs[0].update(spoken_input=source, segment_texts=[source])
        report, old_receipts = self.report(mode)
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 4
        row = report["cases"][0]
        template = copy.deepcopy(row["stage_responses"][0])
        row["stage_responses"] = []
        row["repair_attempt_count"] = 0
        receipts = []
        draft = source
        documents = [source if mode == "standard" else {"edits": initial_edits or []}, *reviews]
        for index, response in enumerate(documents):
            payload = json.loads(self.payload(mode, draft if index else None))
            payload.update(schema_version=4, source_segments=[{"id": "s1", "text": source}])
            if index:
                payload["changes"] = [{"removed": source[a:b], "inserted": c}
                                      for a, b, c in e.actual_modifications(source, draft, 0)]
            stage = copy.deepcopy(template)
            stage.update(attempt_ordinal=index + 1, task=("voicePolishAnalyze" if index else
                         "voicePolishFast" if mode == "light" else "voicePolishRender"),
                         request_payload=json.dumps(payload, ensure_ascii=False),
                         response_text=response if isinstance(response, str) else json.dumps(response, ensure_ascii=False))
            row["stage_responses"].append(stage)
            receipt = copy.deepcopy(old_receipts[0])
            receipt.update(request_ordinal=index + 1, llm_task=stage["task"],
                           provider_response_id=f"unit-test-only-v4-{index + 1}",
                           response_text_sha256=e.legacy.sha256_text(stage["response_text"]),
                           request_binding_sha256=e.legacy.provider_request_binding_sha256(self.nonce, "fixture-01", index + 1, "e" * 64))
            receipts.append(receipt)
            if mode == "light" or index:
                if index and response["edits"]:
                    row["repair_attempt_count"] += 1
                draft = e.apply_recorded_edits(draft, json.dumps({"edits": response["edits"]}),
                    editing_prompt_version=4 if mode == "light" else None,
                    original_source=source, allows_reviewed_directives=True)
        row.update(model_output=draft, llm_call_count=len(documents), llm_attempt_count=len(documents))
        return report, receipts

    def test_v4_real_mislabeled_mechanical_combinations_and_historical_replay(self):
        cases = [
            ("嗯我今天大概七点半到你们不用等我吃饭先吃就行", "我今天大概七点半到，你们不用等我吃饭，先吃就行。"),
            ("部署要做三步第一跑swift test第二跑swift build短横线c release第三执行scripts斜杠package短横线app点sh等一下还有一步要检查codesign所以一共四步最后再启动应用", "部署要做三步：第一，跑 swift test；第二，跑 swift build -c release；第三，执行 scripts/package-app.sh。等一下，还有一步要检查 codesign，所以一共四步，最后再启动应用。"),
            ("嗯我我今天跑swift build短横线c release然后看结果", "我今天跑 swift build -c release，然后看结果。")]
        for before, after in cases:
            for kind in ["punctuation", "filler", "symbol", "word", "correction"]:
                edit = {"before": before, "after": after, "kind": kind}
                self.assertEqual(e.v4_requires_semantic_review([edit]), "我我" in before, (before, kind))
                self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4), after)
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [{"before": before, "after": after, "kind": "punctuation"}]}), editing_prompt_version=3)
        report, receipts = self.v4_report(cases[0][0], initial_edits=[{"before": cases[0][0], "after": cases[0][1], "kind": "word"}])
        self.assertEqual(self.check(report, receipts, "light"), ([], []))

    def test_v4_mechanical_proof_rejects_fact_deletion_token_join_and_paragraph_moves(self):
        for before, after in [("嗯a点b c", "a.bc"), ("v点2 api", "v.2api"), ("swift test", "swifttest"),
                              ("swift build短横线c release", "swift build -crelease"),
                              ("嗯明天小李负责发送", "明天发送。"), ("金额1212", "金额12"),
                              ("嗯甲乙\n丙", "甲\n乙丙"), ("甲\r\n乙丙", "甲乙\r\n丙")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertTrue(e.v4_requires_semantic_review([edit]), before)
            with self.assertRaises(ValueError, msg=before):
                e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4)
        for before, after in [("1212", "12"), ("api api", "api"), ("很好，很好", "很好")]:
            self.assertTrue(e.v4_requires_semantic_review([{"before": before, "after": after, "kind": "stutter"}]))

    def test_v4_filler_allows_plain_punctuation_but_preserves_dotfiles_and_embedded_dots(self):
        for before in ["嗯.参数", "嗯:参数"]:
            self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [
                {"before": before, "after": "参数", "kind": "filler"}]}), editing_prompt_version=4), "参数")
        for before, after in [("嗯 .env", "env"), ("嗯 .gitignore", "gitignore"), ("嗯 a.b", "ab")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertTrue(e.v4_requires_semantic_review([edit]))
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4)
        self.assertEqual(e.apply_recorded_edits("嗯 .env然后检查", json.dumps({"edits": [
            {"before": "嗯 .env然后检查", "after": ".env，然后检查。", "kind": "punctuation"}]}), editing_prompt_version=4), ".env，然后检查。")

    def test_v4_filler_exemption_uses_real_left_boundary_and_extra_right_boundary_for_e(self):
        for source, before, after in [("嗯我今天发。", "嗯我今天发。", "我今天发。"),
                                      ("先说，呃今天发。", "呃今天发。", "今天发。"),
                                      ("嗯呃我今天发。", "嗯呃我今天发。", "我今天发。"),
                                      ("额，今天发。", "额，今天发。", "今天发。")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertEqual(e.v4_requires_semantic_review([edit], source), "呃" in before, source)
            self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4), source.replace(before, after))
        for source in ["额外安排复查。", "额度要保留。", "本周额外安排复查。", "金额待定。", "声音嗯要保留。"]:
            removed = "额" if "额" in source else "嗯"
            for kind in ["filler", "punctuation"]:
                edit = {"before": removed, "after": "", "kind": kind}
                self.assertTrue(e.v4_requires_semantic_review([edit], source), (source, kind))
                if kind == "punctuation":
                    with self.assertRaises(ValueError):
                        e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4)
                else:
                    self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4), source.replace(removed, ""))

    def test_v4_narrow_anchors_preserve_adjacent_real_technical_token_boundaries(self):
        for source, before, after in [("运行swift test", " ", ""), ("调用api", "ap", "ap "),
                                      ("运行swift test", "t ", "t"), ("使用.env", ".", ""), ("使用a.b", ".", "")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertTrue(e.v4_requires_semantic_review([edit], source), source)
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4)

    def test_v4_adjacent_repeated_name_or_stutter_requires_semantic_review_even_when_mislabeled(self):
        for before, after in [("莉莉负责审核。", "莉负责审核。"), ("宝宝今天到了。", "宝今天到了。"), ("我我今天发。", "我今天发。")]:
            edit = {"before": before, "after": after, "kind": "punctuation"}
            self.assertTrue(e.v4_requires_semantic_review([edit], before))
            self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4), after)
            report, receipts = self.v4_report(before, initial_edits=[edit])
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v4_wu_and_e_deletions_are_applicable_previews_but_never_filler_exemptions(self):
        for before, after in [("唔可以退款", "可以退款"), ("唔可以取消订单", "可以取消订单"),
                              ("呃钱", "钱"), ("先说，呃今天发。", "先说，今天发。")]:
            for kind in ("filler", "punctuation"):
                edit = {"before": before, "after": after, "kind": kind}
                self.assertTrue(e.v4_requires_semantic_review([edit], before), (before, kind))
                self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [edit]}), editing_prompt_version=4), after)
                report, receipts = self.v4_report(before, initial_edits=[edit])
                self.assertTrue(self.check(report, receipts, "light")[0], (before, kind))
        source = "嗯唔可以退款"
        edit = {"before": source, "after": "唔可以退款", "kind": "punctuation"}
        self.assertFalse(e.v4_requires_semantic_review([edit], source))
        self.assertEqual(e.apply_recorded_edits(source, json.dumps({"edits": [edit]}), editing_prompt_version=4), "唔可以退款")

    def test_v4_batch_token_proof_covers_composed_space_deletions_and_mixed_semantic_edits(self):
        spaces = [{"before": "swift ", "after": "swift", "kind": "punctuation"},
                  {"before": " test", "after": "test", "kind": "punctuation"}]
        source = "运行swift  test"
        self.assertTrue(e.v4_requires_semantic_review(spaces, source))
        with self.assertRaises(ValueError):
            e.apply_recorded_edits(source, json.dumps({"edits": spaces}), editing_prompt_version=4)
        with self.assertRaises(ValueError):
            e.apply_recorded_edits("按装后运行swift  test", json.dumps({"edits": [
                {"before": "按装", "after": "安装", "kind": "word"}, *spaces]}), editing_prompt_version=4)
        self.assertEqual(e.apply_recorded_edits("按装后运行swift test", json.dumps({"edits": [
            {"before": "按装", "after": "安装", "kind": "word"},
            {"before": "运行swift test", "after": "运行 swift test。", "kind": "punctuation"}]}), editing_prompt_version=4), "安装后运行 swift test。")

    def test_v4_combined_proof_keeps_unicode_paragraphs_and_rejects_partial_application(self):
        before = "👨‍👩‍👧‍👦，嗯今天用e\u0301看结果👍🏽\r\n再运行scripts斜杠app点sh"
        after = "👨‍👩‍👧‍👦，今天用 e\u0301，看结果👍🏽。\r\n再运行 scripts/app.sh。"
        self.assertEqual(e.apply_recorded_edits(before, json.dumps({"edits": [
            {"before": before, "after": after, "kind": "punctuation"}]}), editing_prompt_version=4), after)
        with self.assertRaises(ValueError):
            e.apply_recorded_edits("嗯今天运行swift test", json.dumps({"edits": [
                {"before": "嗯今天", "after": "今天，", "kind": "punctuation"},
                {"before": "swift test", "after": "swifttest", "kind": "punctuation"}]}), editing_prompt_version=4)

    def test_v4_unpunctuated_directive_uses_actual_short_deletion_and_explicit_review_permission(self):
        source, after = "帮我整理一下明天小李负责发材料。", "明天小李负责发材料。"
        response = json.dumps({"edits": [{"before": source, "after": after, "kind": "directive"}]})
        self.assertTrue(e.v4_requires_semantic_review(json.loads(response)["edits"]))
        with self.assertRaises(ValueError):
            e.apply_recorded_edits(source, response, editing_prompt_version=4)
        self.assertEqual(e.apply_recorded_edits(source, response, editing_prompt_version=4, allows_reviewed_directives=True), after)
        for before, output in [("整理" * 17 + "正文", "正文"), ("请整理甲并润色乙", "甲乙"),
                               ("帮我整理甲乙", "乙甲"), ("帮我整理正文", "新正文"), ("帮我整理。", "。")]:
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [{"before": before, "after": output, "kind": "directive"}]}),
                    editing_prompt_version=4, allows_reviewed_directives=True)

    def test_v4_reviewed_source_correction_can_anchor_punctuated_draft_without_merging_tokens(self):
        source = "阿文负责复查重复报名\n重复报名的复查改由阿宁来做"
        draft = "阿文负责复查重复报名。\n重复报名的复查改由阿宁来做。"
        edits = [{"before": "阿文负责复查重复报名。", "after": "阿宁负责复查重复报名。", "kind": "correction",
                  "evidence": "重复报名的复查改由阿宁来做"}]
        self.assertEqual(e.apply_recorded_edits(draft, json.dumps({"edits": edits}), editing_prompt_version=4,
            original_source=source), "阿宁负责复查重复报名。\n重复报名的复查改由阿宁来做。")
        with self.assertRaises(ValueError):
            e.apply_recorded_edits(draft, json.dumps({"edits": edits}), editing_prompt_version=3, original_source=source)
        for original, actual in [("阿文负责 api test", "阿文负责 apitest。"), ("阿文负责 a.b c", "阿文负责 a.bc。"),
                                 ("阿文负责\n复查", "阿文负责复查。"), ("阿文负责其他任务", "阿文负责复查。")]:
            evidence = "复查改由阿宁来做"
            with self.assertRaises(ValueError):
                e.apply_recorded_edits(actual, json.dumps({"edits": [{"before": actual,
                    "after": actual.replace("阿文", "阿宁"), "kind": "correction", "evidence": evidence}]}),
                    editing_prompt_version=4, original_source=original + "\n" + evidence)

    def test_v4_source_risk_requires_review_even_when_initial_edits_empty(self):
        for source in ["帮我整理一下明天发。", "给客户回一下材料已收到。", "预算说错改成一万六。"]:
            report, receipts = self.v4_report(source)
            self.assertTrue(self.check(report, receipts, "light")[0], source)
            report, receipts = self.v4_report(source, reviews=[{"source_roles": [], "edits": []}])
            self.assertEqual(self.check(report, receipts, "light"), ([], []), source)

    def test_v4_roles_require_unique_literal_source_quote_and_target_evidence(self):
        source = "帮我整理一下，发给客户。"
        valid = {"source_roles": [{"quote": "帮我整理一下", "role": "current_editor", "target_evidence": "帮我"}], "edits": []}
        self.assertEqual(e.decode_v4_review(json.dumps(valid), source), valid)
        for field, value in [("quote", "不存在"), ("quote", "，"), ("quote", ""),
                             ("quote", "甲" * 193), ("role", "invented"), ("target_evidence", ""),
                             ("target_evidence", "模型推断的对象"), ("target_evidence", "甲" * 193)]:
            changed = copy.deepcopy(valid); changed["source_roles"][0][field] = value
            with self.assertRaises(ValueError, msg=field):
                e.decode_v4_review(json.dumps(changed), source)
        with self.assertRaises(ValueError):
            e.decode_v4_review(json.dumps(valid), source + source)
        changed = copy.deepcopy(valid); changed["source_roles"] *= 2
        with self.assertRaises(ValueError):
            e.decode_v4_review(json.dumps(changed), source)
        with self.assertRaises(ValueError):
            e.decode_v4_review('{"edits":[]}', source)

    def test_v4_current_editor_residue_cannot_pass_empty_review_but_recipient_or_uncertain_can(self):
        source = "帮我整理一下明天发材料。"
        role = {"quote": "帮我整理一下", "role": "current_editor", "target_evidence": "帮我"}
        for mode in ["light", "standard"]:
            report, receipts = self.v4_report(source, mode=mode, reviews=[{"source_roles": [role], "edits": []}])
            self.assertTrue(self.check(report, receipts, mode)[0])
            for value in ["recipient_content", "uncertain"]:
                report, receipts = self.v4_report(source, mode=mode, reviews=[{"source_roles": [{**role, "role": value}], "edits": []}])
                self.assertEqual(self.check(report, receipts, mode), ([], []))

    def repaired_v4_report(self, mode="light"):
        source, output = "帮我整理一下明天小李发材料。", "明天小李发材料。"
        role = {"quote": "帮我整理一下", "role": "current_editor", "target_evidence": "帮我"}
        edit = {"before": source, "after": output, "kind": "directive" if mode == "light" else "content"}
        if mode == "standard": edit["evidence"] = source
        reviews = [{"source_roles": [role], "edits": [edit]}, {"source_roles": [role], "edits": []}]
        return self.v4_report(source, mode=mode, reviews=reviews)

    def test_v4_both_modes_repair_actual_draft_then_confirm_exact_final_draft(self):
        for mode in ["light", "standard"]:
            report, receipts = self.repaired_v4_report(mode)
            self.assertEqual(self.check(report, receipts, mode), ([], []), mode)
            row = report["cases"][0]
            self.assertEqual(row["repair_attempt_count"], 1)
            self.assertEqual(row["llm_attempt_count"], 3)
            self.assertEqual(row["model_output"], "明天小李发材料。")
            self.assertTrue(self.check(report, receipts[:2], mode)[0])

    def test_v4_repair_missing_confirmation_wrong_task_or_nonempty_third_cannot_pass(self):
        for mode in ["light", "standard"]:
            for mutation in ["missing", "nonempty", "wrong_task", "missing_roles", "extra"]:
                report, receipts = self.repaired_v4_report(mode)
                row = report["cases"][0]
                if mutation == "missing":
                    row["stage_responses"].pop(); receipts.pop()
                    row.update(llm_call_count=2, llm_attempt_count=2)
                elif mutation == "nonempty":
                    stage = row["stage_responses"][2]
                    value = json.loads(stage["response_text"])
                    value["edits"] = [{"before": "明天", "after": "后天", "kind": "word"}]
                    stage["response_text"] = json.dumps(value)
                    receipts[2]["response_text_sha256"] = e.legacy.sha256_text(stage["response_text"])
                elif mutation == "missing_roles":
                    row["stage_responses"][2]["response_text"] = '{"edits":[]}'
                    receipts[2]["response_text_sha256"] = e.legacy.sha256_text('{"edits":[]}')
                elif mutation == "wrong_task":
                    row["stage_responses"][2]["task"] = receipts[2]["llm_task"] = "voicePolishFast"
                else:
                    row["stage_responses"].append(copy.deepcopy(row["stage_responses"][-1]))
                    row.update(llm_call_count=4, llm_attempt_count=4)
                self.assertTrue(self.check(report, receipts, mode)[0], (mode, mutation))

    def test_v4_every_review_binds_source_draft_changes_and_original_segments(self):
        for index in [1, 2]:
            for field, value in [("draft_text", "未经来源的稿"), ("canonical_text", "换掉原文"),
                                 ("changes", [{"removed": "不存在", "inserted": ""}]),
                                 ("source_segments", [{"id": "fake", "text": "fake"}])]:
                report, receipts = self.repaired_v4_report()
                stage = report["cases"][0]["stage_responses"][index]
                payload = json.loads(stage["request_payload"]); payload[field] = value
                stage["request_payload"] = json.dumps(payload)
                self.assertTrue(self.check(report, receipts, "light")[0], (index, field))

    def test_v4_failed_local_repair_preserves_attempt_count_and_fallback(self):
        report, receipts = self.v4_report("帮我整理一下明天发材料。", reviews=[{"source_roles": [], "edits": []}])
        row = report["cases"][0]
        invalid = {"source_roles": [], "edits": [{"before": "不存在", "after": "", "kind": "directive"}]}
        row["stage_responses"][1]["response_text"] = json.dumps(invalid)
        receipts[1]["response_text_sha256"] = e.legacy.sha256_text(json.dumps(invalid))
        row.update(fallback_used=True, repair_attempt_count=1, model_output=self.text,
                   hard_validation_codes=["planIntegrityFailure"], failure_reason="validationFailed")
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, []); self.assertTrue(quality)
        row["repair_attempt_count"] = 0
        self.assertTrue(self.check(report, receipts, "light")[0])
        row["repair_attempt_count"] = 1; row["model_output"] = "部分稿"
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v4_timeout_confirmation_keeps_actual_attempt_and_receipt_counts(self):
        report, receipts = self.repaired_v4_report()
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, llm_call_count=2, failure_reason="timeout")
        row["stage_responses"][2].update(status="failed", response_text="", failure_reason="请求超时", latency_milliseconds=400)
        failures, quality = self.check(report, receipts[:2], "light")
        self.assertEqual(failures, []); self.assertTrue(quality)
        self.assertTrue(self.check(report, receipts, "light")[0])
        payload = json.loads(row["stage_responses"][2]["request_payload"])
        payload["draft_text"] = "伪造的失败请求稿"
        row["stage_responses"][2]["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts[:2], "light")[0])

    def upgrade_report_to_v5(self, report, receipts, delivery="direct_reply"):
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 5
        for index, stage in enumerate(report["cases"][0]["stage_responses"]):
            payload = json.loads(stage["request_payload"])
            payload["schema_version"] = 5
            stage["request_payload"] = json.dumps(payload, ensure_ascii=False)
            if index:
                old = json.loads(stage["response_text"])
                value = {"delivery": delivery, "editor_spans": [r["quote"] for r in old["source_roles"]
                            if r["role"] == "current_editor"], "edits": old["edits"]}
                stage["response_text"] = json.dumps(value, ensure_ascii=False)
                receipts[index]["response_text_sha256"] = e.legacy.sha256_text(stage["response_text"])

    def test_v5_minimal_editor_spans_do_not_require_listing_recipient_tasks(self):
        source = "帮我整理成 Prompt。先别开始研究，只整理任务，预算100元。报告要写建议，不能自行增加预算。"
        value = {"delivery": "ai_prompt", "editor_spans": ["帮我整理成 Prompt。", "先别开始研究，只整理任务，"], "edits": []}
        self.assertEqual(e.decode_v5_review(json.dumps(value), source), value)
        self.assertEqual(len(value["editor_spans"]), 2)
        for delivery in ["direct_reply", "ai_prompt", "delegated_task", "other_or_uncertain"]:
            empty = {"delivery": delivery, "editor_spans": [], "edits": []}
            self.assertEqual(e.decode_v5_review(json.dumps(empty), source), empty)

    def test_v5_rejects_real_v4_explanation_schema_and_explanations_as_spans(self):
        source = "帮我整理成 Prompt。先别开始研究，只整理任务，预算100元。报告要写建议，不能自行增加预算。"
        # ec6b2cd / core-sem-11 的真实第二轮解释字段，保持原文作协议反例。
        explanation = "用户此刻要求输入法把本次文字整理成 Prompt，属于写作过程指令。"
        old = {"source_roles": [{"quote": "帮我整理成 Prompt。", "role": "current_editor", "target_evidence": explanation}], "edits": []}
        with self.assertRaises(e.InvalidV5Review):
            e.decode_v5_review(json.dumps(old), source)
        with self.assertRaises(e.InvalidV5Review):
            e.decode_v5_review(json.dumps({"delivery": "ai_prompt", "editor_spans": [explanation], "edits": []}), source)
        for old_field, old_value in [("source_roles", old["source_roles"]), ("target_evidence", explanation)]:
            with self.assertRaises(e.InvalidV5Review):
                e.decode_v5_review(json.dumps({"delivery": "ai_prompt", "editor_spans": [], "edits": [], old_field: old_value}), source)

    def test_v5_requires_exact_top_keys_delivery_and_typed_spans(self):
        valid = {"delivery": "direct_reply", "editor_spans": ["帮我整理"], "edits": []}
        for key in valid:
            bad = dict(valid); del bad[key]
            with self.assertRaises(e.InvalidV5Review): e.decode_v5_review(json.dumps(bad), "帮我整理正文")
        for delivery in ["recipient_content", "", None, 1, [], {}]:
            with self.assertRaises(e.InvalidV5Review):
                e.decode_v5_review(json.dumps({**valid, "delivery": delivery}), "帮我整理正文")
        for spans in [None, "帮我整理", {}, [1], [None], [{"quote": "帮我整理"}]]:
            with self.assertRaises(e.InvalidV5Review):
                e.decode_v5_review(json.dumps({**valid, "editor_spans": spans}), "帮我整理正文")

    def test_v5_spans_require_literal_unique_substantive_source_and_no_duplicates(self):
        for source, spans in [("帮我整理正文", ["不存在"]), ("帮我整理正文", [""]),
                              ("， \t。正文", ["， \t。"]), ("哈哈哈", ["哈哈"]),
                              ("帮我整理正文", ["帮我整理", "帮我整理"]),
                              ("e\u0301é正文", ["e\u0301", "é"]),
                              ("帮我整理正文", ["帮我，整理"])]:
            with self.assertRaises(e.InvalidV5Review, msg=(source, spans)):
                e.decode_v5_review(json.dumps({"delivery": "other_or_uncertain", "editor_spans": spans, "edits": []}), source)

    def test_v5_span_limits_follow_swift_composed_characters_and_64_items(self):
        span = "👨‍👩‍👧‍👦" + "甲" * 191
        self.assertEqual(len(e.composed_characters(span)), 192)
        valid = {"delivery": "other_or_uncertain", "editor_spans": [span], "edits": []}
        self.assertEqual(e.decode_v5_review(json.dumps(valid), span), valid)
        with self.assertRaises(e.InvalidV5Review):
            e.decode_v5_review(json.dumps({**valid, "editor_spans": [span + "乙"]}), span + "乙")
        spans = [f"标记{i:03d}。" for i in range(65)]
        source = "".join(spans)
        valid["editor_spans"] = spans[:64]
        self.assertEqual(e.decode_v5_review(json.dumps(valid), source), valid)
        with self.assertRaises(e.InvalidV5Review):
            e.decode_v5_review(json.dumps({**valid, "editor_spans": spans}), source)

    def test_v5_editor_spans_remain_unapplied_after_punctuation_or_whitespace_changes(self):
        value = e.decode_v5_review(json.dumps({"delivery": "direct_reply", "editor_spans": ["帮我整理一下"], "edits": []}),
                                   "帮我整理一下明天发材料。")
        self.assertTrue(e.v4_contains_editor_instruction(value, "帮我，整理一下。明天发材料。", 5))
        self.assertTrue(e.v4_contains_editor_instruction(value, "帮 我整理\n一下。明天发材料。", 5))
        self.assertFalse(e.v4_contains_editor_instruction(value, "明天发材料。", 5))
        for mode in ["light", "standard"]:
            report, receipts = self.v4_report("帮我整理一下明天发材料。", mode=mode, reviews=[{"source_roles": [], "edits": []}])
            self.upgrade_report_to_v5(report, receipts)
            stage = report["cases"][0]["stage_responses"][1]
            stage["response_text"] = json.dumps(value)
            receipts[1]["response_text_sha256"] = e.legacy.sha256_text(stage["response_text"])
            self.assertTrue(self.check(report, receipts, mode)[0])
            row = report["cases"][0]
            row.update(fallback_used=True, model_output=self.text, hard_validation_codes=["planIntegrityFailure"], failure_reason="validationFailed")
            self.assertEqual(self.check(report, receipts, mode)[0], [])

    def test_v5_two_modes_keep_same_repair_then_confirmation_chain(self):
        for mode in ["light", "standard"]:
            report, receipts = self.repaired_v4_report(mode)
            self.upgrade_report_to_v5(report, receipts)
            self.assertEqual(self.check(report, receipts, mode), ([], []), mode)
            row = report["cases"][0]
            self.assertEqual((row["repair_attempt_count"], row["llm_attempt_count"]), (1, 3))
            for field, value in [("model_output", "不是补丁实际稿"), ("repair_attempt_count", 0)]:
                changed = copy.deepcopy(report); changed["cases"][0][field] = value
                self.assertTrue(self.check(changed, receipts, mode)[0])
            self.assertTrue(self.check(report, receipts[:2], mode)[0])

    def test_v5_source_risk_empty_initial_edits_still_requires_review_and_mechanical_does_not(self):
        report, receipts = self.v4_report("帮我整理一下明天发材料。")
        self.upgrade_report_to_v5(report, receipts)
        self.assertTrue(self.check(report, receipts, "light")[0])
        source = "嗯我今天到"
        report, receipts = self.v4_report(source, initial_edits=[{"before": source, "after": "我今天到。", "kind": "punctuation"}])
        self.upgrade_report_to_v5(report, receipts)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))

    def test_v5_no_extra_repairs_or_permission_expansion_and_third_must_be_empty(self):
        source = "运行swift test"
        with self.assertRaises(ValueError):
            e.apply_recorded_edits(source, json.dumps({"edits": [{"before": " ", "after": "", "kind": "punctuation"}]}), editing_prompt_version=5)
        for mode in ["light", "standard"]:
            for mutation in ["missing_third", "nonempty_third", "old_third", "fourth"]:
                report, receipts = self.repaired_v4_report(mode); self.upgrade_report_to_v5(report, receipts)
                row = report["cases"][0]
                if mutation == "missing_third":
                    row["stage_responses"].pop(); receipts.pop(); row.update(llm_call_count=2, llm_attempt_count=2)
                elif mutation == "fourth":
                    row["stage_responses"].append(copy.deepcopy(row["stage_responses"][-1])); row.update(llm_call_count=4, llm_attempt_count=4)
                else:
                    value = ({"source_roles": [], "edits": []} if mutation == "old_third" else
                             {"delivery": "direct_reply", "editor_spans": [], "edits": [{"before": "明天", "after": "后天", "kind": "word"}]})
                    row["stage_responses"][2]["response_text"] = json.dumps(value)
                    receipts[2]["response_text_sha256"] = e.legacy.sha256_text(json.dumps(value))
                self.assertTrue(self.check(report, receipts, mode)[0], (mode, mutation))

    def test_v5_review_parse_failure_uses_invalid_structured_response_not_legacy_plan_failure(self):
        for mode in ["light", "standard"]:
            report, receipts = self.v4_report("帮我整理一下明天发。", mode=mode, reviews=[{"source_roles": [], "edits": []}])
            self.upgrade_report_to_v5(report, receipts)
            row = report["cases"][0]
            row["stage_responses"][1]["response_text"] = '{"source_roles":[],"edits":[]}'
            receipts[1]["response_text_sha256"] = e.legacy.sha256_text(row["stage_responses"][1]["response_text"])
            row.update(fallback_used=True, model_output=self.text, failure_reason="validationFailed", hard_validation_codes=["invalidStructuredResponse"])
            failures, quality = self.check(report, receipts, mode)
            self.assertEqual(failures, []); self.assertTrue(quality)
            row["hard_validation_codes"] = ["planIntegrityFailure"]
            self.assertTrue(self.check(report, receipts, mode)[0])

    def test_v5_every_review_keeps_canonical_segments_and_actual_draft_binding(self):
        for index in [1, 2]:
            for field, value in [("canonical_text", "伪造来源"), ("draft_text", "伪造实际稿"),
                                 ("source_segments", [{"id": "other", "text": "改写原分段"}]),
                                 ("changes", [{"removed": "不存在", "inserted": ""}])]:
                report, receipts = self.repaired_v4_report(); self.upgrade_report_to_v5(report, receipts)
                stage = report["cases"][0]["stage_responses"][index]
                payload = json.loads(stage["request_payload"]); payload[field] = value
                stage["request_payload"] = json.dumps(payload)
                self.assertTrue(self.check(report, receipts, "light")[0], (index, field))

    def test_v5_direct_keeps_zero_repair_audit_without_review_protocol_fields(self):
        self.expected["editing_prompt_version"] = 5
        report, receipts = self.report("direct")
        row = report["cases"][0]; row["repair_attempt_count"] = 0
        self.assertEqual(self.check(report, receipts, "direct"), ([], []))
        for value in [None, "0", 1, False, 0.0]:
            row["repair_attempt_count"] = value
            self.assertTrue(self.check(report, receipts, "direct")[0])

    def focus_payload(self, source, draft, located, order):
        """测试作者给定变化、范围与优先顺序；不调用被测排序或另做 diff。"""
        old, new = e.composed_characters(source), e.composed_characters(draft)
        focus = []
        for index in order:
            _, _, a, b, c, d = located[index]
            focus.append({"change_index": index, "source_start": a, "source_end": b,
                          "draft_start": c, "draft_end": d,
                          "source_context": "".join(old[max(0, a - 20):b + 20]),
                          "draft_context": "".join(new[max(0, c - 20):d + 20])})
        return {"changes": [{"removed": row[0], "inserted": row[1]} for row in located],
                "review_focus": focus, "review_focus_total": len(order)}

    def repaired_v6_report(self, mode="light"):
        report, receipts = self.repaired_v4_report(mode)
        self.upgrade_report_to_v5(report, receipts)
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 6
        for index, stage in enumerate(report["cases"][0]["stage_responses"]):
            payload = json.loads(stage["request_payload"])
            payload["schema_version"] = 6
            if index:
                located = [] if index == 1 else [("帮我整理一下", "", 0, 6, 0, 0)]
                payload.update(self.focus_payload(self.text, payload["draft_text"], located, [] if index == 1 else [0]))
            stage["request_payload"] = json.dumps(payload, ensure_ascii=False)
        return report, receipts

    def test_v6_unicode_whitespace_and_ascii_technical_symbols_stay_distinct(self):
        # 2026-09-11 root 实际 Swift Character probe：首标量为空白的组合字仍为空白。
        self.assertEqual(e.v6_content_character_count(" \u0301\r\n\u0085\u00a0\u2028\u2000，。！？；：、"), 0)
        for text in ["\u001c", "\u001d", "\u001e", "\u001f", "\u200b", ".", ":", "/", "+", "=", "!", "😀", "e\u0301"]:
            self.assertEqual(e.v6_content_character_count(text), 1, repr(text))

    def test_v6_focus_prioritizes_substantive_removal_then_size_then_original_index(self):
        source, draft = "aKbbLcccM", "KXXXLYYM非常长新增"
        located = [("a", "", 0, 1, 0, 0), ("bb", "XXX", 2, 4, 1, 4),
                   ("ccc", "YY", 5, 8, 5, 7), ("", "非常长新增", 9, 9, 8, 13)]
        payload = self.focus_payload(source, draft, located, [1, 2, 0, 3])
        self.assertTrue(e.complete_v6_review_focus(source, draft, payload))
        for order in [[2, 1, 0, 3], [3, 1, 2, 0], [0, 1, 2, 3]]:
            bad = self.focus_payload(source, draft, located, order)
            self.assertFalse(e.complete_v6_review_focus(source, draft, bad), order)

    def test_v6_chinese_layout_changes_excluded_but_ascii_and_emoji_removals_kept(self):
        source, draft = "甲，乙:丙/丁😀戊", "甲乙丙丁戊"
        located = [("，", "", 1, 2, 1, 1), (":", "", 3, 4, 2, 2),
                   ("/", "", 5, 6, 3, 3), ("😀", "", 7, 8, 4, 4)]
        payload = self.focus_payload(source, draft, located, [1, 2, 3])
        self.assertTrue(e.complete_v6_review_focus(source, draft, payload))
        for order in [[0, 1, 2, 3], [1, 2], []]:
            self.assertFalse(e.complete_v6_review_focus(source, draft, self.focus_payload(source, draft, located, order)))

    def test_v6_same_text_has_empty_focus_but_requires_explicit_array_and_zero(self):
        payload = self.focus_payload("原文", "原文", [], [])
        self.assertTrue(e.complete_v6_review_focus("原文", "原文", payload))
        for field in ["changes", "review_focus", "review_focus_total"]:
            bad = dict(payload); del bad[field]
            self.assertFalse(e.complete_v6_review_focus("原文", "原文", bad), field)
            bad[field] = None
            self.assertFalse(e.complete_v6_review_focus("原文", "原文", bad), field)
        for total in [True, False, 0.0, "0", -1, 1]:
            self.assertFalse(e.complete_v6_review_focus("原文", "原文", {**payload, "review_focus_total": total}))

    def test_v6_focus_is_not_permission_to_omit_unfocused_layout_changes(self):
        source, draft = "甲 乙", "甲乙，"
        located = [(" ", "", 1, 2, 1, 1), ("", "，", 3, 3, 2, 3)]
        payload = self.focus_payload(source, draft, located, [])
        self.assertTrue(e.complete_v6_review_focus(source, draft, payload))
        for changes in [[], payload["changes"][:1], list(reversed(payload["changes"]))]:
            self.assertFalse(e.complete_v6_review_focus(source, draft, {**payload, "changes": changes}))

    def test_v6_many_ambiguous_unfocused_blocks_still_explain_whole_tail(self):
        payload = {"changes": [{"removed": " ", "inserted": ""}] * 200,
                   "review_focus": [], "review_focus_total": 0}
        self.assertTrue(e.complete_v6_review_focus(" " * 400, " " * 200, payload))
        self.assertFalse(e.complete_v6_review_focus(" " * 400 + "甲", " " * 200, payload))

    def test_v6_repeated_text_accepts_valid_tie_positions_but_not_mixed_paths(self):
        source, draft = "甲甲甲", "甲"
        left = self.focus_payload(source, draft, [("甲", "", 0, 1, 0, 0), ("甲", "", 1, 2, 0, 0)], [0, 1])
        right = self.focus_payload(source, draft, [("甲", "", 1, 2, 1, 1), ("甲", "", 2, 3, 1, 1)], [0, 1])
        self.assertTrue(e.complete_v6_review_focus(source, draft, left))
        self.assertTrue(e.complete_v6_review_focus(source, draft, right))
        # 两个引用分别来自可成立的整条路径；组合后顺序、稿件落点不能共同成立。
        mixed = copy.deepcopy(left); mixed["review_focus"][0] = right["review_focus"][0]
        self.assertFalse(e.complete_v6_review_focus(source, draft, mixed))
        duplicate = copy.deepcopy(left); duplicate["review_focus"][1].update(source_start=0, source_end=1)
        self.assertFalse(e.complete_v6_review_focus(source, draft, duplicate))

    def test_v6_repeated_sentence_cannot_bind_another_occurrence_with_wrong_draft_position(self):
        source, draft = "甲请保留。乙请保留。丙", "甲请保留。乙丙"
        payload = self.focus_payload(source, draft, [("请保留。", "", 6, 10, 6, 6)], [0])
        self.assertTrue(e.complete_v6_review_focus(source, draft, payload))
        wrong = copy.deepcopy(payload); wrong["review_focus"][0].update(source_start=1, source_end=5)
        self.assertFalse(e.complete_v6_review_focus(source, draft, wrong))

    def test_v6_ranges_use_characters_and_context_keeps_exact_source_bytes(self):
        source, draft = "e\u0301👍🏽\r\n甲乙", "é👍🏽\r\n乙"
        payload = self.focus_payload(source, draft, [("甲", "", 3, 4, 3, 3)], [0])
        self.assertTrue(e.complete_v6_review_focus(source, draft, payload))
        self.assertEqual(payload["review_focus"][0]["source_context"], source)
        for values in [{"source_start": 5, "source_end": 6}, {"draft_start": 4, "draft_end": 4},
                       {"source_context": source.replace("e\u0301", "é")}, {"draft_context": source}]:
            bad = copy.deepcopy(payload); bad["review_focus"][0].update(values)
            self.assertFalse(e.complete_v6_review_focus(source, draft, bad), values)
        equivalent = self.focus_payload("e\u0301甲", "甲", [("é", "", 0, 1, 0, 0)], [0])
        self.assertTrue(e.complete_v6_review_focus("e\u0301甲", "甲", equivalent))

    def test_v6_context_has_whole_changed_span_and_exact_twenty_character_sides(self):
        removed = "应完整保留差异正文" * 8
        source, draft = "甲" * 25 + removed + "乙" * 25, "甲" * 25 + "乙" * 25
        payload = self.focus_payload(source, draft, [(removed, "", 25, 25 + len(removed), 25, 25)], [0])
        item = payload["review_focus"][0]
        self.assertEqual(item["source_context"], "甲" * 20 + removed + "乙" * 20)
        self.assertEqual(item["draft_context"], "甲" * 20 + "乙" * 20)
        self.assertTrue(e.complete_v6_review_focus(source, draft, payload))
        for key in ["source_context", "draft_context"]:
            for value in [item[key][1:], "甲" + item[key], "只保留解释", None, 1]:
                bad = copy.deepcopy(payload); bad["review_focus"][0][key] = value
                self.assertFalse(e.complete_v6_review_focus(source, draft, bad), (key, value))

    def test_v6_focus_range_fields_reject_wrong_types_reversed_ranges_and_extra_keys(self):
        source, draft = "甲乙", "乙"
        payload = self.focus_payload(source, draft, [("甲", "", 0, 1, 0, 0)], [0])
        for key in ["change_index", "source_start", "source_end", "draft_start", "draft_end"]:
            for value in [False, True, 0.0, "0", None, -1, 3]:
                bad = copy.deepcopy(payload); bad["review_focus"][0][key] = value
                self.assertFalse(e.complete_v6_review_focus(source, draft, bad), (key, value))
        for item in [None, [], {}, {**payload["review_focus"][0], "role": "current_editor"}]:
            self.assertFalse(e.complete_v6_review_focus(source, draft, {**payload, "review_focus": [item]}))

    def test_v6_cap_preserves_total_ranking_and_all_unselected_changes(self):
        source, draft, located = "", "", []
        for i in range(17):
            located.append(("甲", "乙", len(source), len(source) + 1, len(draft), len(draft) + 1))
            source += "甲" + chr(0x4E10 + i); draft += "乙" + chr(0x4E10 + i)
        payload = self.focus_payload(source, draft, located, list(range(16)))
        payload["review_focus_total"] = 17
        self.assertTrue(e.complete_v6_review_focus(source, draft, payload))
        for mutation in ["total", "missing_focus", "seventeenth", "missing_change", "swap_last"]:
            bad = copy.deepcopy(payload)
            if mutation == "total": bad["review_focus_total"] = 16
            elif mutation == "missing_focus": bad["review_focus"].pop()
            elif mutation == "seventeenth": bad["review_focus"] = self.focus_payload(source, draft, located, list(range(17)))["review_focus"]
            elif mutation == "missing_change": bad["changes"].pop()
            else: bad["review_focus"][-1] = self.focus_payload(source, draft, located, [16])["review_focus"][0]
            self.assertFalse(e.complete_v6_review_focus(source, draft, bad), mutation)

    def test_v6_full_changes_keep_original_schema_order_and_nonempty_difference(self):
        payload = self.focus_payload("甲乙", "乙", [("甲", "", 0, 1, 0, 0)], [0])
        for changes in [None, {}, [None], [{"removed": "甲"}], [{"removed": 1, "inserted": ""}],
                        [{"removed": "甲", "inserted": "", "source_start": 0}], [{"removed": "", "inserted": ""}]]:
            self.assertFalse(e.complete_v6_review_focus("甲乙", "乙", {**payload, "changes": changes}))

    def test_v6_each_mode_keeps_original_stage_budget_and_v5_response_schema(self):
        for mode in ["light", "standard"]:
            report, receipts = self.repaired_v6_report(mode)
            self.assertEqual(self.check(report, receipts, mode), ([], []), mode)
            row = report["cases"][0]
            self.assertEqual((row["repair_attempt_count"], row["llm_attempt_count"]), (1, 3))
            self.assertTrue(self.check(report, receipts[:2], mode)[0])
            stage = row["stage_responses"][2]
            stage["response_text"] = '{"delivery":"direct_reply","editor_spans":[],"edits":[],"review_focus":[]}'
            receipts[2]["response_text_sha256"] = e.legacy.sha256_text(stage["response_text"])
            self.assertTrue(self.check(report, receipts, mode)[0])
        report, receipts = self.report("direct")
        report["cases"][0]["repair_attempt_count"] = 0
        self.assertEqual(self.check(report, receipts, "direct"), ([], []))

    def test_v6_initial_focus_fields_must_be_absent_or_null_even_when_request_fails(self):
        report, receipts = self.repaired_v6_report()
        for key in ["review_focus", "review_focus_total"]:
            for value in [[], 0, {}, False]:
                changed = copy.deepcopy(report); stage = changed["cases"][0]["stage_responses"][0]
                payload = json.loads(stage["request_payload"]); payload[key] = value
                stage["request_payload"] = json.dumps(payload)
                self.assertTrue(self.check(changed, receipts, "light")[0])
        stage = report["cases"][0]["stage_responses"][0]
        payload = json.loads(stage["request_payload"]); payload.update(review_focus=None, review_focus_total=None)
        stage["request_payload"] = json.dumps(payload)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        row = report["cases"][0]; row.update(stage_responses=[stage], fallback_used=True, model_output=self.text,
                                           llm_call_count=0, llm_attempt_count=1, repair_attempt_count=0, failure_reason="timeout")
        stage.update(status="failed", response_text="", failure_reason="请求超时")
        payload.update(review_focus=[], review_focus_total=0); stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, [], "light")[0])

    def test_v6_confirmation_recomputes_focus_from_original_and_actual_repaired_draft(self):
        for mode in ["light", "standard"]:
            report, receipts = self.repaired_v6_report(mode)
            original = json.loads(report["cases"][0]["stage_responses"][1]["request_payload"])
            for mutation in ["old_focus", "canonical", "draft", "segments", "changes"]:
                changed = copy.deepcopy(report); stage = changed["cases"][0]["stage_responses"][2]
                payload = json.loads(stage["request_payload"])
                if mutation == "old_focus": payload.update(review_focus=original["review_focus"], review_focus_total=original["review_focus_total"])
                elif mutation == "canonical": payload["canonical_text"] = "别的原文"
                elif mutation == "draft": payload["draft_text"] = self.text
                elif mutation == "segments": payload["source_segments"] = [{"id": "s1", "text": "改过的分段"}]
                else: payload["changes"] = []
                stage["request_payload"] = json.dumps(payload)
                self.assertTrue(self.check(changed, receipts, mode)[0], (mode, mutation))
            row = report["cases"][0]; row.update(fallback_used=True, model_output=self.text, llm_call_count=2, failure_reason="timeout")
            stage = row["stage_responses"][2]; stage.update(status="failed", response_text="", failure_reason="请求超时")
            self.assertEqual(self.check(report, receipts[:2], mode)[0], [])
            payload = json.loads(stage["request_payload"]); payload["review_focus"] = []
            stage["request_payload"] = json.dumps(payload)
            self.assertTrue(self.check(report, receipts[:2], mode)[0])

    def test_v6_focus_does_not_change_source_risk_or_grant_technical_token_deletion(self):
        report, receipts = self.v4_report("帮我整理一下明天发材料。")
        self.upgrade_report_to_v5(report, receipts)
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 6
        stage = report["cases"][0]["stage_responses"][0]
        payload = json.loads(stage["request_payload"]); payload["schema_version"] = 6
        stage["request_payload"] = json.dumps(payload)
        self.assertTrue(self.check(report, receipts, "light")[0])
        with self.assertRaises(ValueError):
            e.apply_recorded_edits("运行swift test", '{"edits":[{"before":" ","after":"","kind":"punctuation"}]}', editing_prompt_version=6)

    def test_v6_keeps_single_mechanical_call_and_two_call_standard_without_repair(self):
        for mode in ["light", "standard"]:
            source = "嗯我今天到"
            report, receipts = self.v4_report(source, mode=mode,
                initial_edits=[{"before": source, "after": "我今天到。", "kind": "punctuation"}],
                reviews=[] if mode == "light" else [{"source_roles": [], "edits": []}])
            self.upgrade_report_to_v5(report, receipts)
            self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 6
            for index, stage in enumerate(report["cases"][0]["stage_responses"]):
                payload = json.loads(stage["request_payload"]); payload["schema_version"] = 6
                if index: payload.update(review_focus=[], review_focus_total=0)
                stage["request_payload"] = json.dumps(payload)
            self.assertEqual(self.check(report, receipts, mode), ([], []), mode)
            self.assertEqual(report["cases"][0]["llm_attempt_count"], 1 if mode == "light" else 2)

    def test_v6_invalid_review_keeps_v5_fallback_classification(self):
        for mode in ["light", "standard"]:
            report, receipts = self.repaired_v6_report(mode)
            row = report["cases"][0]
            row.update(stage_responses=row["stage_responses"][:2], fallback_used=True, model_output=self.text,
                       llm_call_count=2, llm_attempt_count=2, repair_attempt_count=0,
                       hard_validation_codes=["invalidStructuredResponse"], failure_reason="validationFailed")
            stage = row["stage_responses"][1]; stage["response_text"] = '{"source_roles":[],"edits":[]}'
            receipts = receipts[:2]; receipts[1]["response_text_sha256"] = e.legacy.sha256_text(stage["response_text"])
            failures, quality = self.check(report, receipts, mode)
            self.assertEqual(failures, []); self.assertTrue(quality)
            row["hard_validation_codes"] = ["planIntegrityFailure"]
            self.assertTrue(self.check(report, receipts, mode)[0])

    def v7_report(self, source="甲。乙。", *, mode="standard", initial_edits=(), repair_edits=(), layout=None, review=True, version=7):
        report, receipts = self.v4_report(source, mode=mode, reviews=[{"source_roles": [], "edits": []}])
        row = report["cases"][0]
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = version
        separate = version in (8, 9, 10, 11) and mode == "standard" and e.v4_source_review_risk(source)
        _, canonical_segments = e.frozen_input_envelope(self.inputs[0])
        row["canonical_segments"] = canonical_segments
        draft = e.apply_recorded_edits(source, json.dumps({"edits": list(initial_edits)}, ensure_ascii=False),
            editing_prompt_version=version, allows_reviewed_directives=True, allows_reviewed_source_corrections=True)
        drafts = [source, draft]
        if repair_edits:
            draft = e.apply_recorded_edits(draft, json.dumps({"edits": list(repair_edits)}, ensure_ascii=False),
                editing_prompt_version=version, allows_reviewed_directives=True, allows_reviewed_source_corrections=True, original_source=source)
        if repair_edits or separate:
            drafts.append(draft)
            row["stage_responses"].append(copy.deepcopy(row["stage_responses"][-1]))
            receipts.append(copy.deepcopy(receipts[-1]))
        if not review:
            row["stage_responses"] = row["stage_responses"][:1]
            receipts = receipts[:1]
        if layout is None:
            layout = [{"style": "paragraph", "segment_ids": [s["id"] for s in e.v7_structure_segments(draft)]}]
        for i, stage in enumerate(row["stage_responses"]):
            payload = json.loads(stage["request_payload"])
            payload.update(schema_version=version, source_segments=canonical_segments)
            response = {"edits": list(initial_edits)}
            if i:
                current = drafts[i]
                payload["draft_text"] = current
                located, offset = [], 0
                for start, end, inserted in e.actual_modifications(source, current, 0):
                    current_start = start + offset
                    located.append((source[start:end], inserted, start, end, current_start, current_start + len(inserted)))
                    offset += len(inserted) - (end - start)
                order = [j for j, change in enumerate(located) if e.v6_content_character_count(change[0] + change[1])]
                order.sort(key=lambda j: (not bool(e.v6_content_character_count(located[j][0])),
                    -e.v6_content_character_count(located[j][0] + located[j][1]), j))
                payload.update(self.focus_payload(source, current, located, order))
                response = {"delivery": "other_or_uncertain", "editor_spans": [],
                            "edits": list(repair_edits) if i == 1 else []}
                if version == 9 and mode == "light":
                    response = {"edits": response["edits"]}
                if mode == "standard" and not (separate and i == 1):
                    payload["layout_segments"] = e.v7_structure_segments(current)
                    response["layout"] = [] if response["edits"] else layout
            stage.update(attempt_ordinal=i + 1, request_payload=json.dumps(payload, ensure_ascii=False),
                         response_text=json.dumps(response, ensure_ascii=False))
            receipts[i].update(request_ordinal=i + 1, provider_response_id=f"unit-test-only-v{version}-{i + 1}",
                request_binding_sha256=e.legacy.provider_request_binding_sha256(self.nonce, "fixture-01", i + 1, "e" * 64),
                response_text_sha256=e.legacy.sha256_text(stage["response_text"]))
        row.update(repair_attempt_count=1 if repair_edits else 0, llm_call_count=len(receipts), llm_attempt_count=len(receipts),
                   model_output=e.v7_render_layout(layout, e.v7_structure_segments(draft)) if mode == "standard" else draft)
        return report, receipts

    def v7_response(self, report, receipts, index, value):
        raw = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
        report["cases"][0]["stage_responses"][index]["response_text"] = raw
        receipts[index]["response_text_sha256"] = e.legacy.sha256_text(raw)

    def v7_payload(self, report, index, **changes):
        stage = report["cases"][0]["stage_responses"][index]
        payload = json.loads(stage["request_payload"])
        payload.update(changes)
        stage["request_payload"] = json.dumps(payload, ensure_ascii=False)

    def test_v7_sentence_segments_preserve_exact_text_and_known_boundaries(self):
        cases = [
            ("甲。乙！？丙。  \r\n", ["甲。", "乙！？", "丙。  \r\n"]),
            ("甲，乙\n丙", ["甲，乙\n丙"]),
            ("先说“甲。乙”。再做丙。", ["先说“甲。乙”。", "再做丙。"]),
            ("检查（甲。乙）完成。再走。", ["检查（甲。乙）完成。", "再走。"]),
            ("Dr. Smith visits api.test. Next sentence. Done!", ["Dr. Smith visits api.test. Next sentence.", " Done!"]),
            ("Run `echo 甲。乙` now. Done.", ["Run `echo 甲。乙` now.", " Done."]),
            ("正文。\n```text\n甲。乙\n```\n后续。", ["正文。", "\n```text\n甲。乙\n```\n后续。"]),
            ("    a。b\n后续。末尾。", ["    a。b\n后续。", "末尾。"]),
            ("don't split. Next.", ["don't split.", " Next."]),
            ("e\u0301 与 👨‍👩‍👧‍👦。尾部。", ["e\u0301 与 👨‍👩‍👧‍👦。", "尾部。"]),
        ]
        for source, expected_parts in cases:
            result = e.v7_structure_segments(source)
            self.assertEqual([s["text"] for s in result], expected_parts, source)
            self.assertEqual("".join(s["text"] for s in result).encode(), source.encode())
            self.assertEqual([s["id"] for s in result], [f"c{i + 1}" for i in range(len(expected_parts))])

    def test_v7_segment_cap_keeps_all_remaining_text_without_model_calls(self):
        source = "甲。" * 130
        result = e.v7_structure_segments(source)
        self.assertEqual(len(result), 128)
        self.assertEqual(result[-1], {"id": "c128", "text": "甲。甲。甲。"})
        self.assertEqual("".join(s["text"] for s in result), source)

    def test_v7_segments_reject_empty_unsafe_or_oversized_input(self):
        for source in ["", " \n\t", "甲\x00乙", "甲\u0085乙", "甲\ufdd0乙", "甲" * 349526]:
            with self.assertRaises(ValueError): e.v7_structure_segments(source)

    def test_v7_layout_reorders_all_ids_preserves_bytes_and_resets_numbering(self):
        segments = [{"id": f"c{i + 1}", "text": text} for i, text in enumerate(["甲。", " 乙。", "丙。", "丁。", "戊。", "己。"])]
        layout = [{"style": style, "segment_ids": ids} for style, ids in [
            ("numbered", ["c2"]), ("numbered", ["c1"]), ("bullet", ["c3"]),
            ("numbered", ["c4"]), ("paragraph", ["c6", "c5"])]]
        self.assertEqual(e.v7_render_layout(layout, segments), " 1. 乙。\n\n2. 甲。\n\n- 丙。\n\n1. 丁。\n\n己。戊。")

    def test_v7_layout_rejects_missing_duplicate_unknown_or_free_text(self):
        segments = e.v7_structure_segments("甲。乙。")
        for layout in [[], None, {}, [{"style": "paragraph", "segment_ids": ["c1"]}],
            [{"style": "paragraph", "segment_ids": ["c1", "c1", "c2"]}],
            [{"style": "paragraph", "segment_ids": ["c1", "c3"]}],
            [{"style": "paragraph", "segment_ids": ["c1", "c2"], "text": "新正文"}],
            [{"style": "heading", "segment_ids": ["c1", "c2"]}],
            [{"style": "paragraph", "segment_ids": ["c1", 2]}],
            [{"style": "paragraph", "segment_ids": []}]]:
            with self.subTest(layout=layout), self.assertRaises(ValueError): e.v7_render_layout(layout, segments)

    def test_v7_fenced_code_rejects_added_list_prefix_but_inline_code_can_be_listed(self):
        for fence in ["```", "~~~~"]:
            segments = e.v7_structure_segments("  " + fence + "text\r\n内容。\r\n" + fence)
            for style in ["bullet", "numbered"]:
                with self.assertRaises(ValueError):
                    e.v7_render_layout([{"style": style, "segment_ids": ["c1"]}], segments)
            self.assertEqual(e.v7_render_layout([{"style": "paragraph", "segment_ids": ["c1"]}], segments), "".join(s["text"] for s in segments))
        self.assertEqual(e.v7_render_layout([{"style": "bullet", "segment_ids": ["c1"]}], e.v7_structure_segments("运行 `swift test`。")), "- 运行 `swift test`。")
        segments = [{"id": "c1", "text": "正文。"}, {"id": "c2", "text": "```text\n代码\n```"}]
        for ids in [["c1", "c2"], ["c2", "c1"]]:
            with self.assertRaises(ValueError): e.v7_render_layout([{"style": "paragraph", "segment_ids": ids}], segments)

    def test_v7_layout_and_render_limits_apply_even_after_valid_segments(self):
        segments = [{"id": "c1", "text": "a" * 1_048_576}]
        with self.assertRaises(ValueError): e.v7_render_layout([{"style": "bullet", "segment_ids": ["c1"]}], segments)
        for segments in [[{"id": "wrong", "text": "甲"}], [{"id": "c1", "text": ""}],
                         [{"id": "c1", "text": "甲", "secret": "答案"}]]:
            with self.assertRaises(ValueError): e.v7_render_layout([{"style": "paragraph", "segment_ids": ["c1"]}], segments)

    def test_v7_standard_output_is_layout_render_not_content_draft(self):
        report, receipts = self.v7_report(layout=[{"style": "bullet", "segment_ids": ["c2", "c1"]}])
        self.assertEqual(report["cases"][0]["model_output"], "- 乙。甲。")
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        report["cases"][0]["model_output"] = "甲。乙。"
        self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v7_initial_cannot_be_free_text_or_content_even_with_source_evidence(self):
        for response, code in [("甲。乙。", "planIntegrityFailure"),
            ({"edits": [{"before": "甲。乙。", "after": "乙。", "kind": "content", "evidence": "甲。乙。"}]}, "planIntegrityFailure"),
            ({"edits": [{"before": "甲", "after": "乙", "kind": "unknown"}]}, "invalidStructuredResponse")]:
            report, receipts = self.v7_report()
            row = report["cases"][0]
            row.update(stage_responses=row["stage_responses"][:1], llm_call_count=1, llm_attempt_count=1,
                       model_output=self.text, fallback_used=True, failure_reason="validationFailed", hard_validation_codes=[code])
            receipts = receipts[:1]
            self.v7_response(report, receipts, 0, response)
            failures, quality = self.check(report, receipts, "standard")
            self.assertEqual(failures, [], response); self.assertTrue(quality)
            row["hard_validation_codes"] = ["emptyOutput"]
            self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v7_initial_payload_bans_review_and_layout_fields_even_on_failed_request(self):
        for key, value in [("draft_text", "甲。乙。"), ("changes", []), ("review_focus", []),
                           ("review_focus_total", 0), ("layout_segments", []), ("layout_segments", None),
                           ("review_focus", None), ("draft_text", None)]:
            report, receipts = self.v7_report()
            self.v7_payload(report, 0, **{key: value})
            self.assertTrue(self.check(report, receipts, "standard")[0], key)
            row = report["cases"][0]
            row.update(stage_responses=row["stage_responses"][:1], fallback_used=True, model_output=self.text,
                       llm_call_count=0, llm_attempt_count=1, failure_reason="timeout")
            row["stage_responses"][0].update(status="failed", response_text="", failure_reason="超时")
            self.assertTrue(self.check(report, [], "standard")[0], key)

    def test_v7_light_keeps_local_mode_and_never_accepts_layout_protocol(self):
        report, receipts = self.v7_report("今天发。", mode="light", review=False)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        self.v7_payload(report, 0, layout_segments=[])
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.v7_report("帮我整理今天发。", mode="light")
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        self.v7_payload(report, 1, layout_segments=[{"id": "c1", "text": self.text}])
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.v7_report("帮我整理今天发。", mode="light")
        value = json.loads(report["cases"][0]["stage_responses"][1]["response_text"])
        value["layout"] = []
        self.v7_response(report, receipts, 1, value)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v7_standard_review_segments_bind_exact_order_ids_text_and_boundaries(self):
        mutations = [[{"id": "c1", "text": "甲。乙。"}], [{"id": "c1", "text": "甲。"}],
            [{"id": "c2", "text": "甲。"}, {"id": "c1", "text": "乙。"}],
            [{"id": "c1", "text": "甲。"}, {"id": "c2", "text": "丙。"}], None]
        for segments in mutations:
            report, receipts = self.v7_report()
            self.v7_payload(report, 1, layout_segments=segments)
            self.assertTrue(self.check(report, receipts, "standard")[0], segments)

    def test_v7_failed_review_still_binds_segments_and_focus(self):
        report, receipts = self.v7_report()
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, llm_call_count=1, failure_reason="timeout")
        row["stage_responses"][1].update(status="failed", response_text="", failure_reason="超时")
        self.assertEqual(self.check(report, receipts[:1], "standard")[0], [])
        self.v7_payload(report, 1, layout_segments=[{"id": "c1", "text": "甲。乙。"}])
        self.assertTrue(self.check(report, receipts[:1], "standard")[0])

    def test_v7_review_schema_and_bad_layout_use_invalid_structured_response(self):
        for mutation in ["unknown", "missing", "duplicate", "omitted", "free_text"]:
            report, receipts = self.v7_report()
            row = report["cases"][0]
            value = json.loads(row["stage_responses"][1]["response_text"])
            if mutation == "unknown": value["summary"] = "新内容"
            elif mutation == "missing": del value["layout"]
            elif mutation == "duplicate": value["layout"][0]["segment_ids"] = ["c1", "c1", "c2"]
            elif mutation == "omitted": value["layout"][0]["segment_ids"] = ["c1"]
            else: value["layout"][0]["text"] = "新内容"
            self.v7_response(report, receipts, 1, value)
            row.update(fallback_used=True, model_output=self.text, failure_reason="validationFailed", hard_validation_codes=["invalidStructuredResponse"])
            self.assertEqual(self.check(report, receipts, "standard")[0], [], mutation)
            row["hard_validation_codes"] = ["planIntegrityFailure"]
            self.assertTrue(self.check(report, receipts, "standard")[0], mutation)

    def test_v7_repair_rebuilds_segments_and_requires_layout_of_actual_new_draft(self):
        source = "检查小李。不对，改由小赵。原因保留。"
        edit = {"before": "检查小李。不对，改由小赵。", "after": "检查小赵。", "kind": "correction"}
        report, receipts = self.v7_report(source, repair_edits=[edit])
        self.assertEqual(report["cases"][0]["model_output"], "检查小赵。原因保留。")
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        row = report["cases"][0]
        old = json.loads(row["stage_responses"][1]["request_payload"])
        new = json.loads(row["stage_responses"][2]["request_payload"])
        self.assertEqual(len(old["layout_segments"]), 3)
        self.assertEqual(len(new["layout_segments"]), 2)
        for key in ["layout_segments", "draft_text", "changes", "review_focus", "review_focus_total"]:
            changed = copy.deepcopy(report)
            self.v7_payload(changed, 2, **{key: old[key]})
            self.assertTrue(self.check(changed, receipts, "standard")[0], key)
        final = json.loads(row["stage_responses"][2]["response_text"])
        final["layout"][0]["segment_ids"] = ["c1", "c2", "c3"]
        self.v7_response(report, receipts, 2, final)
        self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v7_pending_repair_cannot_simultaneously_claim_old_layout(self):
        edit = {"before": "按装", "after": "安装", "kind": "word"}
        report, receipts = self.v7_report("按装软件。", repair_edits=[edit])
        row = report["cases"][0]
        row.update(stage_responses=row["stage_responses"][:2], llm_call_count=2, llm_attempt_count=2,
                   repair_attempt_count=0, fallback_used=True, model_output=self.text,
                   failure_reason="validationFailed", hard_validation_codes=["invalidStructuredResponse"])
        receipts = receipts[:2]
        value = json.loads(row["stage_responses"][1]["response_text"])
        value["layout"] = [{"style": "paragraph", "segment_ids": ["c1"]}]
        self.v7_response(report, receipts, 1, value)
        self.assertEqual(self.check(report, receipts, "standard")[0], [])
        row["repair_attempt_count"] = 1
        self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v7_failed_local_repair_counts_attempt_and_never_delivers_partial_draft(self):
        report, receipts = self.v7_report()
        value = {"delivery": "other_or_uncertain", "editor_spans": [], "layout": [],
                 "edits": [{"before": self.text, "after": "乙。", "kind": "content", "evidence": self.text}]}
        self.v7_response(report, receipts, 1, value)
        row = report["cases"][0]
        row.update(repair_attempt_count=1, fallback_used=True, model_output=self.text,
                   failure_reason="validationFailed", hard_validation_codes=["planIntegrityFailure"])
        failures, quality = self.check(report, receipts, "standard")
        self.assertEqual(failures, []); self.assertTrue(quality)
        row["model_output"] = "乙。"
        self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v7_confirmation_must_be_empty_and_never_start_a_fourth_call(self):
        edit = {"before": "按装", "after": "安装", "kind": "word"}
        for mutation in ["missing", "nonempty", "fourth"]:
            report, receipts = self.v7_report("按装软件。", repair_edits=[edit])
            row = report["cases"][0]
            if mutation == "missing":
                row["stage_responses"].pop(); receipts.pop(); row.update(llm_call_count=2, llm_attempt_count=2)
            elif mutation == "nonempty":
                self.v7_response(report, receipts, 2, {"delivery": "other_or_uncertain", "editor_spans": [], "layout": [],
                    "edits": [{"before": "软件", "after": "应用", "kind": "word"}]})
            else:
                row["stage_responses"].append(copy.deepcopy(row["stage_responses"][-1])); row["llm_attempt_count"] = 4
            self.assertTrue(self.check(report, receipts, "standard")[0], mutation)

    def test_v7_permission_budget_changes_do_not_rewrite_v6_history(self):
        before = "不对" + "甲" * 31 + "乙"
        response = json.dumps({"edits": [{"before": before, "after": "乙", "kind": "correction"}]})
        self.assertEqual(e.apply_recorded_edits(before, response, editing_prompt_version=6), "乙")
        with self.assertRaises(ValueError): e.apply_recorded_edits(before, response, editing_prompt_version=7)
        before = "不对" + "甲" * 30 + "乙"
        response = json.dumps({"edits": [{"before": before, "after": "乙", "kind": "correction"}]})
        self.assertEqual(e.apply_recorded_edits(before, response, editing_prompt_version=7), "乙")

    def test_v7_correction_multiple_blocks_use_total_scalar_budget_and_technical_guard(self):
        for before, after, valid in [("不对" + "甲" * 14 + "乙" + "丙" * 16 + "丁", "乙丁", True),
            ("不对" + "甲" * 14 + "乙" + "丙" * 17 + "丁", "乙丁", False),
            ("周三上午十点不对周四上午十点哎十点半才对", "周四上午十点半", True),
            ("不对foo_bar，保留正文", "保留正文", False),
            ("不对" + "\u1100\u1161" * 16 + "结果", "结果", False)]:
            response = json.dumps({"edits": [{"before": before, "after": after, "kind": "correction"}]})
            if valid: self.assertEqual(e.apply_recorded_edits(before, response, editing_prompt_version=7), after)
            else:
                with self.assertRaises(ValueError): e.apply_recorded_edits(before, response, editing_prompt_version=7)

    def test_v7_distant_correction_keeps_explicit_permission_and_source_evidence(self):
        edit = {"before": "阿文负责", "after": "阿宁负责", "kind": "correction", "evidence": "改由阿宁负责"}
        response = json.dumps({"edits": [edit]})
        source = "阿文负责。改由阿宁负责。"
        with self.assertRaises(ValueError): e.apply_recorded_edits(source, response, editing_prompt_version=7)
        self.assertEqual(e.apply_recorded_edits(source, response, editing_prompt_version=7, allows_reviewed_source_corrections=True), "阿宁负责。改由阿宁负责。")
        with self.assertRaises(ValueError): e.apply_recorded_edits("阿文负责。", response, editing_prompt_version=7, allows_reviewed_source_corrections=True)

    def test_v7_complete_ascii_clock_correction_keeps_exact_final_values(self):
        for before, after in [("会议10:30，不对，10:45开始。", "会议10:45开始。"),
            ("会议9:05，不对，09:15开始。", "会议09:15开始。"),
            ("会议9:05不对9:15不对9:25开始。", "会议9:25开始。"),
            ("第一场10:30，不对，10:45，第二场12:00。", "第一场10:45，第二场12:00。")]:
            response = json.dumps({"edits": [{"before": before, "after": after, "kind": "correction"}]})
            self.assertEqual(e.apply_recorded_edits(before, response, editing_prompt_version=7), after)

    def test_v7_clock_exception_rejects_invented_time_removed_colons_and_all_clocks(self):
        before = "会议10:30，不对，10:45开始，后续12:00继续。"
        for after in ["会议10:55开始，后续12:00继续。", "会议1045开始，后续12:00继续。",
                      "会议开始，后续继续。", "会议10:45开始，后续1200继续。"]:
            with self.assertRaises(ValueError): e.apply_recorded_edits(before, json.dumps({"edits": [
                {"before": before, "after": after, "kind": "correction"}]}), editing_prompt_version=7)
        before = "会议10:30" + "甲" * 32 + "不对10:45开始。"
        with self.assertRaises(ValueError): e.apply_recorded_edits(before, json.dumps({"edits": [
            {"before": before, "after": "会议10:45开始。", "kind": "correction"}]}), editing_prompt_version=7)

    def test_v7_clock_exception_uses_real_anchor_neighbors_and_complete_tokens(self):
        anchor = "10:30不对10:45"
        for prefix in ["host:", "foo", "λ", "/tmp/", "`", "_", "110", "["]:
            with self.subTest(prefix=prefix), self.assertRaises(ValueError):
                e.apply_recorded_edits(prefix + anchor, json.dumps({"edits": [
                    {"before": anchor, "after": "10:45", "kind": "correction"}]}), editing_prompt_version=7)
        for before in ["10:30.log不对10:45", "10:30:90不对10:45", "25:30不对10:45", "10:65不对10:45", "10:30\u0301不对10:45"]:
            with self.subTest(before=before), self.assertRaises(ValueError):
                e.apply_recorded_edits(before, json.dumps({"edits": [
                    {"before": before, "after": "10:45", "kind": "correction"}]}), editing_prompt_version=7)

    def test_v7_clock_exception_cannot_remove_other_technical_content_or_authorize_distant_edit(self):
        before = "运行A+B，会议10:30不对10:45开始。"
        with self.assertRaises(ValueError): e.apply_recorded_edits(before, json.dumps({"edits": [
            {"before": before, "after": "运行AB，会议10:45开始。", "kind": "correction"}]}), editing_prompt_version=7)
        before, evidence = "安排10:30和10:45开始。", "改成10:45开始"
        with self.assertRaises(ValueError): e.apply_recorded_edits(before, json.dumps({"edits": [
            {"before": before, "after": "安排10:45开始。", "kind": "correction", "evidence": evidence}]}),
            editing_prompt_version=7, original_source=before + evidence, allows_reviewed_source_corrections=True)

    def test_v7_indented_code_requires_standalone_paragraph(self):
        for text in ["    print('hello')", "\tprint('hello')", "  \tprint('hello')", "前文\n    代码"]:
            segments = [{"id": "c1", "text": text}, {"id": "c2", "text": "后续"}]
            for layout in [[{"style": "bullet", "segment_ids": ["c1"]}, {"style": "paragraph", "segment_ids": ["c2"]}],
                           [{"style": "paragraph", "segment_ids": ["c1", "c2"]}]]:
                with self.assertRaises(ValueError): e.v7_render_layout(layout, segments)
            layout = [{"style": "paragraph", "segment_ids": ["c1"]}, {"style": "paragraph", "segment_ids": ["c2"]}]
            self.assertEqual(e.v7_render_layout(layout, segments), text + "\n\n后续")

    def test_v7_markers_follow_preserved_leading_whitespace_instead_of_occupying_empty_line(self):
        segments = [{"id": "c1", "text": "甲。"}, {"id": "c2", "text": "\n\n  乙。"}]
        for style, expected in [("numbered", "1. 甲。\n\n  2. 乙。"), ("bullet", "- 甲。\n\n  - 乙。")]:
            layout = [{"style": style, "segment_ids": ["c1"]}, {"style": style, "segment_ids": ["c2"]}]
            self.assertEqual(e.v7_render_layout(layout, segments), expected)

    def test_v7_paragraph_separator_counts_actual_combined_characters_and_preserves_original_bytes(self):
        for previous, following, expected in [
            ("甲", "乙", "甲\n\n乙"), ("甲\n", "乙", "甲\n\n乙"),
            ("甲\n\n", "乙", "甲\n\n乙"), ("甲", "\n\n乙", "甲\n\n乙"),
            ("甲\r", "\n乙", "甲\r\n\n乙"), ("甲\r ", " \n乙", "甲\r  \n乙"),
            ("甲\r\n", "\r\n乙", "甲\r\n\r\n乙"), ("甲\n\n\n", "乙", "甲\n\n\n乙"),
            ("甲 \n", " \n乙", "甲 \n \n乙"), ("甲\u2028", "\u2029乙", "甲\u2028\u2029乙")]:
            segments = [{"id": "c1", "text": previous}, {"id": "c2", "text": following}]
            layout = [{"style": "paragraph", "segment_ids": ["c1"]}, {"style": "paragraph", "segment_ids": ["c2"]}]
            self.assertEqual(e.v7_render_layout(layout, segments).encode(), expected.encode(), (previous, following))

    def test_v7_direct_requires_integer_zero_repairs_and_zero_model_activity(self):
        self.expected["editing_prompt_version"] = 7
        report, receipts = self.report("direct")
        report["cases"][0]["repair_attempt_count"] = 0
        self.assertEqual(self.check(report, receipts, "direct"), ([], []))
        report["cases"][0]["repair_attempt_count"] = False
        self.assertTrue(self.check(report, receipts, "direct")[0])

    def test_v7_every_recorded_payload_rejects_unfrozen_extra_answer_fields(self):
        edit = {"before": "按装", "after": "安装", "kind": "word"}
        for mode in ["light", "standard"]:
            for index in range(3):
                report, receipts = self.v7_report("帮我整理按装软件。", mode=mode, repair_edits=[edit])
                self.assertEqual(self.check(report, receipts, mode), ([], []))
                self.v7_payload(report, index, unfrozen_reference_answer="来源没有说：预算五万元。")
                self.assertTrue(self.check(report, receipts, mode)[0], (mode, index))

    def test_v7_failed_payloads_reject_unknown_fields_without_hiding_existing_failure(self):
        edit = {"before": "按装", "after": "安装", "kind": "word"}
        for mode in ["light", "standard"]:
            for index in range(3):
                report, receipts = self.v7_report("帮我整理按装软件。", mode=mode, repair_edits=[edit])
                row = report["cases"][0]
                row.update(stage_responses=row["stage_responses"][:index + 1], llm_call_count=index,
                    llm_attempt_count=index + 1, repair_attempt_count=int(index == 2), fallback_used=True,
                    model_output=self.text, failure_reason="timeout")
                row["stage_responses"][index].update(status="failed", response_text="", failure_reason="超时")
                receipts = receipts[:index]
                failures, quality = self.check(report, receipts, mode)
                self.assertEqual(failures, [], (mode, index)); self.assertTrue(quality)
                self.v7_payload(report, index, unfrozen_reference_answer={"budget": "五万元"})
                self.assertTrue(self.check(report, receipts, mode)[0], (mode, index))

    def test_v7_payload_requires_all_nonoptional_keys_and_omits_nil_preferences(self):
        edit = {"before": "按装", "after": "安装", "kind": "word"}
        for mode in ["light", "standard"]:
            for index in range(3):
                report, receipts = self.v7_report("帮我整理按装软件。", mode=mode, repair_edits=[edit])
                payload = json.loads(report["cases"][0]["stage_responses"][index]["request_payload"])
                for key in payload:
                    changed = copy.deepcopy(report)
                    missing = {k: v for k, v in payload.items() if k != key}
                    changed["cases"][0]["stage_responses"][index]["request_payload"] = json.dumps(missing)
                    self.assertTrue(self.check(changed, receipts, mode)[0], (mode, index, key))
                self.v7_payload(report, index, style_profile=None)
                self.assertTrue(self.check(report, receipts, mode)[0], (mode, index, "nil style_profile must be omitted"))

    def test_v7_validation_codes_only_exist_in_standard_initial_draft_review(self):
        edit = {"before": "按装", "after": "安装", "kind": "word"}
        for mode in ["light", "standard"]:
            for index in range(3):
                if mode == "standard" and index == 1: continue
                for value in [["missingProtectedFact"], [], None]:
                    report, receipts = self.v7_report("帮我整理按装软件。", mode=mode, repair_edits=[edit])
                    self.v7_payload(report, index, validation_codes=value)
                    self.assertTrue(self.check(report, receipts, mode)[0], (mode, index, value))

    def test_v7_validation_codes_reject_free_text_nonemitted_enum_empty_duplicates_and_wrong_order(self):
        for value in [["来源没有说的事实：预算五万元。"], ["layoutRequirementUnmet"], ["unchangedDraft"],
            ["invalidStructuredResponse"], [], None, "missingProtectedFact", [True], [["missingProtectedFact"]],
            ["missingProtectedFact", "missingProtectedFact"], ["missingProtectedFact", "planIntegrityFailure"]]:
            report, receipts = self.v7_report()
            self.v7_payload(report, 1, validation_codes=value)
            self.assertTrue(self.check(report, receipts, "standard")[0], value)
        # 确实删掉受保护的双词强调时，contentCodes 会在首次标准复核附带此提示。
        report, receipts = self.v7_report("确实确实好。",
            initial_edits=[{"before": "确实确实", "after": "确实", "kind": "stutter"}],
            repair_edits=[{"before": "确实好", "after": "确实确实好", "kind": "word"}])
        self.v7_payload(report, 1, validation_codes=["missingProtectedFact"])
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))

    def test_v7_payload_closure_does_not_reinterpret_v6_historical_contract(self):
        report, receipts = self.repaired_v6_report("standard")
        self.v7_payload(report, 0, unfrozen_reference_answer="历史审计未检查该字段")
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))

    def test_v8_risk_empty_content_review_still_requires_layout_confirmation(self):
        report, receipts = self.v7_report("帮我整理甲。乙。", version=8,
            layout=[{"style": "bullet", "segment_ids": ["c2", "c1"]}])
        row = report["cases"][0]
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        self.assertEqual((row["llm_attempt_count"], row["repair_attempt_count"]), (3, 0))
        content = row["stage_responses"][1]
        self.assertNotIn("layout_segments", json.loads(content["request_payload"]))
        self.assertEqual(set(json.loads(content["response_text"])), {"delivery", "edits", "editor_spans"})
        self.assertEqual(row["model_output"], "- 乙。帮我整理甲。")
        row["repair_attempt_count"] = 1
        self.assertTrue(self.check(report, receipts, "standard")[0])
        row.update(repair_attempt_count=0, llm_call_count=2, llm_attempt_count=2,
                   model_output=self.text, stage_responses=row["stage_responses"][:2])
        self.assertTrue(any("完整模式链路" in f for f in self.check(report, receipts[:2], "standard")[0]))

    def test_v8_routing_uses_full_source_even_after_initial_directive_removed(self):
        source = "帮我整理一下：甲。乙。"
        edit = {"before": "帮我整理一下：", "after": "", "kind": "directive"}
        report, receipts = self.v7_report(source, version=8, initial_edits=[edit])
        stages = report["cases"][0]["stage_responses"]
        self.assertEqual(len(stages), 3)
        self.assertFalse(e.v4_source_review_risk(json.loads(stages[1]["request_payload"])["draft_text"]))
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        # 原文风险词已经消失，仍不能把第2轮伪装成直接结构整理。
        self.v7_payload(report, 1, layout_segments=e.v7_structure_segments("甲。乙。"))
        self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v8_no_risk_standard_keeps_two_calls_despite_initial_word_correction(self):
        for edits in [[], [{"before": "按装", "after": "安装", "kind": "word"}]]:
            report, receipts = self.v7_report("按装软件。", version=8, initial_edits=edits)
            row = report["cases"][0]
            self.assertEqual((row["llm_attempt_count"], row["repair_attempt_count"]), (2, 0))
            self.assertIn("layout_segments", json.loads(row["stage_responses"][1]["request_payload"]))
            self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        report, receipts = self.v7_report("按装软件。", version=8,
            repair_edits=[{"before": "按装", "after": "安装", "kind": "word"}])
        self.assertEqual(report["cases"][0]["repair_attempt_count"], 1)
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))

    def test_v8_light_call_count_and_three_field_reviews_are_unchanged(self):
        edit = {"before": "按装", "after": "安装", "kind": "word"}
        for source, initial, repair, review, count in [
            ("今天发。", [], [], False, 1), ("帮我整理今天发。", [], [], True, 2),
            ("按装软件。", [edit], [], True, 2), ("帮我整理按装软件。", [], [edit], True, 3)]:
            report, receipts = self.v7_report(source, version=8, mode="light", initial_edits=initial,
                repair_edits=repair, review=review)
            self.assertEqual(report["cases"][0]["llm_attempt_count"], count)
            self.assertEqual(self.check(report, receipts, "light"), ([], []))
            for stage in report["cases"][0]["stage_responses"]:
                self.assertNotIn("layout_segments", json.loads(stage["request_payload"]))

    def test_v8_risk_content_payload_forbids_layout_and_all_payloads_are_closed(self):
        report, receipts = self.v7_report("帮我整理甲。乙。", version=8)
        for index, stage in enumerate(report["cases"][0]["stage_responses"]):
            payload = json.loads(stage["request_payload"])
            for key in payload:
                changed = copy.deepcopy(report)
                changed["cases"][0]["stage_responses"][index]["request_payload"] = json.dumps(
                    {k: v for k, v in payload.items() if k != key})
                self.assertTrue(self.check(changed, receipts, "standard")[0], (index, key))
            for key, value in [("unfrozen_reference_answer", "新造预算五万元"), ("style_profile", None)]:
                changed = copy.deepcopy(report)
                self.v7_payload(changed, index, **{key: value})
                self.assertTrue(self.check(changed, receipts, "standard")[0], (index, key))
        for value in [None, [], e.v7_structure_segments(self.text)]:
            changed = copy.deepcopy(report)
            self.v7_payload(changed, 1, layout_segments=value)
            self.assertTrue(self.check(changed, receipts, "standard")[0], value)

    def test_v8_content_response_extra_layout_is_decode_failure_before_any_repair(self):
        report, receipts = self.v7_report("帮我整理按装软件。", version=8)
        value = {"delivery": "other_or_uncertain", "editor_spans": [], "layout": [],
                 "edits": [{"before": "按装", "after": "安装", "kind": "word"}]}
        self.v7_response(report, receipts, 1, value)
        row = report["cases"][0]
        row.update(stage_responses=row["stage_responses"][:2], llm_call_count=2, llm_attempt_count=2,
            fallback_used=True, model_output=self.text, failure_reason="validationFailed",
            hard_validation_codes=["invalidStructuredResponse"])
        failures, quality = self.check(report, receipts[:2], "standard")
        self.assertEqual(failures, []); self.assertTrue(quality)
        row["repair_attempt_count"] = 1
        self.assertTrue(self.check(report, receipts[:2], "standard")[0])

    def test_v8_nonempty_content_repair_binds_final_draft_focus_and_new_segments(self):
        source = "检查小李。不对，改由小赵。原因保留。"
        edit = {"before": "检查小李。不对，改由小赵。", "after": "检查小赵。", "kind": "correction"}
        report, receipts = self.v7_report(source, version=8, repair_edits=[edit])
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        row = report["cases"][0]
        self.assertEqual((row["llm_attempt_count"], row["repair_attempt_count"]), (3, 1))
        old = json.loads(row["stage_responses"][1]["request_payload"])
        self.assertNotIn("layout_segments", old)
        for key in ["draft_text", "changes", "review_focus", "review_focus_total"]:
            changed = copy.deepcopy(report)
            self.v7_payload(changed, 2, **{key: old[key]})
            self.assertTrue(self.check(changed, receipts, "standard")[0], key)
        self.v7_payload(report, 2, layout_segments=e.v7_structure_segments(old["draft_text"]))
        self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v8_failed_content_or_confirmation_still_binds_actual_request(self):
        for repair in [[], [{"before": "按装", "after": "安装", "kind": "word"}]]:
            for index in range(3):
                report, receipts = self.v7_report("帮我整理按装软件。", version=8, repair_edits=repair)
                row = report["cases"][0]
                row.update(stage_responses=row["stage_responses"][:index + 1], llm_call_count=index,
                    llm_attempt_count=index + 1, repair_attempt_count=int(index == 2 and bool(repair)),
                    fallback_used=True, model_output=self.text, failure_reason="timeout")
                row["stage_responses"][index].update(status="failed", response_text="", failure_reason="超时")
                failures, quality = self.check(report, receipts[:index], "standard")
                self.assertEqual(failures, [], (repair, index)); self.assertTrue(quality)
                changes = {"unfrozen_reference_answer": "不应存在"} if index == 0 else {"draft_text": "未经实际补丁生成的稿"}
                self.v7_payload(report, index, **changes)
                self.assertTrue(self.check(report, receipts[:index], "standard")[0], (repair, index))

    def test_v8_failed_local_content_repair_counts_once_and_keeps_source(self):
        report, receipts = self.v7_report("帮我整理甲。乙。", version=8)
        self.v7_response(report, receipts, 1, {"delivery": "other_or_uncertain", "editor_spans": [],
            "edits": [{"before": self.text, "after": "乙。", "kind": "content", "evidence": self.text}]})
        row = report["cases"][0]
        row.update(stage_responses=row["stage_responses"][:2], llm_call_count=2, llm_attempt_count=2,
            repair_attempt_count=1, fallback_used=True, model_output=self.text,
            failure_reason="validationFailed", hard_validation_codes=["planIntegrityFailure"])
        failures, quality = self.check(report, receipts[:2], "standard")
        self.assertEqual(failures, []); self.assertTrue(quality)
        row["model_output"] = "乙。"
        self.assertTrue(self.check(report, receipts[:2], "standard")[0])

    def test_v8_final_confirmation_rejects_nonempty_edits_or_missing_layout(self):
        for response, code in [
            ({"delivery": "other_or_uncertain", "editor_spans": [], "edits": []}, "invalidStructuredResponse"),
            ({"delivery": "other_or_uncertain", "editor_spans": [], "edits": [
                {"before": "甲", "after": "乙", "kind": "word"}], "layout": []}, "planIntegrityFailure")]:
            report, receipts = self.v7_report("帮我整理甲。", version=8)
            self.v7_response(report, receipts, 2, response)
            self.assertTrue(self.check(report, receipts, "standard")[0])
            row = report["cases"][0]
            row.update(fallback_used=True, model_output=self.text, hard_validation_codes=[code], failure_reason="validationFailed")
            failures, quality = self.check(report, receipts, "standard")
            self.assertEqual(failures, []); self.assertTrue(quality)

    def test_v8_risk_route_cannot_start_fourth_call_with_valid_receipt_binding(self):
        report, receipts = self.v7_report("帮我整理甲。乙。", version=8)
        row = report["cases"][0]
        stage, receipt = copy.deepcopy(row["stage_responses"][-1]), copy.deepcopy(receipts[-1])
        stage["attempt_ordinal"] = 4
        receipt.update(request_ordinal=4, provider_response_id="unit-test-only-v8-4",
            request_binding_sha256=e.legacy.provider_request_binding_sha256(self.nonce, "fixture-01", 4, "e" * 64))
        row["stage_responses"].append(stage); receipts.append(receipt)
        row.update(llm_call_count=4, llm_attempt_count=4)
        failures, _ = self.check(report, receipts, "standard")
        self.assertTrue(any("调用预算" in f for f in failures))
        self.assertTrue(any("阶段任务顺序" in f for f in failures))

    def test_v8_validation_codes_remain_optional_only_in_initial_content_review(self):
        report, receipts = self.v7_report("帮我整理甲。", version=8)
        for index in range(3):
            for codes in [None, [], ["来源没有说的预算五万元"], ["missingProtectedFact"]]:
                if index == 1 and codes == ["missingProtectedFact"]: continue
                changed = copy.deepcopy(report)
                self.v7_payload(changed, index, validation_codes=codes)
                self.assertTrue(self.check(changed, receipts, "standard")[0], (index, codes))
        report, receipts = self.v7_report("帮我整理确实确实好。", version=8,
            initial_edits=[{"before": "确实确实", "after": "确实", "kind": "stutter"}],
            repair_edits=[{"before": "确实好", "after": "确实确实好", "kind": "word"}])
        self.v7_payload(report, 1, validation_codes=["missingProtectedFact"])
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))

    def test_v8_new_risk_route_does_not_reinterpret_v7_history(self):
        report, receipts = self.v7_report("帮我整理甲。乙。")
        self.assertEqual(report["cases"][0]["llm_attempt_count"], 2)
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        # 同一旧协议链仅换版本号，缺专职内容复核与第3步，不能冒充 v8。
        report["editing_prompt_version"] = self.expected["editing_prompt_version"] = 8
        for i in range(2): self.v7_payload(report, i, schema_version=8)
        self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v9_light_preserves_request_words_without_extra_review(self):
        for source in ["帮我回客户，先别答应赔偿。", "帮我整理成Prompt，预算100元。", "润色这段话，不要写解释。"]:
            report, receipts = self.v7_report(source, version=9, mode="light", review=False)
            self.assertEqual(self.check(report, receipts, "light"), ([], []))
            self.assertEqual(report["cases"][0]["llm_attempt_count"], 1)
            self.assertEqual(report["cases"][0]["model_output"], source)
            # 同样的额外空复核即使有真实格式回执，也不能伪装成当前路由。
            report, receipts = self.v7_report(source, version=9, mode="light", review=True)
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v9_light_mechanical_edits_do_not_turn_requests_into_actions(self):
        source = "帮我回客户先别答应赔偿"
        output = "帮我回客户，先别答应赔偿。"
        report, receipts = self.v7_report(source, version=9, mode="light", review=False,
            initial_edits=[{"before": source, "after": output, "kind": "punctuation"}])
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        self.assertEqual(report["cases"][0]["model_output"], output)

    def test_v9_light_actual_word_change_and_source_correction_still_review(self):
        edit = {"before": "按装", "after": "安装", "kind": "word"}
        for source, initial, repair, count in [
            ("帮我按装软件。", [edit], [], 2),
            ("我说错了，按装软件。", [], [], 2),
            ("我说错了，按装软件。", [], [edit], 3)]:
            report, receipts = self.v7_report(source, version=9, mode="light", initial_edits=initial, repair_edits=repair)
            self.assertEqual(self.check(report, receipts, "light"), ([], []))
            self.assertEqual(report["cases"][0]["llm_attempt_count"], count)
            for stage in report["cases"][0]["stage_responses"][1:]:
                self.assertEqual(set(json.loads(stage["response_text"])), {"edits"})

    def test_v9_light_directive_and_content_are_forbidden_even_with_review_permission(self):
        for kind in ["directive", "content"]:
            raw = json.dumps({"edits": [{"before": "帮我回他：", "after": "", "kind": kind, "evidence": "帮我回他："}]})
            with self.assertRaises(e.V7ContractError):
                e.apply_recorded_edits("帮我回他：晚点到。", raw, editing_prompt_version=9,
                    allows_reviewed_directives=True, allows_reviewed_source_corrections=True,
                    allows_directive_edits=False)
        # 不能把错误类型伪装成无害标点，再绕过入口的档位权限。
        with self.assertRaises(e.V7ContractError):
            e.apply_recorded_edits("甲", '{"edits":[{"before":"甲","after":"甲。","kind":"directive"}]}',
                editing_prompt_version=9, allows_reviewed_directives=True, allows_directive_edits=False)

    def test_v9_light_rejected_initial_directive_keeps_one_attempt_and_source(self):
        report, receipts = self.v7_report("帮我回他：晚点到。", version=9, mode="light", review=False)
        self.v7_response(report, receipts, 0, {"edits": [{"before": "帮我回他：", "after": "", "kind": "directive"}]})
        row = report["cases"][0]
        row.update(fallback_used=True, failure_reason="validationFailed", hard_validation_codes=["planIntegrityFailure"])
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, []); self.assertTrue(quality)
        row["model_output"] = "晚点到。"
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v9_light_review_rejects_old_role_fields_before_any_repair(self):
        for response in [
            {"delivery": "direct_reply", "editor_spans": [], "edits": []},
            {"edits": [], "layout": []}, {"edits": "错误类型"}, {"edits": [] , "unexpected": 1}]:
            report, receipts = self.v7_report("我说错了，明天发。", version=9, mode="light")
            self.v7_response(report, receipts, 1, response)
            row = report["cases"][0]
            row.update(fallback_used=True, failure_reason="validationFailed", hard_validation_codes=["invalidStructuredResponse"])
            failures, quality = self.check(report, receipts, "light")
            self.assertEqual(failures, []); self.assertTrue(quality)
            row["repair_attempt_count"] = 1
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v9_light_rejected_review_directive_counts_attempted_repair_once(self):
        report, receipts = self.v7_report("我说错了，帮我回他：晚点到。", version=9, mode="light")
        self.v7_response(report, receipts, 1, {"edits": [{"before": "帮我回他：", "after": "", "kind": "directive"}]})
        row = report["cases"][0]
        row.update(fallback_used=True, repair_attempt_count=1, failure_reason="validationFailed", hard_validation_codes=["planIntegrityFailure"])
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, []); self.assertTrue(quality)
        row["repair_attempt_count"] = 0
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v9_light_final_review_requires_empty_edits_and_current_draft(self):
        report, receipts = self.v7_report("我说错了，按装软件。", version=9, mode="light",
            repair_edits=[{"before": "按装", "after": "安装", "kind": "word"}])
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        changed = copy.deepcopy(report)
        self.v7_payload(changed, 2, draft_text=self.text)
        self.assertTrue(self.check(changed, receipts, "light")[0])
        self.v7_response(report, receipts, 2, {"edits": [{"before": "软件", "after": "硬件", "kind": "word"}]})
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, failure_reason="validationFailed", hard_validation_codes=["planIntegrityFailure"])
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, []); self.assertTrue(quality)

    def test_v9_standard_keeps_v8_route_and_layout_contract(self):
        for source, count in [("甲。乙。", 2), ("帮我整理甲。乙。", 3)]:
            report, receipts = self.v7_report(source, version=9)
            self.assertEqual(self.check(report, receipts, "standard"), ([], []))
            self.assertEqual(report["cases"][0]["llm_attempt_count"], count)

    def test_v9_light_scope_does_not_regrade_v8_evidence(self):
        report, receipts = self.v7_report("帮我回他：晚点到。", version=8, mode="light")
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        report["editing_prompt_version"] = self.expected["editing_prompt_version"] = 9
        for index in range(2): self.v7_payload(report, index, schema_version=9)
        self.assertTrue(self.check(report, receipts, "light")[0])

    def v10_report(self, source, candidate, *, review=None, confirmation=True):
        report, receipts = self.v7_report(source, mode="light", version=9, review=False)
        row = report["cases"][0]
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 10
        responses, drafts = [{"text": candidate}], [None]
        target = candidate
        changed = False
        if review is not None:
            responses.append(review)
            drafts.append(candidate)
            target = review.get("text")
            changed = isinstance(target, str) and target != candidate
            if changed and confirmation is not None:
                responses.append({"approved": confirmation})
                drafts.append(target)
        template = row["stage_responses"][0]
        receipt_template = receipts[0]
        payload_template = json.loads(template["request_payload"])
        stages, receipts = [], []
        for i, response in enumerate(responses):
            task = "voicePolishFast" if i == 0 else "voicePolishAnalyze"
            payload = copy.deepcopy(payload_template)
            payload["schema_version"] = 10
            if i:
                current = drafts[i]
                payload["draft_text"] = current
                located, offset = [], 0
                for start, end, inserted in e.actual_modifications(source, current, 0):
                    current_start = start + offset
                    located.append((source[start:end], inserted, start, end, current_start, current_start + len(inserted)))
                    offset += len(inserted) - (end - start)
                order = [j for j, change in enumerate(located) if e.v6_content_character_count(change[0] + change[1])]
                order.sort(key=lambda j: (not bool(e.v6_content_character_count(located[j][0])),
                    -e.v6_content_character_count(located[j][0] + located[j][1]), j))
                payload.update(self.focus_payload(source, current, located, order))
            raw = json.dumps(response, ensure_ascii=False)
            stage = copy.deepcopy(template)
            stage.update(task=task, attempt_ordinal=i + 1, request_payload=json.dumps(payload, ensure_ascii=False), response_text=raw)
            stages.append(stage)
            receipt = copy.deepcopy(receipt_template)
            receipt.update(llm_task=task, request_ordinal=i + 1, provider_response_id=f"unit-test-only-v10-{i + 1}",
                request_binding_sha256=e.legacy.provider_request_binding_sha256(self.nonce, "fixture-01", i + 1, "e" * 64),
                response_text_sha256=e.legacy.sha256_text(raw))
            receipts.append(receipt)
        row.update(stage_responses=stages, llm_call_count=len(stages), llm_attempt_count=len(stages),
                   repair_attempt_count=int(changed), model_output=target if isinstance(target, str) else source)
        return report, receipts

    def v10_fallback(self, report, code, *, repairs=None):
        row = report["cases"][0]
        row.update(fallback_used=True, model_output=self.text, failure_reason="validationFailed", hard_validation_codes=[code])
        if repairs is not None: row["repair_attempt_count"] = repairs

    def test_v10_complete_text_mechanical_path_and_request_scope(self):
        for source, target in [("嗯帮我回他先别承诺", "帮我回他，先别承诺。"), ("不", "不"),
                               ("运行scripts斜杠check点sh", "运行 scripts/check.sh。")]:
            report, receipts = self.v10_report(source, target)
            self.assertEqual(self.check(report, receipts, "light"), ([], []))
            self.assertEqual(report["cases"][0]["repair_attempt_count"], 0)
            # 有真实回执也不能编造额外空审核。
            report, receipts = self.v10_report(source, target, review={"text": target, "edits": []})
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v10_original_risk_still_requires_review_for_unchanged_or_mechanical_draft(self):
        for source, target in [("原定周二，改为周三。", "原定周二，改为周三。"),
                               ("等一下明天再说", "等一下，明天再说。")]:
            report, receipts = self.v10_report(source, target, review={"text": target, "edits": []})
            self.assertEqual(self.check(report, receipts, "light"), ([], []))
            report, receipts = self.v10_report(source, target)
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v10_semantic_changes_are_source_bound_not_candidate_bound(self):
        source, candidate = "帮我按装软件", "帮我安装软件。"
        review = {"text": candidate, "edits": [{"before": "按装", "after": "安装", "kind": "word"}]}
        report, receipts = self.v10_report(source, candidate, review=review)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        self.v7_response(report, receipts, 1, {"text": candidate,
            "edits": [{"before": "安装", "after": "安装", "kind": "word"}]})
        self.assertTrue(self.check(report, receipts, "light")[0])
        self.v10_fallback(report, "planIntegrityFailure")
        self.assertEqual(self.check(report, receipts, "light")[0], [])

    def test_v10_no_reviewed_mechanical_permission_for_undeclared_stutter(self):
        for source, target, approved in [
            ("我我到了", "我到了", {"before": "我我", "after": "我", "kind": "stutter"}),
            ("唔我到了", "我到了", {"before": "唔我到了", "after": "我到了", "kind": "filler"})]:
            report, receipts = self.v10_report(source, target, review={"text": target, "edits": []})
            self.assertTrue(self.check(report, receipts, "light")[0])
            self.v10_fallback(report, "planIntegrityFailure")
            self.assertEqual(self.check(report, receipts, "light")[0], [])
            report, receipts = self.v10_report(source, target, review={"text": target, "edits": [approved]})
            self.assertEqual(self.check(report, receipts, "light"), ([], []))

    def test_v10_repair_is_actual_candidate_change_and_requires_cold_confirmation(self):
        source, target = "我说错了，按装软件", "我说错了，安装软件。"
        review = {"text": target, "edits": [{"before": "按装", "after": "安装", "kind": "word"}]}
        report, receipts = self.v10_report(source, source, review=review)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        self.assertEqual(report["cases"][0]["repair_attempt_count"], 1)
        changed = copy.deepcopy(report)
        self.v7_payload(changed, 2, draft_text=source)
        self.assertTrue(self.check(changed, receipts, "light")[0])
        changed = copy.deepcopy(report)
        self.v7_payload(changed, 2, changes=[], review_focus=[], review_focus_total=0)
        self.assertTrue(self.check(changed, receipts, "light")[0])
        missing, short_receipts = self.v10_report(source, source, review=review, confirmation=None)
        self.assertTrue(self.check(missing, short_receipts, "light")[0])
        self.v7_response(report, receipts, 2, {"approved": False})
        self.v10_fallback(report, "semanticDecisionUnverified")
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, []); self.assertTrue(quality)

    def test_v10_null_reject_is_not_repair_and_cannot_deliver_candidate(self):
        report, receipts = self.v10_report("我我到了", "我到了", review={"text": None, "edits": []})
        self.v10_fallback(report, "semanticDecisionUnverified")
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, []); self.assertTrue(quality)
        report["cases"][0]["repair_attempt_count"] = 1
        self.assertTrue(self.check(report, receipts, "light")[0])
        report["cases"][0].update(repair_attempt_count=0, model_output="我到了")
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v10_failed_repair_permission_is_counted_without_third_call(self):
        for kind in ("directive", "content"):
            report, receipts = self.v10_report("我说错了，帮我回他。", "我说错了，帮我回他。",
                review={"text": "我说错了，他。", "edits": [{"before": "帮我回", "after": "", "kind": kind}]}, confirmation=None)
            self.v10_fallback(report, "planIntegrityFailure")
            self.assertEqual(self.check(report, receipts, "light")[0], [])
            report["cases"][0]["repair_attempt_count"] = 0
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v10_repair_does_not_override_reviewed_punctuation_or_submit_partial_edits(self):
        source, initial, target = "等一下明天再说", "等一下。明天，再说。", "等一下，明天再说。"
        report, receipts = self.v10_report(source, initial, review={"text": target, "edits": []})
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        self.assertEqual(report["cases"][0]["repair_attempt_count"], 1)
        report["cases"][0]["model_output"] = initial
        self.assertTrue(self.check(report, receipts, "light")[0])
        for output in ("等一下，后天再说。", "等一下明天再说"):
            report["cases"][0]["model_output"] = output
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v10_protocol_type_failures_are_not_semantic_rejections(self):
        for raw in [{"edits": []}, {"text": ""}, {"text": None}, {"text": 1}, {"text": "甲", "edits": []}]:
            with self.assertRaises(e.V7ContractError) as caught:
                e.decode_v10_light(json.dumps(raw), "initial")
            self.assertEqual(caught.exception.code, "invalidStructuredResponse")
        for raw in [{"text": None, "edits": "错"}, {"text": "甲", "edits": [], "approved": True},
                    {"text": "甲"}, {"text": "甲", "edits": [{"before": "甲", "after": "乙", "kind": "guess"}]}]:
            with self.assertRaises(e.V7ContractError) as caught:
                e.decode_v10_light(json.dumps(raw), "review")
            self.assertEqual(caught.exception.code, "invalidStructuredResponse")
        for raw in [{"approved": 1}, {"approved": "true"}, {"approved": None}, {"edits": []}, {"approved": True, "text": "甲"}]:
            with self.assertRaises(e.V7ContractError) as caught:
                e.decode_v10_light(json.dumps(raw), "confirmation")
            self.assertEqual(caught.exception.code, "invalidStructuredResponse")

    def test_v10_residual_preserves_paragraphs_technical_tokens_and_exact_unicode(self):
        for source, target in [("运行 swift test", "运行 swifttest"), ("甲\n\n乙", "甲。乙"),
                               ("运行 --dry-run", "运行 dryrun")]:
            with self.assertRaises(ValueError): e.v10_strict_mechanical_candidate(source, target)
        for source, target in [("甲\n\n乙", "甲。\n\n乙。"), ("👨‍👩‍👧‍👦到了", "👨‍👩‍👧‍👦到了。"), ("e\u0301到了", "e\u0301到了。")]:
            self.assertEqual(e.v10_strict_mechanical_candidate(source, target).encode(), target.encode())

    def test_v10_standard_keeps_v8_routes_and_v9_light_evidence_remains_valid(self):
        for source, count in [("甲。乙。", 2), ("帮我整理甲。乙。", 3)]:
            report, receipts = self.v7_report(source, version=10)
            self.assertEqual(self.check(report, receipts, "standard"), ([], []))
            self.assertEqual(len(receipts), count)
        report, receipts = self.v7_report("帮我回他，先别承诺。", version=9, mode="light", review=False)
        self.assertEqual(self.check(report, receipts, "light"), ([], []))

    def test_v10_output_shape_cannot_forge_success_with_only_punctuation_growth(self):
        source, target = "甲", "甲" + "。" * 41
        report, receipts = self.v10_report(source, target)
        self.assertTrue(self.check(report, receipts, "light")[0])
        self.v10_fallback(report, "abnormalLength")
        self.assertEqual(self.check(report, receipts, "light")[0], [])
        for output, code in [(" \t\n", "emptyOutput"), ("甲\u0000", "unsafeCharacters")]:
            with self.assertRaises(e.V7ContractError) as caught:
                e.v10_output_shape_check(source, output)
            self.assertEqual(caught.exception.code, code)
        # 组合 emoji 和 CRLF 都按真实字符边界计数，不能用码点数误判长度。
        e.v10_output_shape_check("👨‍👩‍👧‍👦", "👨‍👩‍👧‍👦" + "。" * 40)

    def test_v10_whitespace_delivery_cannot_be_disguised_as_mechanical_success(self):
        for source, output in [("嗯", " "), ("嗯啊", "\t")]:
            report, receipts = self.v10_report(source, output)
            self.assertTrue(self.check(report, receipts, "light")[0])
            self.v10_fallback(report, "emptyOutput")
            failures, blockers = self.check(report, receipts, "light")
            self.assertEqual(failures, []); self.assertTrue(blockers)

    def test_v10_duplicate_keys_cannot_replace_rejection_or_semantic_evidence(self):
        cases = [
            ("initial", '{"text":"甲","text":"乙"}'),
            ("review", '{"text":null,"text":"甲","edits":[]}'),
            ("confirmation", '{"approved":false,"approved":true}'),
            ("initial", '{"text":"甲","\\u0074ext":"乙"}'),
            ("review", '{"text":"乙","edits":[{"before":"甲","before":"乙","after":"乙","kind":"word"}]}'),
        ]
        for stage, raw in cases:
            with self.assertRaises(e.V7ContractError) as caught:
                e.decode_v10_light(raw, stage)
            self.assertEqual(caught.exception.code, "invalidStructuredResponse")
        report, receipts = self.v10_report("我我到了", "我到了", review={"text": "我到了", "edits": []})
        self.v7_response(report, receipts, 1, '{"text":null,"text":"我到了","edits":[]}')
        self.v10_fallback(report, "invalidStructuredResponse")
        self.assertEqual(self.check(report, receipts, "light")[0], [])

    def test_v10_unpaired_surrogates_are_protocol_errors_including_nested_evidence(self):
        for stage, raw in [
            ("initial", r'{"text":"\ud800"}'),
            ("review", r'{"text":"\udfff","edits":[]}'),
            ("review", r'{"text":"甲","edits":[{"before":"\ud800","after":"甲","kind":"word"}]}'),
        ]:
            with self.assertRaises(e.V7ContractError) as caught:
                e.decode_v10_light(raw, stage)
            self.assertEqual(caught.exception.code, "invalidStructuredResponse")
        self.assertEqual(e.decode_v10_light(r'{"text":"\ud83d\ude00"}', "initial")["text"], "😀")
        report, receipts = self.v10_report("甲", "甲")
        self.v7_response(report, receipts, 0, r'{"text":"\ud800"}')
        self.v10_fallback(report, "invalidStructuredResponse")
        self.assertEqual(self.check(report, receipts, "light")[0], [])

    def v11_report(self, source="原定周二，改为周三。", response="周三。"):
        # 显式给定单次请求及正文，不通过旧补丁或语义模型生成预期答案。
        self.text = source
        self.inputs[0].update(spoken_input=source, segment_texts=[source])
        report, receipts = self.report("light")
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 11
        row = report["cases"][0]
        row.update(repair_attempt_count=0, model_output=response,
                   canonical_segments=e.frozen_input_envelope(self.inputs[0])[1])
        row["stage_responses"][0].update(task="voicePolishRender", response_text=response,
            request_payload=json.dumps({"canonical_text": source}, ensure_ascii=False))
        receipts[0].update(llm_task="voicePolishRender", response_text_sha256=e.legacy.sha256_text(response))
        return report, receipts

    def test_v11_single_raw_response_has_no_semantic_or_cleanup_gate(self):
        for source, raw in [
            ("原定周二，改为周三。", "周三。"),
            ("我我按装软件", "我安装软件。"),
            ("千万千万先别发", "千万先别发。"),
            ("甲", "  甲\r\n\r乙\n\n乙\t "),
            ("甲", '<think>原样正文</think>\n润色后：{"text":"甲"}'),
            ("甲", "乙" * 200),
        ]:
            with self.subTest(raw=raw):
                report, receipts = self.v11_report(source, raw)
                self.assertEqual(self.check(report, receipts, "light"), ([], []))
                self.assertEqual(report["cases"][0]["model_output"].encode(), raw.encode())

    def test_v11_payload_is_exact_source_only_json(self):
        invalid = ["{}", "[]", '"甲"', "null", '{"canonical_text":null}', '{"canonical_text":1}',
            '{"canonical_text":"偷偷换稿"}', '{"canonical_text":"甲","mode":"light"}',
            '{"canonical_text":"甲","system":"评分要求"}',
            '{"canonical_text":"甲","canonical_text":"甲"}',
            '{"canonical_text":"甲","\\u0063anonical_text":"甲"}', r'{"canonical_text":"\ud800"}']
        for raw in invalid:
            report, receipts = self.v11_report("甲", "甲")
            report["cases"][0]["stage_responses"][0]["request_payload"] = raw
            self.assertTrue(self.check(report, receipts, "light")[0], raw)
        for key, value in [("schema_version", 11), ("source_segments", []), ("authorized_context", []),
                           ("user_preferences", ""), ("writing_scene", "workChat"), ("draft_text", "甲")]:
            report, receipts = self.v11_report("甲", "甲")
            self.v7_payload(report, 0, **{key: value})
            self.assertTrue(self.check(report, receipts, "light")[0], key)

    def test_v11_full_source_evidence_remains_required_outside_model_payload(self):
        for field, value in [("canonical_segments", []), ("pre_resolution_canonical_input", "甲"),
                             ("segment_texts", ["甲"]), ("context_fixture", {}),
                             ("resolved_entities", [{"surface_text": "伪造"}])]:
            report, receipts = self.v11_report()
            report["cases"][0][field] = value
            self.assertTrue(self.check(report, receipts, "light")[0], field)
        report, receipts = self.v11_report()
        row = report["cases"][0]
        row.update(canonical_input="偷偷换稿", model_output="偷偷换稿")
        self.v7_payload(report, 0, canonical_text="偷偷换稿")
        self.v7_response(report, receipts, 0, "偷偷换稿")
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v11_entity_resolution_is_retained_without_sending_context_to_model(self):
        report, receipts = self.mapped_context_report()
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 11
        row = report["cases"][0]
        row.update(repair_attempt_count=0, canonical_segments=e.frozen_input_envelope(self.inputs[0])[1])
        row["stage_responses"][0].update(task="voicePolishRender", response_text=row["model_output"],
            request_payload=json.dumps({"canonical_text": row["canonical_input"]}, ensure_ascii=False))
        receipts[0].update(llm_task="voicePolishRender",
                           response_text_sha256=e.legacy.sha256_text(row["model_output"]))
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        row["resolved_entities"][0]["source_segment_ids"] = ["s99"]
        self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v11_single_attempt_no_repair_or_extra_stage(self):
        for field, value in [("llm_call_count", 0), ("llm_call_count", True), ("llm_attempt_count", 0),
                             ("llm_attempt_count", 2), ("repair_attempt_count", 1),
                             ("repair_attempt_count", False), ("internal_chunk_count", 2)]:
            report, receipts = self.v11_report()
            report["cases"][0][field] = value
            self.assertTrue(self.check(report, receipts, "light")[0], (field, value))
        for task in ("voicePolishFast", "voicePolishAnalyze"):
            report, receipts = self.v11_report()
            report["cases"][0]["stage_responses"][0]["task"] = receipts[0]["llm_task"] = task
            self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.v11_report()
        report["cases"][0]["stage_responses"][0]["attempt_ordinal"] = True
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.v11_report()
        row = report["cases"][0]
        row["stage_responses"].append(copy.deepcopy(row["stage_responses"][0]))
        row["stage_responses"][1]["attempt_ordinal"] = 2
        row.update(llm_call_count=2, llm_attempt_count=2)
        receipts.append(copy.deepcopy(receipts[0]))
        receipts[1].update(request_ordinal=2, provider_response_id="unit-test-only-v11-2",
            request_binding_sha256=e.legacy.provider_request_binding_sha256(self.nonce, "fixture-01", 2, "e" * 64))
        self.assertTrue(self.check(report, receipts, "light")[0])
        row.update(stage_responses=[], llm_call_count=0, llm_attempt_count=0)
        self.assertTrue(self.check(report, [], "light")[0])

    def test_v11_actual_body_is_not_trimmed_normalized_or_replaced(self):
        for raw, changed in [(" 甲 ", "甲"), ("甲\r\n乙", "甲\n乙"), ("e\u0301", "é"),
                              ("甲\n\n甲", "甲"), ("甲乙", "甲")]:
            report, receipts = self.v11_report("甲乙", raw)
            report["cases"][0]["model_output"] = changed
            self.assertTrue(self.check(report, receipts, "light")[0])
        for raw in (None, 1, "\ud800"):
            report, receipts = self.v11_report()
            report["cases"][0]["stage_responses"][0]["response_text"] = raw
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v11_only_transport_shape_failures_reject_returned_body(self):
        for raw, code in [("", "emptyOutput"), (" \t\r\n\u3000", "emptyOutput"),
                           ("\u0085", "emptyOutput"), ("\u200b", "emptyOutput"),
                           ("\x1c", "unsafeCharacters"), ("甲\x00", "unsafeCharacters"),
                           ("甲\u0085", "unsafeCharacters"), ("甲\ufdd0", "unsafeCharacters")]:
            report, receipts = self.v11_report("甲", raw)
            self.assertTrue(self.check(report, receipts, "light")[0], repr(raw))
            row = report["cases"][0]
            row.update(fallback_used=True, model_output="甲", hard_validation_codes=[code],
                       failure_reason="validationFailed", rejected_model_output=raw)
            failures, quality = self.check(report, receipts, "light")
            self.assertEqual(failures, [], repr(raw)); self.assertTrue(quality)
            row["rejected_model_output"] = "伪造稿"
            self.assertTrue(self.check(report, receipts, "light")[0])
            row.update(rejected_model_output=raw, model_output="局部稿")
            self.assertTrue(self.check(report, receipts, "light")[0])

    def test_v11_foundation_whitespace_and_first_failure_do_not_change_old_character_rules(self):
        for scalar, blank in [("\u001c", False), ("\u0085", True), ("\u200b", True),
                              ("\u200c", False), ("\ufeff", False)]:
            self.assertEqual(e.v11_foundation_whitespace_only(scalar), blank, repr(scalar))
        self.assertFalse(e.swift_character_is_whitespace("\u200b"))
        for raw in ("\u200c", "\ufeff"):
            report, receipts = self.v11_report("甲", raw)
            self.assertEqual(self.check(report, receipts, "light"), ([], []))
        # 超界响应同时命中多项时，只报告 Swift 按空白、unsafe、字节数顺序遇到的首项。
        for raw, code in [("\u0085" * 524_289, "emptyOutput"), ("甲" * 349_526 + "\x00", "unsafeCharacters")]:
            report, receipts = self.v11_report("甲", raw)
            report["cases"][0].update(fallback_used=True, model_output="甲", hard_validation_codes=[code],
                failure_reason="validationFailed", rejected_model_output=raw)
            failures, quality = self.check(report, receipts, "light")
            self.assertEqual(failures, []); self.assertTrue(quality)

    def test_v11_response_limit_is_utf8_bytes_only_with_exact_boundary(self):
        for raw, code in [("😀" * 262_144, None), ("😀" * 262_144 + "甲", "abnormalLength")]:
            report, receipts = self.v11_report("甲", raw)
            if code is None:
                self.assertEqual(self.check(report, receipts, "light"), ([], []))
            else:
                self.assertTrue(self.check(report, receipts, "light")[0])
                report["cases"][0].update(fallback_used=True, model_output="甲", hard_validation_codes=[code],
                    failure_reason="validationFailed", rejected_model_output=raw)
                failures, quality = self.check(report, receipts, "light")
                self.assertEqual(failures, []); self.assertTrue(quality)

    def test_v11_timeout_truncated_and_request_errors_are_full_fallbacks(self):
        for reason, code in [("timeout", "emptyOutput"), ("requestFailed", "emptyOutput"),
                             ("validationFailed", "abnormalLength")]:
            report, _ = self.v11_report()
            row = report["cases"][0]
            row.update(fallback_used=True, model_output=self.text, failure_reason=reason,
                       hard_validation_codes=[code], llm_call_count=0)
            row["stage_responses"][0].update(status="failed", response_text="", failure_reason="明确的测试异常")
            failures, quality = self.check(report, [], "light")
            self.assertEqual(failures, []); self.assertTrue(quality)
            for field, value in [("model_output", "部分候选"), ("rejected_model_output", "不存在的返回"),
                                 ("hard_validation_codes", []), ("hard_validation_codes", [[]]),
                                 ("failure_reason", None), ("failure_reason", [])]:
                changed = copy.deepcopy(report)
                changed["cases"][0][field] = value
                self.assertTrue(self.check(changed, [], "light")[0], field)
        report, receipts = self.v11_report()
        report["cases"][0].update(fallback_used=True, model_output=self.text,
            hard_validation_codes=["abnormalLength"], failure_reason="validationFailed")
        self.assertTrue(self.check(report, receipts, "light")[0])
        # 输入已取消或零 deadline 在 generate 前结束，不编造请求或回执。
        for reason in ("timeout", "requestFailed"):
            report, _ = self.v11_report()
            report["cases"][0].update(fallback_used=True, model_output=self.text, failure_reason=reason,
                hard_validation_codes=["emptyOutput"], stage_responses=[], llm_attempt_count=0, llm_call_count=0)
            failures, quality = self.check(report, [], "light")
            self.assertEqual(failures, []); self.assertTrue(quality)

    def test_v11_provider_failure_and_receipt_mismatch_cannot_forge_success(self):
        for mutation in ("missing", "http", "response", "nonce", "task", "running"):
            report, receipts = self.v11_report()
            if mutation == "missing": receipts = []
            elif mutation == "http": receipts[0]["http_status"] = 500
            elif mutation == "response": receipts[0]["response_text_sha256"] = "0" * 64
            elif mutation == "nonce": receipts[0]["run_nonce"] = "0" * 64
            elif mutation == "task": receipts[0]["llm_task"] = "voicePolishFast"
            else: report["cases"][0]["stage_responses"][0]["status"] = "running"
            self.assertTrue(self.check(report, receipts, "light")[0], mutation)

    def test_v11_does_not_relax_v10_light_or_standard_semantic_contracts(self):
        for version in (8, 9, 10, 11):
            for source, count in [("甲。乙。", 2), ("帮我整理甲。乙。", 3)]:
                report, receipts = self.v7_report(source, version=version)
                self.assertEqual(self.check(report, receipts, "standard"), ([], []))
                self.assertEqual(len(receipts), count)
                row = report["cases"][0]
                row.update(stage_responses=row["stage_responses"][:1], llm_call_count=1, llm_attempt_count=1)
                self.assertTrue(self.check(report, receipts[:1], "standard")[0])
        report, receipts = self.v10_report("原定周二，改为周三。", "周三。")
        self.assertTrue(self.check(report, receipts, "light")[0])
        report, receipts = self.v10_report("原定周二，改为周三。", "原定周二，改为周三。",
            review={"text": "原定周二，改为周三。", "edits": []})
        self.assertEqual(self.check(report, receipts, "light"), ([], []))
        self.expected["editing_prompt_version"] = 11
        report, receipts = self.report("direct")
        report["cases"][0]["repair_attempt_count"] = 0
        self.assertEqual(self.check(report, receipts, "direct"), ([], []))

    def v12_standard_report(self, source="我我先核对。报价等财务回复。", first="我先核对。报价等财务回复。",
                            final="我先核对。\n\n报价等财务回复。"):
        self.text = source
        self.inputs[0].update(spoken_input=source, segment_texts=[source])
        report, receipts = self.report("standard")
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 12
        row = report["cases"][0]
        row.update(repair_attempt_count=0, model_output=final,
                   canonical_segments=e.frozen_input_envelope(self.inputs[0])[1])
        for i, (task, body, raw) in enumerate([
            ("voicePolishRender", source, first), ("voicePolishStructured", first, final)
        ]):
            row["stage_responses"][i].update(task=task, response_text=raw,
                request_payload=json.dumps({"canonical_text": body}, ensure_ascii=False))
            receipts[i].update(llm_task=task, response_text_sha256=e.legacy.sha256_text(raw))
        return report, receipts

    def v13_report(self, mode="standard", source="原定周二，改为周三。", response="周三。"):
        report, receipts = self.v11_report(source, response)
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 13
        report["mode"] = report["quality_mode"] = mode
        row = report["cases"][0]
        row["mode"] = mode
        row["detected_route"] = row["executed_route"] = "structured" if mode == "standard" else "fast"
        task = "voicePolishStructured" if mode == "standard" else "voicePolishRender"
        row["stage_responses"][0]["task"] = task
        receipts[0].update(mode=mode, llm_task=task)
        return report, receipts

    def test_v13_both_modes_read_original_once_and_preserve_response(self):
        for mode in ("light", "standard"):
            report, receipts = self.v13_report(mode, response="  周三。\r\nCafe\u0301 👩🏽‍💻\t ")
            self.assertEqual(self.check(report, receipts, mode), ([], []))

    def test_v13_rejects_extra_request_wrong_task_source_and_output(self):
        for field, value in [("llm_attempt_count", 2), ("repair_attempt_count", 1),
                             ("model_output", "清洗后的正文"), ("diagnostic_codes", ["额外诊断"])]:
            report, receipts = self.v13_report()
            report["cases"][0][field] = value
            self.assertTrue(self.check(report, receipts, "standard")[0], field)
        report, receipts = self.v12_standard_report()
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 13
        self.assertTrue(self.check(report, receipts, "standard")[0], "两次请求不可冒充新标准")
        for changes in [{"task": "voicePolishRender"},
                        {"request_payload": '{"canonical_text":"轻度生成稿"}'}]:
            report, receipts = self.v13_report()
            report["cases"][0]["stage_responses"][0].update(changes)
            self.assertTrue(self.check(report, receipts, "standard")[0], changes)

    def test_v13_invalid_response_falls_back_to_complete_original(self):
        report, receipts = self.v13_report(source="完整原文。", response=" \n")
        report["cases"][0].update(fallback_used=True, model_output="完整原文。",
            failure_reason="validationFailed", hard_validation_codes=["emptyOutput"],
            rejected_model_output=" \n")
        failures, quality = self.check(report, receipts, "standard")
        self.assertEqual(failures, [])
        self.assertTrue(quality)

    def test_v12_light_keeps_v11_single_render_contract(self):
        for raw in ["周三。", "  首尾\r\n\r空白 e\u0301 👩🏽‍💻\n", '{"edits":[]}', "与来源语义不同也只做证据审计"]:
            report, receipts = self.v11_report(response=raw)
            self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 12
            self.assertEqual(self.check(report, receipts, "light"), ([], []))
            for field, value in [("llm_attempt_count", 2), ("repair_attempt_count", 1),
                                 ("model_output", "偷偷清洗正文")]:
                changed = copy.deepcopy(report)
                changed["cases"][0][field] = value
                self.assertTrue(self.check(changed, receipts, "light")[0], field)
        report, receipts = self.v11_report("甲", "\x00甲")
        self.expected["editing_prompt_version"] = report["editing_prompt_version"] = 12
        report["cases"][0].update(fallback_used=True, model_output="甲", failure_reason="validationFailed",
            hard_validation_codes=["unsafeCharacters"], rejected_model_output="\x00甲")
        failures, quality = self.check(report, receipts, "light")
        self.assertEqual(failures, []); self.assertTrue(quality)

    def test_v12_standard_binds_two_complete_plain_text_stages(self):
        for first, final in [("校对稿。", "结构稿。"),
                             ("  甲\r\n乙 e\u0301 👩🏽‍💻\t ", "  乙\r\n\r甲 é 👩🏽‍💻\t "),
                             ('{"edits":[]}', '<think>正文标签</think>\n润色后：{"text":"甲"}')]:
            report, receipts = self.v12_standard_report(first=first, final=final)
            self.assertEqual(self.check(report, receipts, "standard"), ([], []))
        # 本检查只保证实际正文与请求/交付一致，不用语义、扩写比例或行文样式拒绝响应。
        report, receipts = self.v12_standard_report(first="乙" * 300, final="丙" * 600)
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))

    def test_v12_standard_rejects_source_task_or_output_tampering(self):
        for index in (0, 1):
            for payload in ["{}", "[]", '"正文"', "null", '{"canonical_text":null}',
                            '{"canonical_text":"错误来源"}',
                            '{"canonical_text":"甲","canonical_text":"甲"}',
                            r'{"canonical_text":"甲","\u0063anonical_text":"甲"}',
                            r'{"canonical_text":"\ud800"}']:
                report, receipts = self.v12_standard_report()
                report["cases"][0]["stage_responses"][index]["request_payload"] = payload
                self.assertTrue(self.check(report, receipts, "standard")[0], (index, payload))
            for field, value in [("schema_version", 12), ("mode", "standard"), ("source_segments", []),
                                 ("authorized_context", []), ("draft_text", "首稿"), ("layout_segments", [])]:
                report, receipts = self.v12_standard_report()
                self.v7_payload(report, index, **{field: value})
                self.assertTrue(self.check(report, receipts, "standard")[0], (index, field))
            report, receipts = self.v12_standard_report()
            report["cases"][0]["stage_responses"][index]["task"] = receipts[index]["llm_task"] = "voicePolishAnalyze"
            self.assertTrue(self.check(report, receipts, "standard")[0])
        report, receipts = self.v12_standard_report()
        self.v7_payload(report, 1, canonical_text=self.text)
        self.assertTrue(self.check(report, receipts, "standard")[0], "第二请求不能重新读原稿")
        for field, value in [("canonical_segments", []), ("resolved_entities", [{"surface_text": "伪造"}]),
                             ("pre_resolution_canonical_input", "伪造来源"), ("context_fixture", {})]:
            report, receipts = self.v12_standard_report()
            report["cases"][0][field] = value
            self.assertTrue(self.check(report, receipts, "standard")[0], field)
        for raw, changed in [(" 甲 ", "甲"), ("甲\r\n乙", "甲\n乙"), ("e\u0301", "é"),
                             ("甲\n\n甲", "甲"), ("甲乙", "甲")]:
            report, receipts = self.v12_standard_report(final=raw)
            report["cases"][0]["model_output"] = changed
            self.assertTrue(self.check(report, receipts, "standard")[0], repr(raw))
            report, receipts = self.v12_standard_report(first=raw)
            self.v7_payload(report, 1, canonical_text=changed)
            self.assertTrue(self.check(report, receipts, "standard")[0], "第二请求不能清洗首稿")
        for raw in (None, 1, "\ud800"):
            report, receipts = self.v12_standard_report()
            report["cases"][0]["stage_responses"][1]["response_text"] = raw
            self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v12_standard_failure_preserves_original_and_stops(self):
        for failing_index in (0, 1):
            for reason, code in [("timeout", "emptyOutput"), ("requestFailed", "emptyOutput"),
                                 ("validationFailed", "abnormalLength")]:
                report, receipts = self.v12_standard_report()
                row = report["cases"][0]
                first = row["stage_responses"][0]["response_text"]
                row["stage_responses"] = row["stage_responses"][:failing_index + 1]
                row["stage_responses"][-1].update(status="failed", response_text="", failure_reason="单元测试客户端异常")
                row.update(fallback_used=True, model_output=self.text, failure_reason=reason,
                    hard_validation_codes=[code], llm_call_count=failing_index, llm_attempt_count=failing_index + 1,
                    rejected_model_output=first if failing_index else None)
                failures, quality = self.check(report, receipts[:failing_index], "standard")
                self.assertEqual(failures, [], (failing_index, reason)); self.assertTrue(quality)
                for field, value in [("model_output", first), ("rejected_model_output", "不存在的模型稿"),
                                     ("hard_validation_codes", []), ("hard_validation_codes", [[]]),
                                     ("failure_reason", None), ("failure_reason", [])]:
                    changed = copy.deepcopy(report); changed["cases"][0][field] = value
                    self.assertTrue(self.check(changed, receipts[:failing_index], "standard")[0], field)
                if failing_index:
                    row.update(hard_validation_codes=["unsafeCharacters"], failure_reason="validationFailed")
                    self.assertTrue(self.check(report, receipts[:1], "standard")[0], "无正文的请求失败不能伪造字符门禁")
        for started_count in (0, 1):
            for reason in ("timeout", "requestFailed"):
                report, receipts = self.v12_standard_report()
                row = report["cases"][0]
                draft = row["stage_responses"][0]["response_text"] if started_count else None
                row.update(stage_responses=row["stage_responses"][:started_count], llm_call_count=started_count,
                    llm_attempt_count=started_count, fallback_used=True, model_output=self.text,
                    failure_reason=reason, hard_validation_codes=["emptyOutput"], rejected_model_output=draft)
                failures, quality = self.check(report, receipts[:started_count], "standard")
                self.assertEqual(failures, []); self.assertTrue(quality)
        report, receipts = self.v12_standard_report()
        row = report["cases"][0]
        row["stage_responses"][0].update(status="failed", response_text="", failure_reason="首阶段失败")
        row.update(fallback_used=True, model_output=self.text, failure_reason="requestFailed",
                   hard_validation_codes=["emptyOutput"], llm_call_count=1)
        self.v7_payload(report, 1, canonical_text="")
        self.assertTrue(self.check(report, receipts[1:], "standard")[0], "首阶段失败后不得继续结构请求")

    def test_v12_standard_rejects_third_attempt_or_repair(self):
        for field, value in [("llm_call_count", 1), ("llm_call_count", True), ("llm_attempt_count", 1),
                             ("llm_attempt_count", 3), ("repair_attempt_count", 1),
                             ("repair_attempt_count", False), ("internal_chunk_count", 2),
                             ("rejected_model_output", "伪造拒绝稿")]:
            report, receipts = self.v12_standard_report()
            report["cases"][0][field] = value
            self.assertTrue(self.check(report, receipts, "standard")[0], field)
        report, receipts = self.v12_standard_report()
        row = report["cases"][0]
        row["stage_responses"][0]["attempt_ordinal"] = True
        self.assertTrue(self.check(report, receipts, "standard")[0])
        report, receipts = self.v12_standard_report()
        row = report["cases"][0]
        row["stage_responses"].append(copy.deepcopy(row["stage_responses"][-1]))
        row["stage_responses"][-1].update(attempt_ordinal=3)
        row.update(llm_call_count=3, llm_attempt_count=3)
        receipts.append(copy.deepcopy(receipts[-1]))
        receipts[-1].update(request_ordinal=3, provider_response_id="unit-test-only-v12-third",
            request_binding_sha256=e.legacy.provider_request_binding_sha256(self.nonce, "fixture-01", 3, "e" * 64))
        self.assertTrue(self.check(report, receipts, "standard")[0])
        report, receipts = self.v12_standard_report()
        row = report["cases"][0]
        row.update(stage_responses=row["stage_responses"][:1], llm_call_count=1, llm_attempt_count=1,
                   model_output=row["stage_responses"][0]["response_text"])
        self.assertTrue(self.check(report, receipts[:1], "standard")[0], "首稿不能冒充标准成功")
        report, receipts = self.v12_standard_report()
        report["cases"][0]["stage_responses"][1]["started_at"] = (self.now - timedelta(milliseconds=1)).isoformat()
        self.assertTrue(self.check(report, receipts, "standard")[0], "两个请求不能并行")

    def test_v12_standard_transport_guards_apply_to_both_bodies(self):
        for index in (0, 1):
            for raw, code in [("", "emptyOutput"), (" \r\n\u0085\u200b", "emptyOutput"),
                              ("甲\x00", "unsafeCharacters"), ("甲\ufdd0", "unsafeCharacters"),
                              ("😀" * 262_144 + "甲", "abnormalLength")]:
                report, receipts = self.v12_standard_report()
                row = report["cases"][0]
                self.v7_response(report, receipts, index, raw)
                row.update(stage_responses=row["stage_responses"][:index + 1], llm_call_count=index + 1,
                    llm_attempt_count=index + 1, fallback_used=True, model_output=self.text,
                    failure_reason="validationFailed", hard_validation_codes=[code], rejected_model_output=raw)
                failures, quality = self.check(report, receipts[:index + 1], "standard")
                self.assertEqual(failures, [], (index, repr(raw[:20]))); self.assertTrue(quality)
                row.update(fallback_used=False, failure_reason=None, hard_validation_codes=[],
                           rejected_model_output=None, model_output=raw)
                self.assertTrue(self.check(report, receipts[:index + 1], "standard")[0])
        report, receipts = self.v12_standard_report(first="😀" * 262_144, final="😀" * 262_144)
        self.assertEqual(self.check(report, receipts, "standard"), ([], []))

    def test_v12_standard_requires_both_provider_receipts(self):
        for mutation in ("missing", "http", "response", "nonce", "task", "running"):
            report, receipts = self.v12_standard_report()
            if mutation == "missing": receipts = receipts[:1]
            elif mutation == "http": receipts[1]["http_status"] = 500
            elif mutation == "response": receipts[1]["response_text_sha256"] = "0" * 64
            elif mutation == "nonce": receipts[1]["run_nonce"] = "0" * 64
            elif mutation == "task": receipts[1]["llm_task"] = "voicePolishAnalyze"
            else: report["cases"][0]["stage_responses"][1]["status"] = "running"
            self.assertTrue(self.check(report, receipts, "standard")[0], mutation)

    def test_v12_standard_optional_requirements_need_an_independent_source(self):
        source, requirements = "  校对正文\r\n", "  按事项分点，保留我的语气。\n"
        payload = {"canonical_text": source, "additional_requirements": requirements}
        raw = json.dumps(payload, ensure_ascii=False)
        self.assertEqual(e.decode_v12_standard_payload(raw, source, requirements), payload)
        with self.assertRaises(ValueError):
            e.decode_v12_standard_payload(raw, source)
        for changed in [requirements.strip(), "别的要求", None, 1]:
            value = dict(payload, additional_requirements=changed)
            with self.assertRaises(ValueError):
                e.decode_v12_standard_payload(json.dumps(value, ensure_ascii=False), source, requirements)
        with self.assertRaises(ValueError):
            e.decode_v12_standard_payload(json.dumps({"canonical_text": source}), source, requirements)
        for whitespace in ("", " \t\r\n", "\u0085\u200b"):
            single = {"canonical_text": source}
            self.assertEqual(e.decode_v12_standard_payload(json.dumps(single), source, whitespace), single)
            with self.assertRaises(ValueError):
                e.decode_v12_standard_payload(json.dumps(dict(single, additional_requirements=whitespace)),
                                             source, whitespace)
        # 当前 Runner 的偏好恒为空；不能拿实际请求中的字段作为它自己的来源证据。
        for index in (0, 1):
            report, receipts = self.v12_standard_report()
            self.v7_payload(report, index, additional_requirements="请分点")
            self.assertTrue(self.check(report, receipts, "standard")[0])

    def test_v12_direct_still_has_zero_requests_and_repairs(self):
        self.expected["editing_prompt_version"] = 12
        report, receipts = self.report("direct")
        report["cases"][0]["repair_attempt_count"] = 0
        self.assertEqual(self.check(report, receipts, "direct"), ([], []))
        report["cases"][0]["repair_attempt_count"] = False
        self.assertTrue(self.check(report, receipts, "direct")[0])

    def test_input_limit_checks_both_sources_and_rejects_answers(self):
        for source_length, segment_length, valid in [(1000, 1000, True), (1001, 1, False), (1, 1001, False)]:
            inputs = copy.deepcopy(self.inputs)
            inputs[0].update(spoken_input="甲" * source_length, segment_texts=["乙" * segment_length])
            if valid:
                e.validate_inputs(inputs)
            else:
                with self.assertRaises(ValueError): e.validate_inputs(inputs)
        inputs = copy.deepcopy(self.inputs); inputs[0]["reference_output"] = "答案"
        with self.assertRaises(ValueError): e.validate_inputs(inputs)
        with self.assertRaises(ValueError): e.validate_inputs(self.inputs * 2)

    def test_source_paragraph_difference_is_preserved_not_rejected(self):
        inputs = copy.deepcopy(self.inputs)
        inputs[0].update(spoken_input="第一段。\n\n第二段。", segment_texts=["第一段。", "第二段。"])
        before = copy.deepcopy(inputs)
        e.validate_inputs(inputs)
        self.assertEqual(inputs, before)

    def test_frozen_real_dataset_has_separate_suites_and_no_oversize_inputs(self):
        dataset = ROOT / "docs/2026-09-10-Dal-Three-Mode-Quality-Test-Set.json"
        contracts = ROOT / "docs/2026-09-10-Dal-Three-Mode-Quality-Contracts.json"
        document = e.validated_dataset(dataset, e.legacy.sha256_file(dataset), contracts, e.legacy.sha256_file(contracts))
        self.assertEqual(document["suite_counts"], {"acceptance127": 127, "core_regression37": 37, "mode_boundary8": 8})
        self.assertEqual(len(document["inputs"]), 172)
        self.assertEqual(max(len(x["spoken_input"]) for x in document["inputs"]), 907)
        for origin in document["input_provenance"][:127]:
            self.assertEqual(origin["source_input_sha256"], origin["input_sha256"])
        selected = e.selected_inputs(document, ["core-holdout-29", "core-sem-11", "boundary-tiny-01"])
        self.assertEqual(len(selected), 3)
        with self.assertRaises(ValueError): e.selected_inputs(document, ["does-not-exist"])
        with self.assertRaises(ValueError): e.selected_inputs(document, ["micro-01", "micro-01"])
        with self.assertRaises(ValueError): e.validated_dataset(dataset, "0" * 64, contracts, e.legacy.sha256_file(contracts))

    def test_manifest_must_freeze_new_profile_and_contract_hash(self):
        with tempfile.TemporaryDirectory(prefix="DalThreeModeManifestTests-") as directory:
            path = Path(directory) / "manifest.json"
            requirement = 'identifier "pro.daliang.muse" and certificate leaf = H"unit-test-only"'
            manifest = {"schema_version": 1, "artifact_kind": "dal_voice_polish_quality_candidate",
                        "package_mode": "production", "bundle_id": "pro.daliang.muse",
                        "source_commit": "1" * 40, "source_tree": "2" * 40,
                        "executable_sha256": "3" * 64, "dataset_sha256": "4" * 64,
                        "designated_requirement": requirement,
                        "designated_requirement_sha256": e.legacy.sha256_text(requirement),
                        "quality_profile": "three_mode", "supported_modes": list(e.MODES),
                        "scoring_contract_sha256": "5" * 64}
            path.write_text(json.dumps(manifest))
            args = SimpleNamespace(build_manifest=path, expected_build_manifest_sha256=e.legacy.sha256_file(path),
                                   expected_source_commit="1" * 40, expected_source_tree="2" * 40,
                                   expected_executable_sha256="3" * 64, expected_dataset_sha256="4" * 64,
                                   expected_designated_requirement_sha256=e.legacy.sha256_text(requirement),
                                   expected_contract_sha256="5" * 64)
            self.assertEqual(e.validated_manifest(args)["quality_profile"], "three_mode")
            args.expected_contract_sha256 = "6" * 64
            with self.assertRaises(ValueError): e.validated_manifest(args)

    def test_launch_is_explicit_isolated_and_has_no_authorization_operation(self):
        argv = e.launch_command(Path("/fake/Dal"), Path("/input"), Path("/report"), Path("/audit"),
                                Path("/sandbox"), "light", self.nonce)
        self.assertEqual(argv[:6], ["/usr/bin/sandbox-exec", "-f", "/sandbox", "/usr/bin/nice", "-n", "15"])
        self.assertEqual(argv[argv.index("--mode") + 1], "light")
        self.assertNotIn("--voice-polish-quality-authorize-keychain", argv)
        self.assertIn("Library/Application Support/Muse", e.sandbox_policy())
        self.assertIn("deny file-read* file-write*", e.sandbox_policy())
        self.assertIn("deny device-microphone", e.sandbox_policy())
        with self.assertRaises(ValueError):
            e.launch_command(Path("/fake"), Path("/i"), Path("/r"), Path("/a"), Path("/s"), "automatic", self.nonce)

    def test_run_root_is_exclusive_and_rejects_protected_user_directory(self):
        with tempfile.TemporaryDirectory(prefix="DalThreeModeRootTests-") as directory:
            with self.assertRaises(ValueError): e.validate_run_root(Path(directory))
            e.validate_run_root(Path(directory) / "unused")
        with self.assertRaises(ValueError): e.validate_run_root(Path("relative-output"))
        protected = Path(e.pwd.getpwuid(os.getuid()).pw_dir) / "Library/Application Support/Muse/forbidden-test-output"
        with self.assertRaises(ValueError): e.validate_run_root(protected)

    def test_actual_package_manifest_writer_binds_separate_contracts(self):
        package = (ROOT / "scripts/package-app.sh").read_text()
        marker = '/usr/bin/python3 - "$QUALITY_BUILD_MANIFEST_PATH" <<\'PY\'\n'
        self.assertEqual(package.count(marker), 1)
        source = package.split(marker, 1)[1].split("\nPY\n", 1)[0]
        with tempfile.TemporaryDirectory(prefix="DalThreeModePackageWriterTests-") as directory:
            directory = Path(directory)
            dataset = directory / "dataset.json"
            dataset.write_text(json.dumps({"inputs": self.inputs}))
            contract = directory / "contract.json"
            contract.write_text(json.dumps({"dataset_sha256": e.legacy.sha256_file(dataset), "input_count": 1}))
            output = directory / "manifest.json"
            requirement = 'identifier "pro.daliang.muse"'
            environment = {
                "DAL_MANIFEST_PACKAGE_MODE": "test", "DAL_MANIFEST_BUNDLE_ID": "pro.daliang.muse",
                "DAL_MANIFEST_SOURCE_COMMIT": "1" * 40, "DAL_MANIFEST_SOURCE_TREE": "2" * 40,
                "DAL_MANIFEST_EXECUTABLE_SHA256": "3" * 64,
                "DAL_MANIFEST_DATASET_SHA256": e.legacy.sha256_file(dataset),
                "DAL_MANIFEST_DESIGNATED_REQUIREMENT": requirement,
                "DAL_MANIFEST_DESIGNATED_REQUIREMENT_SHA256": e.legacy.sha256_text(requirement),
                "DAL_MANIFEST_QUALITY_PROFILE": "three_mode", "DAL_MANIFEST_CONTRACT_PATH": str(contract),
                "DAL_MANIFEST_DATASET_PATH": str(dataset),
            }
            with patch.dict(os.environ, environment), patch.object(sys, "argv", ["manifest-writer", str(output)]):
                exec(compile(source, "package-app.sh manifest writer", "exec"), {})
            manifest = json.loads(output.read_text())
            self.assertEqual(manifest["quality_profile"], "three_mode")
            self.assertEqual(manifest["supported_modes"], list(e.MODES))
            self.assertEqual(manifest["scoring_contract_sha256"], e.legacy.sha256_file(contract))
            self.assertEqual(manifest["three_mode_input_count"], 1)
            self.assertEqual(output.stat().st_mode & 0o777, 0o444)
            contract.write_text(json.dumps({"dataset_sha256": "0" * 64, "input_count": 1}))
            with patch.dict(os.environ, environment), patch.object(sys, "argv", ["manifest-writer", str(directory / "invalid.json")]):
                with self.assertRaises(SystemExit):
                    exec(compile(source, "package-app.sh manifest writer", "exec"), {})


if __name__ == "__main__":
    unittest.main()
