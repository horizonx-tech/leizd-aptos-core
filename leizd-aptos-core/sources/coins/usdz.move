module leizd::usdz {
    
    use std::string;
    use aptos_std::signer;
    use leizd::coin_base;

    friend leizd::trove;

    struct USDZ has key, store {}

    public(friend) fun initialize(owner: &signer) {
        coin_base::initialize<USDZ>(
            owner,
            string::utf8(b"USDZ"),
            string::utf8(b"USDZ"),
            18,
        );
    }

    public(friend) fun mint(account: &signer, amount: u64) {
        mint_internal(signer::address_of(account), amount);
    }

    fun mint_internal(account_addr: address, amount: u64) {
        coin_base::mint<USDZ>(account_addr, amount);
    }

    public(friend) fun burn(account: &signer, amount: u64) {
        coin_base::burn<USDZ>(account, amount);
    }

    public entry fun balance_of(owner: address): u64 {
        coin_base::balance_of<USDZ>(owner)
    }

    public entry fun supply(): u128 {
        coin_base::supply<USDZ>()
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
