#!/bin/sh
sed -i "s/\"TEST_PRIVATE_KEY\"/\"$TEST_PRIVATE_KEY\"/g" .aptos/config.test.yaml
cp .aptos/config.test.yaml .aptos/config.yaml
export OWNER=abfa2e2a861e08a8d6fc34465565e00595913ac1605ef74f9191b7bbc537f759
aptos account fund-with-faucet --account ${OWNER}
for pkg in `ls | grep leizd-aptos`; do sed -i '' "s/\"0x0123456789ABCDEF\"/\"$OWNER\"/g" ${pkg}/Move.toml; done
for pkg in `ls | grep leizd-aptos`; do aptos move compile --package-dir ${pkg} ; done
