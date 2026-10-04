import crypto
import json
import path
import string

var OTA_updater = module("OTA_updater")

var APP_NAME = "TasmotaBerryOTA"
var GITHUB_OWNER = "WakMun"
var GITHUB_REPOSITORY = "TasmotaBerryOTA"
var PUBLIC_KEY_PATH = "/OTA_Updater_p256.pub"
var APP_PATH = "/Application.bec"
var DOWNLOAD_PATH = "/Application.new"
var STAGED_PATH = "/Application.new.bec"
var STAGED_SOURCE_PATH = "/Application.new.be"
var STAGED_BYTECODE_PATH = "/Application.new.bec"
var STAGED_BUILD_PATH = "/Application.new.build"
var PENDING_PATH = "/Application.update.pending"
var INSTALLED_BUILD_PATH = "/Application.build"
var OLD_APP_PATH = "/Application.bec.old"
var FAILED_APP_PATH = "/Application.bec.failed"
var MAX_APP_SIZE = 65536
var MAX_MANIFEST_SIZE = 4096
var TIMER_ID = "OTAUpdateTimer"
var BOOT_UPDATE_DELAY = 60000
var RETRY_DELAY = 600000
var REGULAR_CHECK_DELAY = 3600000

def _log(message)
  print("TasmotaBerryOTA updater:", message)
end

def _remove_if_exists(file_path)
  if path.exists(file_path) && !path.remove(file_path)
    _log("could not remove " + file_path)
    return false
  end
  return true
end

def _read_text(file_path)
  var file = open(file_path, "r")
  var text = file.read()
  file.close()
  return text
end

def _pending_marker_is_ready()
  try
    return _read_text(PENDING_PATH) == "ready"
  except .. as error, message
    _log("could not read pending marker: " + message)
    return false
  end
end

def _cleanup_unstaged_files()
  if path.exists(PENDING_PATH)
    if _pending_marker_is_ready()
      return
    end
    _log("removing an incomplete pending marker")
    if !_remove_if_exists(PENDING_PATH)
      return
    end
  end
  _remove_if_exists(DOWNLOAD_PATH)
  _remove_if_exists(STAGED_SOURCE_PATH)
  _remove_if_exists(STAGED_BYTECODE_PATH)
  _remove_if_exists(STAGED_BUILD_PATH)
end

def _write_new_file(file_path, text)
  if path.exists(file_path)
    _log("refusing to overwrite " + file_path)
    return false
  end
  var file = open(file_path, "w")
  file.write(text)
  file.flush()
  file.close()
  if !path.exists(file_path) || _read_text(file_path) != text
    _log("could not write and verify " + file_path)
    _remove_if_exists(file_path)
    return false
  end
  return true
end

def _parse_version(text)
  var parts = string.split(text, ".")
  if size(parts) != 3
    return nil
  end
  for part : parts
    if part == ""
      return nil
    end
    var version_component = 0
    try
      version_component = int(part)
    except .. as error, message
      return nil
    end
    if version_component < 0 || version_component > 65535 || str(version_component) != part
      return nil
    end
  end
  return true
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

def _copy_verified_source()
  if !_remove_if_exists(STAGED_SOURCE_PATH)
    return false
  end
  var source = open(DOWNLOAD_PATH, "r")
  var destination = open(STAGED_SOURCE_PATH, "w")
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

  var downloaded = _hash_file(DOWNLOAD_PATH)
  var copied = _hash_file(STAGED_SOURCE_PATH)
  if total != downloaded["size"] || hash.out() != downloaded["digest"] ||
      copied["size"] != downloaded["size"] || copied["digest"] != downloaded["digest"]
    _log("verified source copy failed its size or SHA-256 check")
    _remove_if_exists(STAGED_SOURCE_PATH)
    return false
  end
  return true
end

def _fetch_text(url)
  if !string.startswith(url, "https://")
    _log("refusing a non-HTTPS URL")
    return nil
  end
  var client = webclient()
  client.set_follow_redirects(true)
  client.set_useragent("TasmotaBerryOTA-updater")
  client.begin(url)
  var status = client.GET()
  if status != 200
    client.close()
    _log("manifest request failed with HTTP " + str(status) + " for " + url)
    return nil
  end
  var response_size = client.get_size()
  if response_size < 0 || response_size > MAX_MANIFEST_SIZE
    client.close()
    _log("manifest size is unknown or exceeds 4 KiB")
    return nil
  end
  var body = client.get_string()
  client.close()
  return body
end

def _download_application(url)
  if !string.startswith(url, "https://")
    _log("refusing a non-HTTPS application URL")
    return false
  end
  if !_remove_if_exists(DOWNLOAD_PATH)
    return false
  end
  var client = webclient()
  client.set_follow_redirects(true)
  client.set_useragent("TasmotaBerryOTA-updater")
  client.begin(url)
  var status = client.GET()
  if status != 200
    client.close()
    _log("application download failed with HTTP " + str(status))
    return false
  end
  var expected_size = client.get_size()
  if expected_size <= 0 || expected_size > MAX_APP_SIZE
    client.close()
    _log("application size is unknown, empty, or exceeds 64 KiB")
    return false
  end
  client.write_file(DOWNLOAD_PATH)
  client.close()
  var result = _hash_file(DOWNLOAD_PATH)
  if result["size"] != expected_size
    _log("application download size does not match its HTTP content length")
    _remove_if_exists(DOWNLOAD_PATH)
    return false
  end
  return result
end

def _read_public_key()
  if !path.exists(PUBLIC_KEY_PATH)
    _log("missing device public key " + PUBLIC_KEY_PATH)
    return nil
  end
  var file = open(PUBLIC_KEY_PATH, "r")
  var key = file.readbytes(65)
  var extra = file.readbytes(1)
  file.close()
  if size(key) != 65 || key[0] != 4 || size(extra) != 0
    _log("device P-256 public key must be exactly 65 uncompressed bytes")
    return nil
  end
  return key
end

def _verify_manifest(manifest, result)
  var version = manifest.find("version")
  var build_value = manifest.find("build")
  var digest_hex = manifest.find("sha256")
  var signature_hex = manifest.find("signature")
  if version == nil || build_value == nil || digest_hex == nil || signature_hex == nil
    _log("manifest is missing a required field")
    return nil
  end
  version = str(version)
  if !_parse_version(version)
    _log("manifest version is invalid")
    return nil
  end
  var build = 0
  try
    build = int(build_value)
  except .. as error, message
    _log("manifest build number is invalid")
    return nil
  end
  if build <= 0 || str(build) != str(build_value)
    _log("manifest build number must be a positive integer")
    return nil
  end
  if size(digest_hex) != 64 || size(signature_hex) != 128
    _log("manifest digest or signature has an invalid length")
    return nil
  end
  if result["digest"].tohex() != digest_hex
    _log("SECURITY ERROR: application SHA-256 does not match the manifest")
    return nil
  end

  var signature = bytes().fromhex(signature_hex)
  var signed_message = bytes().fromstring(APP_NAME + "\n" + version + "\n" + str(build) + "\n" + digest_hex)
  var public_key = _read_public_key()
  if public_key == nil || !crypto.EC_P256().ecdsa_verify_sha256(public_key, signed_message, signature)
    _log("SECURITY ERROR: manifest signature verification failed")
    return nil
  end
  return {"version": version, "build": build}
end

def _compile_staged_application()
  if !_remove_if_exists(STAGED_SOURCE_PATH) || !_remove_if_exists(STAGED_BYTECODE_PATH)
    return false
  end
  if !_copy_verified_source()
    _log("could not prepare verified source for compilation: " + STAGED_SOURCE_PATH)
    return false
  end
  tasmota.compile(STAGED_SOURCE_PATH)
  if !path.exists(STAGED_BYTECODE_PATH)
    _log("Tasmota did not produce staged bytecode")
    return false
  end
  var compiled = _hash_file(STAGED_BYTECODE_PATH)
  if compiled["size"] <= 0 || compiled["size"] > MAX_APP_SIZE
    _log("compiled bytecode is empty or exceeds 64 KiB")
    return false
  end
  if !_remove_if_exists(STAGED_SOURCE_PATH)
    return false
  end
  if !_remove_if_exists(DOWNLOAD_PATH)
    _log("could not remove the verified source download after compilation")
    return false
  end
  return true
end

def _stage_update()
  if path.exists(PENDING_PATH)
    _log("a verified update is already waiting for reboot")
    return false
  end
  if GITHUB_OWNER == "YOUR_GITHUB_OWNER" || GITHUB_OWNER == ""
    _log("set GITHUB_OWNER in OTA_updater.be before deployment")
    return false
  end
  _cleanup_unstaged_files()

  var base_url = "https://github.com/" + GITHUB_OWNER + "/" + GITHUB_REPOSITORY + "/releases/latest/download/"
  var body = _fetch_text(base_url + "app_manifest.json")
  if body == nil
    return false
  end
  var manifest = json.load(body)
  var build_value = manifest.find("build")
  var remote_build = 0
  try
    remote_build = int(build_value)
  except .. as error, message
    _log("manifest build number is invalid")
    return false
  end
  var installed_build = 0
  if path.exists(INSTALLED_BUILD_PATH)
    try
      installed_build = int(_read_text(INSTALLED_BUILD_PATH))
    except .. as error, message
      _log("installed build number is invalid; refusing to update")
      return false
    end
  end
  if remote_build <= installed_build
    _log("build " + str(remote_build) + " is not newer than installed build " + str(installed_build))
    return false
  end

  var result = _download_application(base_url + "Application.be")
  if result == nil || result == false
    _remove_if_exists(DOWNLOAD_PATH)
    return false
  end
  var verified = nil
  try
    verified = _verify_manifest(manifest, result)
  except .. as error, message
    _log("security validation failed: " + message)
  end
  if verified == nil
    _remove_if_exists(DOWNLOAD_PATH)
    _log("SECURITY ERROR: rejected unverified application; staged source deleted")
    return false
  end
  _log("signature verified for version " + verified["version"] + ", build " + str(verified["build"]))
  if !_compile_staged_application()
    _remove_if_exists(DOWNLOAD_PATH)
    _remove_if_exists(STAGED_SOURCE_PATH)
    _remove_if_exists(STAGED_BYTECODE_PATH)
    return false
  end
  if !_write_new_file(STAGED_BUILD_PATH, str(verified["build"]))
    _remove_if_exists(STAGED_PATH)
    return false
  end
  if !_write_new_file(PENDING_PATH, "ready")
    _remove_if_exists(STAGED_PATH)
    _remove_if_exists(STAGED_BUILD_PATH)
    return false
  end
  _log("verified update staged; it will activate on the next boot")
  return true
end

def check_for_update()
  if !tasmota.wifi("up")
    _log("Wi-Fi is not connected; retrying later")
    tasmota.remove_timer(TIMER_ID)
    tasmota.set_timer(RETRY_DELAY, check_for_update, TIMER_ID)
    return
  end
  try
    _stage_update()
  except .. as error, message
    _log("update check failed: " + message)
    _cleanup_unstaged_files()
  end
  tasmota.remove_timer(TIMER_ID)
  tasmota.set_timer(REGULAR_CHECK_DELAY, check_for_update, TIMER_ID)
end

def start_background_check()
  tasmota.remove_timer(TIMER_ID)
  tasmota.set_timer(BOOT_UPDATE_DELAY, check_for_update, TIMER_ID)
end

def activate_staged()
  if !path.exists(PENDING_PATH)
    return false
  end
  if !_pending_marker_is_ready()
    _log("pending marker is incomplete; refusing to activate the update")
    _remove_if_exists(PENDING_PATH)
    return false
  end
  if !path.exists(STAGED_PATH)
    if path.exists(APP_PATH)
      _log("staged update was already activated; awaiting application health check")
      return true
    end
    if path.exists(OLD_APP_PATH)
      if !path.rename(OLD_APP_PATH, APP_PATH)
        _log("could not recover the previous application")
        return false
      end
    end
    _log("pending update has no staged bytecode; recovered previous application")
    _remove_if_exists(PENDING_PATH)
    _remove_if_exists(STAGED_BUILD_PATH)
    return false
  end

  if path.exists(APP_PATH)
    if path.exists(OLD_APP_PATH)
      _log("ambiguous interrupted swap; preserving all application files")
      return false
    end
    if !path.rename(APP_PATH, OLD_APP_PATH)
      _log("could not preserve the running application")
      return false
    end
  end
  if !path.rename(STAGED_PATH, APP_PATH)
    _log("could not activate staged bytecode")
    if path.exists(OLD_APP_PATH) && !path.exists(APP_PATH)
      path.rename(OLD_APP_PATH, APP_PATH)
    end
    return false
  end
  _log("activated verified bytecode; checking it during this boot")
  return true
end

def confirm_active(activation_ok)

  if path.exists(PENDING_PATH)
    if !_pending_marker_is_ready()
      _log("pending marker is incomplete; refusing to confirm the update")
      return false
    end

    # CRITICAL FIX: If an update was pending but activation failed, 
    # clear out the staging files and refuse to update the build number.
    if !activation_ok
      _log("WARNING: Update was pending but activation failed. Cleaning up staged files to prevent build mismatch.")
      _remove_if_exists(PENDING_PATH)
      _remove_if_exists(STAGED_BUILD_PATH)
      _remove_if_exists(STAGED_PATH)
      return false
    end

    if !path.exists(STAGED_BUILD_PATH)
      _log("missing staged build marker; preserving recovery files")
      return false
    end

    var build = _read_text(STAGED_BUILD_PATH)
    var file = open(INSTALLED_BUILD_PATH, "w")
    file.write(build)
    file.flush()
    file.close()
    
    if !_remove_if_exists(PENDING_PATH) || !_remove_if_exists(STAGED_BUILD_PATH)
      return false
    end
    _log("confirmed installed build " + build)
  end
  return _remove_if_exists(OLD_APP_PATH)
end


def rollback_staged()
  if !path.exists(PENDING_PATH)
    return false
  end
  if path.exists(APP_PATH)
    if !_remove_if_exists(FAILED_APP_PATH)
      return false
    end
    if !path.rename(APP_PATH, FAILED_APP_PATH)
      _log("could not quarantine bytecode that failed to load")
      return false
    end
  end
  if path.exists(OLD_APP_PATH)
    if !path.rename(OLD_APP_PATH, APP_PATH)
      _log("could not restore the previous application")
      return false
    end
  end
  _remove_if_exists(PENDING_PATH)
  _remove_if_exists(STAGED_BUILD_PATH)
  _remove_if_exists(STAGED_PATH)
  _log("rolled back the staged application; restarting Tasmota")
  tasmota.cmd("Restart 1")
  return true
end

OTA_updater.start_background_check = start_background_check
OTA_updater.activate_staged = activate_staged
OTA_updater.confirm_active = confirm_active
OTA_updater.rollback_staged = rollback_staged

return OTA_updater
