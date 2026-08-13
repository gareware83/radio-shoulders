#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/zybo-br-tree"

echo "=== Building Zybo Z7-20 image ==="
make -C ../buildroot/ O="$(pwd)/output-zybo" BR2_EXTERNAL="$(pwd)" zybo_z720_defconfig
make -C ../buildroot/ O="$(pwd)/output-zybo" BR2_EXTERNAL="$(pwd)"

echo "=== Building PYNQ-Z1 image ==="
make -C ../buildroot/ O="$(pwd)/output-pynq" BR2_EXTERNAL="$(pwd)" pynq_z1_defconfig
make -C ../buildroot/ O="$(pwd)/output-pynq" BR2_EXTERNAL="$(pwd)"

echo "=== Done ==="
echo "Zybo images: $(pwd)/output-zybo/images/"
echo "PYNQ images: $(pwd)/output-pynq/images/"
