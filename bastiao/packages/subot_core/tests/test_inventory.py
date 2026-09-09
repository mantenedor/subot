from __future__ import annotations

import pytest

from subot_core.inventory import Inventory


def test_reload_finds_host_yaml_at_any_depth(tmp_path):
    domain = tmp_path / "domain"
    (domain / "on-prem" / "compose").mkdir(parents=True)
    (domain / "on-prem" / "compose" / "host.yaml").write_text(
        "address: 10.32.51.120\nuser: subot\ngroups: [container-hosts]\ntags: [protected]\n",
        encoding="utf-8",
    )
    (domain / "acme" / "us-east" / "zone-a" / "web-1").mkdir(parents=True)
    (domain / "acme" / "us-east" / "zone-a" / "web-1" / "host.yaml").write_text(
        "address: 10.0.0.9\n", encoding="utf-8",
    )

    inv = Inventory(path=domain)

    names = {h.name for h in inv.list()}
    assert names == {"compose", "web-1"}
    compose = inv.get("compose")
    assert compose.address == "10.32.51.120"
    assert compose.is_protected
    assert inv.host_dir("compose") == domain / "on-prem" / "compose"


def test_reload_on_missing_domain_dir_is_empty(tmp_path):
    inv = Inventory(path=tmp_path / "does-not-exist")
    assert inv.list() == []


def test_get_missing_host_raises_keyerror(tmp_path):
    inv = Inventory(path=tmp_path / "domain")
    with pytest.raises(KeyError):
        inv.get("nope")


def test_save_new_host_requires_domain_path(tmp_path):
    inv = Inventory(path=tmp_path / "domain")
    with pytest.raises(ValueError):
        inv.save("newhost", {"address": "10.0.0.1"})


def test_save_new_host_creates_leaf_and_reloads(tmp_path):
    domain = tmp_path / "domain"
    inv = Inventory(path=domain)

    host_dir = inv.save("newhost", {"address": "10.0.0.1", "user": "subot"}, domain_path="on-prem")

    assert host_dir == domain / "on-prem" / "newhost"
    assert (host_dir / "host.yaml").exists()
    assert inv.get("newhost").address == "10.0.0.1"


def test_save_existing_host_reuses_its_own_dir_and_ignores_domain_path(tmp_path):
    domain = tmp_path / "domain"
    inv = Inventory(path=domain)
    inv.save("newhost", {"address": "10.0.0.1"}, domain_path="on-prem")

    # domain_path diferente é ignorado — o host já tem um diretório-folha.
    host_dir = inv.save("newhost", {"address": "10.0.0.2"}, domain_path="should-be-ignored")

    assert host_dir == domain / "on-prem" / "newhost"
    assert not (domain / "should-be-ignored").exists()
    assert inv.get("newhost").address == "10.0.0.2"
