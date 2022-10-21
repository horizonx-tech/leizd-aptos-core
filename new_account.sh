#!bin/bash
expect -c "
spawn aptos init --rest-url https://aptos-testnet.ml/v1 --faucet-url https://faucet.aptos-testnet.ml/ --assume-yes
expect \"Choose network from\"  
send \"custom\n\" 
expect \"Enter your private key as a hex literal\"  
send \"\n\"
expect \"$\"
exit 0
"
