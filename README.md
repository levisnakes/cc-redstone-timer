# CC Redstone Timer

ComputerCraft timer for a machine (for example, a Create mechanical bearing tree farm) that parks on a redstone contact, with a stats dashboard on a monitor.

While the machine is parked, the contact powers the top of the computer. Every 18 minutes the timer turns the back on and holds it until the machine leaves the contact and parks again. Then it turns the back off and starts the next 18-minute countdown.

The monitor shows the countdown, the run status, and stats for the output vault: items stored, items per hour, gain since the last harvest, harvest count, how full the vault is, and the top items. If a DirectGPU block is connected, the dashboard is drawn in full color. Otherwise it falls back to plain monitor text.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-redstone-timer/main/redstone_timer.lua startup.lua
```

The settings at the top of the file set the interval, the redstone sides, the monitor, the vault, and the title.
