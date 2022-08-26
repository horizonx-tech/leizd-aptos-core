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
        stb_usdz::mint(signer::address_of(account), amount);
    }

    public entry fun withdraw(account: &signer, amount: u64) acquires StabilityPool {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);

        coin::deposit(signer::address_of(account), coin::extract(&mut pool_ref.shadow, amount));
        pool_ref.total_deposited = pool_ref.total_deposited - (amount as u128);
        stb_usdz::burn(account, amount);
    }

    public(friend) entry fun borrow<C>(amount: u64): coin::Coin<USDZ> acquires StabilityPool, Balance {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        let balance_ref = borrow_global_mut<Balance<C>>(@leizd);

        balance_ref.total_borrowed = balance_ref.total_borrowed + (amount as u128);
        coin::extract<USDZ>(&mut pool_ref.shadow, amount)
    }

    public(friend) entry fun repay<C>(shadow: coin::Coin<USDZ>) acquires StabilityPool, Balance {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        let balance_ref = borrow_global_mut<Balance<C>>(@leizd);

        let amount = (coin::value<USDZ>(&shadow) as u128);
        balance_ref.total_borrowed = balance_ref.total_borrowed - amount;
        coin::merge<USDZ>(&mut pool_ref.shadow, shadow);
    }

    public fun balance<C>(): u128 acquires Balance {
        borrow_global<Balance<C>>(@leizd).total_borrowed
    }
}