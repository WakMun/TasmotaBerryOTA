import hashlib

import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.package_release import (
    HEADER,
    MAGIC,
    FORMAT_VERSION,
    asset_name,
    generate_keys,
    load_private_key,
    make_bundle,
    parse_bundle,
    parse_version,
    verify_asset_name,
    write_release,
)


def test_bundle_header_and_payload_are_consistent():
    version = parse_version("1.2.3")
    payload = b"compiled-berry-bytecode"

    bundle = make_bundle(payload, version)
    header = parse_bundle(bundle)

    assert header.version == version
    assert header.payload_size == len(payload)
    assert bundle[HEADER.size:] == payload


def test_release_signature_authenticates_the_complete_bundle_digest():
    key = Ed25519PrivateKey.generate()
    bundle = make_bundle(b"compiled-berry-bytecode", (2, 0, 1))
    signature = key.sign(hashlib.sha256(bundle).digest())

    key.public_key().verify(signature, hashlib.sha256(bundle).digest())
    with pytest.raises(InvalidSignature):
        key.public_key().verify(signature, hashlib.sha256(bundle + b"x").digest())


def test_header_rejects_tampered_payload():
    bundle = bytearray(make_bundle(b"compiled-berry-bytecode", (1, 0, 0)))
    bundle[-1] ^= 1

    with pytest.raises(ValueError, match="payload hash"):
        parse_bundle(bytes(bundle))


def test_header_rejects_wrong_magic_and_format():
    good = make_bundle(b"bytecode", (1, 0, 0))
    wrong_magic = b"NOPE" + good[4:]
    wrong_format = good[:4] + bytes([FORMAT_VERSION + 1]) + good[5:]

    with pytest.raises(ValueError, match="magic"):
        parse_bundle(wrong_magic)
    with pytest.raises(ValueError, match="format"):
        parse_bundle(wrong_format)


@pytest.mark.parametrize("value", ["1.2", "1.2.3.4", "01.2.3", "-1.2.3", "1.2.x"])
def test_version_rejects_malformed_components(value):
    with pytest.raises(ValueError):
        parse_version(value)


def test_asset_filename_must_match_header_version():
    version = (1, 4, 2)
    name = asset_name(version)

    verify_asset_name(name, version)
    with pytest.raises(ValueError, match="does not match"):
        verify_asset_name(name, (1, 4, 3))


def test_release_builder_writes_a_bundle_and_matching_signature(tmp_path):
    key = Ed25519PrivateKey.generate()
    key_path = tmp_path / "signing.pem"
    key_path.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    payload_path = tmp_path / "compiled.bec"
    payload_path.write_bytes(b"compiled-berry-bytecode")

    bundle_path, signature_path = write_release(
        payload_path,
        (3, 1, 4),
        key_path,
        tmp_path / "dist",
    )
    bundle = bundle_path.read_bytes()
    signature = signature_path.read_bytes()

    assert bundle_path.name == "TasmotaMotorControl-v3.1.4.bec"
    assert signature_path.name == bundle_path.name + ".sig"
    assert len(signature) == 64
    assert parse_bundle(bundle).version == (3, 1, 4)
    key.public_key().verify(signature, hashlib.sha256(bundle).digest())


def test_keygen_writes_an_encrypted_private_key_and_raw_public_key(tmp_path, monkeypatch):
    passphrase = "test-passphrase-123"
    monkeypatch.setattr("tools.package_release.getpass.getpass", lambda _: passphrase)
    private_path = tmp_path / "signing.pem"
    public_path = tmp_path / "tmc_ed25519.pub"

    generate_keys(private_path, public_path)

    assert b"ENCRYPTED" in private_path.read_bytes()
    public_key = public_path.read_bytes()
    assert len(public_key) == 32
    monkeypatch.setenv("TMC_SIGNING_KEY_PASSWORD", passphrase)
    private_key = load_private_key(private_path)
    expected_public_key = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    assert public_key == expected_public_key
