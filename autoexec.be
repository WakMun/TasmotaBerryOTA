import path
import tmc_updater

var updater_available = true
try
  tmc_updater.activate_staged()
except .. as error, message
  print("TasmotaAutoUpdater: updater unavailable:", message)
end

if updater_available
  try
    tmc_updater.start_background_check()
  except .. as error, message
    print("TasmotaAutoUpdater: could not schedule update check:", message)
  end
end

var application_started = false
if path.exists("Application.bec")
  try
    load("Application.bec")
    application_started = true
  except .. as error, message
    print("TasmotaAutoUpdater: application load failed:", message)
    if updater_available
      try
        tmc_updater.rollback_staged()
      except .. as rollback_error, rollback_message
        print("TasmotaAutoUpdater: rollback failed:", rollback_message)
      end
    end
  end
else
  print("TasmotaAutoUpdater: no installed bytecode")
end

if updater_available && application_started
  try
    tmc_updater.confirm_active()
  except .. as error, message
    print("TasmotaAutoUpdater: could not confirm application:", message)
  end
end
