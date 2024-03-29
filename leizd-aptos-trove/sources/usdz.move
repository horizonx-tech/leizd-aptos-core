module leizd_aptos_trove::usdz {
    
    use std::string;
    use aptos_std::signer;
    use leizd_aptos_trove::coin_base_usdz;
    use aptos_framework::coin::{Coin};

    friend leizd_aptos_trove::trove;

    struct USDZ has key, store {}

    public(friend) fun initialize(owner: &signer) {
        coin_base_usdz::initialize<USDZ>(
            owner,
            string::utf8(b"USDZ"),
            string::utf8(b"USDZ"),
            8,
        );
    }

    public(friend) fun mint(account: &signer, amount: u64) {
        mint_internal(signer::address_of(account), amount);
    }

    fun mint_internal(account_addr: address, amount: u64) {
        coin_base_usdz::mint<USDZ>(account_addr, amount);
    }

    public(friend) fun burn_from(account: &signer, amount: u64) {
        coin_base_usdz::burn_from<USDZ>(account, amount);
    }

    public(friend) fun burn(coin: Coin<USDZ>) {
        coin_base_usdz::burn<USDZ>(coin)
    }

    public fun balance_of(owner: address): u64 {
        coin_base_usdz::balance_of<USDZ>(owner)
    }

    public fun supply(): u128 {
        coin_base_usdz::supply<USDZ>()
    }

    #[test_only]
    public fun initialize_for_test(owner: &signer) {
        initialize(owner);
    }
    #[test_only]
    public fun mint_for_test(account_addr: address, amount: u64) {
        mint_internal(account_addr, amount);
    }
}
