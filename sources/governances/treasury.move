module leizd::treasury {

    use aptos_framework::coin;
    use leizd::zusd::{ZUSD};

    friend leizd::pool;

    const DECIMAL_PRECISION: u128 = 1000000000000000000;

    struct Treasury<phantom C> has key {
        asset: coin::Coin<C>,
        shadow: coin::Coin<ZUSD>,
    }

    public(friend) fun initialize<C>(owner: &signer) {
        move_to(owner, Treasury<C> {
            asset: coin::zero<C>(),
            shadow: coin::zero<ZUSD>()
        });
    }

    public(friend) fun collect_asset_fee<C>(coin: coin::Coin<C>) acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(@leizd);
        coin::merge<C>(&mut treasury_ref.asset, coin);
    }

    public(friend) fun collect_shadow_fee<C>(coin: coin::Coin<ZUSD>) acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(@leizd);
        coin::merge<ZUSD>(&mut treasury_ref.shadow, coin);
    }
}