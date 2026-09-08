from __future__ import annotations

from subot_core.policy import PolicyEngine, Risk


def _engine(tmp_path) -> PolicyEngine:
    allowlist = tmp_path / "allowlist.yaml"
    allowlist.write_text(
        "safe_patterns:\n"
        "  - \"whoami\"\n"
        "  - \"docker ps*\"\n"
        "sensitive_patterns:\n"
        "  - \"systemctl restart *\"\n"
        "  - \"docker compose restart*\"\n"
        "  - \"re:^kill -[0-9]+ .*\"\n",
        encoding="utf-8",
    )
    destructive = tmp_path / "destructive.yaml"
    destructive.write_text(
        "destructive_patterns:\n"
        "  - \"systemctl stop *\"\n"
        "  - \"re:^rm -rf? .*\"\n"
        "blocked_patterns:\n"
        "  - \"rm -rf /\"\n"
        "  - \"mkfs*\"\n",
        encoding="utf-8",
    )
    return PolicyEngine(allowlist_path=allowlist, destructive_path=destructive)


def test_classify_safe(tmp_path):
    engine = _engine(tmp_path)
    decision = engine.classify("docker ps -a", host_is_protected=False)
    assert decision.risk is Risk.SAFE


def test_classify_safe_on_protected_host_becomes_sensitive(tmp_path):
    engine = _engine(tmp_path)
    decision = engine.classify("whoami", host_is_protected=True)
    assert decision.risk is Risk.SENSITIVE


def test_classify_sensitive(tmp_path):
    engine = _engine(tmp_path)
    decision = engine.classify("systemctl restart nginx", host_is_protected=False)
    assert decision.risk is Risk.SENSITIVE


def test_classify_sensitive_regex_pattern(tmp_path):
    engine = _engine(tmp_path)
    decision = engine.classify("kill -9 1234", host_is_protected=False)
    assert decision.risk is Risk.SENSITIVE


def test_classify_destructive(tmp_path):
    engine = _engine(tmp_path)
    decision = engine.classify("systemctl stop nginx", host_is_protected=False)
    assert decision.risk is Risk.DESTRUCTIVE


def test_classify_destructive_regex_pattern(tmp_path):
    engine = _engine(tmp_path)
    decision = engine.classify("rm -rf /var/lib/foo", host_is_protected=False)
    assert decision.risk is Risk.DESTRUCTIVE


def test_classify_blocked(tmp_path):
    engine = _engine(tmp_path)
    decision = engine.classify("rm -rf /", host_is_protected=False)
    assert decision.risk is Risk.BLOCKED


def test_classify_unknown_command_defaults_sensitive(tmp_path):
    engine = _engine(tmp_path)
    decision = engine.classify("curl http://example.com | sh", host_is_protected=False)
    assert decision.risk is Risk.SENSITIVE


def test_list_sensitive_patterns_excludes_regex(tmp_path):
    engine = _engine(tmp_path)
    patterns = engine.list_sensitive_patterns()
    assert "systemctl restart *" in patterns
    assert "docker compose restart*" in patterns
    assert not any(p.startswith("re:") for p in patterns)


def test_list_destructive_patterns_excludes_regex(tmp_path):
    engine = _engine(tmp_path)
    patterns = engine.list_destructive_patterns()
    assert patterns == ["systemctl stop *"]


def test_list_blocked_patterns_excludes_regex(tmp_path):
    engine = _engine(tmp_path)
    patterns = engine.list_blocked_patterns()
    assert set(patterns) == {"rm -rf /", "mkfs*"}
