module leizd::coin_base {
    use std::string;
    use std::signer;
    use std::option;
    use aptos_framework::coin;
    use leizd_aptos_common::permission;

    friend leizd::usdz;
    friend leizd::stb_usdz;
    
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
        let caps = borrow_global<Capabilities<C>>(permission::owner_address());
        let coin_minted = coin::mint(amount, &caps.mint_cap);
        coin::deposit(minter_addr, coin_minted);
    }

    public(friend) fun burn<C>(account: &signer, amount: u64) acquires Capabilities {
        let caps = borrow_global<Capabilities<C>>(permission::owner_address());
        
        let coin_burned = coin::withdraw<C>(account, amount);
        coin::burn(coin_burned, &caps.burn_cap);
    }

    public fun balance_of<C>(addr: address): u64 {
        coin::balance<C>(addr)
    }

    public fun supply<C>(): u128 {
        let _supply = coin::supply<C>();
        if (option::is_some(&_supply)) {
            *option::borrow<u128>(&_supply)
        } else {
            0
        }
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    struct Dummy {}
    #[test(owner = @leizd, account = @0x111)]
    fun test_end_to_end(owner: &signer, account: &signer) acquires Capabilities {
        let owner_address = signer::address_of(owner);
        let account_address = signer::address_of(account);
        account::create_account_for_test(owner_address);
        account::create_account_for_test(account_address);
        initialize<Dummy>(
            owner,
            string::utf8(b"Dummy"),
            string::utf8(b"DUMMY"),
            18
        );
        assert!(exists<Capabilities<Dummy>>(owner_address), 0);

        register<Dummy>(account);
        
        assert!(supply<Dummy>() == 0, 0);
        assert!(balance_of<Dummy>(account_address) == 0, 0);

        mint<Dummy>(account_address, 100);
        assert!(supply<Dummy>() == 100, 0);
        assert!(balance_of<Dummy>(account_address) == 100, 0);

        burn<Dummy>(account, 50);
        assert!(supply<Dummy>() == 50, 0);
        assert!(balance_of<Dummy>(account_address) == 50, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_initialize_with_not_owner(account: &signer) {
        account::create_account_for_test(signer::address_of(account));
        initialize<Dummy>(
            account,
            string::utf8(b"Dummy"),
            string::utf8(b"DUMMY"),
            18
        );
    }
}