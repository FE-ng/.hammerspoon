-- Window management

-- Keep a short window-move animation: the default 0.2s feels laggy when cycling
-- sizes with repeated presses, but 0 is too abrupt. 0.08s stays snappy with a
-- subtle transition. (Cycle detection re-reads the frame on the next press, by
-- which time this short animation has finished, so step detection stays correct.)
hs.window.animationDuration = 0.08

-- Defines for window maximize toggler
local frameCache = {}
local logger = hs.logger.new("windows")

-- Apps that lock their window aspect ratio. setFrame() honors top-left but
-- shrinks the requested size, leaving the window pinned to the wrong edge
-- (e.g. "right half" ends up in the middle with a gap on the right).
local aspectLockedApps = {
   ["Simulator"] = true,
   ["DeviceHub"] = true,  -- Xcode 27 起 Simulator 并入 DeviceHub（/Applications/Xcode.app/Contents/Applications/DeviceHub.app）
}

local function isAspectLocked(win)
   if not win then return false end
   local ok, app = pcall(function() return win:application() end)
   if not ok or not app then return false end
   return aspectLockedApps[app:name()] == true
end

-- Move into a unit rect, then re-align to the requested edge if the app
-- shrank the window (aspect-lock fixup).
local function moveAligned(win, rect, hAlign, vAlign)
   win:move(rect)
   local f = win:frame()
   local sf = win:screen():frame()
   local expectedW = rect[3] * sf.w
   local expectedH = rect[4] * sf.h
   local tol = 2
   local newX, newY = f.x, f.y
   if f.w + tol < expectedW then
      if hAlign == "right" then
         newX = sf.x + sf.w - f.w
      elseif hAlign == "center" then
         newX = sf.x + (sf.w - f.w) / 2
      elseif hAlign == "left" then
         newX = sf.x
      end
   end
   if f.h + tol < expectedH then
      if vAlign == "bottom" then
         newY = sf.y + sf.h - f.h
      elseif vAlign == "center" then
         newY = sf.y + (sf.h - f.h) / 2
      elseif vAlign == "top" then
         newY = sf.y
      end
   end
   if math.abs(newX - f.x) > 0.5 or math.abs(newY - f.y) > 0.5 then
      win:setFrame({x = newX, y = newY, w = f.w, h = f.h})
   end
end

-- Resize current window

function winresize(how)
   local win = hs.window.focusedWindow()
   if not win then return end
   local newrect, hAlign, vAlign

   if how == "left" then
      newrect, hAlign = hs.layout.left50, "left"
   elseif how == "right" then
      newrect, hAlign = hs.layout.right50, "right"
   elseif how == "up" then
      newrect, vAlign = {0,0,1,0.5}, "top"
   elseif how == "down" then
      newrect, vAlign = {0,0.5,1,0.5}, "bottom"
   elseif how == "max" then
      newrect = hs.layout.maximized
   elseif how == "left_third" or how == "hthird-0" then
      newrect, hAlign = {0,0,1/3,1}, "left"
   elseif how == "middle_third_h" or how == "hthird-1" then
      newrect, hAlign = {1/3,0,1/3,1}, "center"
   elseif how == "right_third" or how == "hthird-2" then
      newrect, hAlign = {2/3,0,1/3,1}, "right"
   elseif how == "top_third" or how == "vthird-0" then
      newrect, vAlign = {0,0,1,1/3}, "top"
   elseif how == "middle_third_v" or how == "vthird-1" then
      newrect, vAlign = {0,1/3,1,1/3}, "center"
   elseif how == "bottom_third" or how == "vthird-2" then
      newrect, vAlign = {0,2/3,1,1/3}, "bottom"
   end

   moveAligned(win, newrect, hAlign, vAlign)
end

function winmovescreen(how)
   local win = hs.window.focusedWindow()
   if how == "left" then
      win:moveOneScreenWest()
   elseif how == "right" then
      win:moveOneScreenEast()
   end
end

-- Toggle a window between its normal size, and being maximized
function toggle_window_maximized()
   local win = hs.window.focusedWindow()
   if frameCache[win:id()] then
      win:setFrame(frameCache[win:id()])
      frameCache[win:id()] = nil
   else
      frameCache[win:id()] = win:frame()
      win:maximize()
   end
end

-- Move between thirds of the screen
function get_horizontal_third(win)
   local frame=win:frame()
   local screenframe=win:screen():frame()
   local relframe=hs.geometry(frame.x-screenframe.x, frame.y-screenframe.y, frame.w, frame.h)
   local third = math.floor(3.01*relframe.x/screenframe.w)
   logger.df("Screen frame: %s", screenframe)
   logger.df("Window frame: %s, relframe %s is in horizontal third #%d", frame, relframe, third)
   return third
end

function get_vertical_third(win)
   local frame=win:frame()
   local screenframe=win:screen():frame()
   local relframe=hs.geometry(frame.x-screenframe.x, frame.y-screenframe.y, frame.w, frame.h)
   local third = math.floor(3.01*relframe.y/screenframe.h)
   logger.df("Screen frame: %s", screenframe)
   logger.df("Window frame: %s, relframe %s is in vertical third #%d", frame, relframe, third)
   return third
end

function left_third()
   local win = hs.window.focusedWindow()
   local third = get_horizontal_third(win)
   if third == 0 then
      winresize("hthird-0")
   else
      winresize("hthird-" .. (third-1))
   end
end

function right_third()
   local win = hs.window.focusedWindow()
   local third = get_horizontal_third(win)
   if third == 2 then
      winresize("hthird-2")
   else
      winresize("hthird-" .. (third+1))
   end
end

function up_third()
   local win = hs.window.focusedWindow()
   local third = get_vertical_third(win)
   if third == 0 then
      winresize("vthird-0")
   else
      winresize("vthird-" .. (third-1))
   end
end

function down_third()
   local win = hs.window.focusedWindow()
   local third = get_vertical_third(win)
   if third == 2 then
      winresize("vthird-2")
   else
      winresize("vthird-" .. (third+1))
   end
end

function center()
   local win = hs.window.focusedWindow()
   win:centerOnScreen()
end

-- Cycle a window through size fractions on one side of the screen.
-- Repeated presses step the size: 1/2 -> 1/3 -> 2/3 -> 1/2 ...
-- left/right cycle width (full height); up/down cycle height (full width).
-- Stateless: the next step is derived from the window's current frame, so a
-- fresh press from anywhere else snaps to 1/2 first.
local halfCycles = {
   left  = { {0,   0,   1/2, 1},   {0,   0,   1/3, 1},   {0,   0,   2/3, 1} },
   right = { {1/2, 0,   1/2, 1},   {2/3, 0,   1/3, 1},   {1/3, 0,   2/3, 1} },
   up    = { {0,   0,   1,   1/2}, {0,   0,   1,   1/3}, {0,   0,   1,   2/3} },
   down  = { {0,   1/2, 1,   1/2}, {0,   2/3, 1,   1/3}, {0,   1/3, 1,   2/3} },
}

function cycle_half(direction)
   local win = hs.window.focusedWindow()
   if not win then return end

   -- Aspect-locked apps (Simulator) can't be resized into our cycle rects,
   -- so just pin them to the requested edge without changing width/height.
   -- Use setFrame (not setTopLeft) so hs.window.animationDuration applies.
   -- When moving horizontally, center vertically (and vice versa) so a
   -- fixed-size window doesn't end up flush to the top/left corner.
   if isAspectLocked(win) then
      local f = win:frame()
      local sf = win:screen():frame()
      local newX, newY = f.x, f.y
      if direction == "left" then
         newX = sf.x
         newY = sf.y + (sf.h - f.h) / 2
      elseif direction == "right" then
         newX = sf.x + sf.w - f.w
         newY = sf.y + (sf.h - f.h) / 2
      elseif direction == "up" then
         newY = sf.y
         newX = sf.x + (sf.w - f.w) / 2
      elseif direction == "down" then
         newY = sf.y + sf.h - f.h
         newX = sf.x + (sf.w - f.w) / 2
      end
      win:setFrame({x = newX, y = newY, w = f.w, h = f.h})
      return
   end

   local seq = halfCycles[direction]
   local frame = win:frame()
   local sf = win:screen():frame()
   local rx, ry = (frame.x - sf.x) / sf.w, (frame.y - sf.y) / sf.h
   local rw, rh = frame.w / sf.w, frame.h / sf.h
   local tol = 0.03

   local function matches(rect)
      return math.abs(rx - rect[1]) < tol and math.abs(ry - rect[2]) < tol
         and math.abs(rw - rect[3]) < tol and math.abs(rh - rect[4]) < tol
   end

   local target = seq[1]  -- default (first press / coming from elsewhere): 1/2
   for i, rect in ipairs(seq) do
      if matches(rect) then
         target = seq[(i % #seq) + 1]  -- advance to next step in the cycle
         break
      end
   end

   local hAlign, vAlign
   if direction == "left" then hAlign = "left"
   elseif direction == "right" then hAlign = "right"
   elseif direction == "up" then vAlign = "top"
   elseif direction == "down" then vAlign = "bottom"
   end
   moveAligned(win, target, hAlign, vAlign)
end


-- Set hyper to ctrl + alt + cmd + shift
local hyper = {'ctrl', 'cmd'}

-- Move Mouse to center of next Monitor
hs.hotkey.bind(hyper, '\'', function()
    local screen = hs.mouse.getCurrentScreen()
    local nextScreen = screen:next()
    local rect = nextScreen:fullFrame()
    local center = hs.geometry.rectMidPoint(rect)
    hs.mouse.setAbsolutePosition(center)
end)
hs.hotkey.bind(hyper, ';', function()
    local screen = hs.mouse.getCurrentScreen()
    local nextScreen = screen:next()
    local rect = nextScreen:fullFrame()
    local center = hs.geometry.rectMidPoint(rect)
    hs.mouse.setAbsolutePosition(center)
end)

-------- Key bindings

-- Halves of the screen (repeated press cycles size: 1/2 -> 1/3 -> 2/3 -> 1/2)
hs.hotkey.bind(hyper, "Left",  hs.fnutils.partial(cycle_half, "left"))
hs.hotkey.bind(hyper, "Right", hs.fnutils.partial(cycle_half, "right"))
hs.hotkey.bind(hyper, "Up",    hs.fnutils.partial(cycle_half, "up"))
hs.hotkey.bind(hyper, "Down",  hs.fnutils.partial(cycle_half, "down"))

-- Center of the screen
hs.hotkey.bind(hyper, "C", center)

-- Thirds of the screen
hs.hotkey.bind({"ctrl", "alt"}, "Left",  left_third)
hs.hotkey.bind({"ctrl", "alt"}, "Right", right_third)
hs.hotkey.bind({"ctrl", "alt"}, "Up",    up_third)
hs.hotkey.bind({"ctrl", "alt"}, "Down",  down_third)

-- Maximized
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "F",     hs.fnutils.partial(winresize, "max"))
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "Up",    hs.fnutils.partial(winresize, "max"))

-- Move between screens
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "Left",  hs.fnutils.partial(winmovescreen, "left"))
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "Right", hs.fnutils.partial(winmovescreen, "right"))

