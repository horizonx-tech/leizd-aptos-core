#!/bin/sh
sed -i "s/\"PRIVATE_KEY\"/\"$TEST_PRIVATE_KEY\"/g" .aptos/config.test.yaml
cp .aptos/config.test.yaml .aptos/config.yaml
aptos account fund-with-faucet --account default
export OWNER=b63e63d9526b03248c6b4d9ada14020e6d15923d67c5ecbf98b9a5f163e60b5e
for pkg in `ls | grep leizd-aptos`; do sed -i '' "s/\"0x0123456789ABCDEF\"/\"$OWNER\"/g" ${pkg}/Move.toml; done
for pkg in `ls | grep leizd-aptos`; do aptos move compile --package-dir ${pkg} ; done
