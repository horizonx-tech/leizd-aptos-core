module leizd::trove {

    use aptos_framework::coin;
    use leizd::zusd;

    struct Trove<phantom C> has key {
        coin: coin::Coin<C>,
    }

    public entry fun initialize(owner: &signer) {
        zusd::initialize(owner);
    }

    public entry fun open_trove<C>(account: &signer, amount: u64) {

        // TODO: active pool -> increate ZUSD debt
        zusd::mint(account, amount);
        
        move_to(account, Trove<C> {
            coin: coin::zero<C>()
        });
    }
}