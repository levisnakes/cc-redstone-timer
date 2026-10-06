# CC Redstone Timer

ComputerCraft timer for a machine (for example, a Create mechanical bearing) that parks on a redstone contact.

While the machine is parked, the contact powers the top of the computer. Every 18 minutes the timer turns the back on and holds it until the machine leaves the contact and parks again. Then it turns the back off and starts the next 18-minute countdown.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-redstone-timer/main/redstone_timer.lua startup.lua
```

The settings at the top of the file control the interval and the sides used.
