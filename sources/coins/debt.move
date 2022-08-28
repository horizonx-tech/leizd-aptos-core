module leizd::debt {
    use std::string;
    use aptos_framework::coin;
    use leizd::pool_type::{Asset,Shadow};
    use leizd::coin_base;

    friend leizd::pool;

    const E_NOT_INITIALIZED: u64 = 1;

    struct Debt<phantom C, phantom P> {
        coin: coin::Coin<C>
    }

    public(friend) fun initialize<C>(owner: &signer) {
        initialize_internal<C>(owner);
    }

    fun initialize_internal<C>(owner: &signer) {
        // TODO: should not be initialized based on aptos_framework::coin to prevent it from transferring to others
        assert!(coin::is_coin_initialized<C>(), E_NOT_INITIALIZED);

        let coin_name = coin::name<C>();
        let coin_symbol = coin::symbol<C>();
        let coin_decimals = coin::decimals<C>();

        let name = string::utf8(b"Leizd Debt ");
        let symbol = string::utf8(b"d");
        string::append(&mut name, coin_name);
        string::append(&mut symbol, coin_symbol);
        coin_base::initialize<Debt<C,Asset>>(owner, name, symbol, coin_decimals);

        let name = string::utf8(b"Leizd Shadow Debt ");
        let symbol = string::utf8(b"sd");
        string::append(&mut name, coin_name);
        string::append(&mut symbol, coin_symbol);
        coin_base::initialize<Debt<C,Shadow>>(owner, name, symbol, 18);
    }

    public fun register<C>(account: &signer) {
        coin_base::register<Debt<C,Asset>>(account);
        coin_base::register<Debt<C,Shadow>>(account);
    }

    public(friend) fun mint<C,P>(minter_addr: address, amount: u64) {
        coin_base::mint<Debt<C,P>>(minter_addr, amount);
    }

    public(friend) fun burn<C,P>(account: &signer, amount: u64) {
        coin_base::burn<Debt<C,P>>(account, amount);
    }

    public entry fun balance_of<C,P>(addr: address): u64 {
        coin_base::balance_of<Debt<C,P>>(addr)
    }

    public entry fun supply<C,P>(): u128 {
        coin_base::supply<Debt<C,P>>()
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd::test_common::{Self,WETH};
    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_std::comparator;

    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_initialize_debt_coins(owner: signer) {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        test_common::init_weth(&owner);
        initialize_internal<WETH>(&owner);
        
        assert!(comparator::is_equal(&comparator::compare(
            string::bytes(&coin::name<Debt<WETH,Asset>>()),
            &b"Leizd Debt WETH"
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            string::bytes(&coin::symbol<Debt<WETH,Asset>>()),
            &b"dWETH"
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            &coin::decimals<Debt<WETH,Asset>>(),
            &coin::decimals<WETH>()
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            string::bytes(&coin::name<Debt<WETH,Shadow>>()),
            &b"Leizd Shadow Debt WETH"
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            string::bytes(&coin::symbol<Debt<WETH,Shadow>>()),
            &b"sdWETH"
        )), 0);
        assert!(comparator::is_equal(&comparator::compare(
            &coin::decimals<Debt<WETH,Shadow>>(),
            &18
        )), 0);
    }
}