-- Redstone Timer for a machine that parks on a redstone contact.
-- While parked, PARKED_SIDE is on. Every INTERVAL_MINUTES the timer pulses
-- OUTPUT_SIDE to start the machine, waits for it to leave (signal off) and
-- come back (signal on), then starts the next countdown.

INTERVAL_MINUTES = 18
PULSE_SECONDS = 1
OUTPUT_SIDE = "back"
PARKED_SIDE = "top"

-- If the machine hasn't left the contact this many seconds after a pulse, pulse again.
RETRY_SECONDS = 10


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

-- Wait for a redstone change, or until `seconds` pass. Returns true on timeout.
local function waitRedstone(seconds)
  local timer = os.startTimer(seconds)
  while true do
    local ev, id = os.pullEvent()
    if ev == "redstone" then return false end
    if ev == "timer" and id == timer then return true end
  end
end

local function waitUntilParked()
  draw("Machine moving, waiting for it to park...")
  while not parked() do os.pullEvent("redstone") end
  local nextAt = now() + INTERVAL_MINUTES * 60
  saveNext(nextAt)
  return nextAt
end

local function pulse()
  rs.setOutput(OUTPUT_SIDE, true)
  sleep(PULSE_SECONDS)
  rs.setOutput(OUTPUT_SIDE, false)
end

-- Pulse until the machine leaves the contact.
local function startMachine()
  local tries = 0
  while parked() do
    tries = tries + 1
    draw(tries == 1 and "Starting machine..." or ("Machine didn't start, retry " .. (tries - 1)))
    pulse()
    local deadline = now() + RETRY_SECONDS
    while parked() and now() < deadline do
      waitRedstone(math.max(0.05, deadline - now()))
    end
  end
end

rs.setOutput(OUTPUT_SIDE, false)

local nextAt = loadNext()
if not parked() or not nextAt then
  nextAt = waitUntilParked()
end

while true do
  if not parked() then
    -- Moved by something other than this timer; restart the countdown once it parks.
    nextAt = waitUntilParked()
  elseif now() >= nextAt then
    startMachine()
    nextAt = waitUntilParked()
  else
    draw("Parked. Next start in " .. fmt(nextAt - now()))
    waitRedstone(1)
  end
end
