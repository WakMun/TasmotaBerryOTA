# TasmotaMotorControl

A Berry boot updater for a Tasmota32 device. At boot, `autoexec.be` checks the
latest GitHub release, downloads a newer signed Berry bytecode bundle, verifies
it using a public key kept on the device, and only then replaces the installed
bytecode. The previous bytecode is retained as `TasmotaMotorControl.bec.old`.

This repository contains the updater and release packaging tools; it does not
include motor-control application logic. Supply a compiled Berry `.bec` file as
the release input.

## Device requirements

- ESP32 running Tasmota with Berry and UFS enabled. Berry/UFS is not available
  in the same way on ESP8266.
- Firmware exposing both `crypto.ED25519` and `crypto.SHA256`. These classes
  are compile-time optional in Tasmota. If either is missing, the updater logs
  the error and leaves the installed application untouched.
- Enough UFS free space for the incoming bundle, staged executable, and
  previous executable. The updater caps a bundle at 64 KiB; allow at least
  224 KiB free for an update at that limit.

## Install on Tasmota

1. Set `GITHUB_OWNER` in `tmc_updater.be` to the account or organization that
   will host this repository.
2. Generate a signing key pair as described below. Copy the 32-byte raw public
   key to the device UFS as `/tmc_ed25519.pub`. Never upload that key as a
   GitHub release asset; keep the private key offline.
3. Upload `autoexec.be` and `tmc_updater.be` to the root of Tasmota UFS. Tasmota
   runs `autoexec.be` automatically at boot.
4. If an application binary is already installed, also create
   `/TasmotaMotorControl.version` containing its exact `MAJOR.MINOR.PATCH`
   version. The updater refuses to guess the version of an existing binary.
   With no installed application or version file, the first signed release can
   be installed on the next boot.

The release check uses GitHub's `releases/latest` API endpoint and scans its
assets for `TasmotaMotorControl-vMAJOR.MINOR.PATCH.bec` and the matching
`.sig` asset. Only a release newer than the installed version is downloaded.
The repository owner and name in the script must match the eventual GitHub
repository.

## Create and publish a release

Use Python 3.10 or newer:

```powershell
python -m pip install -e ".[test]"
python tools/package_release.py keygen --private-key signing-key.pem --public-key tmc_ed25519.pub
python tools/package_release.py package --version 1.2.3 --input TasmotaMotorControl.bec --private-key signing-key.pem
python -m pytest
```

Compile the application bytecode with the Tasmota Berry compiler first. The
`--input` file is the resulting raw `.bec` bytecode. `keygen` encrypts the
private key with a passphrase; keep it in secure storage. The generated raw
public key is the file to provision manually to Tasmota UFS. Do not commit
either key.

Upload both generated files from `dist/` to the GitHub release:

```text
TasmotaMotorControl-v1.2.3.bec
TasmotaMotorControl-v1.2.3.bec.sig
```

The `.bec` release asset is a small versioned bundle: a 47-byte `TMCB` header
followed by the compiled Berry bytecode. Its header records the format version,
semantic version, payload length, and payload SHA-256 digest. The updater
authenticates the SHA-256 digest of the complete bundle with a detached
Ed25519 signature, then checks the header and extracts the bytecode. The
filename version and signed header version must agree.

The signature is plain Ed25519 over the 32-byte SHA-256 digest of the complete
bundle (not Ed25519ph and not a signature over the raw bundle bytes). This
allows Tasmota to hash the download from UFS in chunks without buffering the
whole executable in RAM. The detached signature is exactly 64 raw bytes.

## Update and recovery behavior

The script downloads into temporary UFS files, checks the HTTP status and
bounded size, verifies the detached signature with the device-only public key,
validates the signed bundle header and payload, and then promotes the staged
bytecode. The previous executable and version are renamed to `.old` before
promotion. Tasmota is restarted after an installation so the boot script loads
the new bytecode on the following boot.

If an installed bytecode file fails to load, `autoexec.be` attempts to restore
the `.old` executable and restarts. An update error is logged and does not
replace the current executable. HTTPS is used for transport, but Tasmota's
default synchronous webclient does not necessarily authenticate the TLS
server; release authenticity comes from the Ed25519 signature and the public
key on UFS.

The updater's header format and release signer are implemented in
[`tools/package_release.py`](./tools/package_release.py); protocol regression
tests are in [`tests/test_package_release.py`](./tests/test_package_release.py).
