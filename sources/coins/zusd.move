module leizd::zusd {
    
    use std::string;
    use aptos_std::signer;
    use aptos_framework::coin::{Self, MintCapability, BurnCapability};
    use aptos_framework::coins;

    friend leizd::trove;

    struct ZUSD has key, store {}

    struct Capabilities<phantom T> has key {
        mint_cap: MintCapability<T>,
        burn_cap: BurnCapability<T>,
    }

    public(friend) fun initialize(owner: &signer) {
        let (mint_cap, burn_cap) = coin::initialize<ZUSD>(
            owner,
            string::utf8(b"ZUSD"),
            string::utf8(b"ZUSD"),
            18,
            true
        );
        move_to(owner, Capabilities<ZUSD> {
            mint_cap,
            burn_cap,
        });
    }

    public(friend) fun mint(account: &signer, amount: u64) acquires Capabilities {
        mint_internal(account, amount);
    }

    fun mint_internal(account: &signer, amount: u64) acquires Capabilities {
        let account_addr = signer::address_of(account);
        if (!coin::is_account_registered<ZUSD>(account_addr)) {
            coins::register<ZUSD>(account);
        };

        let caps = borrow_global<Capabilities<ZUSD>>(@leizd);
        let coin_minted = coin::mint(amount, &caps.mint_cap);
        coin::deposit(account_addr, coin_minted);
    }

    public(friend) fun burn(account: &signer, amount: u64) acquires Capabilities {
        let caps = borrow_global<Capabilities<ZUSD>>(@leizd);
        let coin_burned = coin::withdraw<ZUSD>(account, amount);
        coin::burn(coin_burned, &caps.burn_cap);
    }

    public entry fun balance(owner: address): u64 {
        coin::balance<ZUSD>(owner)
    }

    #[test_only]
    public fun mint_for_test(account: &signer, amount: u64) acquires Capabilities {
        mint_internal(account, amount);
    }
}