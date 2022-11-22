#!bin/bash
expect -c "
spawn aptos init --rest-url https://fullnode.devnet.aptoslabs.com/v1 --faucet-url https://faucet.devnet.aptoslabs.com/ --assume-yes
expect \"Choose network from\"  
send \"custom\n\" 
expect \"Enter your private key as a hex literal\"  
send \"\n\"
expect \"$\"
exit 0
"
