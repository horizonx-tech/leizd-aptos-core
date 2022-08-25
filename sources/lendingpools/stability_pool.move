module leizd::stability_pool {

    use aptos_framework::coin;
    use leizd::usdz::{USDZ};

    struct StabilityPool has key {
        shadow: coin::Coin<USDZ>,
    }

    // TODO: stability pool logic

    struct StabilityStorage has key {
        total_deposits: u128,
        total_borrows: u128,
    }

    public entry fun initialize(owner: &signer) {
        move_to(owner, StabilityPool {
            shadow: coin::zero<USDZ>(),
        });
    }

    public entry fun deposit(account: &signer, amount: u64) acquires StabilityPool {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        coin::merge(&mut pool_ref.shadow, coin::withdraw<USDZ>(account, amount));
    }
}