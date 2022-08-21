module leizd::collateral_only {
    use std::string;
    use aptos_framework::coin;
    use leizd::pool_type::{Asset,Shadow};
    use leizd::coin_base;

    friend leizd::pool;

    const E_NOT_INITIALIZED: u64 = 1;

    struct CollateralOnly<phantom C, phantom P> {
        coin: coin::Coin<C>
    }

    public(friend) fun initialize<C>(owner: &signer) {
        assert!(coin::is_coin_initialized<C>(), E_NOT_INITIALIZED);
        let coin_name = coin::name<C>();
        let coin_symbol = coin::symbol<C>();
        let coin_decimals = coin::decimals<C>();

        let prefix_name = b"Leizd Collateral Only ";
        let prefix_symbol = b"co";
        string::insert(&mut coin_name, 0, string::utf8(prefix_name));
        string::insert(&mut coin_symbol, 0, string::utf8(prefix_symbol));
        coin_base::initialize<CollateralOnly<C,Asset>>(owner, coin_name, coin_symbol, coin_decimals);

        let prefix_name = b"Leizd Shadow Collateral Only ";
        let prefix_symbol = b"sco";
        string::insert(&mut coin_name, 0, string::utf8(prefix_name));
        string::insert(&mut coin_symbol, 0, string::utf8(prefix_symbol));
        coin_base::initialize<CollateralOnly<C,Shadow>>(owner, coin_name, coin_symbol, coin_decimals);
    }

    public fun register<C>(account: &signer) {
        coin_base::register<CollateralOnly<C,Asset>>(account);
        coin_base::register<CollateralOnly<C,Shadow>>(account);
    }

    public(friend) fun mint<C,P>(minter_addr: address, amount: u64) {
        coin_base::mint<CollateralOnly<C,P>>(minter_addr, amount);
    }

    public(friend) fun burn<C,P>(account: &signer, amount: u64) {
        coin_base::burn<CollateralOnly<C,P>>(account, amount);
    }

    public entry fun balance_of<C,P>(addr: address): u64 {
        coin_base::balance_of<CollateralOnly<C,P>>(addr)
    }

    public entry fun supply<C,P>(): u128 {
        coin_base::supply<CollateralOnly<C,P>>()
    }
}