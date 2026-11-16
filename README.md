# raspberrypi-kernel

Raspberry Pi 5 커널을 **Ubuntu에서 크로스 컴파일**하고, 라즈베리파이로 전송·설치까지 한 번에 하는 스크립트입니다.

| 항목 | 내용 |
|---|---|
| 빌드 호스트 | Ubuntu 22.04 (VirtualBox VM 가능) |
| 타깃 | Raspberry Pi 5 (BCM2712, `kernel_2712`, 64bit) |
| 툴체인 | `crossbuild-essential-arm64` (`aarch64-linux-gnu-`) |
| 커널 소스 | <https://github.com/raspberrypi/linux> |

## 빠른 시작

Ubuntu(VM)에서:

```bash
git clone https://github.com/jykim130/raspberrypi-kernel.git
cd raspberrypi-kernel
chmod +x rpi5_cross_build.sh
./rpi5_cross_build.sh -i 192.168.0.132      # 라즈베리파이 IP
```

끝나고 재부팅한 뒤 1~2분 후:

```bash
ssh pi@192.168.0.132 uname -r               # 결과에 v8 이 들어 있으면 성공
```

## 옵션

```
./rpi5_cross_build.sh [-i IP] [-u USER] [-j N] [-s] [-r] [-h]
```

| 옵션 | 설명 |
|---|---|
| `-i IP` | 라즈베리파이 IP. 넣으면 빌드 후 **전송 + 원격 설치**까지 진행. 생략하면 빌드/압축까지만 |
| `-u USER` | 라즈베리파이 사용자명 (기본 `pi`) |
| `-j N` | 빌드 병렬 작업 수 (기본: CPU 코어 수) |
| `-s` | 빌드 건너뛰기 — 이미 빌드된 소스를 압축/전송/설치만 |
| `-r` | 설치 후 묻지 않고 바로 재부팅 |
| `-h` | 도움말 |

### 예시

```bash
./rpi5_cross_build.sh                               # 빌드 + 압축만 (/usr/src/linux.zip)
./rpi5_cross_build.sh -i 192.168.0.132              # 빌드 → 전송 → 설치 → (재부팅 여부 질문)
./rpi5_cross_build.sh -i 192.168.0.132 -j 8 -r      # 8코어로 빌드, 끝나면 자동 재부팅
./rpi5_cross_build.sh -i 192.168.0.132 -s -r        # 재빌드 없이 다시 설치 (버전이 안 바뀌었을 때)
./rpi5_cross_build.sh -i 192.168.0.50 -u myuser     # 사용자명이 pi 가 아닐 때
```

## 스크립트가 하는 일

**Ubuntu에서**

| 단계 | 내용 |
|---|---|
| 0 | (`-i` 지정 시) 라즈베리파이 ssh 접속 확인 — IP가 틀리면 빌드 전에 바로 중단 |
| 1 | 종속성 설치: `git bc bison flex libssl-dev make libc6-dev libncurses5-dev zip` |
| 2 | 툴체인 설치: `crossbuild-essential-arm64` |
| 3 | `/usr/src/linux` 에 커널 소스 `git clone --depth=1` (실패 시 3회 재시도, 이미 있으면 생략) |
| 4 | `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2712_defconfig` |
| 5 | `make -jN ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image modules dtbs` |
| 6 | `/usr/src/linux.zip` 으로 압축 |
| 7 | `scp` 로 라즈베리파이 `~/linux.zip` 전송 |

**라즈베리파이에서 (ssh 원격 실행)**

| 단계 | 내용 |
|---|---|
| 0 | 시간대 `Asia/Seoul` 설정, 시계를 Ubuntu 시각으로 맞춤 (make clock skew 방지) |
| 8 | `linux.zip` 을 `/usr/src` 로 옮기고 압축 해제 |
| 9 | 기존 `/boot/firmware/kernel_2712.img` 를 `kernel_2712-backup.img` 로 백업 → `make modules_install` → dtb / overlays / README / `Image` 복사 |
| - | 재부팅 (질문 또는 `-r`) |

## 사전 준비 / 주의사항

- **네트워크**: VM에서 `ping <라즈베리파이 IP>` 가 되어야 합니다. 안 되면 VirtualBox 네트워크를 **어댑터에 브리지**로 바꾸고, PC와 라즈베리파이를 같은 공유기에 연결하세요.
- **ssh**: 라즈베리파이에 ssh 가 켜져 있어야 합니다 (`sudo raspi-config` → Interface Options → SSH).
- **비밀번호**: ssh 연결을 재사용하므로 라즈베리파이 비밀번호는 처음 한 번만 묻습니다. Ubuntu `sudo` 비밀번호도 중간에 물을 수 있습니다.
- **디스크**: 소스 + 빌드 결과 + zip 으로 약 10GB 필요합니다.
- **시간**: VM 코어 수에 따라 빌드에 수십 분 걸립니다 (라즈베리파이에서 직접 빌드하는 것보다는 빠름).
- **줄바꿈**: `bad interpreter` 오류가 나면 CRLF 문제입니다 → `sed -i 's/\r$//' rpi5_cross_build.sh`

## 트러블슈팅

**재부팅했는데 `uname -r` 버전이 그대로**
파일 복사가 제대로 안 된 경우입니다. 빌드 없이 다시 설치하세요.

```bash
./rpi5_cross_build.sh -i <IP> -s -r
```

**새 커널로 부팅이 안 됨**
SD카드를 PC에 꽂고 `bootfs` 파티션에서 `kernel_2712-backup.img` 를 `kernel_2712.img` 로 이름을 바꾸면 이전 커널로 돌아갑니다.

**커널 소스를 새로 받고 싶음**

```bash
sudo rm -rf /usr/src/linux
./rpi5_cross_build.sh -i <IP>
```

## 참고

- Raspberry Pi 공식 문서 — The Linux kernel: <https://www.raspberrypi.com/documentation/computers/linux_kernel.html>
