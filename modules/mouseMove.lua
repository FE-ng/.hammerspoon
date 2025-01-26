local eventtap = require "hs.eventtap"
local event = eventtap.event
local timer = require "hs.timer"

local scrollAmount = 10
local scrollInterval = 0.01

local scrollUpTimer = nil
local scrollDownTimer = nil

-- Function to simulate mouse scroll
function scrollMouse(x, y)
    local scrollEvent = event.newScrollEvent({x, y}, {}, "pixel")
    scrollEvent:post()
end

-- Function to start scroll up
function startScrollUp()
    if scrollUpTimer == nil then
        scrollUpTimer = timer.doEvery(scrollInterval, function()
            scrollMouse(0, -scrollAmount)
        end)
    end
end

-- Function to stop scroll up
function stopScrollUp()
    if scrollUpTimer ~= nil then
        scrollUpTimer:stop()
        scrollUpTimer = nil
    end
end

-- Function to start scroll down
function startScrollDown()
    if scrollDownTimer == nil then
        scrollDownTimer = timer.doEvery(scrollInterval, function()
            scrollMouse(0, scrollAmount)
        end)
    end
end

-- Function to stop scroll down
function stopScrollDown()
    if scrollDownTimer ~= nil then
        scrollDownTimer:stop()
        scrollDownTimer = nil
    end
end

-- Bind scroll up to Ctrl+Alt+U
hs.hotkey.bind({"ctrl", "alt"}, "U", startScrollUp, stopScrollUp)
-- Bind scroll down to Ctrl+Alt+D
hs.hotkey.bind({"ctrl", "alt"}, "D", startScrollDown, stopScrollDown)

-- 实现鼠标移动的脚本
-- 加载 hs.hotkey、hs.eventtap 和 hs.timer 模块
local hotkey = hs.hotkey
local eventtap = hs.eventtap
local mouse = hs.mouse
local timer = hs.timer

-- 定义移动步长和移动间隔
local moveStep = 5
local moveInterval = 0.01

-- 定义一个函数来移动鼠标
local function moveMouse(x, y)
    local pos = mouse.absolutePosition()
    pos.x = pos.x + x
    pos.y = pos.y + y
    mouse.setAbsolutePosition(pos)
end

-- 定义一个函数来启动定时器
local function startTimer(x, y)
    return timer.doEvery(moveInterval, function() moveMouse(x, y) end)
end

-- 定义一个函数来停止定时器
local function stopTimer(t)
    if t then
        t:stop()
    end
end

-- 定义按键绑定和定时器变量
local timers = {}

hotkey.bind({"ctrl", "alt"}, "Left",
    function() timers["left"] = startTimer(-moveStep, 0) end,
    function() stopTimer(timers["left"]) end
)

hotkey.bind({"ctrl", "alt"}, "Right",
    function() timers["right"] = startTimer(moveStep, 0) end,
    function() stopTimer(timers["right"]) end
)

hotkey.bind({"ctrl", "alt"}, "Up",
    function() timers["up"] = startTimer(0, -moveStep) end,
    function() stopTimer(timers["up"]) end
)

hotkey.bind({"ctrl", "alt"}, "Down",
    function() timers["down"] = startTimer(0, moveStep) end,
    function() stopTimer(timers["down"]) end
)

-- 定义回车键单击操作
hotkey.bind({"ctrl", "alt"}, "return", function()
    local pos = mouse.absolutePosition()
    eventtap.leftClick(pos)
end)
