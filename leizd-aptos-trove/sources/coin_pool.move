module leizd_aptos_trove::coin_pool {

    use aptos_framework::coin::{Self, Coin};
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::usdz::{USDZ};
    friend leizd_aptos_trove::trove;

    struct CollateralPool<phantom C> has key {
        active_coin: Coin<C>,
        default_coin: Coin<C>,
    }

    struct USDZPool has key {
        active_amount: u64,
        default_amount: u64,
        gas_compensation: Coin<USDZ>
    }

    public(friend) fun initialize(owner: &signer) {
        move_to<USDZPool>(owner, USDZPool {
            active_amount: 0,
            default_amount: 0,
            gas_compensation: coin::zero<USDZ>(),
        })
    }

    public(friend) fun add_supported_coin<C>(owner: &signer) {
        move_to<CollateralPool<C>>(owner, CollateralPool {
            active_coin: coin::zero<C>(),
            default_coin: coin::zero<C>(),
        });
    }

    public(friend) fun move_pending_trove_rewards_to_active_pool<C>(account: &signer, usdz: u64, amount: u64) acquires CollateralPool, USDZPool {
        decrease_default_debt(usdz);
        increase_active_debt(usdz);
        deposit_to_active_pool<C>(account, amount)
    }

    public fun active_collateral_amount<C>(): u64 acquires CollateralPool {
        coin::value(&borrow_global<CollateralPool<C>>(permission::owner_address()).active_coin)
    }

    public fun default_collateral_amount<C>(): u64 acquires CollateralPool {
        coin::value(&borrow_global<CollateralPool<C>>(permission::owner_address()).active_coin)
    }

    public fun active_usdz_amount(): u64 acquires USDZPool {
        borrow_global<USDZPool>(permission::owner_address()).active_amount
    }

    public fun default_usdz_amount(): u64 acquires USDZPool {
        borrow_global<USDZPool>(permission::owner_address()).active_amount
    }

    public(friend) fun move_collateral_to_active_pool<C>(amount: u64) acquires CollateralPool {
        let pool = borrow_global_mut<CollateralPool<C>>(permission::owner_address());
        coin::merge(&mut pool.active_coin, coin::extract(&mut pool.default_coin, amount))
    }

    public(friend) fun move_collateral_to_default_pool<C>(amount: u64) acquires CollateralPool {
        let pool = borrow_global_mut<CollateralPool<C>>(permission::owner_address());
        move_coin(&mut pool.default_coin, &mut pool.active_coin, amount)
    }

    public(friend) fun send_gas_compensation(coin: Coin<USDZ>) acquires USDZPool {
        let pool = borrow_global_mut<USDZPool>(permission::owner_address());
        pool.active_amount = pool.active_amount + coin::value<USDZ>(&coin);
        coin::merge<USDZ>(&mut pool.gas_compensation, coin);
    }


    public(friend) fun increase_active_debt(amount: u64) acquires USDZPool {
        let pool = borrow_global_mut<USDZPool>(permission::owner_address());
        pool.active_amount = pool.active_amount + amount
    }

    public(friend) fun increase_default_debt(amount: u64) acquires USDZPool {
        let pool = borrow_global_mut<USDZPool>(permission::owner_address());
        pool.default_amount = pool.default_amount + amount
    }

    public(friend) fun decrease_active_debt(amount: u64) acquires USDZPool {
        let pool = borrow_global_mut<USDZPool>(permission::owner_address());
        pool.active_amount = pool.active_amount - amount
    }

    public(friend) fun decrease_default_debt(amount: u64) acquires USDZPool {
        let pool = borrow_global_mut<USDZPool>(permission::owner_address());
        pool.default_amount = pool.default_amount - amount
    }

    public(friend) fun deposit_to_active_pool<C>(account: &signer, amount: u64) acquires CollateralPool {
        deposit<C>(account, amount, &mut borrow_global_mut<CollateralPool<C>>(permission::owner_address()).active_coin)
    }

    public(friend) fun send_from_active_pool<C>(to: address, amount: u64) acquires CollateralPool {
        withdraw<C>(to, amount, &mut borrow_global_mut<CollateralPool<C>>(permission::owner_address()).active_coin)
    }

    fun move_coin<C>(from: &mut Coin<C>, to: &mut Coin<C>, amount: u64) {
        coin::merge(to, coin::extract(from, amount))
    }

    fun deposit<C>(account: &signer, amount: u64, to: &mut Coin<C>) {
        coin::merge<C>(to, coin::withdraw<C>(account, amount))
    }
    
    fun withdraw<C>(to: address, amount: u64, coin: &mut Coin<C>) {
        coin::deposit<C>(to, coin::extract<C>(coin, amount))
    }


}
