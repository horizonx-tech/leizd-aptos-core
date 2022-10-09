#!/bin/bash

git clone https://github.com/horizonx-tech/leizd-aptos-test.git
cp .aptos/config.yaml leizd-aptos-test/.aptos/config.devnet.yaml
cd leizd-aptos-test
git add .aptos/config.devnet.yaml
git commit -m 'update account'
git push
