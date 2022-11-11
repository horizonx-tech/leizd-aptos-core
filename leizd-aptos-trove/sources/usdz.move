module leizd_aptos_trove::usdz {
    
    use std::string;
    use aptos_std::signer;
    use leizd_aptos_trove::coin_base_usdz;
    use aptos_framework::coin::{Self, Coin};

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

    public(friend) fun mint_for(account: &signer, amount: u64) {
        mint_for_internal(signer::address_of(account), amount);
    }

    public(friend) fun mint(amount: u64): Coin<USDZ> {
        coin_base_usdz::mint<USDZ>(amount)
    }

    fun mint_for_internal(account_addr: address, amount: u64) {
        coin_base_usdz::mint_for<USDZ>(account_addr, amount);
    }

    public(friend) fun burn_from(account: &signer, amount: u64) {
        coin_base_usdz::burn_from<USDZ>(account, amount);
    }

    public(friend) fun burn(coin: Coin<USDZ>) {
        coin_base_usdz::burn<USDZ>(coin)
    }

    public entry fun balance_of(owner: address): u64 {
        coin_base_usdz::balance_of<USDZ>(owner)
    }

    public entry fun supply(): u128 {
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
