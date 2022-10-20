#!/bin/bash
COMMIT_HASH=$1

mkdir leizd-aptos-test/.aptos/
cp .aptos/config.yaml leizd-aptos-test/.aptos/config.devnet.yaml
cd leizd-aptos-test
git checkout dev
git add -f .aptos/config.devnet.yaml 
git config --global user.email "hide-yoshi@horizonx.tech"
git config --global user.name "hide-yoshi"
git commit -m "update account for ${COMMIT_HASH}"
git push
