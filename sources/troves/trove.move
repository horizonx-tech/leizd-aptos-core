// TODO: This file and related logic should be moved under `leizd-aptos-stablecoin`
module leizd::trove {
    use aptos_framework::coin;
    use leizd::usdz;
    //use leizd::price_oracle;

    struct Trove<phantom C> has key {
        coin: coin::Coin<C>
    }

    public entry fun initialize(owner: &signer) {
        usdz::initialize(owner);
    }

    public entry fun open_trove<C>(account: &signer, amount: u64) acquires Trove {
        open_trove_internal<C>(account, amount, borrowable_usdz<C>(amount));
    }

    public entry fun close_trove<C>(account: &signer) acquires Trove {
        close_trove_internal<C>(account);
    }

    public entry fun repay<C>(_account: &signer, _amount: u64) {

    }

    public entry fun borrowable_usdz<C>(amount:u64):u64 {
        //let price = price_oracle::price<C>();
        let price = 1;
        let decimals = (coin::decimals<C>() as u64);
        let decimals_usdz = (coin::decimals<usdz::USDZ>() as u64);
        (price * amount) * decimals_usdz / decimals
    }


    fun open_trove_internal<C>(account: &signer, collateral_amount: u64, amount: u64) acquires Trove {
        validate_open_trove<C>(account, amount);
        // TODO: active pool -> increate USDZ debt
        let initialized = exists<Trove<C>>(signer::address_of(account));
        if (!initialized) {
            move_to(account, Trove<C> {
                    coin: coin::zero<C>(),
            });
        };
        let trove = borrow_global_mut<Trove<C>>(signer::address_of(account));
        coin::merge(&mut trove.coin, coin::withdraw<C>(account, collateral_amount));        
        usdz::mint(account, amount);
    }

    fun close_trove_internal<C>(accont: &signer) acquires Trove {
        let trove = borrow_global_mut<Trove<C>>(signer::address_of(accont));
        let balance = coin::value(&trove.coin);
        usdz::burn(accont, borrowable_usdz<C>(balance));
        coin::deposit<C>(signer::address_of(accont), coin::extract(&mut trove.coin, balance));
    }

    fun validate_open_trove<C>(account: &signer, amount: u64) {
        require_valid_max_fee_percentage(account);
        require_trove_is_not_active(account);
        require_at_least_min_net_debt<C>(account, amount);
        let icr = current_collateral_ratio(account);
        if (is_recovery_mode()) {
            require_icr_is_above_ccr(icr);
        } else {
            require_icr_is_above_mcr(icr);
            requir_new_tcr_is_above_ccr(0);
        };
    }


    fun is_recovery_mode(): bool {
        // TODO: implement
        false
    }

    fun require_valid_max_fee_percentage(_account: &signer) {
        // TODO: implement
    }

    fun require_trove_is_not_active(_account: &signer) {
        // TODO: implement
    }

    fun require_at_least_min_net_debt<C>(_account: &signer, _amount: u64) {
        // TODO: implement
    }

    fun new_collateral_ratio<C>(_account: &signer, _amount: u64) :u64 {
        // TODO: implement
        1
    }

    fun current_collateral_ratio(_acccount: &signer): u64 {
        // TODO: implement
        return 1
    }

    fun nominal_collateral_ratio(_account: &signer): u64 {
        // TODO: implement
        1
    }

    fun require_icr_is_above_ccr(_new_icr: u64) {
        // TODO: implement
    }

    fun minimum_collateral_ratio(): u64 {
        // TODO: implement
        1
    }

    fun require_icr_is_above_mcr(_new_icr: u64) {
        // TODO: implement
    }

    fun requir_new_tcr_is_above_ccr(_new_rcr: u64) {
        // TODO: implement
    }


    #[test_only]
    fun open_trove_for_test<C>(account: &signer, amount: u64) acquires Trove {
        open_trove_internal<C>(account, amount, amount);
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd::test_coin::{Self,USDC};
    #[test_only]
    use aptos_framework::signer;
    #[test_only]
    use aptos_std::comparator;

    #[test_only]
    fun set_up(owner: &signer, account1: &signer) {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let usdc_amt = 10000;
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_coin::init_usdc(owner);
        managed_coin::register<USDC>(account1);
        managed_coin::register<usdz::USDZ>(account1);
        managed_coin::mint<USDC>(owner, account1_addr, usdc_amt);
        initialize(owner);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_open_trove(owner: signer, account1: signer) acquires Trove{
        set_up(&owner, &account1);
        let account1_addr = signer::address_of(&account1);
        let usdc_amt = 10000;
        let want = usdc_amt * 3;
        open_trove<USDC>(&account1, 10000);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &want
        )), 0);
        assert!(coin::balance<USDC>(account1_addr) == 0, 0);
        // add more USDC
        managed_coin::mint<USDC>(&owner, account1_addr, 10000);
        open_trove<USDC>(&account1, 10000);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &(want * 2)
        )), 0);
    }


    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_close_trove(owner: signer, account1: signer) acquires Trove {
        set_up(&owner, &account1);
        open_trove<USDC>(&account1, 10000);
        close_trove<USDC>(&account1);
        let account1_addr = signer::address_of(&account1);
        assert!(coin::balance<USDC>(account1_addr) == 10000, 0);
        let trove = borrow_global<Trove<USDC>>(account1_addr);
        assert!(coin::value(&trove.coin) == 0, 0);
    }

    #[test(owner=@leizd,aptos_framework=@aptos_framework)]
    fun test_usdz_amount(owner: signer)  {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        let usdc_amt = 12345678;
        let usdc_want = usdc_amt * 3;
        test_coin::init_usdc(&owner);
        initialize(&owner);
        assert!(comparator::is_equal(&comparator::compare(
            &borrowable_usdz<USDC>(usdc_amt),
            &usdc_want
        )), 0);
    }

}