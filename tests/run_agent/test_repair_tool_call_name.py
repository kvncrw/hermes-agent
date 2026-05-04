"""Tests for AIAgent._repair_tool_call — tool-name normalization.

Regression guard for #14784: Claude-style models sometimes emit
class-like tool-call names (``TodoTool_tool``, ``Patch_tool``,
``BrowserClick_tool``, ``PatchTool``). Before the fix they returned
"Unknown tool" even though the target tool was registered under a
snake_case name. The repair routine now normalizes CamelCase,
strips trailing ``_tool`` / ``-tool`` / ``tool`` suffixes (up to
twice to handle double-tacked suffixes like ``TodoTool_tool``), and
falls back to fuzzy match.
"""
from __future__ import annotations

import json
from types import SimpleNamespace

import pytest


VALID = {
    "todo",
    "patch",
    "browser_click",
    "browser_navigate",
    "web_search",
    "read_file",
    "write_file",
    "terminal",
}


@pytest.fixture
def repair():
    """Return a bound _repair_tool_call built on a minimal shell agent.

    We avoid constructing a real AIAgent (which pulls in credential
    resolution, session DB, etc.) because the repair routine only
    reads self.valid_tool_names. A SimpleNamespace stub is enough to
    bind the unbound function.
    """
    from run_agent import AIAgent
    stub = SimpleNamespace(valid_tool_names=VALID)
    return AIAgent._repair_tool_call.__get__(stub, AIAgent)


class TestExistingBehaviorStillWorks:
    """Pre-existing repairs must keep working (no regressions)."""

    def test_lowercase_already_matches(self, repair):
        assert repair("browser_click") == "browser_click"

    def test_uppercase_simple(self, repair):
        assert repair("TERMINAL") == "terminal"

    def test_dash_to_underscore(self, repair):
        assert repair("web-search") == "web_search"

    def test_space_to_underscore(self, repair):
        assert repair("write file") == "write_file"

    def test_fuzzy_near_miss(self, repair):
        # One-character typo — fuzzy match at 0.7 cutoff
        assert repair("terminall") == "terminal"

    def test_unknown_returns_none(self, repair):
        assert repair("xyz_no_such_tool") is None


class TestClassLikeEmissions:
    """Regression coverage for #14784 — CamelCase + _tool suffix variants."""

    def test_camel_case_no_suffix(self, repair):
        assert repair("BrowserClick") == "browser_click"

    def test_camel_case_with_underscore_tool_suffix(self, repair):
        assert repair("BrowserClick_tool") == "browser_click"

    def test_camel_case_with_Tool_class_suffix(self, repair):
        assert repair("PatchTool") == "patch"

    def test_double_tacked_class_and_snake_suffix(self, repair):
        # Hardest case from the report: TodoTool_tool — strip both
        # '_tool' (trailing) and 'Tool' (CamelCase embedded) to reach 'todo'.
        assert repair("TodoTool_tool") == "todo"

    def test_simple_name_with_tool_suffix(self, repair):
        assert repair("Patch_tool") == "patch"

    def test_simple_name_with_dash_tool_suffix(self, repair):
        assert repair("patch-tool") == "patch"

    def test_camel_case_preserves_multi_word_match(self, repair):
        assert repair("ReadFile_tool") == "read_file"
        assert repair("WriteFileTool") == "write_file"

    def test_mixed_separators_and_suffix(self, repair):
        assert repair("write-file_Tool") == "write_file"


class TestEdgeCases:
    """Edge inputs that must not crash or produce surprising results."""

    def test_empty_string(self, repair):
        assert repair("") is None

    def test_only_tool_suffix(self, repair):
        # '_tool' by itself is not a valid tool name — must not match
        # anything plausible.
        assert repair("_tool") is None

    def test_none_passed_as_name(self, repair):
        # Defensive: real callers always pass str, but guard against
        # a bug upstream that sends None.
        assert repair(None) is None

    def test_very_long_name_does_not_match_by_accident(self, repair):
        # Fuzzy match should not claim a tool for something obviously unrelated.
        assert repair("ThisIsNotRemotelyARealToolName_tool") is None


class TestSkillToolConfusionRepair:
    """Local models may call a skill slug as though it were a tool."""

    def test_skill_slug_tool_call_rewrites_to_skill_view(self, monkeypatch):
        from run_agent import AIAgent

        stub = SimpleNamespace(valid_tool_names={"skill_view"})
        stub._repair_tool_call = AIAgent._repair_tool_call.__get__(stub, AIAgent)
        stub._resolve_skill_name_for_tool_call = (
            AIAgent._resolve_skill_name_for_tool_call.__get__(stub, AIAgent)
        )
        repair_call = AIAgent._repair_tool_call_for_execution.__get__(stub, AIAgent)

        monkeypatch.setattr(
            "agent.skill_commands.resolve_skill_command_key",
            lambda command: "/github-issues" if command == "github-issues" else None,
        )
        monkeypatch.setattr(
            "agent.skill_commands.get_skill_commands",
            lambda: {"/github-issues": {"name": "github-issues"}},
        )

        tool_call = SimpleNamespace(
            function=SimpleNamespace(
                name="github_issues",
                arguments='{"action":"create","title":"bug"}',
            )
        )

        assert repair_call(tool_call) == ("github_issues", "skill_view")
        assert tool_call.function.name == "skill_view"
        assert json.loads(tool_call.function.arguments) == {"name": "github-issues"}

    def test_bare_textual_skill_view_is_recovered_as_tool_call(self):
        from run_agent import AIAgent

        stub = SimpleNamespace(valid_tool_names={"skill_view"})
        stub._strip_think_blocks = lambda content: content
        stub._deterministic_call_id = AIAgent._deterministic_call_id
        parse = AIAgent._parse_bare_textual_tool_call.__get__(stub, AIAgent)

        tool_call = parse("skill_view(name='github-issues')")

        assert tool_call is not None
        assert tool_call.function.name == "skill_view"
        assert json.loads(tool_call.function.arguments) == {"name": "github-issues"}

    def test_bare_textual_recovery_ignores_prose(self):
        from run_agent import AIAgent

        stub = SimpleNamespace(valid_tool_names={"skill_view"})
        stub._strip_think_blocks = lambda content: content
        stub._deterministic_call_id = AIAgent._deterministic_call_id
        parse = AIAgent._parse_bare_textual_tool_call.__get__(stub, AIAgent)

        assert parse("I should call skill_view(name='github-issues') next.") is None
