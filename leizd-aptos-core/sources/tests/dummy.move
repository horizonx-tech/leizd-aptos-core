#[test_only]
module leizd::dummy {
    use aptos_framework::coin;
    use aptos_framework::managed_coin;

    struct WETH has key, store {}

    public fun init_weth(account: &signer) {
        init_coin<WETH>(account, b"WETH", 18);
    }

    fun init_coin<T>(account: &signer, name: vector<u8>, decimals: u8) {
        managed_coin::initialize<T>(
            account,
            name,
            name,
            decimals,
            true
        );
        assert!(coin::is_coin_initialized<T>(), 0);
        managed_coin::register<T>(account);
    }
}