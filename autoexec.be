import path
import OTA_updater

var updater_available = true
try
  OTA_updater.activate_staged()
except .. as error, message
  print("TasmotaBerryOTA: updater unavailable:", message)
end

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
    if updater_available
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

if updater_available && application_started
  try
    OTA_updater.confirm_active()
  except .. as error, message
    print("TasmotaBerryOTA: could not confirm application:", message)
  end
end
