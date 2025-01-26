-- **************************************************
-- 连接到公司 Wi-Fi 后自动静音
-- **************************************************

-- --------------------------------------------------

local function mute()
  hs.audiodevice.defaultOutputDevice():setOutputMuted(true)
end

local function unmute()
  hs.audiodevice.defaultOutputDevice():setOutputMuted(false)
end
local handleWifiChanged = function()
  local currentSSID = hs.wifi.currentNetwork()

  if currentSSID == wifiName then
    mute()
  else
    unmute()
  end
end

wm_wifiWatcher = hs.wifi.watcher.new(handleWifiChanged)
wm_wifiWatcher:start()
