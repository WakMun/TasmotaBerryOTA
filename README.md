# TasmotaBerryOTA

This repo provides an OTA update capability for ESP32 microcontrollers running 
tasmota32. Your Microcontroller must support berry scripting to use this eg ESP32s. 
Normally, Tasmota versions for ESP8266s do not come with berry scripting enabled.
In that case, this functionality will not work.  

Basically there are four files here: `autoexec.be`, `OTA_updater.be`, `OTA_Updater_p256.pub`
and `Application.be`.


 `autoexec.be` is the
small boot guard: it activates bytecode staged by an earlier update check,
loads `Application.bec`, then schedules a GitHub check three minutes after
startup. The updater verifies the downloaded raw Berry source before compiling
it locally and marking it ready for the next boot.

`Application.be` is the sample Application. The release workflow publishes a
copy named `Application.be`, together with `app_manifest.json`, as assets of a
stable GitHub Release.

`OTA_updater.be` is activated by `autoexec.be`. It checkes if there is a newer version of 
`Application.be` if available on the github and authenticates it using the public key stored 
in Tasmota UFS. If authenticated, it used as new the new application starting next reboot.

Last one is `OTA_Updater_p256.pub`. It stores the P-256 public key against
which `Application.be` is authenticated.

## Device requirements and setup

- ESP32 running Tasmota with Berry and UFS enabled.
- Tasmota Berry exposing `crypto.SHA256`,
  `crypto.EC_P256().ecdsa_verify_sha256`, and `tasmota.compile`. The updater
  uses P-256 (secp256r1) ECDSA, available in standard `tasmota32.bin` builds.
- Enough free UFS space for the downloaded source, verified source copy,
  compiled staging file, active application, and rollback copy (allow about
  320 KiB for an update at the 64 KiB per-file limit).

Before uploading the files:

1. Set `GITHUB_OWNER` in `OTA_updater.be` to the GitHub account or organization
   containing this repository.
2. Generate a P-256 key pair (instructions below) and copy the 65-byte
   uncompressed public key to Tasmota UFS as `OTA_Updater_p256.pub`. Keep the
   private key private; never upload it or commit it. This replaces the former
   previous Ed25519 key: generate a new pair, update the GitHub Actions
   secrets, upload the matching public key and revised `OTA_updater.be` to
   every device, then publish a new P-256-signed release before relying on OTA
   updates.
3. Upload `autoexec.be` and `OTA_updater.be` to the root of Tasmota UFS.
4. Compile `Application.be` on the device with
   `tasmota.compile("Application.be")`, then ensure the compiled
   `/Application.bec` is installed as `/Application.bec`. The casing in the
   filesystem path may matter on the device.
5. Create `/Application.build` containing the installed release's build
   integer, or `0` for an application not yet released by this workflow.

The sample `Application.be` expects GPIO8 to be configured as WS2812. Change
that pin if needed.

## Stable release workflow

Create an encrypted P-256 ECDSA key pair once:

```powershell
python -m pip install -e ".[test]"
python tools/package_release.py keygen --private-key signing-key.pem --public-key OTA_Updater_p256.pub
```

The key-generation command is a one-time setup step; it is not part of
publishing each release. Keep the private key in secure storage and add two
GitHub Actions repository secrets:

- `OTA_SIGNING_KEY_PEM`: the complete PEM private key.
- `OTA_SIGNING_KEY_PASSWORD`: its passphrase.

To publish an update, commit and push the changed `Application.be`, then push a
stable semantic-version tag for that commit, such as `v1.2.3`. The tag push
triggers GitHub Actions. You do not run `package_release.py manifest` or
generate the manifest yourself: Actions runs the Python tests, generates a
monotonically increasing build number from the GitHub Actions run number, and
runs `package_release.py` to hash the source and sign `app_manifest.json`. It
then publishes the raw source as `Application.be` and the generated manifest
as assets of the stable GitHub Release.

`tools/package_release.py` is the workflow's signing helper, not a required
manual release step. It also provides the one-time key-generation command
above.

The manifest includes `version`, `build`, `sha256`, and a hex-encoded P-256 ECDSA
`signature`. The signature authenticates the source hash **and** the version
and build fields, preventing those fields from being altered independently.
The signer applies ECDSA with SHA-256 to the UTF-8 text
`TasmotaBerryOTA\n<version>\n<build>\n<SHA256_HEX>`. The manifest stores the
signature as 64 raw bytes (`r` and `s`, 32 bytes each) encoded as 128
hexadecimal characters; this is the raw format expected by Tasmota's
`ecdsa_verify_sha256` method, rather than ASN.1/DER.
The SHA-256 value is calculated over the exact raw bytes of
`Application.be`; no header or packaging bytes are added.

Run the local test suite with:

```powershell
python -m pytest
```

## Device update and recovery

The boot guard follows this sequence:

1. If `/Application.update.pending` contains the complete `ready` marker,
   activate `/Application.new.bec` by
   renaming the previous `/Application.bec` to a rollback file, then promoting
   the staged bytecode.
2. Load `/Application.bec`. If loading fails during an update, restore the
   previous bytecode and restart Tasmota. After a successful load, record the
   build and remove the rollback files.
3. Schedule a check after 1 minute. If Wi-Fi is down, retry later.
4. Fetch the latest stable release manifest, and skip it when its build is not
   greater than the locally installed build.
5. Download raw `Application.be` to `Application.new`, check its SHA-256 and
   P-256 ECDSA signature using the device-only public key, copy the verified
   source to `Application.new.be`, and compile it to `Application.new.bec`.
   The verified bytecode remains staged there until the pending marker is set.
   The current application keeps running; the staged update is activated on
   the next boot.

LittleFS/UFS files include `autoexec.be` (boot guard),
`Application.bec` (active bytecode), `Application.new` (downloaded source
during verification), and
`Application.new.bec` (verified compiled bytecode awaiting activation). Small
marker/build files and a rollback copy support recovery from interrupted file
renames and failed application startup.

The timer defers update work until after startup, but Berry's event loop and
Tasmota's standard `webclient` and compile call are synchronous. A network
request or compilation can therefore temporarily block the Tasmota loop; this
design is delayed/cooperative work, not a separate background thread.
Transport uses HTTPS, while authenticity is provided by the P-256 ECDSA signature
and the public key stored on the device.
