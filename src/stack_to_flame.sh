#!/bin/sh

me="$(dirname $0)"

TARGET_FILE=$1
TARGET_NAME="${TARGET_FILE/.out/}"
TARGET_NAME="${TARGET_NAME##*/}"
OUT_FILE="flame_${TARGET_NAME}.svg"
cat ${TARGET_FILE} | $me/flamegraph.pl --countname="nanosecond" > ${OUT_FILE}
echo "=> ${OUT_FILE}"
