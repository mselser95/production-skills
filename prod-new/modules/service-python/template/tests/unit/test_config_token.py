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
