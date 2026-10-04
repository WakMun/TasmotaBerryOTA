import path
import OTA_updater

var updater_available = true
var activation_ok = true

# Activate a previously verified update before loading Application.bec.
try
  activation_ok = OTA_updater.activate_staged()
  if !activation_ok
    print("TasmotaBerryOTA: staged update activation failed")
  end
except .. as error, message
  activation_ok = false
  print("TasmotaBerryOTA: updater activation error:", message)
end

# Only schedule future update checks if the updater is usable.
if updater_available
  try
    OTA_updater.start_background_check()
  except .. as error, message
    print("TasmotaBerryOTA: could not schedule update check:", message)
  end
end

var application_started = false
if path.exists("Application.bec")
  try
    load("Application.bec")
    application_started = true
  except .. as error, message
    print("TasmotaBerryOTA: application load failed:", message)
    if updater_available && activation_ok
      try
        OTA_updater.rollback_staged()
      except .. as rollback_error, rollback_message
        print("TasmotaBerryOTA: rollback failed:", rollback_message)
      end
    end
  end
else
  print("TasmotaBerryOTA: no installed bytecode")
end

# Only confirm if the application actually loaded successfully.
if updater_available && application_started
  try
    OTA_updater.confirm_active()
  except .. as error, message
    print("TasmotaBerryOTA: could not confirm application:", message)
  end
end
