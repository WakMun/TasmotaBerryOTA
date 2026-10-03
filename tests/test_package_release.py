import hashlib
import json

import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from tools.package_release import (
    create_manifest,
    generate_keys,
    load_private_key,
    parse_build,
    parse_version,
    signed_manifest_message,
    write_manifest,
)


def test_manifest_contains_source_hash_and_signed_release_metadata():
    key = Ed25519PrivateKey.generate()
    source = b'import gpio\nchange_color()\n'

    manifest = create_manifest(source, "1.2.3", 42, key)

    assert manifest["version"] == "1.2.3"
    assert manifest["build"] == 42
    assert manifest["sha256"] == hashlib.sha256(source).hexdigest().upper()
    key.public_key().verify(
        bytes.fromhex(manifest["signature"]),
        hashlib.sha256(
            signed_manifest_message("1.2.3", 42, manifest["sha256"])
        ).digest(),
    )


def test_signature_authenticates_build_and_version():
    key = Ed25519PrivateKey.generate()
    manifest = create_manifest(b"application", "2.0.1", 7, key)
    tampered_message = hashlib.sha256(
        signed_manifest_message("2.0.1", 8, manifest["sha256"])
    ).digest()

    with pytest.raises(InvalidSignature):
        key.public_key().verify(bytes.fromhex(manifest["signature"]), tampered_message)


def test_manifest_rejects_empty_source_and_invalid_version_or_build():
    key = Ed25519PrivateKey.generate()

    with pytest.raises(ValueError, match="must not be empty"):
        create_manifest(b"", "1.0.0", 1, key)
    with pytest.raises(ValueError):
        parse_version("01.0.0")
    with pytest.raises(ValueError):
        parse_version("65536.0.0")
    with pytest.raises(ValueError):
        parse_build("0")
    with pytest.raises(ValueError):
        parse_build("1.2")


def test_write_manifest_serializes_a_signed_source_manifest(tmp_path):
    key = Ed25519PrivateKey.generate()
    key_path = tmp_path / "signing.pem"
    key_path.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    source_path = tmp_path / "Application.be"
    source_path.write_bytes(b"application source")
    manifest_path = tmp_path / "dist" / "app_manifest.json"

    write_manifest(source_path, "3.1.4", 123, key_path, manifest_path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    assert manifest["sha256"] == hashlib.sha256(source_path.read_bytes()).hexdigest().upper()
    key.public_key().verify(
        bytes.fromhex(manifest["signature"]),
        hashlib.sha256(
            signed_manifest_message("3.1.4", 123, manifest["sha256"])
        ).digest(),
    )


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
