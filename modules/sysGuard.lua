-- *******************************************************************
-- sysGuard：系统资源监控告警（防"温水煮青蛙"式全场卡死）
-- ---------------------------------------------------------------
-- 背景：swap 43GB 涨满前没有任何感知，Chrome 全场卡死才发现。
-- 监控三项指标，越线即 hs.notify 告警 + 菜单栏指示灯：
--   1) swap 用量      黄 >16GB（≈物理内存等量） 红 >30GB
--   2) 数据盘余量     黄 <40GB                 红 <20GB
--   3) 5min load      黄 >12                   红 >24
-- 防骚扰：连续 2 次采样越线才告警（防抖）；同类告警 30 分钟冷却；
--         回落越线以下发"已恢复"通知。
-- ---------------------------------------------------------------
-- 控制台调试（hs -c 调用）：
--   sysGuardCheck()   手动跑一次采样（返回结果表）
--   sysGuardStatus()  当前状态摘要（菜单栏 tooltip 同款）
-- *******************************************************************

local logger = hs.logger.new('sysGuard', 'info')

local M = {}

local CHECK_INTERVAL = 60     -- 采样间隔：60s
local DEBOUNCE_HITS   = 2     -- 连续 N 次越线才告警
local ALERT_COOLDOWN  = 1800   -- 同类告警冷却：30 分钟

-- 阈值（物理内存 16GB 的口径）
local SWAP_WARN_GB,  SWAP_ALERT_GB  = 16, 30
local DISK_WARN_GB,  DISK_ALERT_GB  = 40, 20
local LOAD_WARN,     LOAD_ALERT     = 12, 24

-- ---------------------------------------------------------------
-- 采样
-- ---------------------------------------------------------------

-- 采样都走 awk 取列，避开 hs.execute 多返回值 + Lua 正则匹配的坑
--（曾踩：df 里 inode 列的 %iused 段让模式抓错列，得到 ifree 而不是 avail）
local function shellNum(cmd)
  local out = hs.execute(cmd)
  return tonumber(out) or 0
end

local function readSwapUsedGB()
  -- vm.swapusage 格式: "total = 44032.00M  used = 43020.06M  free = ... (encrypted)"
  return shellNum("sysctl -n vm.swapusage | awk '{for(i=1;i<=NF;i++)if($i==\"used\")print $(i+2)}' | tr -d M") / 1024
end

local function readDiskAvailGB()
  return shellNum("df -k /System/Volumes/Data | awk 'NR==2 {print $4}'") / 1024 / 1024
end

local function readLoad5()
  return shellNum("sysctl -n vm.loadavg | awk '{print $3}'")
end

-- 每项指标计算级别：'ok' / 'warn' / 'alert'
local function sample()
  local swap, disk, load = readSwapUsedGB(), readDiskAvailGB(), readLoad5()
  local lv = { swap = 'ok', disk = 'ok', load = 'ok' }
  if swap >= SWAP_ALERT_GB then lv.swap = 'alert' elseif swap >= SWAP_WARN_GB then lv.swap = 'warn' end
  if disk <= DISK_ALERT_GB then lv.disk = 'alert' elseif disk <= DISK_WARN_GB then lv.disk = 'warn' end
  if load >= LOAD_ALERT then lv.load = 'alert' elseif load >= LOAD_WARN then lv.load = 'warn' end
  return { swap = swap, disk = disk, load = load, level = lv }
end

-- ---------------------------------------------------------------
-- 告警状态机：debounce 计数 + 冷却 + 恢复通知
-- ---------------------------------------------------------------

-- state[metric] = { hits=越线连击, sent=最近发送的级别, at=上次告警时间 }
local state = { swap = {}, disk = {}, load = {} }

local METRIC_META = {
  swap = { title = '交换分区 Swap', unit = 'GB', fmt = '%.0fGB',
           check = function(s) return s.swap end, warn = SWAP_WARN_GB, alert = SWAP_ALERT_GB },
  disk = { title = '磁盘余量', unit = 'GB', fmt = '%.0fGB',
           check = function(s) return s.disk end, warn = DISK_WARN_GB, alert = DISK_ALERT_GB },
  load = { title = '系统负载(5min)', unit = '', fmt = '%.1f',
           check = function(s) return s.load end, warn = LOAD_WARN, alert = LOAD_ALERT },
}

local function levelRank(lv) return lv == 'alert' and 2 or (lv == 'warn' and 1 or 0) end

local function notify(metric, meta, lv, value)
  local st = state[metric]
  local now = os.time()
  -- 冷却：同级/更轻的告警 30 分钟内不重复
  if st.sent and (now - st.at) < ALERT_COOLDOWN and levelRank(lv) <= levelRank(st.sent) then
    return
  end
  local higher = st.sent and levelRank(lv) > levelRank(st.sent)
  st.sent, st.at = lv, now
  local headline = string.format('%s %s%s', meta.title,
                                 string.format(meta.fmt, value), meta.unit)
  local msg
  if metric == 'swap' then
    msg = (lv == 'alert')
      and '接近打满，全场卡死前兆！建议关闭大应用，或择机重启清空 swap'
       or '超过物理内存等量，冷页开始外溢磁盘，建议排查大应用'
  elseif metric == 'disk' then
    msg = (lv == 'alert')
      and '磁盘余量告急，swap 文件无法增长，会放大卡死风险，请清理'
       or '磁盘余量偏低，建议清理大文件'
  else
    msg = (lv == 'alert')
      and '负载极高，GUI 应用将排队无响应，查看 CPU Top 并杀僵尸进程'
       or '负载偏高，关注 devGuard 僵尸进程巡检'
  end
  hs.notify.new(nil, {
    title = (lv == 'alert' and '🔴 sysGuard 告警 · ' or '🟡 sysGuard 提醒 · ') .. headline,
    subTitle = higher and '级别已升级' or nil,
    message = msg,
    soundName = lv == 'alert' and 'Basso' or nil,
    autoWithdraw = 10,
  }):send()
  logger.wf('notify %s %s value=%s', metric, lv, headline)
end

local function evalMetric(metric, meta, s)
  local st = state[metric]
  local lv = s.level[metric]
  if lv ~= 'ok' then
    st.hits = (st.hits or 0) + 1
    if st.hits >= DEBOUNCE_HITS then
      notify(metric, meta, lv, meta.check(s))
    end
  else
    -- 回落：若有未恢复的告警状态，发恢复通知并复位
    if st.sent then
      hs.notify.new(nil, {
        title = '🟢 sysGuard 已恢复 · ' .. meta.title,
        message = string.format('当前值 ' .. meta.fmt .. '，已回落到阈值内', meta.check(s)),
        autoWithdraw = 6,
      }):send()
      logger.i('recovered', metric)
    end
    st.hits, st.sent, st.at = 0, nil, nil
  end
end

-- ---------------------------------------------------------------
-- 菜单栏指示灯
-- ---------------------------------------------------------------

local menubar

local function renderMenubar(s)
  if not menubar then return end
  local worst = 'ok'
  for _, lv in pairs(s.level) do
    if levelRank(lv) > levelRank(worst) then worst = lv end
  end
  local icon = worst == 'ok' and 'SG ✓' or (worst == 'warn' and 'SG ⚠️' or 'SG 🔴')
  menubar:setTitle(icon)
  menubar:setTooltip(string.format(
    'sysGuard\nswap: %.0fGB (warn>16 alert>30)\ndisk avail: %.0fGB (warn<40 alert<20)\nload5: %.1f (warn>12 alert>24)\n上次采样: %s',
    s.swap, s.disk, s.load, os.date('%H:%M:%S')))
  return worst
end

-- ---------------------------------------------------------------
-- 一键止血 / 清理（告警之后的动作入口，也可菜单栏手点）
-- ---------------------------------------------------------------

-- 止血 1：关闭所有 booted 模拟器（每个占 1-2GB 内存 + 一个磁盘镜像句柄）
function M.shutdownSims()
  local out = hs.execute("xcrun simctl list devices | grep Booted | wc -l")
  local n = tonumber(out) or 0
  if n == 0 then
    hs.alert('没有 Booted 状态的模拟器')
    return
  end
  hs.execute('osascript -e \'display notification "正在关闭 ' .. n .. ' 台模拟器" with title "sysGuard"\'')
  hs.execute('for U in $(xcrun simctl list devices | grep Booted | grep -oE "[0-9A-F-]{36}"); do xcrun simctl shutdown $U; done')
  logger.i('shutdown sims:', n)
end

-- 止血 2：跑一次 devGuard 孤儿进程巡检（清 PPID=1 的僵尸 dev 进程）
function M.scanZombies()
  if _G.devGuardScan then
    _G.devGuardScan()
    hs.alert('devGuard 巡检已执行，结果见通知/日志')
  else
    hs.alert('devGuard 未加载')
  end
end

-- 清盘 1：报告开发缓存大头（只读扫描，>500MB 才列，不动文件）
-- 控制台：sysGuardDiskHogs() 手动调用
function M.diskHogs()
  local dirs = {
    '~/Library/Developer/Xcode/DerivedData',
    '~/Library/Developer/Xcode/iOS DeviceSupport',
    '~/Library/Developer/CoreSimulator/Caches',
    '~/Library/Developer/CoreSimulator/Devices', -- 模拟器本体（删=丢模拟器数据，慎）
    '~/Library/Caches',
    '~/.npm',
    '~/Downloads',
  }
  local lines = {}
  for _, d in ipairs(dirs) do
    local out = hs.execute('du -xsk ' .. d .. ' 2>/dev/null')
    local kb = tonumber(out:match('^(%d+)')) or 0
    local gb = kb / 1024 / 1024
    if gb >= 0.5 then
      table.insert(lines, string.format('%6.1fGB  %s', gb, d))
    end
  end
  local report = #lines > 0 and table.concat(lines, '\n') or '暂无 >500MB 的开发缓存大头'
  hs.notify.new(nil, {
    title = 'sysGuard 磁盘大头扫描（只报告，不删除）',
    message = report,
    autoWithdraw = 30,
  }):send()
  return report
end

-- 清盘 2：真删安全缓存（DerivedData / CoreSimulator Caches / npm cache）
-- 默认 dry-run；清盘入口都要求显式传 true 才动手
function M.cleanCaches(danger)
  if danger ~= true then
    local dry = hs.execute(
      'du -sk ~/Library/Developer/Xcode/DerivedData ~/Library/Developer/CoreSimulator/Caches ~/.npm 2>/dev/null'
    )
    hs.notify.new(nil, {
      title = 'sysGuard 清理预览（未删除）',
      message = '当前占用:\n' .. dry .. '\n\n在菜单栏点「执行清理」或 hs -c "sysGuardCleanCaches()" 才会真删',
      autoWithdraw = 30,
    }):send()
    return 'dry-run'
  end
  hs.execute('rm -rf ~/Library/Developer/Xcode/DerivedData/* 2>/dev/null')
  hs.execute('rm -rf ~/Library/Developer/CoreSimulator/Caches/* 2>/dev/null')
  hs.execute('npm cache clean --force 2>/dev/null')
  local freed = hs.execute('df -k /System/Volumes/Data | awk \'NR==2{print $4}\'')
  hs.notify.new(nil, {
    title = 'sysGuard 清理完成',
    message = 'DerivedData + 模拟器缓存 + npm 已清，当前磁盘余量 ' ..
      string.format('%.0fGB', tonumber(freed) / 1024 / 1024),
  }):send()
  M.check()
  return 'cleaned'
end

-- ---------------------------------------------------------------
-- 入口
-- ---------------------------------------------------------------

function M.check()
  local s = sample()
  renderMenubar(s)
  for metric, meta in pairs(METRIC_META) do
    evalMetric(metric, meta, s)
  end
  return s
end

function M.status()
  local s = sample()
  return string.format('swap=%.0fGB diskAvail=%.0fGB load5=%.1f | %s/%s/%s',
    s.swap, s.disk, s.load, s.level.swap, s.level.disk, s.level.load)
end

menubar = hs.menubar.new()
menubar:setTitle('SG …')
-- 点击弹出：详情 + 常用动作
menubar:setMenu(function()
  local s = sample()
  return {
    { title = string.format('swap %.0fGB  (黄>16 红>30)', s.swap), disabled = true },
    { title = string.format('磁盘余量 %.0fGB  (黄<40 红<20)', s.disk), disabled = true },
    { title = string.format('load5m %.1f  (黄>12 红>24)', s.load), disabled = true },
    { title = '──────────', disabled = true },
    { title = '立即重新采样', fn = function() M.check() end },
    { title = '──────────', disabled = true },
    { title = '🩹 止血：关闭所有模拟器', fn = function() M.shutdownSims() end },
    { title = '🧟 止血：devGuard 孤儿进程巡检', fn = function() M.scanZombies() end },
    { title = '📂 清盘：扫描磁盘大头（只报告）', fn = function() M.diskHogs() end },
    { title = '🗑 清盘：清理缓存预览（不删除）', fn = function() M.cleanCaches(false) end },
    { title = '⚠️ 清盘：执行清理（DerivedData/缓存/npm）', fn = function() M.cleanCaches(true) end },
    { title = '──────────', disabled = true },
    { title = '打开活动监视器', fn = function()
        hs.execute('open -a "Activity Monitor"') end },
    { title = 'devGuard 巡检（僵尸 dev 进程）', fn = function()
        hs.execute('hs -c "devGuardScan()"') end },
  }
end)

M.timer = hs.timer.doEvery(CHECK_INTERVAL, function() M.check() end)
-- 启动即采样一次
M.check()

-- hs -c 全局函数别名
_G.sysGuardCheck  = function() return M.check() end
_G.sysGuardStatus = function() return M.status() end
_G.sysGuardRelieve = function() M.shutdownSims(); M.scanZombies(); end
_G.sysGuardDiskHogs = function() return M.diskHogs() end
_G.sysGuardCleanCaches = function() return M.cleanCaches(true) end

logger.i('sysGuard loaded')

return M
