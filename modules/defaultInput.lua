local function Chinese()
    -- hs.keycodes.currentSourceID("com.apple.inputmethod.SCIM.ITABC")
    hs.keycodes.currentSourceID("com.sogou.inputmethod.sogou.pinyin")
end

local function English()
    hs.keycodes.currentSourceID("com.apple.keylayout.ABC")
end

function updateFocusAppInputMethod()
    local focusAppPath = hs.window.frontmostWindow():application():path()
    for index, app in pairs(appInputMethod) do
        local appPath = app[1]
        local expectedIme = app[2]

        if focusAppPath == appPath then
            if expectedIme == 'English' then
                English()
            else
                Chinese()
            end
            break
        end
    end
end

-- helper hotkey to figure out the app path and name of current focused window
hs.hotkey.bind({'ctrl', 'cmd'}, ".", function()
    hs.alert.show("App path:        "
    ..hs.window.focusedWindow():application():path()
    .."\n"
    .."App name:      "
    ..hs.window.focusedWindow():application():name()
    .."\n"
    .."IM source id:  "
    ..hs.keycodes.currentSourceID())
end)

-- Handle cursor focus and application's screen manage.
function applicationWatcher(appName, eventType, appObject)
    if (eventType == hs.application.watcher.activated) then
        updateFocusAppInputMethod()
    end
end

appWatcher = hs.application.watcher.new(applicationWatcher)
appWatcher:start()

-- ============================================================
-- 输入法自动回滚：macOS 在密码框/系统界面等场景会自动切到 ABC，
-- 非英文映射 App 内出现 ABC 键盘布局时，强制回滚到搜狗。
-- 映射为 'English' 的 App（Finder / 系统设置）保持 ABC 不干预。
-- ============================================================
local IME_SOGOU = 'com.sogou.inputmethod.sogou.pinyin'

local function isAppleKeyLayout(sourceID)
    return sourceID ~= nil and string.find(sourceID, '^com%.apple%.keylayout%.') ~= nil
end

local function frontAppExpectedIme()
    local win = hs.window.frontmostWindow()
    if win == nil then return nil end
    local app = win:application()
    if app == nil then return nil end
    local appPath = app:path()
    if appPath == nil then return nil end
    for index, item in pairs(appInputMethod) do
        if appPath == item[1] then
            return item[2]
        end
    end
    return nil
end

hs.keycodes.inputSourceChanged(function()
    local sourceID = hs.keycodes.currentSourceID()
    -- 只拦"系统把输入法切成 ABC 类键盘布局"的情况；切到搜狗/其他输入法不干预
    if not isAppleKeyLayout(sourceID) then return end
    -- 映射为 English 的 App 是主动切 ABC，放行
    if frontAppExpectedIme() == 'English' then return end
    -- 切回搜狗（再次触发 inputSourceChanged 时 sourceID 已不是 keylayout，自然终止）
    hs.keycodes.currentSourceID(IME_SOGOU)
end)