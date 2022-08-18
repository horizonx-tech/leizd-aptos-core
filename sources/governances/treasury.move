module leizd::treasury {

    use std::signer;
    use aptos_framework::coin;
    use leizd::zusd::{ZUSD};

    friend leizd::pool;

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

    public entry fun withdraw_asset_fee<C>(account: &signer, amount: u64) acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(@leizd);
        let deposited = coin::extract(&mut treasury_ref.asset, amount);
        coin::deposit<C>(signer::address_of(account), deposited);
    }

    public entry fun withdraw_shadow_fee<C>(account: &signer, amount: u64) acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(@leizd);
        let deposited = coin::extract(&mut treasury_ref.shadow, amount);
        coin::deposit<ZUSD>(signer::address_of(account), deposited);
    }
}