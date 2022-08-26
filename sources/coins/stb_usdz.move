module leizd::stb_usdz {
    
    use std::string;
    use aptos_framework::coin;
    use leizd::usdz::{USDZ};
    use leizd::coin_base;

    friend leizd::stability_pool;

    struct StabilityCollateral {
        coin: coin::Coin<USDZ>
    }

    public(friend) fun initialize(owner: &signer) {
        initialize_internal(owner);
    }

    fun initialize_internal(owner: &signer) {
        assert!(coin::is_coin_initialized<USDZ>(), 0);

        let coin_name = coin::name<USDZ>();
        let coin_symbol = coin::symbol<USDZ>();
        let coin_decimals = coin::decimals<USDZ>();

        let name = string::utf8(b"Leizd Stabilized Collateral ");
        let symbol = string::utf8(b"stb");
        string::append(&mut name, coin_name);
        string::append(&mut symbol, coin_symbol);
        coin_base::initialize<StabilityCollateral>(owner, name, symbol, coin_decimals);
    }

    public fun register(account: &signer) {
        coin_base::register<StabilityCollateral>(account);
    }

    public(friend) fun mint(minter_addr: address, amount: u64) {
        coin_base::mint<StabilityCollateral>(minter_addr, amount);
    }

    public(friend) fun burn(account: &signer, amount: u64) {
        coin_base::burn<StabilityCollateral>(account, amount);
    }

    public entry fun balance_of(addr: address): u64 {
        coin_base::balance_of<StabilityCollateral>(addr)
    }

    public entry fun supply(): u128 {
        coin_base::supply<StabilityCollateral>()
    }
}