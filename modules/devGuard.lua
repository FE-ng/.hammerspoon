-- *******************************************************************
-- devGuard：开发进程守护
-- ---------------------------------------------------------------
-- 1) 僵尸 dev 进程清理（跨天累积的 rollup -w / tsc / nx / act 等
--    watch 进程脱离终端后（PPID=1）只会空耗 CPU，还会干扰预览）
--    - 手动：cmd+ctrl+alt+k 打开救援器（孤儿进程 / CPU 热点，选中杀）
--    - 自动：每 1 小时巡检一次，仅在系统唤醒状态执行；
--      清理对象限定「PPID=1 的孤儿 dev 进程」——你终端里正在用的
--      dev server 有父进程，不会被波及。
-- 2) 构建期自动防休眠
--    - 每 30 秒探测构建任务（npm/tnpm run、rollup、tsc、nx、vitest、act）
--    - 存在则阻止系统休眠；构建停止 2 分钟后自动恢复
--    - 手动兜底：cmd+ctrl+alt+c 临时防休眠（循环上次时长，首次 2h）
-- ---------------------------------------------------------------
-- 控制台调试（hs -c 调用）：
--    devGuardScan()          手动跑一次巡检
--    devGuardBuilding()      当前是否处于构建期
--    devGuardCaffeinate()    当前防休眠状态
--    devGuardKill(pid)       按升级策略杀指定进程（TERM→3s→KILL）
-- *******************************************************************

local logger = hs.logger.new('devGuard', 'info')

local SCAN_INTERVAL = 3600            -- 巡检间隔：1 小时
local BUILD_CHECK_INTERVAL = 30       -- 构建探测间隔：30 秒
local BUILD_RELEASE_DEBOUNCE = 120    -- 构建消失 2 分钟后才恢复休眠
local MANUAL_CAFFEINATE_MINUTES = 120 -- 手动防休眠默认时长
local CPU_HOT_THRESHOLD = 80          -- CPU 热点阈值（只报告，不自动杀）

-- 自动巡检清理的对象：命令行包含以下关键字 && PPID=1（脱离终端的孤儿）
local ORPHAN_PATTERNS = {
  'rollup', 'vitest', 'act server', 'nx', 'npm run', 'tnpm run', 'tsc',
}

-- CPU 热点候选（报告给救援器）
local CPU_HOT_PATTERNS = { 'node', 'rollup', 'vitest', 'tsc', 'nx' }

-- "构建期"判定（防休眠用）：只认一次性构建/测试；
-- dev watch 型（rollup -w / run-executor / vitest --watch）不算——
-- 否则常驻 dev server 会把休眠锁死一整天
local BUILD_PATTERNS = {
  'npm run build', 'tnpm run build', 'npm run upload', 'tnpm run upload',
  'npm run build:tsc', 'vitest', 'jest', 'vite build', 'nx build', 'nx run',
}
local BUILD_EXCLUDE_PATTERNS = { '--watch', 'run-executor', ':dev', ':watch' }

-- ---------------------------------------------------------------
-- 进程扫描
-- ---------------------------------------------------------------

local function getProcs()
  local out = hs.execute('ps -axeo pid=,ppid=,pcpu=,etime=,command=')
  if not out then return {} end
  local procs = {}
  for line in out:gmatch('[^\r\n]+') do
    local pid, ppid, pcpu, etime, cmd =
      line:match('^%s*(%d+)%s+(%d+)%s+([%d%.]+)%s+([%d:%-]+)%s+(.+)$')
    if cmd then
      table.insert(procs, {
        pid = tonumber(pid), ppid = tonumber(ppid),
        cpu = tonumber(pcpu), etime = etime, cmd = cmd,
      })
    end
  end
  return procs
end

local function matchesAny(cmd, patterns)
  for _, p in ipairs(patterns) do
    if cmd:find(p, 1, true) then return p end
  end
  return nil
end

local function findAlive(pids)
  local result = {}
  for _, pid in ipairs(pids) do
    local out = hs.execute('ps -p ' .. pid .. ' -o pid=')
    if out and tonumber(out) == pid then
      table.insert(result, pid)
    end
  end
  return result
end

-- 杀进程：先 TERM，3 秒后残余升级 KILL，最后通知结果
local function killProcs(pidList, title)
  if #pidList == 0 then return end
  hs.execute('kill -TERM ' .. table.concat(pidList, ' '))

  hs.timer.doAfter(3, function()
    local alive = findAlive(pidList)
    if #alive > 0 then
      hs.execute('kill -9 ' .. table.concat(alive, ' '))
    end
    hs.timer.doAfter(1, function()
      local leftover = findAlive(pidList)
      hs.notify.new(nil, {
        title = title,
        informativeText = string.format(
          '清理 %d/%d 个%s',
          #pidList - #leftover, #pidList,
          #leftover > 0 and ('，顽固残留: ' .. table.concat(leftover, ',')) or ''
        ),
      }):send()
      logger.i('killProcs done:', #pidList - #leftover, '/', #pidList)
    end)
  end)
end

-- ---------------------------------------------------------------
-- 唤醒态跟踪 + 定时巡检
-- ---------------------------------------------------------------

local awake = true  -- 初始视为唤醒：系统真入睡时定时器本身也会暂停，
                    -- watcher 只负责在事件发生时翻转状态
local function isAwake()
  return awake
end

local caffeinateWatcher = hs.caffeinate.watcher.new(function(eventType)
  if eventType == hs.caffeinate.watcher.systemWillSleep
      or eventType == hs.caffeinate.watcher.screensDidSleep then
    awake = false
  elseif eventType == hs.caffeinate.watcher.systemDidWake
      or eventType == hs.caffeinate.watcher.screensDidWake then
    awake = true
    -- 唤醒后 1 分钟补一次巡检（在底部启动区注册）
  end
end)
caffeinateWatcher:start()

local function scanAndClean()
  if not isAwake() then
    logger.i('skip scan: system asleep')
    return
  end
  local zombies = {}
  for _, proc in ipairs(getProcs()) do
    if proc.ppid == 1 and matchesAny(proc.cmd, ORPHAN_PATTERNS) then
      table.insert(zombies, proc)
    end
  end
  if #zombies > 0 then
    local pids = {}
    local info = {}
    for _, z in ipairs(zombies) do
      table.insert(pids, z.pid)
      table.insert(info, z.pid .. ':' .. z.cmd:sub(1, 40))
    end
    logger.i('auto cleanup zombies:', table.concat(info, ' | '))
    killProcs(pids, '孤儿 dev 进程已自动清理')
  else
    logger.i('scan clean, no orphans')
  end
end

-- ---------------------------------------------------------------
-- 手动救援器（cmd+ctrl+alt+k）
-- ---------------------------------------------------------------

local rescue

local function buildChoices()
  local choices = {}
  for _, proc in ipairs(getProcs()) do
    if proc.ppid == 1 and matchesAny(proc.cmd, ORPHAN_PATTERNS) then
      table.insert(choices, {
        text = '【孤儿】 ' .. proc.cmd:sub(1, 90),
        subText = 'pid:' .. proc.pid .. '  uptime:' .. proc.etime .. '  cpu:' .. proc.cpu .. '%',
        pid = proc.pid,
      })
    elseif proc.cpu >= CPU_HOT_THRESHOLD and matchesAny(proc.cmd, CPU_HOT_PATTERNS) then
      table.insert(choices, {
        text = '【CPU ' .. proc.cpu .. '%】 ' .. proc.cmd:sub(1, 90),
        subText = 'pid:' .. proc.pid .. '  ppid:' .. proc.ppid .. '  uptime:' .. proc.etime,
        pid = proc.pid,
      })
    end
  end
  return choices
end

rescue = hs.chooser.new(function(choice)
  if not choice then return end
  killProcs({ choice.pid }, '手动清理 pid ' .. choice.pid)
end)

hs.hotkey.bind({ 'cmd', 'ctrl', 'alt' }, 'k', 'dev 进程救援器', function()
  local choices = buildChoices()
  if #choices == 0 then
    hs.alert.show('没有发现孤儿 dev 进程或 CPU 热点', 1.5)
  else
    rescue:choices(choices)
    rescue:show()
  end
end)

-- ---------------------------------------------------------------
-- 构建期自动防休眠（30 秒探测，构建停 2 分钟后恢复）
-- ---------------------------------------------------------------

local caffeinated = false
local lastBuildSeen = os.time() - (BUILD_RELEASE_DEBOUNCE + 60)
local manualUntil = 0  -- 手动防休眠截止时间戳（0 = 未开启）

-- 模块加载时重置断言（热重载后断言会残留，先清零再由探测器接管）
local function releaseAll()
  hs.caffeinate.set('systemIdle', false)
  hs.caffeinate.set('displayIdle', false)
  caffeinated = false
end
releaseAll()

local function isBuildProc(cmd)
  if not matchesAny(cmd, BUILD_PATTERNS) then return false end
  for _, p in ipairs(BUILD_EXCLUDE_PATTERNS) do
    if cmd:find(p, 1, true) then return false end
  end
  if cmd:find('%-w%s') then return false end  -- rollup -w / tsc -w
  return true
end

local function hasBuildProcess()
  for _, proc in ipairs(getProcs()) do
    if isBuildProc(proc.cmd) then return proc end
  end
  return nil
end

local function acquire()
  if not caffeinated then
    hs.caffeinate.set('systemIdle', true)
    hs.caffeinate.set('displayIdle', true)
    caffeinated = true
    logger.i('caffeinate ON (build detected / manual)')
  end
end

local function release()
  if caffeinated then
    releaseAll()
    logger.i('caffeinate OFF')
  end
end

hs.hotkey.bind({ 'cmd', 'ctrl', 'alt' }, 'c', '构建期防休眠（手动兜底）', function()
  if manualUntil > 0 then
    manualUntil = 0
    release()
    hs.alert.show('devGuard：手动防休眠已取消', 1.5)
  else
    manualUntil = os.time() + MANUAL_CAFFEINATE_MINUTES * 60
    hs.alert.show('devGuard：' .. MANUAL_CAFFEINATE_MINUTES .. ' 分钟内不会休眠（按 cmd+ctrl+alt+c 取消）', 2)
  end
end)

-- ---------------------------------------------------------------
-- 对外调试入口 + 启动
-- ---------------------------------------------------------------

devGuardScan = scanAndClean
devGuardBuilding = function()
  local found = hasBuildProcess()
  if found then logger.i('build proc: ' .. found.pid .. ' ' .. found.cmd:sub(1, 80)) end
  return found ~= nil
end
devGuardCaffeinate = function()
  return caffeinated, hs.caffeinate.get('systemIdle'), hs.caffeinate.get('displayIdle')
end
devGuardKill = function(pid)
  killProcs({ tonumber(pid) }, '手动清理 pid ' .. tostring(pid))
end

-- 启动：唤醒态起跑第一次巡检 + 周期巡检（持有引用防 GC）
local scanTimer = hs.timer.doEvery(SCAN_INTERVAL, scanAndClean)
local buildTimer = hs.timer.doEvery(BUILD_CHECK_INTERVAL, function()
  -- 手动兜底优先
  if manualUntil > 0 then
    if os.time() < manualUntil then
      acquire()
      return
    end
    manualUntil = 0
    release()
    hs.notify.new(nil, { title = 'devGuard', informativeText = '手动防休眠时段结束，已恢复休眠' }):send()
    return
  end

  if hasBuildProcess() then
    lastBuildSeen = os.time()
    acquire()
  elseif caffeinated and (os.time() - lastBuildSeen) > BUILD_RELEASE_DEBOUNCE then
    release()
    hs.notify.new(nil, { title = 'devGuard', informativeText = '构建已结束，恢复系统正常休眠' }):send()
  end
end)

devGuardState = {
  scanTimer = scanTimer,
  buildTimer = buildTimer,
  caffeinateWatcher = caffeinateWatcher,
  rescue = rescue,
}

hs.timer.doAfter(5, function()
  scanAndClean()
end)
-- 唤醒后 1 分钟补一次巡检
hs.timer.doAfter(60, function()
  if isAwake() then scanAndClean() end
end)
