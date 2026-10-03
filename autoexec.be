import path

var updater_available = false
try
  import tmc_updater
  updater_available = true
  tmc_updater.activate_staged()
except .. as error, message
  print("TasmotaMotorControl: updater unavailable:", message)
end

if updater_available
  tmc_updater.start_background_check()
end

var application_started = false
if path.exists("/application.bec")
  try
    load("/application.bec")
    application_started = true
  except .. as error, message
    print("TasmotaMotorControl: application load failed:", message)
    if updater_available
      try
        tmc_updater.rollback_staged()
      except .. as rollback_error, rollback_message
        print("TasmotaMotorControl: rollback failed:", rollback_message)
      end
    end
  end
else
  print("TasmotaMotorControl: no installed bytecode")
end

if updater_available && application_started
  tmc_updater.confirm_active()
end
