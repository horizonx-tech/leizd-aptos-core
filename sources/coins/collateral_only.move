module leizd::collateral_only {
    use std::string;
    use aptos_framework::coin;
    use leizd::pool_type::{Asset,Shadow};
    use leizd::coin_base;

    friend leizd::pool;

    const E_NOT_INITIALIZED: u64 = 1;

    struct CollateralOnly<phantom C, phantom P> {
        coin: coin::Coin<C>
    }

    public(friend) fun initialize<C>(owner: &signer) {
         initialize_internal<C>(owner);
    }

    fun initialize_internal<C>(owner: &signer) {
        assert!(coin::is_coin_initialized<C>(), E_NOT_INITIALIZED);

        let coin_name = coin::name<C>();
        let coin_symbol = coin::symbol<C>();
        let coin_decimals = coin::decimals<C>();

        let name = string::utf8(b"Leizd Collateral Only ");
        let symbol = string::utf8(b"co");
        string::append(&mut name, coin_name);
        string::append(&mut symbol, coin_symbol);
        coin_base::initialize<CollateralOnly<C,Asset>>(owner, name, symbol, coin_decimals);

        let name = string::utf8(b"Leizd Shadow Collateral Only ");
        let symbol = string::utf8(b"sco");
        string::append(&mut name, coin_name);
        string::append(&mut symbol, coin_symbol);
        coin_base::initialize<CollateralOnly<C,Shadow>>(owner, name, symbol, 18);
    }

    public fun register<C>(account: &signer) {
        coin_base::register<CollateralOnly<C,Asset>>(account);
        coin_base::register<CollateralOnly<C,Shadow>>(account);
    }

    public(friend) fun mint<C,P>(minter_addr: address, amount: u64) {
        coin_base::mint<CollateralOnly<C,P>>(minter_addr, amount);
    }

    public(friend) fun burn<C,P>(account: &signer, amount: u64) {
        coin_base::burn<CollateralOnly<C,P>>(account, amount);
    }

    public entry fun balance_of<C,P>(addr: address): u64 {
        coin_base::balance_of<CollateralOnly<C,P>>(addr)
    }

    public entry fun supply<C,P>(): u128 {
        coin_base::supply<CollateralOnly<C,P>>()
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd::common::{Self,WETH};
    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_std::comparator;

    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_initialize_collateral_only_coins(owner: signer) {
        let owner_addr = signer::address_of(&owner);
        // account::create_account(owner_addr);
        common::init_weth(&owner);
        initialize_internal<WETH>(&owner);
        
        assert!(comparator::is_equal(&comparator::compare(
            string::bytes(&coin::name<CollateralOnly<WETH,Asset>>()),
            &b"Leizd Collateral Only WETH"
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            string::bytes(&coin::symbol<CollateralOnly<WETH,Asset>>()),
            &b"coWETH"
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            &coin::decimals<CollateralOnly<WETH,Asset>>(),
            &coin::decimals<WETH>()
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            string::bytes(&coin::name<CollateralOnly<WETH,Shadow>>()),
            &b"Leizd Shadow Collateral Only WETH"
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            string::bytes(&coin::symbol<CollateralOnly<WETH,Shadow>>()),
            &b"scoWETH"
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            &coin::decimals<CollateralOnly<WETH,Shadow>>(),
            &18
        )), 0);
    }
}