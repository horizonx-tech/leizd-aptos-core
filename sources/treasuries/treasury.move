module leizd::treasury {

    use std::signer;
    use aptos_framework::coin;
    use leizd::usdz::{USDZ};
    use leizd::permission;

    friend leizd::pool;

    struct Treasury<phantom C> has key {
        asset: coin::Coin<C>,
        shadow: coin::Coin<USDZ>,
    }

    public(friend) fun initialize<C>(owner: &signer) {
        move_to(owner, Treasury<C> {
            asset: coin::zero<C>(),
            shadow: coin::zero<USDZ>()
        });
    }

    public(friend) fun collect_asset_fee<C>(coin: coin::Coin<C>) acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(@leizd);
        coin::merge<C>(&mut treasury_ref.asset, coin);
    }

    public(friend) fun collect_shadow_fee<C>(coin: coin::Coin<USDZ>) acquires Treasury {
        let treasury_ref = borrow_global_mut<Treasury<C>>(@leizd);
        coin::merge<USDZ>(&mut treasury_ref.shadow, coin);
    }

    public entry fun withdraw_asset_fee<C>(owner: &signer, amount: u64) acquires Treasury {
        permission::assert_owner(signer::address_of(owner));

        let treasury_ref = borrow_global_mut<Treasury<C>>(@leizd);
        let deposited = coin::extract(&mut treasury_ref.asset, amount);
        coin::deposit<C>(signer::address_of(owner), deposited);
    }

    public entry fun withdraw_shadow_fee<C>(owner: &signer, amount: u64) acquires Treasury {
        permission::assert_owner(signer::address_of(owner));

        let treasury_ref = borrow_global_mut<Treasury<C>>(@leizd);
        let deposited = coin::extract(&mut treasury_ref.shadow, amount);
        coin::deposit<USDZ>(signer::address_of(owner), deposited);
    }
}