import hashlib
import json

import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import (
    encode_dss_signature,
)
from cryptography.hazmat.primitives.hashes import SHA256

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
    key = ec.generate_private_key(ec.SECP256R1())
    source = b'import gpio\nchange_color()\n'

    manifest = create_manifest(source, "1.2.3", 42, key)

    assert manifest["version"] == "1.2.3"
    assert manifest["build"] == 42
    assert manifest["sha256"] == hashlib.sha256(source).hexdigest().upper()
    signature = bytes.fromhex(manifest["signature"])
    assert len(signature) == 64
    r = int.from_bytes(signature[:32], "big")
    s = int.from_bytes(signature[32:], "big")
    key.public_key().verify(
        encode_dss_signature(r, s),
        signed_manifest_message("1.2.3", 42, manifest["sha256"]),
        ec.ECDSA(SHA256()),
    )


def test_signature_authenticates_build_and_version():
    key = ec.generate_private_key(ec.SECP256R1())
    manifest = create_manifest(b"application", "2.0.1", 7, key)
    tampered_message = signed_manifest_message("2.0.1", 8, manifest["sha256"])

    with pytest.raises(InvalidSignature):
        raw_signature = bytes.fromhex(manifest["signature"])
        r = int.from_bytes(raw_signature[:32], "big")
        s = int.from_bytes(raw_signature[32:], "big")
        key.public_key().verify(
            encode_dss_signature(r, s),
            tampered_message,
            ec.ECDSA(SHA256()),
        )


def test_manifest_rejects_empty_source_and_invalid_version_or_build():
    key = ec.generate_private_key(ec.SECP256R1())

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


def test_manifest_signer_rejects_a_different_curve():
    key = ec.generate_private_key(ec.SECP384R1())

    with pytest.raises(ValueError, match="P-256"):
        create_manifest(b"application", "1.0.0", 1, key)


def test_write_manifest_serializes_a_signed_source_manifest(tmp_path):
    key = ec.generate_private_key(ec.SECP256R1())
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
    signature = bytes.fromhex(manifest["signature"])
    r = int.from_bytes(signature[:32], "big")
    s = int.from_bytes(signature[32:], "big")
    key.public_key().verify(
        encode_dss_signature(r, s),
        signed_manifest_message("3.1.4", 123, manifest["sha256"]),
        ec.ECDSA(SHA256()),
    )


def test_keygen_writes_an_encrypted_private_key_and_uncompressed_public_key(tmp_path, monkeypatch):
    passphrase = "test-passphrase-123"
    monkeypatch.setattr("tools.package_release.getpass.getpass", lambda _: passphrase)
    private_path = tmp_path / "signing.pem"
    public_path = tmp_path / "OTA_Updater_p256.pub"

    generate_keys(private_path, public_path)

    assert b"ENCRYPTED" in private_path.read_bytes()
    public_key = public_path.read_bytes()
    assert len(public_key) == 65
    assert public_key[0] == 4
    monkeypatch.setenv("OTA_SIGNING_KEY_PASSWORD", passphrase)
    private_key = load_private_key(private_path)
    expected_public_key = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.X962,
        format=serialization.PublicFormat.UncompressedPoint,
    )
    assert public_key == expected_public_key
