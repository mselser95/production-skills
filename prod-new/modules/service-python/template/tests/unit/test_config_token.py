import pytest

from <PACKAGE>.platform import (
    config,
)

GOOD = "A1._~+/=-" + "x" * 23


# provenance: derived
# verifies: units_ledger/write_authn
@pytest.mark.parametrize(
    "token",
    [
        " " * 16,
        " " * 32,
        "x" * 31,
        "x" * 31 + " ",
        " " + "x" * 32,
        "x" * 16 + " " + "x" * 16,
        "x" * 32 + "\n",
        "x" * 31 + "\t",
        "x" * 31 + "é",
        "x" * 31 + "!",
        "x" * 31 + chr(0x661),
        "",
    ],
)
def test_a_weak_or_malformed_token_refuses_to_start(token: str) -> None:
    with pytest.raises(config.ConfigError) as caught:
        config.load({"SVC_API_TOKEN": token})
    assert "SVC_API_TOKEN" in str(caught.value)
    assert token.strip() == "" or token not in str(caught.value)


# provenance: derived
# verifies: units_ledger/write_authn
def test_a_token_of_32_allowed_characters_is_accepted() -> None:
    assert config.load({"SVC_API_TOKEN": GOOD}).api_token == GOOD
    assert config.load({"SVC_API_TOKEN": "x" * 200}).api_token == "x" * 200


# provenance: derived
# verifies: refuses_bad_config
@pytest.mark.parametrize("port", ["9" * 5000, "9" * 6, "65536", "-1", "", "1e3", chr(0x661), " 80"])
def test_a_bad_port_is_a_config_error_never_a_traceback(port: str) -> None:
    with pytest.raises(config.ConfigError, match="SVC_PORT"):
        config.load({"SVC_API_TOKEN": GOOD, "SVC_PORT": port})


# provenance: derived
# verifies: refuses_bad_config
def test_a_port_in_range_is_accepted() -> None:
    assert config.load({"SVC_API_TOKEN": GOOD, "SVC_PORT": "65535"}).port == 65535
    assert config.load({"SVC_API_TOKEN": GOOD, "SVC_PORT": "0"}).port == 0
