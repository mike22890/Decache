#!/data/data/com.termux/files/usr/bin/bash
# decache · 一键启动(前台保活)
# 为什么前台跑: Android 的前台服务有通知, 系统不会像后台进程那样随手杀。
# 加 while 循环: 进程崩了自动拉起(手机内存紧张/系统回收时不会一睡不醒)。
#
# 热修(断电重启后 start.sh 卡死):
# 重启后 Termux:API 的 IPC 可能未就绪/被系统冻结, termux-notification 会永久挂起。
# 旧版这两行没有超时保护, 一挂住 server.py 就永远执行不到 → 敲 start.sh 无响应。
# 修法: 所有 termux-* 调用限时(timeout) + 后台化, 主循环立刻起 server。
set -u
cd ~/decache || { echo "找不到 ~/decache, 先跑 install.sh"; exit 1; }
( timeout 10 termux-wake-lock 2>/dev/null ) &
( sleep 2; timeout 10 termux-notification --title "Decache" --content "媒体库运行中" --id decache --priority low 2>/dev/null ) &
while true; do
  if ! pgrep -f "python.*server.py" >/dev/null 2>&1; then
    python server.py
  fi
  sleep 3
done