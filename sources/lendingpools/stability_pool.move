module leizd::stability_pool {

    use std::signer;
    use aptos_framework::coin;
    use leizd::usdz::{USDZ};
    use leizd::stb_usdz;

    friend leizd::pool;

    struct StabilityPool has key {
        shadow: coin::Coin<USDZ>,
        total_deposited: u128,
    }

    struct Balance<phantom C> has key {
        total_borrowed: u128,
    }

    public entry fun initialize(owner: &signer) {
        stb_usdz::initialize(owner);
        move_to(owner, StabilityPool {
            shadow: coin::zero<USDZ>(),
            total_deposited: 0
        });
    }

    public entry fun init_pool<C>(owner: &signer) {
        move_to(owner, Balance<C> {
            total_borrowed: 0
        });
    }

    public entry fun deposit(account: &signer, amount: u64) acquires StabilityPool {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        
        coin::merge(&mut pool_ref.shadow, coin::withdraw<USDZ>(account, amount));
        pool_ref.total_deposited = pool_ref.total_deposited + (amount as u128);
        if (!stb_usdz::is_account_registered(signer::address_of(account))) {
            stb_usdz::register(account);
        };
        stb_usdz::mint(signer::address_of(account), amount);
    }

    public entry fun withdraw(account: &signer, amount: u64) acquires StabilityPool {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);

        coin::deposit(signer::address_of(account), coin::extract(&mut pool_ref.shadow, amount));
        pool_ref.total_deposited = pool_ref.total_deposited - (amount as u128);
        stb_usdz::burn(account, amount);
    }

    public(friend) entry fun borrow<C>(amount: u64): coin::Coin<USDZ> acquires StabilityPool, Balance {
        borrow_internal<C>(amount)
    }

    fun borrow_internal<C>(amount: u64): coin::Coin<USDZ> acquires StabilityPool, Balance {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        let balance_ref = borrow_global_mut<Balance<C>>(@leizd);

        balance_ref.total_borrowed = balance_ref.total_borrowed + (amount as u128);
        coin::extract<USDZ>(&mut pool_ref.shadow, amount)
    }

    public(friend) entry fun repay<C>(shadow: coin::Coin<USDZ>) acquires StabilityPool, Balance {
        repay_internal<C>(shadow)
    }

    fun repay_internal<C>(shadow: coin::Coin<USDZ>) acquires StabilityPool, Balance {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        let balance_ref = borrow_global_mut<Balance<C>>(@leizd);

        let amount = (coin::value<USDZ>(&shadow) as u128);
        balance_ref.total_borrowed = balance_ref.total_borrowed - amount;
        coin::merge<USDZ>(&mut pool_ref.shadow, shadow);
    }

    public fun balance(): u128 acquires StabilityPool {
        (coin::value<USDZ>(&borrow_global<StabilityPool>(@leizd).shadow) as u128)
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_common::{Self,WETH};
    #[test_only]
    use leizd::usdz;
    #[test_only]
    use leizd::initializer;
    #[test_only]
    use aptos_framework::account;


    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_to_stability_pool(owner: signer, account1: signer) acquires StabilityPool {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);

        test_common::init_weth(&owner);
        initializer::initialize(&owner);
        initializer::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        initializer::register<USDZ>(&account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(&owner); // stability pool
        init_pool<WETH>(&owner);
                
        deposit(&account1, 400000);
        assert!(balance() == 400000, 0);
    }

}