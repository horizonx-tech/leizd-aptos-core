// HACK: duplicated to leizd-aptos-core
module leizd_aptos_trove::price_calculator {
    use std::string::{String};
    use leizd_aptos_lib::math128;
    use std::vector::{Self};
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_common::coin_key::{key};
    use aptos_framework::coin;
    use leizd_aptos_trove::usdz::{USDZ};

    struct CoinInfo has copy, drop {
        key: String,
        price: u128,
        decimals: u8,
        amount: u64,
    }

    public fun to_coin_info_of(key: String, amount: u64, price: u128, decimals: u8): CoinInfo {
        CoinInfo {
            key,
            price,
            decimals,
            amount
        }        
    }

    public fun to_current_coin_info<C>(amount: u64): CoinInfo {
        let key = key<C>();
        to_current_coin_info_of(key<C>(), amount)
    }


    public fun to_coin_info<C>(amount: u64, price: u128, decimals: u8): CoinInfo {
        to_coin_info_of(key<C>(), amount, price, decimals)
    }

    public fun to_current_coin_info_of(key: String, amount: u64): CoinInfo {
        let (price, decimals) = price_oracle::price_of(&key);
        to_coin_info_of(key, amount, price, decimals)
    }

    public fun total_amount_in_base_coin(base_coin_decimals: u8, info: &vector<CoinInfo>): u64 {
        let total = 0;
        let i = 0;
        while (i < vector::length<CoinInfo>(info)) {
            let coin = vector::borrow<CoinInfo>(info, i);
            total = total + amount_in_base_coin(base_coin_decimals, *coin);
            i = i + 1
        };
        total
    }

    public fun amount_in_base_coin(base_coin_decimals: u8, info: CoinInfo): u64 {
        let coin = info;
        let decimals = (coin.decimals as u128);
        let numerator = coin.price * (coin.amount as u128) * math128::pow(10, (base_coin_decimals as u128));
        let dominator = (math128::pow(10, decimals * 2));
        (numerator / dominator as u64)
    }

    public fun current_amount_in(usdz_amount: u64, key: String): u64 {
        let (price, _decimals) = price_oracle::price_of(&key);
        let decimals = (_decimals as u128);
        let decimals_usdz = (coin::decimals<USDZ>() as u128);
        let numerator = (usdz_amount as u128) * math128::pow(10, decimals * 2);
        let dominator = (price * math128::pow(10, decimals_usdz));
        (numerator / dominator as u64)
    }

    //#[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    //fun test_current_amount_in(owner: signer, account1: signer, aptos_framework: signer) acquires SupportedCoins {
    //    set_up(&owner, &account1, &aptos_framework);
    //    assert!(comparator::is_equal(&comparator::compare(
    //        &current_amount_in(10000, key_of<USDC>()),
    //        &100
    //    )), current_amount_in(100, key_of<USDC>()));
    //}
    //#[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    //fun test_current_amount_in(owner: signer, account1: signer, aptos_framework: signer) acquires SupportedCoins {
    //    set_up(&owner, &account1, &aptos_framework);
    //    assert!(comparator::is_equal(&comparator::compare(
    //        &price_calculator::current_amount_in(10000, key_of<USDC>()),
    //        &100
    //    )), price_calculator::current_amount_in(100, key_of<USDC>()));
    //}


}
