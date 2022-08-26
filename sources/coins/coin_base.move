module leizd::coin_base {
    use std::string;
    use std::signer;
    use std::option;
    use aptos_framework::coin;
    use leizd::permission;

    friend leizd::collateral;
    friend leizd::collateral_only;
    friend leizd::debt;
    friend leizd::usdz;
    
    struct Capabilities<phantom C> has key {
        burn_cap: coin::BurnCapability<C>,
        freeze_cap: coin::FreezeCapability<C>,
        mint_cap: coin::MintCapability<C>,
    }

    public(friend) fun initialize<C>(owner: &signer, coin_name: string::String, coin_symbol: string::String, coin_decimals: u8) {
        permission::assert_owner(signer::address_of(owner));
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<C>(
            owner,
            coin_name,
            coin_symbol,
            coin_decimals,
            true
        );
        move_to(owner, Capabilities<C> {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    public(friend) fun register<C>(account: &signer) {
        let account_addr = signer::address_of(account);
        if (!coin::is_account_registered<C>(account_addr)) {
            coin::register<C>(account);
        };
    }

    public(friend) fun mint<C>(minter_addr: address, amount: u64) acquires Capabilities {
        assert!(coin::is_account_registered<C>(minter_addr), 0);
        let caps = borrow_global<Capabilities<C>>(@leizd);
        let coin_minted = coin::mint(amount, &caps.mint_cap);
        coin::deposit(minter_addr, coin_minted);
    }

    public(friend) fun burn<C>(account: &signer, amount: u64) acquires Capabilities {
        let caps = borrow_global<Capabilities<C>>(@leizd);
        
        let coin_burned = coin::withdraw<C>(account, amount);
        coin::burn(coin_burned, &caps.burn_cap);
    }

    public entry fun balance_of<C>(addr: address): u64 {
        coin::balance<C>(addr)
    }

    public entry fun supply<C>(): u128 {
        let _supply = coin::supply<C>();
        if (option::is_some(&_supply)) {
            *option::borrow<u128>(&_supply)
        } else {
            0
        }
    }
}