#!/usr/bin/env python3
"""Create a signed manifest for raw TasmotaMotorControl Berry source."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import re
from pathlib import Path
from typing import TypedDict

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.hashes import SHA256


APP_NAME = "TasmotaBerryOTA"
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
BUILD_PATTERN = re.compile(r"[1-9][0-9]*\Z")


class Manifest(TypedDict):
    version: str
    build: int
    sha256: str
    signature: str


def parse_version(value: str) -> str:
    match = VERSION_PATTERN.fullmatch(value)
    if match is None:
        raise ValueError("version must be numeric MAJOR.MINOR.PATCH")
    if any(int(part) > 65535 for part in match.groups()):
        raise ValueError("each version component must be at most 65535")
    return value


def parse_build(value: str) -> int:
    if BUILD_PATTERN.fullmatch(value) is None:
        raise ValueError("build must be a positive integer")
    build = int(value)
    if build > 0x7FFFFFFF:
        raise ValueError("build must not exceed 2147483647")
    return build


def signed_manifest_message(version: str, build: int, digest_hex: str) -> bytes:
    return f"{APP_NAME}\n{version}\n{build}\n{digest_hex}".encode("ascii")


def create_manifest(
    source: bytes,
    version: str,
    build: int,
    private_key: ec.EllipticCurvePrivateKey,
) -> Manifest:
    parse_version(version)
    if not isinstance(private_key.curve, ec.SECP256R1):
        raise ValueError("signing key must use the P-256 (secp256r1) curve")
    if build <= 0 or build > 0x7FFFFFFF:
        raise ValueError("build must be between 1 and 2147483647")
    if not source:
        raise ValueError("Berry source file must not be empty")

    digest_hex = hashlib.sha256(source).hexdigest().upper()
    der_signature = private_key.sign(
        signed_manifest_message(version, build, digest_hex),
        ec.ECDSA(SHA256()),
    )
    r, s = decode_dss_signature(der_signature)
    signature_hex = (r.to_bytes(32, "big") + s.to_bytes(32, "big")).hex().upper()
    return {
        "version": version,
        "build": build,
        "sha256": digest_hex,
        "signature": signature_hex,
    }


def load_private_key(path: Path) -> ec.EllipticCurvePrivateKey:
    key_data = path.read_bytes()
    password_text = os.environ.get("TMC_SIGNING_KEY_PASSWORD")
    password = password_text.encode("utf-8") if password_text else None
    try:
        key = serialization.load_pem_private_key(key_data, password=password)
    except (TypeError, ValueError):
        if password is not None:
            raise
        password_text = getpass.getpass("Signing key passphrase (blank if unencrypted): ")
        password = password_text.encode("utf-8") if password_text else None
        key = serialization.load_pem_private_key(key_data, password=password)

    if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(
        key.curve, ec.SECP256R1
    ):
        raise ValueError("signing key must use the P-256 (secp256r1) curve")
    return key


def write_manifest(
    source_path: Path,
    version: str,
    build: int,
    private_key_path: Path,
    manifest_path: Path,
) -> Path:
    manifest = create_manifest(
        source_path.read_bytes(),
        version,
        build,
        load_private_key(private_key_path),
    )
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def generate_keys(private_key_path: Path, public_key_path: Path) -> None:
    if private_key_path.resolve() == public_key_path.resolve():
        raise ValueError("private and public key paths must be different")
    if private_key_path.exists() or public_key_path.exists():
        raise FileExistsError("refusing to overwrite an existing key file")

    first = getpass.getpass("New signing-key passphrase (required): ")
    second = getpass.getpass("Confirm passphrase: ")
    if len(first) < 12 or first != second:
        raise ValueError("passphrases must match and contain at least 12 characters")

    private_key = ec.generate_private_key(ec.SECP256R1())
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.BestAvailableEncryption(first.encode("utf-8")),
    )
    public_raw = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.X962,
        format=serialization.PublicFormat.UncompressedPoint,
    )

    private_key_path.parent.mkdir(parents=True, exist_ok=True)
    public_key_path.parent.mkdir(parents=True, exist_ok=True)
    private_key_path.write_bytes(private_pem)
    public_key_path.write_bytes(public_raw)
    if os.name != "nt":
        private_key_path.chmod(0o600)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    keygen = subparsers.add_parser("keygen", help="create a P-256 ECDSA signing key pair")
    keygen.add_argument("--private-key", type=Path, required=True)
    keygen.add_argument("--public-key", type=Path, required=True)

    manifest = subparsers.add_parser("manifest", help="hash source and sign its manifest")
    manifest.add_argument("--version", required=True)
    manifest.add_argument("--build", required=True)
    manifest.add_argument("--input", type=Path, required=True)
    manifest.add_argument("--private-key", type=Path, required=True)
    manifest.add_argument("--output", type=Path, default=Path("app_manifest.json"))
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "keygen":
            generate_keys(args.private_key, args.public_key)
            print(f"Uncompressed P-256 public key written to {args.public_key}")
            print("Keep the private key offline; provision only the public key to Tasmota UFS.")
            return 0

        write_manifest(
            args.input,
            parse_version(args.version),
            parse_build(args.build),
            args.private_key,
            args.output,
        )
    except (FileNotFoundError, FileExistsError, OSError, TypeError, ValueError) as error:
        print(f"error: {error}")
        return 1

    print(f"Manifest:  {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
