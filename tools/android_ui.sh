#!/bin/bash
# Ставит Winter-Walks.apk на эмулятор, задаёт GPS (Киев), открывает вкладки и делает скриншоты.
set -x
pkg=com.winterhub.winter_walks
adb install -r Winter-Walks.apk || echo "install-failed" >> out/status.txt
adb shell pm grant $pkg android.permission.ACCESS_FINE_LOCATION
adb shell pm grant $pkg android.permission.ACCESS_COARSE_LOCATION
adb emu geo fix 30.5234 50.4501
sleep 2
adb emu geo fix 30.5234 50.4501
size=$(adb shell wm size | tail -1 | grep -o '[0-9]*x[0-9]*'); w=${size%x*}; h=${size#*x}
dens=$(adb shell wm density | tail -1 | grep -o '[0-9]*$')
dp() { echo $(( $1 * dens / 160 )); }
echo "size=$size density=$dens" >> out/status.txt
adb logcat -c
adb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1
sleep 20
adb emu geo fix 30.5234 50.4501
sleep 60
pid=$(adb shell pidof $pkg | tr -d '\r')
echo "running=${pid:+yes}" >> out/status.txt
adb exec-out screencap -p > out/a1-places.png
navy=$(( h - $(dp 70) ))
adb shell input tap $(( w / 2 )) $navy
sleep 15
adb exec-out screencap -p > out/a2-news.png
adb shell input tap $(( w / 6 )) $navy
sleep 2
# Первая карточка в списке.
adb shell input tap $(( w / 3 )) $(dp 330)
sleep 8
adb exec-out screencap -p > out/a3-place.png
adb shell input keyevent KEYCODE_BACK
sleep 2
adb shell input tap $(( w - $(dp 30) )) $(dp 215)
sleep 15
adb exec-out screencap -p > out/a4-map.png
adb logcat -d -s AndroidRuntime:E flutter:E flutter:I | tail -60 > out/android.log
cat out/status.txt
