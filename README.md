# ECE436 Wireless Communications — ath9k fairness experiments

Local repository for NITLab Wi-Fi medium-access fairness/unfairness experiments using the Linux backports `ath9k` driver.

## Contents

```text
backports-5.4.56-1/                       Backports driver source tree
backports-5.4.56-1.tar.xz                 Original downloaded kernel.org archive
```

## Source version

The driver source is from the official kernel.org backports stable archive:

```text
https://cdn.kernel.org/pub/linux/kernel/projects/backports/stable/v5.4.56/backports-5.4.56-1.tar.xz
```

## Build/install

```bash
cd backports-5.4.56-1
make defconfig-ath9k
make -j$(nproc)
sudo modprobe -r ath9k ath9k_common ath9k_hw ath mac80211 cfg80211 || true
sudo make install
sudo modprobe ath9k
modinfo ath9k | egrep 'filename|version'
dmesg | tail -100
```
