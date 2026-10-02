import path

var restarting = false
try
  import tmc_updater
  restarting = tmc_updater.check_and_install()
except .. as error, message
  print("TasmotaMotorControl: updater unavailable:", message)
end

if !restarting
  if path.exists("/TasmotaMotorControl.bec")
    try
      load("/TasmotaMotorControl.bec")
    except .. as error, message
      print("TasmotaMotorControl: bytecode load failed:", message)
      try
        tmc_updater.restore_previous()
      except .. as recovery_error, recovery_message
        print("TasmotaMotorControl: rollback failed:", recovery_message)
      end
    end
  else
    print("TasmotaMotorControl: no installed bytecode")
  end
end
