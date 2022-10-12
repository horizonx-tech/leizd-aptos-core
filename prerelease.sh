#!/bin/sh
export OWNER=$(cat .aptos/config.yaml|grep -v -|yq -P .profiles.default.account)
aptos account fund-with-faucet --account ${OWNER} --amount 100000000000
for pkg in `ls | grep leizd-aptos`; do sed -i "s/\"0x0123456789ABCDEF\"/\"$OWNER\"/g" ${pkg}/Move.toml; done
for pkg in `ls | grep leizd-aptos`; do aptos move compile --package-dir ${pkg} ; done
