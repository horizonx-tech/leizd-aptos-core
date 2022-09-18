#!/bin/sh
sed -i "s/\"PRIVATE_KEY\"/\"$TEST_PRIVATE_KEY\"/g" .aptos/config.test.yaml
cp .aptos/config.test.yaml .aptos/config.yaml
export OWNER=e9882582cd52c6ed40a8d205502c2231899f8495a1655d05c0fa135329508b65
aptos account fund-with-faucet --account ${OWNER}
for pkg in `ls | grep leizd-aptos`; do sed -i "s/\"0x0123456789ABCDEF\"/\"$OWNER\"/g" ${pkg}/Move.toml; done
for pkg in `ls | grep leizd-aptos`; do aptos move compile --package-dir ${pkg} ; done
