#!/bin/sh
#sed -i "s/\"TEST_PRIVATE_KEY\"/\"$TEST_PRIVATE_KEY\"/g" .aptos/config.test.yaml
cp .aptos/config.test.yaml .aptos/config.yaml
export OWNER=0d0f80691ec91cdb044db41a46bd88efa30dab982c8698f5afe87d41f303d2fe
aptos account fund-with-faucet --account ${OWNER} --amount 100000000000
for pkg in `ls | grep leizd-aptos`; do sed -i "s/\"0x0123456789ABCDEF\"/\"$OWNER\"/g" ${pkg}/Move.toml; done
for pkg in `ls | grep leizd-aptos`; do aptos move compile --package-dir ${pkg} ; done
