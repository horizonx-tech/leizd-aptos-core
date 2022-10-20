#[test_only]
module leizd_aptos_common::test_coin {

    struct USDC {}
    struct USDT {}
    struct WETH {}
    struct UNI {}

    use aptos_framework::coin;
    use aptos_framework::managed_coin;

    public fun init_usdc(account: &signer) {
        init_coin<USDC>(account, b"USDC", 6);
    }

    public fun init_usdt(account: &signer) {
        init_coin<USDT>(account, b"USDT", 6);
    }

    public fun init_weth(account: &signer) {
        init_coin<WETH>(account, b"WETH", 18);
    }

    public fun init_uni(account: &signer) {
        init_coin<UNI>(account, b"UNI", 18);
    }

    public fun init_coin<T>(account: &signer, name: vector<u8>, decimals: u8) {
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
