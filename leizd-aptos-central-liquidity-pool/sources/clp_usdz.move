module leizd_aptos_central_liquidity_pool::clp_usdz {
    
    use std::string;
    use aptos_framework::coin;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_central_liquidity_pool::coin_base_clp_usdz;

    friend leizd_aptos_central_liquidity_pool::central_liquidity_pool;

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
        coin_base_clp_usdz::initialize<StabilityCollateral>(owner, name, symbol, coin_decimals);
    }

    public fun register(account: &signer) {
        coin_base_clp_usdz::register<StabilityCollateral>(account);
    }

    public fun is_account_registered(addr: address): bool {
        coin::is_account_registered<StabilityCollateral>(addr)
    }

    public(friend) fun mint(minter_addr: address, amount: u64) {
        coin_base_clp_usdz::mint<StabilityCollateral>(minter_addr, amount);
    }

    public(friend) fun burn(account: &signer, amount: u64) {
        coin_base_clp_usdz::burn<StabilityCollateral>(account, amount);
    }

    public fun balance_of(addr: address): u64 {
        coin_base_clp_usdz::balance_of<StabilityCollateral>(addr)
    }

    public fun supply(): u128 {
        coin_base_clp_usdz::supply<StabilityCollateral>()
    }
}