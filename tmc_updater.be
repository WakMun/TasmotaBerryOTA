import crypto
import json
import path
import string

var APP_NAME = "TasmotaMotorControl"
var GITHUB_OWNER = "YOUR_GITHUB_OWNER"
var GITHUB_REPOSITORY = "TasmotaMotorControl"
var PUBLIC_KEY_PATH = "/tmc_ed25519.pub"
var APP_PATH = "/TasmotaMotorControl.bec"
var VERSION_PATH = "/TasmotaMotorControl.version"
var OLD_APP_PATH = "/TasmotaMotorControl.bec.old"
var OLD_VERSION_PATH = "/TasmotaMotorControl.version.old"
var FAILED_APP_PATH = "/TasmotaMotorControl.bec.failed"
var FAILED_VERSION_PATH = "/TasmotaMotorControl.version.failed"
var PACKAGE_PATH = "/TasmotaMotorControl.download.part"
var PAYLOAD_PATH = "/TasmotaMotorControl.new"
var VERSION_TEMP_PATH = "/TasmotaMotorControl.version.new"
var PENDING_PATH = "/TasmotaMotorControl.update.pending"
var PENDING_TEMP_PATH = "/TasmotaMotorControl.update.pending.new"

var HEADER_SIZE = 47
var MAX_BUNDLE_SIZE = 65536
var MAX_SMALL_RESPONSE_SIZE = 32767

def _log(message)
  print("TasmotaMotorControl updater:", message)
end

def _remove_if_exists(file_path)
  if path.exists(file_path)
    if !path.remove(file_path)
      _log("could not remove " + file_path)
      return false
    end
  end
  return true
end

def _read_text(file_path)
  var file = open(file_path, "r")
  var text = file.read()
  file.close()
  return text
end

def _write_text(file_path, text)
  if !_remove_if_exists(file_path)
    return false
  end
  var file = open(file_path, "w")
  file.write(text)
  file.flush()
  file.close()
  return true
end

def _parse_version_text(text)
  var parts = string.split(text, ".")
  if size(parts) != 3
    return nil
  end

  var version = []
  for part : parts
    if part == ""
      return nil
    end
    var number = 0
    try
      number = int(part)
    except .. as error, message
      return nil
    end
    if number < 0 || number > 65535 || str(number) != part
      return nil
    end
    version.push(number)
  end
  return version
end

def _version_text(version)
  return str(version[0]) + "." + str(version[1]) + "." + str(version[2])
end

def _is_newer(left, right)
  if left[0] != right[0]
    return left[0] > right[0]
  end
  if left[1] != right[1]
    return left[1] > right[1]
  end
  return left[2] > right[2]
end

def _same_version(left, right)
  return left[0] == right[0] && left[1] == right[1] && left[2] == right[2]
end

def _version_from_asset(name)
  var name_parts = string.split(name, "-v")
  if size(name_parts) != 2 || name_parts[0] != APP_NAME
    return nil
  end

  var parts = string.split(name_parts[1], ".")
  if size(parts) != 4 || parts[3] != "bec"
    return nil
  end
  return _parse_version_text(parts[0] + "." + parts[1] + "." + parts[2])
end

def _hash_file(file_path)
  var file = open(file_path, "r")
  var hash = crypto.SHA256()
  var total = 0
  while true
    var chunk = file.readbytes(1024)
    if size(chunk) == 0
      break
    end
    total += size(chunk)
    hash.update(chunk)
  end
  file.close()
  return {"digest": hash.out(), "size": total}
end

def _small_response(url, binary)
  if !string.startswith(url, "https://")
    _log("refusing a non-HTTPS asset URL")
    return nil
  end

  var client = webclient()
  client.set_follow_redirects(true)
  client.set_useragent("TasmotaMotorControl-updater")
  client.begin(url)
  var status = client.GET()
  if status != 200
    client.close()
    _log("HTTP request failed with status " + str(status))
    return nil
  end

  var response_size = client.get_size()
  if response_size < 0 || response_size >= MAX_SMALL_RESPONSE_SIZE
    client.close()
    _log("small response has an unknown or excessive size")
    return nil
  end

  var response = nil
  if binary
    response = client.get_bytes()
  else
    response = client.get_string()
  end
  client.close()
  return response
end

def _latest_release()
  if GITHUB_OWNER == "YOUR_GITHUB_OWNER" || GITHUB_OWNER == ""
    _log("set GITHUB_OWNER in tmc_updater.be before deployment")
    return nil
  end

  var url = "https://api.github.com/repos/" + GITHUB_OWNER + "/" + GITHUB_REPOSITORY + "/releases/latest"
  var client = webclient()
  client.set_follow_redirects(true)
  client.set_useragent("TasmotaMotorControl-updater")
  client.addheader("Accept", "application/vnd.github+json")
  client.begin(url)
  var status = client.GET()
  if status != 200
    client.close()
    _log("GitHub release API returned HTTP " + str(status))
    return nil
  end

  var response_size = client.get_size()
  if response_size < 0 || response_size >= MAX_SMALL_RESPONSE_SIZE
    client.close()
    _log("GitHub release API response has an unknown or excessive size")
    return nil
  end
  var body = client.get_string()
  client.close()
  return json.load(body)
end

def _select_assets(assets, current_version, failed_version)
  var selected = nil
  var selected_version = nil

  for asset : assets
    var version = _version_from_asset(asset["name"])
    if version != nil && _is_newer(version, current_version)
      if failed_version != nil && _same_version(version, failed_version)
        _log("skipping previously failed version " + _version_text(version))
      else
        if selected_version == nil || _is_newer(version, selected_version)
          selected = asset
          selected_version = version
        end
      end
    end
  end

  if selected == nil
    return nil
  end

  var signature_asset = nil
  var signature_name = selected["name"] + ".sig"
  for asset : assets
    if asset["name"] == signature_name
      if signature_asset != nil
        _log("release contains duplicate signature assets")
        return nil
      end
      signature_asset = asset
    end
  end

  if signature_asset == nil
    _log("release is missing the detached signature asset")
    return nil
  end
  return [selected, signature_asset, selected_version]
end

def _download_signature(url)
  var signature = _small_response(url, true)
  if signature == nil || size(signature) != 64
    _log("Ed25519 signature must be exactly 64 bytes")
    return nil
  end
  return signature
end

def _download_bundle(url)
  if !string.startswith(url, "https://")
    _log("refusing a non-HTTPS bundle URL")
    return nil
  end
  if !_remove_if_exists(PACKAGE_PATH)
    return nil
  end

  var client = webclient()
  client.set_follow_redirects(true)
  client.set_useragent("TasmotaMotorControl-updater")
  client.begin(url)
  var status = client.GET()
  if status != 200
    client.close()
    _log("bundle download failed with HTTP " + str(status))
    return nil
  end

  var expected_size = client.get_size()
  if expected_size <= HEADER_SIZE || expected_size > MAX_BUNDLE_SIZE
    client.close()
    _log("bundle size is unknown, empty, or exceeds 64 KiB")
    return nil
  end
  client.write_file(PACKAGE_PATH)
  client.close()

  var result = _hash_file(PACKAGE_PATH)
  if result["size"] != expected_size
    _log("downloaded bundle size does not match its HTTP content length")
    return nil
  end
  return result
end

def _read_public_key()
  if !path.exists(PUBLIC_KEY_PATH)
    _log("missing device public key " + PUBLIC_KEY_PATH)
    return nil
  end
  var file = open(PUBLIC_KEY_PATH, "r")
  var key = file.readbytes(32)
  var extra = file.readbytes(1)
  file.close()
  if size(key) != 32 || size(extra) != 0
    _log("device public key must contain exactly 32 raw bytes")
    return nil
  end
  return key
end

def _verify_digest(digest, signature)
  var public_key = _read_public_key()
  if public_key == nil
    return false
  end
  return crypto.ED25519().verify(digest, signature, public_key)
end

def _uint16(bytes, offset)
  return bytes[offset] * 256 + bytes[offset + 1]
end

def _uint32(bytes, offset)
  return ((bytes[offset] * 256 + bytes[offset + 1]) * 256 + bytes[offset + 2]) * 256 + bytes[offset + 3]
end

def _read_header(file_path)
  var file = open(file_path, "r")
  var header = file.readbytes(HEADER_SIZE)
  file.close()
  if size(header) != HEADER_SIZE
    _log("bundle header is truncated")
    return nil
  end
  if header[0] != 84 || header[1] != 77 || header[2] != 67 || header[3] != 66
    _log("bundle magic is invalid")
    return nil
  end
  if header[4] != 1
    _log("bundle format version is unsupported")
    return nil
  end

  var version = [_uint16(header, 5), _uint16(header, 7), _uint16(header, 9)]
  var payload_size = _uint32(header, 11)
  if payload_size == 0 || payload_size > MAX_BUNDLE_SIZE - HEADER_SIZE
    _log("bundle payload length is invalid")
    return nil
  end
  return {
    "version": version,
    "payload_size": payload_size,
    "payload_digest": header[15..46]
  }
end

def _extract_payload(header)
  if !_remove_if_exists(PAYLOAD_PATH)
    return false
  end

  var source = open(PACKAGE_PATH, "r")
  var skipped = source.readbytes(HEADER_SIZE)
  if size(skipped) != HEADER_SIZE
    source.close()
    _log("could not skip bundle header")
    return false
  end

  var destination = open(PAYLOAD_PATH, "w")
  var hash = crypto.SHA256()
  var total = 0
  while true
    var chunk = source.readbytes(1024)
    if size(chunk) == 0
      break
    end
    destination.write(chunk)
    hash.update(chunk)
    total += size(chunk)
  end
  source.close()
  destination.flush()
  destination.close()

  if total != header["payload_size"] || hash.out() != header["payload_digest"]
    _log("extracted bytecode length or digest does not match the signed header")
    _remove_if_exists(PAYLOAD_PATH)
    return false
  end
  var staged = _hash_file(PAYLOAD_PATH)
  if staged["size"] != header["payload_size"] || staged["digest"] != header["payload_digest"]
    _log("staged bytecode failed its post-write digest check")
    _remove_if_exists(PAYLOAD_PATH)
    return false
  end
  return true
end

def _read_installed_version()
  if !path.exists(APP_PATH)
    if path.exists(VERSION_PATH)
      _log("version file exists without an installed bytecode file")
      return nil
    end
    return [0, 0, 0]
  end
  if !path.exists(VERSION_PATH)
    _log("existing bytecode has no version file; refusing an unsafe update")
    return nil
  end
  var version = _parse_version_text(_read_text(VERSION_PATH))
  if version == nil
    _log("installed version file is invalid")
  end
  return version
end

def _recover_pending_update()
  if !path.exists(PENDING_PATH)
    return true
  end

  var pending_version = _parse_version_text(_read_text(PENDING_PATH))
  var installed_version = nil
  if path.exists(VERSION_PATH)
    installed_version = _parse_version_text(_read_text(VERSION_PATH))
  end

  if path.exists(APP_PATH) && pending_version != nil && installed_version != nil && _same_version(pending_version, installed_version)
    _log("completed interrupted update promotion")
    return _remove_if_exists(PENDING_PATH)
  end

  if path.exists(OLD_APP_PATH)
    if path.exists(APP_PATH) && !_remove_if_exists(APP_PATH)
      return false
    end
    if !path.rename(OLD_APP_PATH, APP_PATH)
      _log("failed to restore the previous bytecode")
      return false
    end
    if path.exists(OLD_VERSION_PATH)
      if path.exists(VERSION_PATH) && !_remove_if_exists(VERSION_PATH)
        return false
      end
      if !path.rename(OLD_VERSION_PATH, VERSION_PATH)
        _log("failed to restore the previous version file")
        return false
      end
    end
  elif path.exists(APP_PATH) && installed_version == nil
    if !_remove_if_exists(APP_PATH)
      return false
    end
  end

  _log("rolled back an interrupted update")
  return _remove_if_exists(PENDING_PATH)
end

def _install_payload(version)
  if !_remove_if_exists(OLD_APP_PATH) || !_remove_if_exists(OLD_VERSION_PATH)
    return false
  end
  if !_write_text(VERSION_TEMP_PATH, _version_text(version))
    return false
  end
  if !_write_text(PENDING_TEMP_PATH, _version_text(version))
    return false
  end
  if !path.rename(PENDING_TEMP_PATH, PENDING_PATH)
    _log("could not create the update recovery marker")
    return false
  end

  if path.exists(APP_PATH)
    if !path.rename(APP_PATH, OLD_APP_PATH)
      _log("could not preserve the existing bytecode")
      _recover_pending_update()
      return false
    end
    if !path.rename(VERSION_PATH, OLD_VERSION_PATH)
      _log("could not preserve the existing version")
      _recover_pending_update()
      return false
    end
  end

  if !path.rename(PAYLOAD_PATH, APP_PATH)
    _log("could not promote the verified bytecode")
    _recover_pending_update()
    return false
  end
  if !path.rename(VERSION_TEMP_PATH, VERSION_PATH)
    _log("could not promote the verified version")
    _recover_pending_update()
    return false
  end

  _log("installed version " + _version_text(version) + "; restarting Tasmota")
  tasmota.cmd("Restart 1")
  return true
end

def _check_for_update()
  var current_version = _read_installed_version()
  if current_version == nil
    return false
  end

  var failed_version = nil
  if path.exists(FAILED_VERSION_PATH)
    failed_version = _parse_version_text(_read_text(FAILED_VERSION_PATH))
    if failed_version == nil
      _log("failed-version marker is invalid; not suppressing any release")
    end
  end

  var release = _latest_release()
  if release == nil
    return false
  end
  var assets = release["assets"]
  var selection = _select_assets(assets, current_version, failed_version)
  if selection == nil
    _log("no newer signed bytecode asset is available")
    return false
  end

  var bundle_asset = selection[0]
  var signature_asset = selection[1]
  var filename_version = selection[2]
  var signature_url = signature_asset["browser_download_url"]
  var bundle_url = bundle_asset["browser_download_url"]
  var signature = _download_signature(signature_url)
  if signature == nil
    return false
  end
  var bundle = _download_bundle(bundle_url)
  if bundle == nil
    return false
  end

  if !_verify_digest(bundle["digest"], signature)
    _log("bundle signature verification failed")
    return false
  end
  _log("bundle signature verified")

  var header = _read_header(PACKAGE_PATH)
  if header == nil
    return false
  end
  if !_same_version(header["version"], filename_version)
    _log("release filename version does not match the signed bundle header")
    return false
  end
  if !_is_newer(header["version"], current_version)
    _log("signed bundle is not newer than the installed version")
    return false
  end
  if bundle["size"] != HEADER_SIZE + header["payload_size"]
    _log("bundle size does not match its signed header")
    return false
  end
  if !_extract_payload(header)
    return false
  end

  if !_install_payload(header["version"])
    _log("verified update could not be installed")
    return false
  end
  return true
end

def _cleanup_temporary_files()
  _remove_if_exists(PACKAGE_PATH)
  _remove_if_exists(PAYLOAD_PATH)
  _remove_if_exists(VERSION_TEMP_PATH)
  _remove_if_exists(PENDING_TEMP_PATH)
end

def check_and_install()
  try
    if !_recover_pending_update()
      _log("recovery failed; leaving the installed files unchanged")
      return false
    end
    var installed = _check_for_update()
    _cleanup_temporary_files()
    return installed
  except .. as error, message
    _log("update check failed: " + message)
    _recover_pending_update()
    _cleanup_temporary_files()
    return false
  end
end

def restore_previous()
  if path.exists(VERSION_PATH)
    if !_write_text(FAILED_VERSION_PATH, _read_text(VERSION_PATH))
      _log("could not record the failed version")
    end
  end

  if path.exists(APP_PATH)
    if !_remove_if_exists(FAILED_APP_PATH)
      return false
    end
    if !path.rename(APP_PATH, FAILED_APP_PATH)
      _log("could not quarantine the bytecode that failed to load")
      return false
    end
  end

  if path.exists(OLD_APP_PATH)
    if !path.rename(OLD_APP_PATH, APP_PATH)
      _log("could not restore the previous bytecode")
      return false
    end
    if path.exists(OLD_VERSION_PATH)
      if path.exists(VERSION_PATH) && !_remove_if_exists(VERSION_PATH)
        return false
      end
      if !path.rename(OLD_VERSION_PATH, VERSION_PATH)
        _log("could not restore the previous version")
        return false
      end
    end
    _log("restored the previous bytecode; restarting Tasmota")
    tasmota.cmd("Restart 1")
    return true
  end

  _log("no previous bytecode is available; the failed file was quarantined")
  _remove_if_exists(VERSION_PATH)
  return false
end
