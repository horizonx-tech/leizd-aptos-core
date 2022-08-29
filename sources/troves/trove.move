// TODO: This file and related logic should be moved under `leizd-aptos-stablecoin`
module leizd::trove {
    use aptos_framework::coin;
    use leizd::usdz;
    use leizd::price_oracle;

    struct Trove<phantom C> has key {
        coin: coin::Coin<C>,
    }

    public entry fun initialize(owner: &signer) {
        usdz::initialize(owner);
    }

    public entry fun open_trove<C>(account: &signer, amount: u64) {
        open_trove_internal<C>(account, usdz_amount<C>(amount));
    }

    public entry fun usdz_amount<C>(amount:u64):u64 {
        let price = price_oracle::price<C>();
        let decimals = (coin::decimals<C>() as u64);
        let decimals_usdz = (coin::decimals<usdz::USDZ>() as u64);
        (price * amount) * decimals_usdz / decimals
    }

    fun open_trove_internal<C>(account: &signer, amount: u64) {
        // TODO: active pool -> increate USDZ debt
        usdz::mint(account, amount);

        move_to(account, Trove<C> {
            coin: coin::zero<C>()
        });
    }


    #[test_only]
    fun open_trove_for_test<C>(account: &signer, amount: u64) {
        open_trove_internal<C>(account, amount);
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd::test_common::{Self,USDC};
    #[test_only]
    use aptos_framework::signer;
    #[test_only]
    use aptos_std::comparator;

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_open_trove(owner: signer, account1: signer)  {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        let usdc_amt = 10000;
        let want = usdc_amt * 3;
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_common::init_usdc(&owner);
        managed_coin::register<USDC>(&account1);
        managed_coin::register<usdz::USDZ>(&account1);
        managed_coin::mint<USDC>(&owner, account1_addr, usdc_amt);
        initialize(&owner);
        open_trove<USDC>(&account1, 10000);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &want
        )), 0);
    }

    #[test(owner=@leizd,aptos_framework=@aptos_framework)]
    fun test_usdz_amount(owner: signer)  {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        let usdc_amt = 12345678;
        let usdc_want = usdc_amt * 3;
        test_common::init_usdc(&owner);
        initialize(&owner);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz_amount<USDC>(usdc_amt),
            &usdc_want
        )), 0);
    }

}