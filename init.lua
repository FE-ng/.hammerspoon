require "modules.reload"
require "config"

-- hs CLI IPC（外部命令行调用 Hammerspoon：
-- /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c 'hs.reload()'）
pcall(function()
    hs.ipc.cliInstallPort('Hammerspoon')
end)
require "modules.window"
require "modules.launcher"
require "modules.defaultInput"
require "modules.wifiMute"
require "modules.bluetoothSleep"
-- require "modules.clipboard"
require "modules.ring"
require "modules.mouseMove"
require "modules.devGuard"

hs.hotkey.bind({'cmd', 'shift'}, 'h', function()
	hs.alert('Hello World') 
	speaker = hs.speech.new()
	speaker:speak("Hammerspoon is online")
	hs.notify.new({title="Hammerspoon launch", informativeText="Boss, at your service"}):send()
end)
