#!/bin/bash
export OWNER=$(cat .aptos/config.yaml|grep -v -|yq -P .profiles.default.account)
cd leizd-indexer
yarn
export TARGET=$(cat aptos-codegen.json |jq -r |grep money_market|cut -c 6-71)
yarn gen -c aptos-codegen.json
sed -i "s/\"${TARGET}\"/\"$OWNER\"/g" ${pkg}/Move.toml
git add .
git config --global user.email "hide-yoshi@horizonx.tech"
git config --global user.name "hide-yoshi"
git commit -m "update account for ${COMMIT_HASH}"
git push
