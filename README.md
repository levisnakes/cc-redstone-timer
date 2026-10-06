# CC Redstone Timer

ComputerCraft timer for a machine (for example, a Create mechanical bearing) that parks on a redstone contact.

While the machine is parked, the contact powers the top of the computer. Every 18 minutes the timer pulses the back to start the machine. It waits for the machine to leave the contact and come back, then starts the next 18-minute countdown. If the machine doesn't leave the contact within 10 seconds of a pulse, it pulses again.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-redstone-timer/main/redstone_timer.lua startup.lua
```

The settings at the top of the file control the interval, how long the pulse lasts, the sides used, and the retry delay.
