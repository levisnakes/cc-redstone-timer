-- Tree Farm Timer: runs a machine that parks on a redstone contact and shows
-- harvest stats on a monitor.
-- While parked, PARKED_SIDE is on. Every INTERVAL_MINUTES the timer turns
-- OUTPUT_SIDE on and holds it until the machine leaves the contact and comes
-- back (a new signal on PARKED_SIDE), then starts the next countdown.

INTERVAL_MINUTES = 18
OUTPUT_SIDE = "back"
PARKED_SIDE = "top"

MONITOR = "monitor_2"
VAULT = "create:item_vault_37"
TITLE = "TREE FARM"


-- ===================== state =====================

local SAVE = ".redstone_timer"

local function now()
  return os.epoch("utc") / 1000
end

-- Saved across reboots: next start time and harvest history.
local state = {
  nextAt = nil,
  cycles = 0,
  lastGain = nil,
  lastRunSeconds = nil,
  runStartTotal = nil,
}

local phase = "parked"
local runStartedAt = nil

local function load()
  if not fs.exists(SAVE) then return end
  local f = fs.open(SAVE, "r")
  local text = f.readAll()
  f.close()
  local saved = textutils.unserialize(text)
  if type(saved) == "table" then
    for k, v in pairs(saved) do state[k] = v end
  elseif tonumber(text) then
    state.nextAt = tonumber(text)
  end
end

local function save()
  local f = fs.open(SAVE, "w")
  f.write(textutils.serialize(state))
  f.close()
end

-- ===================== vault stats =====================

local vault = {
  ok = false,
  total = 0,
  capacity = 0,
  top = {},
  samples = {},
  perHour = nil,
}

local function prettyName(id)
  local name = id:gsub("^[^:]+:", ""):gsub("_", " ")
  return (name:gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
end

local function scanVault()
  local ok, items = pcall(peripheral.call, VAULT, "list")
  local okSize, size = pcall(peripheral.call, VAULT, "size")
  if not ok or not items then
    vault.ok = false
    return
  end
  vault.ok = true

  local total, byName = 0, {}
  for _, item in pairs(items) do
    total = total + item.count
    byName[item.name] = (byName[item.name] or 0) + item.count
  end
  vault.total = total
  vault.capacity = (okSize and size or 0) * 64

  local top = {}
  for name, count in pairs(byName) do
    top[#top + 1] = { name = prettyName(name), count = count }
  end
  table.sort(top, function(a, b) return a.count > b.count end)
  vault.top = top

  -- Rolling one-hour rate. Needs 5 minutes of data before it shows anything.
  local t = now()
  table.insert(vault.samples, { t = t, total = total })
  while #vault.samples > 1 and t - vault.samples[1].t > 3600 do
    table.remove(vault.samples, 1)
  end
  local first = vault.samples[1]
  if t - first.t >= 300 then
    vault.perHour = math.max(0, (total - first.total) / (t - first.t) * 3600)
  else
    vault.perHour = nil
  end
end

-- ===================== timer =====================

local function fmtTime(seconds)
  local s = math.max(0, math.floor(seconds))
  if s >= 3600 then
    return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
  end
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function parked()
  return rs.getInput(PARKED_SIDE)
end

local function waitForPark()
  while not parked() do os.pullEvent("redstone") end
end

local function startRun()
  phase = "running"
  runStartedAt = now()
  if vault.ok then
    if state.runStartTotal then
      state.lastGain = math.max(0, vault.total - state.runStartTotal)
    end
    state.runStartTotal = vault.total
  end
  rs.setOutput(OUTPUT_SIDE, true)
end

local function finishRun()
  rs.setOutput(OUTPUT_SIDE, false)
  phase = "parked"
  if runStartedAt then
    state.lastRunSeconds = now() - runStartedAt
    state.cycles = state.cycles + 1
  end
  state.nextAt = now() + INTERVAL_MINUTES * 60
  save()
end

local function timerLoop()
  -- Off the contact at boot means a run was cut short (the output resets on
  -- reboot), so keep driving it until it parks.
  if not parked() then
    phase = "running"
    rs.setOutput(OUTPUT_SIDE, true)
    waitForPark()
    rs.setOutput(OUTPUT_SIDE, false)
    phase = "parked"
    state.nextAt = nil
  end
  if not state.nextAt then
    state.nextAt = now() + INTERVAL_MINUTES * 60
    save()
  end

  while true do
    if now() >= state.nextAt then
      startRun()
      while parked() do os.pullEvent("redstone") end
      waitForPark()
      finishRun()
    else
      local timer = os.startTimer(1)
      repeat
        local ev, id = os.pullEvent()
      until ev == "redstone" or (ev == "timer" and id == timer)
    end
  end
end

local function vaultLoop()
  while true do
    scanVault()
    sleep(5)
  end
end

-- ===================== display =====================

local function fmtNum(n)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

local function status()
  if phase == "running" then
    return "HARVESTING", "Running for " .. fmtTime(now() - (runStartedAt or now())), nil
  end
  local left = (state.nextAt or now()) - now()
  local frac = 1 - left / (INTERVAL_MINUTES * 60)
  return "PARKED", "Next harvest in " .. fmtTime(left), math.max(0, math.min(1, frac))
end

local function statLines()
  return {
    { "Stored", vault.ok and fmtNum(vault.total) or "--" },
    { "Per hour", vault.perHour and fmtNum(vault.perHour) or "--" },
    { "Last harvest", state.lastGain and ("+" .. fmtNum(state.lastGain)) or "--" },
    { "Harvests", tostring(state.cycles) },
  }
end

-- DirectGPU renderer (full RGB). Returns false if it can't draw, so the
-- caller can fall back to the plain monitor.
local gpu, display, W, H

local FONT = "SansSerif"
local BG = { 16, 18, 22 }
local PANEL = { 30, 34, 41 }
local MUTED = { 140, 148, 160 }
local WHITE = { 235, 238, 242 }
local GREEN = { 60, 190, 90 }
local AMBER = { 240, 170, 50 }
local TRACK = { 50, 56, 66 }

local function setupGpu()
  gpu = peripheral.find("directgpu")
  if not gpu then return false end
  local ok, id = pcall(gpu.autoDetectAndCreateDisplay, MONITOR)
  if not ok then return false end
  display = id
  local info = gpu.getDisplayInfo(display)
  W, H = info.pixelWidth, info.pixelHeight
  pcall(gpu.setDisplayPersistent, display, true)
  return true
end

local function rect(x, y, w, h, c)
  gpu.fillRect(display, math.floor(x), math.floor(y), math.max(0, math.floor(w)), math.max(0, math.floor(h)), c[1], c[2], c[3])
end

local function text(s, x, y, c, size, style)
  return gpu.drawText(display, s, math.floor(x), math.floor(y), c[1], c[2], c[3], FONT, math.floor(size), style or "plain")
end

local function textWidth(s, size, style)
  local m = gpu.measureText(s, FONT, math.floor(size), style or "plain")
  return m and m.width or 0
end

local function textRight(s, right, y, c, size, style)
  text(s, right - textWidth(s, size, style), y, c, size, style)
end

local function bar(x, y, w, h, frac, c)
  rect(x, y, w, h, TRACK)
  rect(x, y, w * math.max(0, math.min(1, frac)), h, c)
end

local function drawGpu()
  local pad = math.max(4, math.floor(W * 0.03))
  local small = math.max(8, math.floor(H * 0.055))
  local medium = math.max(10, math.floor(H * 0.08))
  local big = math.max(14, math.floor(H * 0.14))

  gpu.clear(display, BG[1], BG[2], BG[3])

  -- Header with status pill
  local headH = medium + pad * 2
  rect(0, 0, W, headH, PANEL)
  text(TITLE, pad, pad, WHITE, medium, "bold")
  local label, line, frac = status()
  local pillColor = phase == "running" and AMBER or GREEN
  local pillW = textWidth(label, small, "bold") + pad * 2
  local pillH = small + pad
  rect(W - pad - pillW, (headH - pillH) / 2, pillW, pillH, pillColor)
  text(label, W - pad - pillW + pad, (headH - pillH) / 2 + pad / 2, BG, small, "bold")

  -- Countdown and interval progress
  local y = headH + pad
  text(line, pad, y, WHITE, big, "bold")
  y = y + big + pad / 2
  if frac then
    bar(pad, y, W - pad * 2, math.max(3, pad / 2), frac, GREEN)
  else
    -- Moving stripe while the machine runs
    local w = W - pad * 2
    rect(pad, y, w, math.max(3, pad / 2), TRACK)
    local pos = (now() * 0.5) % 1
    rect(pad + pos * w * 0.75, y, w * 0.25, math.max(3, pad / 2), AMBER)
  end
  y = y + math.max(3, pad / 2) + pad

  -- Stat cards
  local stats = statLines()
  local gap = pad / 2
  local cardW = (W - pad * 2 - gap * (#stats - 1)) / #stats
  local cardH = small + medium + pad * 2
  for i, s in ipairs(stats) do
    local x = pad + (i - 1) * (cardW + gap)
    rect(x, y, cardW, cardH, PANEL)
    text(s[1], x + pad / 2, y + pad / 2, MUTED, small)
    text(s[2], x + pad / 2, y + pad / 2 + small + pad / 2, WHITE, medium, "bold")
  end
  y = y + cardH + pad

  -- Vault fill
  if vault.ok and vault.capacity > 0 then
    local fill = vault.total / vault.capacity
    text("Vault " .. math.floor(fill * 100) .. "% full", pad, y, MUTED, small)
    textRight(fmtNum(vault.total) .. " / " .. fmtNum(vault.capacity), W - pad, y, MUTED, small)
    y = y + small + pad / 3
    bar(pad, y, W - pad * 2, math.max(3, pad / 2), fill, fill > 0.9 and AMBER or GREEN)
    y = y + math.max(3, pad / 2) + pad
  elseif not vault.ok then
    text("Can't read " .. VAULT, pad, y, AMBER, small)
    y = y + small + pad
  end

  -- Top items, as many rows as fit
  local rowH = small + pad / 2 + 4
  local maxCount = vault.top[1] and vault.top[1].count or 1
  for i, item in ipairs(vault.top) do
    if y + rowH > H - pad / 2 then break end
    text(item.name, pad, y, WHITE, small)
    textRight(fmtNum(item.count), W - pad, y, WHITE, small, "bold")
    bar(pad, y + small + 2, W - pad * 2, 3, item.count / maxCount, i == 1 and GREEN or MUTED)
    y = y + rowH
  end

  gpu.updateDisplay(display)
end

-- Plain monitor fallback when there's no DirectGPU block.
local function drawPlain()
  local mon = peripheral.wrap(MONITOR)
  if not mon then return end
  mon.setTextScale(0.5)
  mon.setBackgroundColour(colours.black)
  mon.clear()
  local w = mon.getSize()
  local function line(y, s, c)
    mon.setCursorPos(2, y)
    mon.setTextColour(c or colours.white)
    mon.write(s)
  end
  local label, l, _ = status()
  line(1, TITLE)
  line(2, label, phase == "running" and colours.orange or colours.lime)
  line(3, l)
  local y = 5
  for _, s in ipairs(statLines()) do
    line(y, s[1] .. ": " .. s[2])
    y = y + 1
  end
  y = y + 1
  for _, item in ipairs(vault.top) do
    local _, h = mon.getSize()
    if y > h then break end
    local count = fmtNum(item.count)
    line(y, item.name, colours.lightGrey)
    mon.setCursorPos(w - #count, y)
    mon.write(count)
    y = y + 1
  end
end

local gpuError = nil

local function drawTerminal()
  local label, line = status()
  term.clear()
  term.setCursorPos(1, 1)
  print(TITLE .. " timer")
  print("")
  print(label .. ": " .. line)
  print("")
  for _, s in ipairs(statLines()) do print(s[1] .. ": " .. s[2]) end
  if gpuError then
    print("")
    if term.isColour() then term.setTextColour(colours.orange) end
    print("GPU: " .. gpuError)
    term.setTextColour(colours.white)
  end
end

-- Uses DirectGPU when it works, otherwise the plain monitor, and retries
-- the GPU every 30 seconds.
local function displayLoop()
  local useGpu = setupGpu()
  local retryAt = now() + 30
  if not useGpu then gpuError = "no DirectGPU block found, using plain monitor" end
  while true do
    if useGpu then
      local ok, err = pcall(drawGpu)
      if ok then
        gpuError = nil
      else
        useGpu = false
        gpuError = tostring(err)
        retryAt = now() + 30
      end
    end
    if not useGpu then
      pcall(drawPlain)
      if now() >= retryAt then
        useGpu = setupGpu()
        retryAt = now() + 30
      end
    end
    drawTerminal()
    sleep(1)
  end
end

load()
scanVault()
parallel.waitForAny(timerLoop, vaultLoop, displayLoop)
