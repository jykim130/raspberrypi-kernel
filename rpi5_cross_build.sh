#!/usr/bin/env bash
# =============================================================================
#  Raspberry Pi 5 커널 크로스 컴파일 (Ubuntu 호스트에서 실행하는 단일 스크립트)
#
#  1. 종속성 설치  2. 툴체인 설치  3. 소스 다운로드  4. defconfig
#  5. 빌드         6. 압축         7. scp 전송 (-i 지정 시)
#  8~9. 라즈베리파이에서 압축 해제 / modules_install / 파일 복사 (ssh 원격 실행)
#
#  사용법:
#     ./rpi5_cross_build.sh -i <라즈베리파이_IP> [옵션]
#
#  옵션:
#     -i IP     라즈베리파이 IP. 지정하면 빌드 후 전송 + 원격 설치까지 진행
#               (생략하면 빌드/압축까지만)
#     -u USER   라즈베리파이 사용자명 (기본: pi)
#     -j N      빌드 병렬 작업 수 (기본: CPU 코어 수)
#     -s        빌드 건너뛰기 (이미 빌드된 소스를 압축/전송/설치만)
#     -r        설치 후 묻지 않고 바로 재부팅
#     -h        도움말
#
#  예)
#     ./rpi5_cross_build.sh -i 192.168.0.132
#     ./rpi5_cross_build.sh -i 192.168.0.132 -s -r     # 재전송 + 재설치 + 재부팅
# =============================================================================
set -euo pipefail

PI_IP=""
PI_USER="pi"
JOBS="$(nproc)"
SKIP_BUILD=0
AUTO_REBOOT=0

SRC_DIR=/usr/src
LINUX_DIR="$SRC_DIR/linux"
ZIP_FILE="$SRC_DIR/linux.zip"
REPO_URL=https://github.com/raspberrypi/linux

KERNEL=kernel_2712                       # Raspberry Pi 5 (BCM2712)
DEFCONFIG=bcm2712_defconfig
ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu-

log()   { echo -e "\n\033[1;32m==> $*\033[0m"; }
err()   { echo -e "\033[1;31m[ERROR] $*\033[0m" >&2; exit 1; }
usage() { sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "i:u:j:srh" opt; do
    case "$opt" in
        i) PI_IP="$OPTARG" ;;
        u) PI_USER="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        s) SKIP_BUILD=1 ;;
        r) AUTO_REBOOT=1 ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done

PI="${PI_USER}@${PI_IP}"
# ssh 연결 재사용 → 비밀번호는 처음 한 번만 입력
SSH_OPTS=(-o ControlMaster=auto -o ControlPath="/tmp/rpi5-ssh-%r@%h:%p" -o ControlPersist=10m)

# -----------------------------------------------------------------------------
if [ -n "$PI_IP" ]; then
    log "0. 라즈베리파이 접속 확인 ($PI)"
    echo "처음 접속이면 'yes', 이어서 라즈베리파이 비밀번호 입력"
    ssh "${SSH_OPTS[@]}" "$PI" "echo '접속 성공: '\$(hostname)' / 현재 커널 '\$(uname -r)" \
        || err "$PI 에 ssh 접속 실패. IP/사용자명/ssh 활성화 여부를 확인하세요."
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
    # -------------------------------------------------------------------------
    log "1. 종속성 라이브러리 설치"
    sudo apt-get update
    sudo apt install -y git bc bison flex libssl-dev make libc6-dev libncurses5-dev zip

    # -------------------------------------------------------------------------
    log "2. 64bit 커널 빌드용 툴체인 설치"
    sudo apt install -y crossbuild-essential-arm64
    command -v ${CROSS_COMPILE}gcc >/dev/null || err "${CROSS_COMPILE}gcc 를 찾을 수 없습니다."

    # -------------------------------------------------------------------------
    log "3. 커널 소스 다운로드 ($LINUX_DIR)"
    if [ -d "$LINUX_DIR/.git" ]; then
        echo "이미 소스가 있으므로 clone 을 건너뜁니다. (새로 받으려면 sudo rm -rf $LINUX_DIR)"
    else
        # 네트워크 대역폭 문제로 중간에 멈추는 경우가 있어 최대 3회 재시도
        for i in 1 2 3; do
            echo "git clone 시도 $i/3 ..."
            sudo rm -rf "$LINUX_DIR"
            if sudo git clone --depth=1 "$REPO_URL" "$LINUX_DIR"; then
                break
            fi
            [ "$i" -eq 3 ] && err "git clone 3회 실패. 네트워크를 확인하세요."
            sleep 3
        done
    fi

    cd "$LINUX_DIR"

    # -------------------------------------------------------------------------
    log "4. make config 진행 ($DEFCONFIG)"
    sudo make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE $DEFCONFIG

    # -------------------------------------------------------------------------
    log "5. 커널 빌드 (Image modules dtbs, -j$JOBS)"
    time sudo make -j"$JOBS" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE Image modules dtbs
else
    log "1~5. 빌드 건너뜀 (-s)"
    sudo apt install -y zip >/dev/null
fi

[ -f "$LINUX_DIR/arch/arm64/boot/Image" ] || err "$LINUX_DIR/arch/arm64/boot/Image 가 없습니다. 빌드를 먼저 하세요."
echo "빌드된 커널 버전: $(make -s -C "$LINUX_DIR" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE kernelrelease)"

# -----------------------------------------------------------------------------
log "6. linux 디렉토리 압축 ($ZIP_FILE)"
cd "$SRC_DIR"
sudo rm -f "$ZIP_FILE"
sudo zip -q -r linux.zip linux
ls -lh "$ZIP_FILE"

if [ -z "$PI_IP" ]; then
    log "완료 (IP 미지정 → 전송/설치 생략)"
    echo "전송까지 하려면:  $0 -i <라즈베리파이_IP> -s"
    exit 0
fi

# -----------------------------------------------------------------------------
log "7. 라즈베리파이5로 전송 (scp → $PI:~)"
scp "${SSH_OPTS[@]}" "$ZIP_FILE" "$PI:~"

# -----------------------------------------------------------------------------
log "8~9. 라즈베리파이에서 압축 해제 / 모듈 설치 / 파일 복사"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"   # 호스트 시각으로 Pi 시간 동기화 (clock skew 방지)

ssh -t "${SSH_OPTS[@]}" "$PI" "
set -e
echo '[0] 시간 동기화'
sudo ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime
sudo date -s '$NOW'

command -v unzip >/dev/null || { sudo apt-get update; sudo apt install -y unzip; }

echo '[8] 파일 이동 및 압축 해제'
sudo mv ~/linux.zip /usr/src/
cd /usr/src
sudo unzip -o -q linux.zip
cd /usr/src/linux

echo '[9] 커널 모듈 설치 및 파일 복사'
KERNEL=$KERNEL
if [ -f /boot/firmware/\$KERNEL.img ]; then
    sudo cp /boot/firmware/\$KERNEL.img /boot/firmware/\$KERNEL-backup.img
    echo \"기존 커널 백업: /boot/firmware/\$KERNEL-backup.img\"
fi
sudo make modules_install
sudo cp arch/arm64/boot/dts/broadcom/*.dtb /boot/firmware/
sudo cp arch/arm64/boot/dts/overlays/*.dtb* /boot/firmware/overlays/
sudo cp arch/arm64/boot/dts/overlays/README /boot/firmware/overlays/
sudo cp arch/arm64/boot/Image /boot/firmware/\$KERNEL.img
sync
echo \"설치 완료. 현재 커널: \$(uname -r)\"
"

# -----------------------------------------------------------------------------
if [ "$AUTO_REBOOT" -eq 0 ]; then
    read -r -p "라즈베리파이를 지금 재부팅할까요? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] && AUTO_REBOOT=1
fi

if [ "$AUTO_REBOOT" -eq 1 ]; then
    log "재부팅"
    ssh "${SSH_OPTS[@]}" "$PI" "sudo reboot" || true
    ssh "${SSH_OPTS[@]}" -O exit "$PI" 2>/dev/null || true
    echo "1~2분 뒤 확인:  ssh $PI uname -r   (v8 포함되면 성공)"
else
    echo "나중에:  ssh $PI sudo reboot   →   ssh $PI uname -r"
fi
