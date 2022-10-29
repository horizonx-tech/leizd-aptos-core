#[test_only]
module leizd_aptos_common::test_coin {

    struct USDC {}
    struct USDT {}
    struct WETH {}
    struct UNI {}
    struct CoinDec10 {}

    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::managed_coin;

    public fun init_usdc(account: &signer) {
        init_coin<USDC>(account, b"USDC", 8); // temp, TOOD: use 6 as decimals
    }

    public fun init_usdt(account: &signer) {
        init_coin<USDT>(account, b"USDT", 8); // temp, TOOD: use 6 as decimals
    }

    public fun init_weth(account: &signer) {
        init_coin<WETH>(account, b"WETH", 8);
    }

    public fun init_uni(account: &signer) {
        init_coin<UNI>(account, b"UNI", 8);
    }

    public fun init_coin_dec_10(account: &signer) {
        init_coin<CoinDec10>(account, b"DEC10", 10);
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

    // utilities
    public fun mint_and_withdraw<CoinType>(
        account: &signer,
        amount: u64,
    ): coin::Coin<CoinType> {
        let account_addr = signer::address_of(account);
        managed_coin::mint<CoinType>(account, account_addr, amount);
        coin::withdraw<CoinType>(account, amount)
    }
}
