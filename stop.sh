#!/bin/bash

export DISPLAY=:0

pkill -x AppManager 2>/dev/null || true
pkill -x ShakerView2.0.x 2>/dev/null || true

echo "AppManager watchdog and ShakerView stopped."
