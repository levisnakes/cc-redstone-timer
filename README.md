# CC Redstone Timer

ComputerCraft timer for a machine (for example, a Create mechanical bearing tree farm) that parks on a redstone contact, with a stats dashboard on a monitor.

While the machine is parked, the contact powers the top of the computer. When the countdown ends, the timer turns the back on and keeps it on while the machine leaves the contact, parks again, and the harvest unloads. Once the vault stops going up for 30 seconds, it turns the back off and starts the next 5-minute countdown. If nothing arrives within 10 minutes of parking, it runs the machine again.

The monitor shows an analog clock, the countdown, a FORCE START button, the run status, and stats for the output vault: items stored, items per hour, gain since the last harvest, harvest count, how full the vault is, and the top items. If a DirectGPU block is connected, the dashboard is drawn in full color. Otherwise it falls back to plain monitor text.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-redstone-timer/main/redstone_timer.lua startup.lua
```

The settings at the top of the file set the interval, the redstone sides, the monitor, the vault, and the title.
