#!/data/data/com.termux/files/usr/bin/bash
# decache · 一键启动(前台保活)
# 为什么前台跑: Android 的前台服务有通知, 系统不会像后台进程那样随手杀。
# 加 while 循环: 进程崩了自动拉起(手机内存紧张/系统回收时不会一睡不醒)。
set -u
cd ~/decache || { echo "找不到 ~/decache, 先跑 install.sh"; exit 1; }
termux-wake-lock 2>/dev/null || true      # 保持 CPU 唤醒, 下载不被冻结
termux-notification --title "Decache" --content "媒体库运行中" --id decache --priority low 2>/dev/null || true
while true; do
  if ! pgrep -f "python.*server.py" >/dev/null 2>&1; then
    python server.py
  fi
  sleep 3
done
