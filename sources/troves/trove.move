// TODO: This file and related logic should be moved under `leizd-aptos-stablecoin`
module leizd::trove {

    use aptos_framework::coin;
    use leizd::usdz;

    struct Trove<phantom C> has key {
        coin: coin::Coin<C>,
    }

    public entry fun initialize(owner: &signer) {
        usdz::initialize(owner);
    }

    public entry fun open_trove<C>(account: &signer, amount: u64) {

        // TODO: active pool -> increate USDZ debt
        usdz::mint(account, amount);
        
        move_to(account, Trove<C> {
            coin: coin::zero<C>()
        });
    }
}