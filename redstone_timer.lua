-- Redstone Timer: pulses OUTPUT_SIDE every INTERVAL_MINUTES.
-- A signal on STOP_SIDE stops it; the countdown restarts once that signal turns off.

INTERVAL_MINUTES = 18
PULSE_SECONDS = 1
OUTPUT_SIDE = "back"
STOP_SIDE = "top"


-- The next pulse time is saved to disk so a reboot or server restart
-- doesn't reset the countdown.
local SAVE = ".redstone_timer"

local function now()
  return os.epoch("utc") / 1000
end

local function loadNext()
  if fs.exists(SAVE) then
    local f = fs.open(SAVE, "r")
    local t = tonumber(f.readAll())
    f.close()
    if t then return t end
  end
  return now() + INTERVAL_MINUTES * 60
end

local function saveNext(t)
  local f = fs.open(SAVE, "w")
  f.write(tostring(t))
  f.close()
end

local function fmt(seconds)
  local s = math.max(0, math.floor(seconds))
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function draw(line)
  term.clear()
  term.setCursorPos(1, 1)
  print("Redstone Timer")
  print("")
  print(line)
end

rs.setOutput(OUTPUT_SIDE, false)
local nextAt = loadNext()
saveNext(nextAt)

while true do
  if rs.getInput(STOP_SIDE) then
    draw("Stopped: signal on " .. STOP_SIDE)
    repeat os.pullEvent("redstone") until not rs.getInput(STOP_SIDE)
    nextAt = now() + INTERVAL_MINUTES * 60
    saveNext(nextAt)
  elseif now() >= nextAt then
    draw("Pulsing " .. OUTPUT_SIDE)
    rs.setOutput(OUTPUT_SIDE, true)
    sleep(PULSE_SECONDS)
    rs.setOutput(OUTPUT_SIDE, false)
    nextAt = now() + INTERVAL_MINUTES * 60
    saveNext(nextAt)
  else
    draw("Next pulse in " .. fmt(nextAt - now()))
    local timer = os.startTimer(1)
    repeat
      local ev, id = os.pullEvent()
    until (ev == "timer" and id == timer) or ev == "redstone"
  end
end
