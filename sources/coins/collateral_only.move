module leizd::collateral_only {

    use std::string;
    use std::signer;
    use std::option;
    use aptos_framework::coin;
    use aptos_framework::coins;
    use leizd::pool_type::{Asset,Shadow};

    friend leizd::pool;

    struct CollateralOnly<phantom C, phantom P> {
        coin: coin::Coin<C>
    }

    struct Capabilities<phantom C> has key {
        mint_cap: coin::MintCapability<C>,
        burn_cap: coin::BurnCapability<C>
    }

    public(friend) fun initialize<C>(owner: &signer) {
        let prefix_name = b"Leizd Collateral Only ";
        let prefix_symbol = b"co";
        initialize_internal<C,Asset>(owner, prefix_name, prefix_symbol);

        let prefix_name = b"Leizd Shadow Collateral Only ";
        let prefix_symbol = b"sco";
        initialize_internal<C,Shadow>(owner, prefix_name, prefix_symbol);
    }

    fun initialize_internal<C,P>(owner: &signer, prefix_name: vector<u8>, prefix_symbol: vector<u8>) {
      let coin_name = coin::name<C>();
        let coin_symbol = coin::symbol<C>();
        let coin_decimals = coin::decimals<C>();

        string::insert(&mut coin_name, 0, string::utf8(prefix_name));
        string::insert(&mut coin_symbol, 0, string::utf8(prefix_symbol));

        let (mint_cap, burn_cap) = coin::initialize<CollateralOnly<C,P>>(
            owner,
            coin_name,
            coin_symbol,
            coin_decimals,
            true
        );
        move_to(owner, Capabilities<CollateralOnly<C,P>> {
            mint_cap,
            burn_cap,
        });
    }

    public(friend) fun mint<C,P>(account: &signer, amount: u64) acquires Capabilities {
        let account_addr = signer::address_of(account);
        let caps = borrow_global<Capabilities<CollateralOnly<C,P>>>(@leizd);
        if (!coin::is_account_registered<CollateralOnly<C,P>>(account_addr)) {
            coins::register<CollateralOnly<C,P>>(account);
        };

        let coin_minted = coin::mint(amount, &caps.mint_cap);
        coin::deposit(account_addr, coin_minted);
    }

    public(friend) fun burn<C,P>(account: &signer, amount: u64) acquires Capabilities {
        let caps = borrow_global<Capabilities<CollateralOnly<C,P>>>(@leizd);
        
        let coin_burned = coin::withdraw<CollateralOnly<C,P>>(account, amount);
        coin::burn(coin_burned, &caps.burn_cap);
    }

    public entry fun balance_of<C,P>(addr: address): u64 {
        coin::balance<CollateralOnly<C,P>>(addr)
    }

    public entry fun supply<C,P>(): u128 {
        let _supply = coin::supply<CollateralOnly<C,P>>();
        if (option::is_some(&_supply)) {
            *option::borrow<u128>(&_supply)
        } else {
            0
        }
    }
}