-- Tree Farm Timer: runs a machine that parks on a redstone contact and shows
-- harvest stats on a monitor.
-- While parked, PARKED_SIDE is on. The timer turns OUTPUT_SIDE on and holds it
-- while the machine leaves the contact, comes back, and the harvest unloads
-- into the vault. Once unloading stops it turns the output off and starts the next
-- INTERVAL_MINUTES countdown. If nothing arrives within UNLOAD_TIMEOUT_MINUTES,
-- it runs the machine again.

INTERVAL_MINUTES = 5
UNLOAD_TIMEOUT_MINUTES = 10
-- Unloading counts as done once the vault hasn't gone up for this long
SETTLE_SECONDS = 10
OUTPUT_SIDE = "back"
PARKED_SIDE = "top"

MONITOR = "monitor_2"
VAULT = "create:item_vault_37"
TITLE = "TREE FARM"
AUTO_UPDATE = true        -- install new versions from GitHub automatically, keeping these settings

-- Settings in /config.lua override the ones above. Use it for anything you
-- don't want to retype: it survives reinstalls and updates, and one file can
-- be shared by every computer (each program ignores settings it doesn't use).
do
  local path = "/config.lua"
  if fs.exists(path) then
    local fn, err = loadfile(path, "t", _ENV)
    if fn then
      local ok, runErr = pcall(fn)
      if not ok then printError("config.lua: " .. tostring(runErr)) sleep(3) end
    else
      printError("config.lua: " .. tostring(err))
      sleep(3)
    end
  end
end


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
  reruns = 0,
  unloading = false,
}

local phase = "parked"
local runStartedAt = nil
local forceRequested = false

-- Progress of the current unload wait
local unload = { since = 0, peak = 0, started = false, lastUp = 0 }

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
  if vault.ok then state.runStartTotal = vault.total end
  rs.setOutput(OUTPUT_SIDE, true)
end

local function finishRun()
  if runStartedAt then
    state.lastRunSeconds = now() - runStartedAt
    state.cycles = state.cycles + 1
  end
  state.unloading = true
  save()
end

-- Sleep up to `seconds`, waking early for a force start.
local function waitOrForce(seconds)
  local timer = os.startTimer(seconds)
  repeat
    local ev, id = os.pullEvent()
  until ev == "force_start" or (ev == "timer" and id == timer)
end

-- After parking, wait until the vault stops filling. Returns false if
-- nothing arrived within the timeout. A force start ends the wait early.
local function waitForUnload()
  phase = "unloading"
  -- The output stays on while the harvest unloads.
  rs.setOutput(OUTPUT_SIDE, true)
  scanVault()
  unload = { since = now(), peak = vault.total, started = false, lastUp = now() }
  if not vault.ok then return true end

  while not forceRequested do
    scanVault()
    if vault.ok and vault.total > unload.peak then
      unload.peak = vault.total
      unload.started = true
      unload.lastUp = now()
    end
    if unload.started and now() - unload.lastUp >= SETTLE_SECONDS then
      return true
    end
    if not unload.started and now() - unload.since >= UNLOAD_TIMEOUT_MINUTES * 60 then
      return false
    end
    waitOrForce(2)
  end
  return true
end

local function afterRun()
  local unloaded = waitForUnload()
  if state.runStartTotal then
    state.lastGain = math.max(0, unload.peak - state.runStartTotal)
  end
  rs.setOutput(OUTPUT_SIDE, false)
  if unloaded then
    state.nextAt = now() + INTERVAL_MINUTES * 60
  else
    state.reruns = state.reruns + 1
    state.nextAt = now()
    -- Brief off gap so the re-run starts on a fresh signal
    sleep(1)
  end
  state.unloading = false
  phase = "parked"
  save()
end

local function timerLoop()
  -- Off the contact at boot means a run was cut short (the output resets on
  -- reboot), so keep driving it until it parks.
  if not parked() then
    phase = "running"
    rs.setOutput(OUTPUT_SIDE, true)
    waitForPark()
    state.unloading = true
  end
  if state.unloading then
    afterRun()
  end
  if not state.nextAt then
    state.nextAt = now() + INTERVAL_MINUTES * 60
    save()
  end

  while true do
    if forceRequested or now() >= state.nextAt then
      forceRequested = false
      startRun()
      while parked() do os.pullEvent("redstone") end
      waitForPark()
      finishRun()
      afterRun()
    else
      local timer = os.startTimer(1)
      repeat
        local ev, id = os.pullEvent()
      until ev == "redstone" or ev == "force_start" or (ev == "timer" and id == timer)
    end
  end
end

local function forceStart()
  if phase == "parked" or phase == "unloading" then
    forceRequested = true
    os.queueEvent("force_start")
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

-- Returns badge label, caption, time string, and interval progress (nil while running).
local function status()
  if phase == "running" then
    return "HARVESTING", "Running for", fmtTime(now() - (runStartedAt or now())), nil
  end
  if phase == "unloading" then
    if unload.started then
      return "UNLOADING", "Unloaded so far", "+" .. math.max(0, unload.peak - (state.runStartTotal or unload.peak)), nil
    end
    return "WAITING", "Re-run if nothing in", fmtTime(UNLOAD_TIMEOUT_MINUTES * 60 - (now() - unload.since)), nil
  end
  local left = (state.nextAt or now()) - now()
  local frac = 1 - left / (INTERVAL_MINUTES * 60)
  return "PARKED", "Next harvest in", fmtTime(left), math.max(0, math.min(1, frac))
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
local useGpuInput = false

local FONT = "SansSerif"
local BG = { 16, 18, 22 }
local PANEL = { 30, 34, 41 }
local MUTED = { 140, 148, 160 }
local WHITE = { 235, 238, 242 }
local GREEN = { 60, 190, 90 }
local AMBER = { 240, 170, 50 }
local TRACK = { 50, 56, 66 }
local WEDGE = { 40, 105, 60 }
local RED = { 200, 70, 60 }
local BLUE = { 70, 150, 230 }

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

local function line(x1, y1, x2, y2, c)
  gpu.drawLine(display, math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2), c[1], c[2], c[3])
end

-- Thick line: a few parallel lines offset sideways.
local function thickLine(x1, y1, x2, y2, width, c)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len == 0 then return end
  local nx, ny = -dy / len, dx / len
  for o = -width / 2, width / 2, 0.5 do
    line(x1 + nx * o, y1 + ny * o, x2 + nx * o, y2 + ny * o, c)
  end
end

local function circle(cx, cy, r, c, filled)
  gpu.drawCircle(display, math.floor(cx), math.floor(cy), math.floor(r), c[1], c[2], c[3], filled)
end

-- Angle for a fraction of a full turn, starting at 12 o'clock, clockwise.
local function clockPoint(cx, cy, r, frac)
  local a = frac * 2 * math.pi - math.pi / 2
  return cx + math.cos(a) * r, cy + math.sin(a) * r
end

-- Analog clock: the shaded wedge and hand show how far through the
-- interval we are. While harvesting, the hand sweeps continuously.
local function drawClock(cx, cy, r, frac)
  circle(cx, cy, r, PANEL, true)

  local handFrac, handColor
  if frac then
    -- Elapsed wedge, drawn as radial lines (one per pixel of arc).
    local steps = math.max(1, math.floor(2 * math.pi * r * frac))
    for i = 0, steps do
      local x, y = clockPoint(cx, cy, r - 2, frac * i / steps)
      line(cx, cy, x, y, WEDGE)
    end
    handFrac, handColor = frac, WHITE
  else
    handFrac, handColor = (now() / 4) % 1, phase == "unloading" and BLUE or AMBER
  end

  for i = 0, 11 do
    local inner = (i % 3 == 0) and 0.78 or 0.86
    local x1, y1 = clockPoint(cx, cy, r * inner, i / 12)
    local x2, y2 = clockPoint(cx, cy, r * 0.95, i / 12)
    thickLine(x1, y1, x2, y2, (i % 3 == 0) and 2 or 1, MUTED)
  end
  circle(cx, cy, r, MUTED, false)
  circle(cx, cy, r - 1, MUTED, false)

  local hx, hy = clockPoint(cx, cy, r * 0.75, handFrac)
  thickLine(cx, cy, hx, hy, math.max(2, r / 15), handColor)
  circle(cx, cy, math.max(2, r / 10), handColor, true)
end

-- Force start button position, in display pixels; set each frame.
local button = nil

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
  local label, caption, timeStr, frac = status()
  local pillColor = (phase == "running" and AMBER) or (phase == "unloading" and BLUE) or GREEN
  local pillW = textWidth(label, small, "bold") + pad * 2
  local pillH = small + pad
  rect(W - pad - pillW, (headH - pillH) / 2, pillW, pillH, pillColor)
  text(label, W - pad - pillW + pad, (headH - pillH) / 2 + pad / 2, BG, small, "bold")

  -- Clock on the left; countdown and force start button beside it
  local y = headH + pad
  local r = math.floor(math.min(W * 0.16, H * 0.17))
  drawClock(pad + r, y + r, r, frac)

  local tx = pad + r * 2 + pad * 1.5
  text(caption, tx, y, MUTED, small)
  text(timeStr, tx, y + small + pad / 4, WHITE, big, "bold")

  local btnLabel = phase == "running" and "RUNNING..." or "FORCE START"
  local bw = textWidth(btnLabel, small, "bold") + pad * 2
  local bh = small + pad
  local bx, by = tx, y + r * 2 - bh
  rect(bx, by, bw, bh, phase == "running" and TRACK or RED)
  text(btnLabel, bx + pad, by + pad / 2, phase == "running" and MUTED or WHITE, small, "bold")
  button = { x = bx, y = by, w = bw, h = bh }

  y = y + r * 2 + pad

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

local plainButtonRow = nil

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
  local label, caption, timeStr = status()
  line(1, TITLE)
  line(2, label, (phase == "running" and colours.orange) or (phase == "unloading" and colours.lightBlue) or colours.lime)
  line(3, caption .. " " .. timeStr)
  mon.setCursorPos(2, 4)
  if phase == "running" then
    mon.setBackgroundColour(colours.grey)
    mon.setTextColour(colours.lightGrey)
    mon.write(" RUNNING... ")
  else
    mon.setBackgroundColour(colours.red)
    mon.setTextColour(colours.white)
    mon.write(" FORCE START ")
  end
  mon.setBackgroundColour(colours.black)
  plainButtonRow = 4
  local y = 6
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
  local label, caption, timeStr = status()
  term.clear()
  term.setCursorPos(1, 1)
  print(TITLE .. " timer")
  print("")
  print(label .. ": " .. caption .. " " .. timeStr)
  print("")
  for _, s in ipairs(statLines()) do print(s[1] .. ": " .. s[2]) end
  print("Re-runs (nothing unloaded): " .. state.reruns)
  print("")
  print("Press F or tap FORCE START to start now")
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
    useGpuInput = useGpu
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

local function inButton(x, y)
  return button and x >= button.x and x <= button.x + button.w
    and y >= button.y and y <= button.y + button.h
end

-- Force start from the F key, a tap on the plain monitor, or a click on
-- the DirectGPU display.
local function inputLoop()
  while true do
    local timer = os.startTimer(0.1)
    local ev = { os.pullEvent() }
    if ev[1] == "key" and ev[2] == keys.f then
      forceStart()
    elseif ev[1] == "monitor_touch" and ev[2] == MONITOR then
      if useGpuInput and W then
        local mw, mh = peripheral.call(MONITOR, "getSize")
        if inButton((ev[3] - 0.5) / mw * W, (ev[4] - 0.5) / mh * H) then forceStart() end
      elseif ev[4] == plainButtonRow then
        forceStart()
      end
    end
    if useGpuInput and gpu and display then
      local ok, has = pcall(gpu.hasEvents, display)
      while ok and has do
        local e = gpu.pollEvent(display)
        if e and e.type == "mouse_click" and inButton(e.x, e.y) then forceStart() end
        ok, has = pcall(gpu.hasEvents, display)
      end
    end
    if ev[1] ~= "timer" or ev[2] ~= timer then os.cancelTimer(timer) end
  end
end

load()
scanVault()
local function readyToUpdate()
  -- only between harvests, never mid-run or while unloading
  return phase == "parked"
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-redstone-timer"
local UPDATE_FILE = "redstone_timer.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local function checkForUpdate(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not _G.load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not _G.load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

local function updateLoop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
local function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end

bootUpdate()
parallel.waitForAny(timerLoop, vaultLoop, displayLoop, inputLoop, updateLoop)
