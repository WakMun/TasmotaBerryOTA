#!/usr/bin/env python3
"""Build and sign TasmotaMotorControl release bundles."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import os
import re
import struct
from pathlib import Path
from typing import NamedTuple

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)


APP_NAME = "TasmotaMotorControl"
MAGIC = b"TMCB"
FORMAT_VERSION = 1
HEADER = struct.Struct(">4sBHHHI32s")
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
ASSET_PATTERN = re.compile(
    rf"{APP_NAME}-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.bec\Z"
)


class BundleHeader(NamedTuple):
    version: tuple[int, int, int]
    payload_size: int
    payload_sha256: bytes


def parse_version(value: str) -> tuple[int, int, int]:
    match = VERSION_PATTERN.fullmatch(value)
    if match is None:
        raise ValueError("version must be numeric MAJOR.MINOR.PATCH")

    version = tuple(int(part) for part in match.groups())
    if any(part > 0xFFFF for part in version):
        raise ValueError("each version component must be at most 65535")
    return version


def version_text(version: tuple[int, int, int]) -> str:
    return ".".join(str(part) for part in version)


def asset_name(version: tuple[int, int, int]) -> str:
    return f"{APP_NAME}-v{version_text(version)}.bec"


def make_bundle(payload: bytes, version: tuple[int, int, int]) -> bytes:
    if not payload:
        raise ValueError("compiled Berry bytecode must not be empty")
    if len(payload) > 0xFFFFFFFF:
        raise ValueError("compiled Berry bytecode exceeds the format limit")

    header = HEADER.pack(
        MAGIC,
        FORMAT_VERSION,
        *version,
        len(payload),
        hashlib.sha256(payload).digest(),
    )
    return header + payload


def parse_bundle(bundle: bytes) -> BundleHeader:
    if len(bundle) < HEADER.size:
        raise ValueError("bundle is smaller than its header")

    magic, format_version, major, minor, patch, payload_size, payload_hash = (
        HEADER.unpack_from(bundle)
    )
    if magic != MAGIC:
        raise ValueError("invalid bundle magic")
    if format_version != FORMAT_VERSION:
        raise ValueError(f"unsupported bundle format version: {format_version}")
    if payload_size != len(bundle) - HEADER.size:
        raise ValueError("bundle payload length does not match its header")
    if not payload_size:
        raise ValueError("bundle payload is empty")

    payload = bundle[HEADER.size:]
    if hashlib.sha256(payload).digest() != payload_hash:
        raise ValueError("bundle payload hash does not match its header")

    return BundleHeader((major, minor, patch), payload_size, payload_hash)


def verify_asset_name(name: str, version: tuple[int, int, int]) -> None:
    match = ASSET_PATTERN.fullmatch(name)
    if match is None or tuple(int(part) for part in match.groups()) != version:
        raise ValueError("asset name version does not match the signed bundle header")


def load_private_key(path: Path) -> Ed25519PrivateKey:
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

    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("signing key must be an Ed25519 private key")
    return key


def write_release(
    payload_path: Path,
    version: tuple[int, int, int],
    private_key_path: Path,
    output_dir: Path,
) -> tuple[Path, Path]:
    payload = payload_path.read_bytes()
    bundle = make_bundle(payload, version)
    digest = hashlib.sha256(bundle).digest()
    signature = load_private_key(private_key_path).sign(digest)

    output_dir.mkdir(parents=True, exist_ok=True)
    bundle_path = output_dir / asset_name(version)
    signature_path = output_dir / f"{bundle_path.name}.sig"
    bundle_path.write_bytes(bundle)
    signature_path.write_bytes(signature)
    return bundle_path, signature_path


def generate_keys(private_key_path: Path, public_key_path: Path) -> None:
    if private_key_path.resolve() == public_key_path.resolve():
        raise ValueError("private and public key paths must be different")
    if private_key_path.exists() or public_key_path.exists():
        raise FileExistsError("refusing to overwrite an existing key file")

    first = getpass.getpass("New signing-key passphrase (required): ")
    second = getpass.getpass("Confirm passphrase: ")
    if len(first) < 12 or first != second:
        raise ValueError("passphrases must match and contain at least 12 characters")

    private_key = Ed25519PrivateKey.generate()
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.BestAvailableEncryption(first.encode("utf-8")),
    )
    public_raw = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
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

    keygen = subparsers.add_parser("keygen", help="create an Ed25519 signing key pair")
    keygen.add_argument("--private-key", type=Path, required=True)
    keygen.add_argument("--public-key", type=Path, required=True)

    package = subparsers.add_parser("package", help="wrap and sign compiled Berry bytecode")
    package.add_argument("--version", required=True)
    package.add_argument("--input", type=Path, required=True)
    package.add_argument("--private-key", type=Path, required=True)
    package.add_argument("--output-dir", type=Path, default=Path("dist"))
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "keygen":
            generate_keys(args.private_key, args.public_key)
            print(f"Raw public key written to {args.public_key}")
            print("Keep the private key offline; provision only the raw public key to Tasmota UFS.")
            return 0

        version = parse_version(args.version)
        bundle_path, signature_path = write_release(
            args.input,
            version,
            args.private_key,
            args.output_dir,
        )
    except (FileNotFoundError, FileExistsError, OSError, TypeError, ValueError) as error:
        print(f"error: {error}")
        return 1

    print(f"Bundle:    {bundle_path}")
    print(f"Signature: {signature_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
