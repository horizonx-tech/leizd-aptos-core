module leizd::collateral {
    use std::string;
    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::coins;
    use leizd::pool_type::{Asset,Shadow};
    use leizd::coin_base;

    friend leizd::pool;

    struct Collateral<phantom C, phantom P> {
        coin: coin::Coin<C>
    }

    public(friend) fun initialize<C>(owner: &signer) {
        let coin_name = coin::name<C>();
        let coin_symbol = coin::symbol<C>();
        let coin_decimals = coin::decimals<C>();

        let prefix_name = b"Leizd Collateral ";
        let prefix_symbol = b"c";
        string::insert(&mut coin_name, 0, string::utf8(prefix_name));
        string::insert(&mut coin_symbol, 0, string::utf8(prefix_symbol));
        coin_base::initialize<Collateral<C,Asset>>(owner, coin_name, coin_symbol, coin_decimals);

        let prefix_name = b"Leizd Shadow Collateral ";
        let prefix_symbol = b"sc";
        string::insert(&mut coin_name, 0, string::utf8(prefix_name));
        string::insert(&mut coin_symbol, 0, string::utf8(prefix_symbol));
        coin_base::initialize<Collateral<C,Shadow>>(owner, coin_name, coin_symbol, coin_decimals);
    }

    public fun register<C>(account: &signer) {
        let account_addr = signer::address_of(account);
        if (!coin::is_account_registered<Collateral<C,Asset>>(account_addr)) {
            coins::register<Collateral<C,Asset>>(account);
        };
        if (!coin::is_account_registered<Collateral<C,Shadow>>(account_addr)) {
            coins::register<Collateral<C,Shadow>>(account);
        };
    }

    public(friend) fun mint<C,P>(minter_addr: address, amount: u64) {
        coin_base::mint<Collateral<C,P>>(minter_addr, amount);
    }

    public(friend) fun burn<C,P>(account: &signer, amount: u64) {
        coin_base::burn<Collateral<C,P>>(account, amount);
    }

    public entry fun balance_of<C,P>(addr: address): u64 {
        coin_base::balance_of<Collateral<C,P>>(addr)
    }

    public entry fun supply<C,P>(): u128 {
        coin_base::supply<Collateral<C,P>>()
    }
}