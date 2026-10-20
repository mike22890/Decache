#!/data/data/com.termux/files/usr/bin/bash
# decache · 开机自启(Termux:Boot 调用)
# 安装: 装 Termux:Boot(F-Droid) → 把这个脚本软链/复制到 ~/.termux/boot/
set -u
export PATH="$PREFIX/bin:$PATH"
termux-wake-lock 2>/dev/null || true
sleep 8                                  # 等系统网络/存储就绪
bash ~/decache/start.sh >/dev/null 2>&1 &
