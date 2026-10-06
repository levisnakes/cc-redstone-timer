-- Redstone Timer for a machine that parks on a redstone contact.
-- While parked, PARKED_SIDE is on. Every INTERVAL_MINUTES the timer turns
-- OUTPUT_SIDE on and holds it until the machine leaves the contact and comes
-- back (a new signal on PARKED_SIDE), then starts the next countdown.

INTERVAL_MINUTES = 18
OUTPUT_SIDE = "back"
PARKED_SIDE = "top"


-- The next start time is saved to disk so a reboot or server restart
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
  return nil
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

local function parked()
  return rs.getInput(PARKED_SIDE)
end

-- Wait for a redstone change, or until `seconds` pass.
local function waitRedstone(seconds)
  local timer = os.startTimer(seconds)
  while true do
    local ev, id = os.pullEvent()
    if ev == "redstone" or (ev == "timer" and id == timer) then return end
  end
end

-- Hold the output on until the machine has left the contact and parked again.
local function runMachine()
  rs.setOutput(OUTPUT_SIDE, true)
  draw("Running: waiting for machine to leave...")
  while parked() do os.pullEvent("redstone") end
  draw("Running: waiting for machine to park...")
  while not parked() do os.pullEvent("redstone") end
  rs.setOutput(OUTPUT_SIDE, false)
  local nextAt = now() + INTERVAL_MINUTES * 60
  saveNext(nextAt)
  return nextAt
end

local nextAt = loadNext()

-- Off the contact at boot means a run was cut short (the output resets on
-- reboot), so keep driving it until it parks.
if not parked() then
  rs.setOutput(OUTPUT_SIDE, true)
  draw("Running: waiting for machine to park...")
  while not parked() do os.pullEvent("redstone") end
  rs.setOutput(OUTPUT_SIDE, false)
  nextAt = nil
end

if not nextAt then
  nextAt = now() + INTERVAL_MINUTES * 60
  saveNext(nextAt)
end

while true do
  if now() >= nextAt then
    nextAt = runMachine()
  else
    draw("Parked. Next start in " .. fmt(nextAt - now()))
    waitRedstone(1)
  end
end
